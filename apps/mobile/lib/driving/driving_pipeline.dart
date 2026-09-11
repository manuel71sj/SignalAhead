import 'dart:async';

import 'package:flutter/foundation.dart';

import '../location/location_sample.dart';
import '../prediction/prediction.dart';
import '../signals/signal_stream.dart';
import '../signals/signal_target.dart';
import 'driving_view_data.dart';

/// Session-owned normalization boundary. Rendering never opens a connection.
class DrivingPipeline extends ChangeNotifier {
  DrivingPipeline(
      {required this.signals,
      required this.policy,
      required int Function() monotonicNow,
      DateTime Function()? utcNow,
      this.synthetic = false})
      : _now = monotonicNow,
        _utcNow = utcNow ?? DateTime.now {
    if (synthetic && !kDebugMode) throw StateError('Replay is debug-only');
    signals.addListener(_emit);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _emit());
  }

  final SignalStreamController signals;
  final PredictionPolicy policy;
  final bool synthetic;
  final int Function() _now;
  final DateTime Function() _utcNow;
  late final Timer _timer;
  bool _disposed = false;
  bool _active = false;
  bool _foreground = true;
  String? _sessionId;
  SignalTarget? _target;
  LocationSample? _location;
  int? _locationDeadline;
  NumericInterval? _distance;
  bool get active => _active;

  void start(String sessionId) {
    stop();
    _sessionId = sessionId;
    _active = true;
    signals.setForeground(_foreground);
    _emit();
  }

  Future<void> update({
    required LocationSample? location,
    required SignalTarget? target,
    NumericInterval? distanceM,
  }) async {
    if (!_active ||
        !_foreground ||
        (location != null && location.sessionId != _sessionId) ||
        (target != null && target.sessionId != _sessionId)) {
      return;
    }
    if (target != null &&
        _target != null &&
        target != _target &&
        target.targetGeneration <= _target!.targetGeneration) {
      return;
    }
    final now = _now();
    final age =
        location == null ? 5000 : now - location.deviceReceivedMonotonicMs;
    final sourceAge = location == null
        ? 5000
        : _utcNow().millisecondsSinceEpoch - location.measuredAtUtcMs;
    final fresh = location != null &&
        age >= 0 &&
        age < 5000 &&
        sourceAge >= 0 &&
        sourceAge < 5000 &&
        location.horizontalAccuracyM.isFinite &&
        location.horizontalAccuracyM > 0;
    // Commit matching, distance and sensor evidence together. A listener must
    // never see a new distance combined with the preceding target or speed.
    _location = fresh ? location : null;
    // Receipt of an already-old position cannot grant another five seconds.
    _locationDeadline =
        fresh ? now + 5000 - (age > sourceAge ? age : sourceAge) : null;
    _target = fresh ? target : null;
    _distance = _target == null ? null : distanceM;
    final selecting = signals.selectTarget(_target);
    _emit();
    await selecting;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) _location = null;
    signals.setForeground(foreground && _active);
    _emit();
  }

  DrivingViewData get view {
    final sample = _location;
    final received = sample?.deviceReceivedMonotonicMs;
    final now = _now();
    final deadline = _locationDeadline;
    final freshLocation = received != null &&
        deadline != null &&
        now >= received &&
        now < deadline;
    final activeNow = _active && _foreground;
    final reading =
        activeNow && freshLocation && _target != null ? signals.reading : null;
    final speed = sample?.speedMps;
    final speedError = sample?.speedAccuracyMps;
    final speedInterval = speed != null &&
            speedError != null &&
            speed.isFinite &&
            speedError.isFinite &&
            speed >= 0 &&
            speedError >= 0
        ? NumericInterval(
            min: (speed - speedError).clamp(0, double.infinity),
            max: speed + speedError)
        : null;
    final result = evaluatePrediction(
        PredictionInput(
          sessionActive: activeNow,
          targetMatched: _target != null,
          signalState: reading?.signalState ?? SignalState.unknown,
          signalFresh: reading != null,
          timingQuality: reading == null
              ? TimingQuality.unverified
              : TimingQuality.verified,
          locationValid: freshLocation,
          horizontalAccuracyM: sample?.horizontalAccuracyM,
          distanceM: _distance,
          speedMps: speedInterval,
          greenRemainingMs: reading?.remainingMs,
          syntheticFixture: synthetic,
        ),
        policy);
    final phase = !_active
        ? '주행 전'
        : !_foreground
            ? '일시 정지'
            : freshLocation
                ? '주행 중'
                : '위치 확인';
    return DrivingViewData(
      active: _active,
      phaseLabel: phase,
      directionLabel: _target == null ? '방향 불명' : '↑ 직진 · 다음 신호',
      heading: !_active
          ? '주행을 시작할까요?'
          : reading == null
              ? '판단 보류'
              : '',
      message: !_active
          ? '시작 전에는 위치와 신호를 수집하지 않습니다.'
          : !freshLocation
              ? '새 위치를 기다리는 중입니다.'
              : _target == null
                  ? '확정된 접근로가 없어 신호를 선택하지 않습니다.'
                  : reading == null
                      ? '신호 정보가 없거나 만료되었습니다. 새 신호를 기다립니다.'
                      : '',
      signalState: reading?.signalState ?? SignalState.unknown,
      remainingMs: reading?.remainingMs,
      prediction: activeNow && freshLocation && _target != null ? result : null,
      speedMps: freshLocation ? speed : null,
      horizontalAccuracyM: freshLocation ? sample?.horizontalAccuracyM : null,
      distanceM: freshLocation && _target != null ? _distance : null,
      synthetic: synthetic,
    );
  }

  void stop() {
    _active = false;
    _sessionId = null;
    _location = null;
    _locationDeadline = null;
    _target = null;
    _distance = null;
    unawaited(signals.selectTarget(null));
    signals.setForeground(false);
    _emit();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer.cancel();
    signals.removeListener(_emit);
    signals.dispose();
    super.dispose();
  }
}
