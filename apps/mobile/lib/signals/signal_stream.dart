import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../prediction/prediction.dart';
import 'clock_calibration.dart';
import 'signal_target.dart';

class SignalReading {
  const SignalReading(
      {required this.signalState,
      required this.remainingMs,
      required this.sourceEventKey,
      required this.sourceObservedAtUtcMs});
  final SignalState signalState;
  final IntervalMs remainingMs;
  final String sourceEventKey;
  final int sourceObservedAtUtcMs;
}

class _SourceLifetime {
  int observedAt = -1;
  String? eventKey;
  MonotonicSignalDeadline? deadline;
  SignalState state = SignalState.unknown;
  bool revoked = true;
}

/// One owner per drive session. Every reconnect starts a new HTTP clock exchange
/// and full subscription. Neither transport order nor reconnection renews source
/// evidence. Limits are fail-closed: five retries, 16KiB frames and 128 source
/// targets. Each target retains only its source timestamp high-water mark and
/// current event identity, never an accumulating history of source events.
class SignalStreamController extends ChangeNotifier {
  SignalStreamController(
      {required this.baseUri,
      required this.policy,
      required this.monotonicNow,
      DateTime Function()? utcNow,
      this.syntheticFixture = false})
      : utcNow = utcNow ?? DateTime.now;

  final Uri baseUri;
  final PredictionPolicy policy;
  final int Function() monotonicNow;
  final DateTime Function() utcNow;
  final bool syntheticFixture;
  final Map<String, _SourceLifetime> _sources = {};
  SignalTarget? _target;
  _SourceLifetime? _source;
  ClockCalibration? _clock;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  http.Client? _http;
  Timer? _retryTimer;
  Timer? _expiryTimer;
  Timer? _clockTimer;
  Timer? _snapshotTimer;
  bool _disposed = false;
  bool _foreground = true;
  bool _connected = false;
  int _generation = 0;
  int _requestCounter = 0;
  int _retries = 0;
  int _sequence = 0;
  String? _epoch;
  String? _requestId;
  String? _reason = 'NO_TARGET';

  bool get isConnected => !_disposed && _foreground && _connected;
  String? get unavailableReason {
    if (_source?.revoked == false && reading == null) return 'SIGNAL_EXPIRED';
    return _reason;
  }

  /// Freshness is checked on access as well as by the expiry timer, so a stalled
  /// event loop can never expose stale state while waiting for timer delivery.
  SignalReading? get reading {
    final source = _source;
    final clock = _clock;
    if (!isConnected || source == null || source.revoked || clock == null) {
      return null;
    }
    final now = monotonicNow();
    if (!clock.isValidAt(
        monotonicMs: now, utcMs: utcNow().millisecondsSinceEpoch)) {
      source.revoked = true;
      _reason = 'CLOCK_UNCERTAIN';
      return null;
    }
    source.deadline = source.deadline?.advanceTo(now);
    final remaining = source.deadline?.remainingMs;
    if (remaining == null) return null;
    return SignalReading(
        signalState: source.state,
        remainingMs: remaining,
        sourceEventKey: source.deadline!.eventKey!,
        sourceObservedAtUtcMs: source.observedAt);
  }

  bool get _authorized =>
      policy.isValid &&
      (policy.syntheticFixtureOnly
          ? syntheticFixture && kDebugMode
          : policy.approvedForOperation == true);
  bool get _active =>
      !_disposed && _foreground && _target != null && _authorized;
  bool _current(int generation) => _active && generation == _generation;

  Future<void> selectTarget(SignalTarget? target) async {
    if (_disposed || _target == target) return;
    final closing = _reset(target == null ? 'NO_TARGET' : 'CONNECTING');
    _target = target;
    _source = null;
    _retries = 0;
    if (target != null) {
      if (!_validTarget(target)) {
        _reason = 'TARGET_INVALID';
      } else if (!_authorized) {
        _reason = 'POLICY_UNCALIBRATED';
      } else {
        final key = jsonEncode([
          target.provider,
          target.intersectionKey,
          target.approachKey,
          target.movement,
          target.catalogVersion
        ]);
        if (!_sources.containsKey(key) && _sources.length >= 128) {
          _reason = 'SOURCE_LIMIT';
        } else {
          _source = _sources.putIfAbsent(key, _SourceLifetime.new);
          if (_foreground) unawaited(_connect(_generation));
        }
      }
    }
    notifyListeners();
    await closing;
  }

  void setForeground(bool value) {
    if (_disposed || _foreground == value) return;
    _foreground = value;
    unawaited(_reset(
        value ? (_target == null ? 'NO_TARGET' : 'CONNECTING') : 'BACKGROUND'));
    _retries = 0;
    if (_active && _source != null) unawaited(_connect(_generation));
    notifyListeners();
  }

  bool _validTarget(SignalTarget target) =>
      _text(target.sessionId, 512) &&
      validTime(target.targetGeneration) &&
      _text(target.provider, 512) &&
      _text(target.intersectionKey, 512) &&
      _text(target.approachKey, 512) &&
      _text(target.catalogVersion, 512) &&
      target.movement == 'straight' &&
      (baseUri.scheme == 'http' || baseUri.scheme == 'https') &&
      baseUri.host.isNotEmpty &&
      baseUri.userInfo.isEmpty;

  Future<void> _connect(int generation) async {
    if (!_current(generation) || _source == null) return;
    final client = http.Client();
    _http = client;
    _snapshotTimer = Timer(const Duration(seconds: 5), () {
      if (_current(generation)) _fail('CONNECTION_TIMEOUT');
    });
    try {
      final sentMono = monotonicNow();
      final sentUtc = utcNow().millisecondsSinceEpoch;
      final response = await client
          .send(http.Request('GET', baseUri.resolve('/v1/time')))
          .timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      if (response.statusCode != 200) throw const FormatException();
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 5))) {
        if (!_current(generation)) return;
        if (bytes.length + chunk.length > 1024) throw const FormatException();
        bytes.addAll(chunk);
      }
      final receivedMono = monotonicNow();
      final receivedUtc = utcNow().millisecondsSinceEpoch;
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic> ||
          !_keys(body, {'serverReceivedAtUtcMs', 'serverSentAtUtcMs'})) {
        throw const FormatException();
      }
      final clock = ClockCalibration.fromExchange(
          sentMonotonicMs: sentMono,
          receivedMonotonicMs: receivedMono,
          sentUtcMs: sentUtc,
          receivedUtcMs: receivedUtc,
          serverReceivedAtUtcMs: body['serverReceivedAtUtcMs'],
          serverSentAtUtcMs: body['serverSentAtUtcMs'],
          skewBudgetMs: policy.clockSkewBudgetMs!);
      if (clock == null) {
        throw const FormatException('CLOCK_UNCERTAIN');
      }
      if (!_current(generation)) return;
      _clock = clock;
      final channel = WebSocketChannel.connect(baseUri
          .resolve('/v1/stream')
          .replace(scheme: baseUri.scheme == 'https' ? 'wss' : 'ws'));
      _channel = channel;
      _subscription = channel.stream.listen((dynamic message) {
        if (_current(generation)) _message(message, generation);
      }, onError: (Object error) {
        if (_current(generation)) _fail('DISCONNECTED');
      }, onDone: () {
        if (_current(generation)) _fail('DISCONNECTED');
      });
      await channel.ready.timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      _connected = true;
      _requestId = 'mobile-${++_requestCounter}';
      final target = _target!;
      channel.sink.add(jsonEncode({
        'type': 'subscribe',
        'requestId': _requestId,
        'approachKey': target.approachKey,
        'movement': target.movement,
        'catalogVersion': target.catalogVersion
      }));
      _snapshotTimer?.cancel();
      _snapshotTimer = Timer(const Duration(seconds: 5), () {
        if (_current(generation)) _fail('SNAPSHOT_TIMEOUT');
      });
      _clockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!_current(generation)) return;
        if (!_clock!.isValidAt(
            monotonicMs: monotonicNow(),
            utcMs: utcNow().millisecondsSinceEpoch)) {
          _fail('CLOCK_UNCERTAIN');
        }
      });
      notifyListeners();
    } on FormatException catch (error) {
      if (_current(generation)) {
        _fail(error.message == 'CLOCK_UNCERTAIN'
            ? 'CLOCK_UNCERTAIN'
            : 'INVALID_CLOCK_RESPONSE');
      }
    } on TimeoutException {
      if (_current(generation)) _fail('CONNECTION_TIMEOUT');
    } catch (_) {
      if (_current(generation)) {
        _fail(_clock == null
            ? 'CLOCK_CONNECTION_FAILED'
            : 'SOCKET_CONNECTION_FAILED');
      }
    } finally {
      client.close();
      if (identical(_http, client)) _http = null;
    }
  }

  void _message(dynamic raw, int generation) {
    try {
      if (raw is! String ||
          raw.length > 16384 ||
          utf8.encode(raw).length > 16384) {
        throw const FormatException();
      }
      final packet = jsonDecode(raw);
      if (packet is! Map<String, dynamic>) throw const FormatException();
      final type = packet['type'];
      final field = switch (type) {
        'snapshot' => 'snapshot',
        'unavailable' => 'reason',
        'error' => 'error',
        _ => throw const FormatException(),
      };
      if (!_keys(packet,
              {'type', 'requestId', 'streamEpoch', 'sequence', field}) ||
          !_text(packet['streamEpoch'], 128) ||
          !validTime(packet['sequence']) ||
          packet['sequence'] == 0 ||
          !(packet['requestId'] == null && type == 'error' ||
              _text(packet['requestId'], 128))) {
        throw const FormatException();
      }
      if (_epoch != null && packet['streamEpoch'] != _epoch) {
        throw const FormatException();
      }
      if ((packet['sequence'] as int) <= _sequence) {
        throw const FormatException();
      }
      _epoch ??= packet['streamEpoch'] as String;
      _sequence = packet['sequence'] as int;
      // A request ID is bound locally to the entire target and session identity.
      // Never let a late subscription result clear or populate another target.
      if (packet['requestId'] != _requestId && packet['requestId'] != null) {
        return;
      }
      _snapshotTimer?.cancel();
      if (type != 'snapshot') {
        if (!_text(packet[field], 512)) throw const FormatException();
        if (type == 'error') {
          _fail('STREAM_ERROR');
          return;
        }
        _clear('SIGNAL_UNAVAILABLE');
        notifyListeners();
        return;
      }
      final snapshot = packet['snapshot'];
      if (snapshot is! Map<String, dynamic> || !_validSnapshot(snapshot)) {
        throw const FormatException();
      }
      final target = _target!;
      if (snapshot['provider'] != target.provider ||
          snapshot['intersectionKey'] != target.intersectionKey ||
          snapshot['approachKey'] != target.approachKey ||
          snapshot['movement'] != target.movement ||
          snapshot['catalogVersion'] != target.catalogVersion ||
          '${snapshot['provider']}:${snapshot['sourceIntersectionId']}' !=
              target.intersectionKey) {
        throw const FormatException();
      }
      final source = _source!;
      final stamp = snapshot['sourceObservedAtUtcMs'];
      if (snapshot['timingQuality'] != 'verified' ||
          snapshot['sourceTimeKind'] != 'generated' ||
          snapshot['unitEvidence']['sourceUnit'] == 'unknown' ||
          snapshot['signalState'] == 'unknown' ||
          stamp == null ||
          snapshot['remainingAtSourceMs'] == null ||
          snapshot['expiresAtUtcMs'] == null) {
        if (stamp is int && stamp > source.observedAt) {
          source.observedAt = stamp;
        }
        _clear('TIMING_UNVERIFIED');
        notifyListeners();
        return;
      }
      final eventKey = jsonEncode([
        target.provider,
        target.intersectionKey,
        target.approachKey,
        target.movement,
        target.catalogVersion,
        snapshot['sourceEventId'] ?? stamp
      ]);
      if (stamp <= source.observedAt || source.eventKey == eventKey) return;
      final now = monotonicNow();
      final deadline = _clock!.deadline(
          eventKey: eventKey,
          sourceObservedAtUtcMs: stamp as int,
          serverReceivedAtUtcMs: snapshot['serverReceivedAtUtcMs'] as int,
          serverSentAtUtcMs: snapshot['serverSentAtUtcMs'] as int,
          remainingAtSourceMs: snapshot['remainingAtSourceMs'] as int,
          expiresAtUtcMs: snapshot['expiresAtUtcMs'] as int,
          maxSignalAgeMs: policy.maxSignalAgeMs!,
          monotonicMs: now,
          utcMs: utcNow().millisecondsSinceEpoch);
      source.observedAt = stamp;
      source.eventKey = eventKey;
      if (deadline == null || !deadline.fresh) {
        _clear('SIGNAL_EXPIRED');
      } else {
        source.deadline = source.deadline?.acceptReceipt(deadline,
                nowMonotonicMs: now, verifiedNewerSourceEvent: true) ??
            deadline;
        if (source.deadline!.eventKey != eventKey || !source.deadline!.fresh) {
          _clear('CLOCK_UNCERTAIN');
          notifyListeners();
          return;
        }
        _retries = 0;
        source.state =
            SignalState.values.byName(snapshot['signalState'] as String);
        source.revoked = false;
        _reason = null;
        _expiryTimer?.cancel();
        final lifetime = math.min(source.deadline!.ttlAtReceiptMs!,
                source.deadline!.remainingAtReceiptMs!.earliestMs!) -
            source.deadline!.elapsedMs!;
        _expiryTimer = Timer(Duration(milliseconds: math.max(0, lifetime)), () {
          if (_current(generation)) {
            _clear('SIGNAL_EXPIRED');
            notifyListeners();
          }
        });
      }
      notifyListeners();
    } catch (_) {
      if (_current(generation)) _fail('INVALID_STREAM');
    }
  }

  static bool _text(Object? value, int max) =>
      value is String && value.trim().isNotEmpty && value.length <= max;
  static bool _keys(Map<String, dynamic> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);
  static bool _validSnapshot(Map<String, dynamic> value) {
    if (!_keys(value, {
          'schemaVersion',
          'kind',
          'provider',
          'intersectionKey',
          'approachKey',
          'movement',
          'signalState',
          'catalogVersion',
          'sourceRevision',
          'sourceIntersectionId',
          'sourceEventId',
          'sourceObservedAtUtcMs',
          'sourceTimeKind',
          'serverReceivedAtUtcMs',
          'serverSentAtUtcMs',
          'remainingAtSourceMs',
          'expiresAtUtcMs',
          'timingQuality',
          'unitEvidence',
          'rawStateCode'
        }) ||
        value['schemaVersion'] != 'sa-contract-1' ||
        value['kind'] != 'SignalObservation' ||
        value['movement'] != 'straight' ||
        !{'green', 'yellow', 'red', 'flashing', 'unknown'}
            .contains(value['signalState']) ||
        !{'verified', 'unverified'}.contains(value['timingQuality']) ||
        !{'generated', 'transmitted', 'unknown'}
            .contains(value['sourceTimeKind'])) {
      return false;
    }
    for (final key in [
      'provider',
      'intersectionKey',
      'approachKey',
      'catalogVersion',
      'sourceRevision',
      'sourceIntersectionId'
    ]) {
      if (!_text(value[key], 512)) return false;
    }
    for (final key in ['sourceEventId', 'rawStateCode']) {
      if (value[key] != null && !_text(value[key], 512)) return false;
    }
    for (final key in ['serverReceivedAtUtcMs', 'serverSentAtUtcMs']) {
      if (!validTime(value[key])) return false;
    }
    for (final key in [
      'sourceObservedAtUtcMs',
      'remainingAtSourceMs',
      'expiresAtUtcMs'
    ]) {
      if (value[key] != null && !validTime(value[key])) return false;
    }
    final evidence = value['unitEvidence'];
    return evidence is Map<String, dynamic> &&
        _keys(evidence,
            {'sourceField', 'sourceUnit', 'conversion', 'evidence'}) &&
        {'ms', 'centisecond', 'second', 'unknown'}
            .contains(evidence['sourceUnit']) &&
        _text(evidence['sourceField'], 512) &&
        _text(evidence['conversion'], 2048) &&
        _text(evidence['evidence'], 4096);
  }

  void _clear(String reason) {
    _source?.revoked = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _reason = reason;
  }

  Future<void> _reset(String reason) {
    ++_generation;
    _clear(reason);
    _connected = false;
    _clock = null;
    _epoch = null;
    _sequence = 0;
    _requestId = null;
    _retryTimer?.cancel();
    _clockTimer?.cancel();
    _snapshotTimer?.cancel();
    _http?.close();
    _http = null;
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    // Detach synchronously before awaiting either close; stale completions can
    // never null or close the replacement socket created by a target switch.
    return _close(channel, subscription);
  }

  static Future<void> _close(WebSocketChannel? channel,
      StreamSubscription<dynamic>? subscription) async {
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 1));
    } catch (_) {}
    try {
      await channel?.sink.close().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  void _fail(String reason, {bool retry = true}) {
    unawaited(_reset(reason));
    if (retry && _active && _source != null && _retries < 5) {
      final delay = 250 * (1 << _retries++);
      final generation = _generation;
      _retryTimer = Timer(Duration(milliseconds: delay), () {
        if (_current(generation)) unawaited(_connect(generation));
      });
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_reset('DISPOSED'));
    _target = null;
    _source = null;
    super.dispose();
  }
}
