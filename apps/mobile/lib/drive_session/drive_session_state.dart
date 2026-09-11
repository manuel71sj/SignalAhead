import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../driving/driving_pipeline.dart';
import '../driving/driving_view_data.dart';
import '../location/location_gateway.dart';
import '../location/location_sample.dart';
import '../signals/catalog_client.dart';
import '../map_matching/road_matcher.dart';
import '../map_matching/driving_bundle.dart';
import '../signals/signal_stream.dart';
import '../signals/signal_target.dart';

enum DriveSessionPhase {
  idle,
  requestingPermission,
  acquiringLocation,
  driving,
  paused,
  stopped
}

class DriveSessionController extends ChangeNotifier {
  DriveSessionController({
    required this.location,
    required this.createCatalogClient,
    this.signalBaseUri,
    DateTime Function()? utcNow,
    int Function()? monotonicNow,
  }) : _utcNow = utcNow ?? DateTime.now {
    _clock.start();
    _monotonicNow = monotonicNow ?? () => _clock.elapsedMilliseconds;
  }

  final LocationGateway location;
  final CatalogClient Function() createCatalogClient;
  final Uri? signalBaseUri;
  final DateTime Function() _utcNow;
  final Stopwatch _clock = Stopwatch();
  late final int Function() _monotonicNow;
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _services;
  Timer? _freshnessTimer;
  CatalogClient? _catalog;
  int _generation = 0;
  int? _lastCatalogCheck;
  bool _queryPending = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _permissionPending = false;
  int? _acquiringSince;
  DrivingPipeline? _pipeline;
  RoadMatcher? _matcher;
  String? _activeCatalogVersion;
  SignalTarget? _target;
  int _targetGeneration = 0;
  DrivingViewData? get drivingView => _pipeline?.view;

  DriveSessionPhase phase = DriveSessionPhase.idle;
  LocationBlocker? blocker;
  LocationSample? sample;
  CoverageResult coverage = const CoverageResult(CoverageStatus.checking);
  String? sessionId;
  bool get running =>
      phase == DriveSessionPhase.driving ||
      phase == DriveSessionPhase.acquiringLocation;

  Future<void> start({bool requestPermission = true}) async {
    if (_disposed || !_foreground || _permissionPending || running) return;
    _clearResources();
    final generation = ++_generation;
    phase = DriveSessionPhase.requestingPermission;
    blocker = null;
    _permissionPending = true;
    _emit();
    LocationBlocker? permissionBlocker;
    try {
      permissionBlocker =
          await location.authorize(requestPermission: requestPermission);
    } on Exception {
      permissionBlocker = LocationBlocker.sensorError;
    }
    _permissionPending = false;
    if (_disposed || generation != _generation) {
      if (!_disposed && _foreground && phase == DriveSessionPhase.paused) {
        unawaited(start(requestPermission: false));
      }
      return;
    }
    if (!_foreground) {
      phase = DriveSessionPhase.paused;
      _emit();
      return;
    }
    if (permissionBlocker != null) {
      blocker = permissionBlocker;
      phase = DriveSessionPhase.stopped;
      _emit();
      return;
    }
    sessionId = 'session-$generation-${_monotonicNow()}';
    phase = DriveSessionPhase.acquiringLocation;
    _acquiringSince = _monotonicNow();
    try {
      _catalog = createCatalogClient();
      _positions = location.positions().listen(
        (position) => _receive(position, generation),
        onError: (Object error) {
          if (generation != _generation || _disposed) return;
          stop();
          blocker = error is PermissionDeniedException
              ? LocationBlocker.permissionDenied
              : LocationBlocker.sensorError;
          _emit();
        },
        onDone: () {
          if (generation != _generation || _disposed) return;
          stop();
          blocker = LocationBlocker.sensorError;
          _emit();
        },
      );
      if (!kIsWeb) {
        _services = location.serviceStatus().listen((status) {
          if (generation != _generation || _disposed) return;
          if (status == ServiceStatus.disabled) {
            stop();
            blocker = LocationBlocker.serviceOff;
            _emit();
          }
        }, onError: (Object _) {
          if (generation != _generation || _disposed) return;
          stop();
          blocker = LocationBlocker.sensorError;
          _emit();
        });
      }
    } on Exception {
      stop();
      blocker = LocationBlocker.sensorError;
      _emit();
      return;
    }
    _freshnessTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => checkFreshness());
    _emit();
  }

  void _receive(Position position, int generation) {
    if (_disposed || generation != _generation || !_foreground) return;
    final ageMs = _utcNow().millisecondsSinceEpoch -
        position.timestamp.millisecondsSinceEpoch;
    // Acquisition guard, not an approved prediction policy. No last-known reads.
    if (ageMs < -1000 ||
        ageMs > 5000 ||
        !position.latitude.isFinite ||
        position.latitude.abs() >= 90 ||
        !position.longitude.isFinite ||
        position.longitude.abs() > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0) {
      sample = null;
      blocker = LocationBlocker.staleLocation;
      phase = DriveSessionPhase.acquiringLocation;
      _invalidateMatch();
      _emit();
      return;
    }
    final previous = sample;
    if (previous != null &&
        position.timestamp.millisecondsSinceEpoch <= previous.measuredAtUtcMs) {
      return;
    }
    final now = _monotonicNow();
    final speed = LocationSample.nonNegativeOrNull(position.speed);
    final headingAccuracy =
        LocationSample.nonNegativeOrNull(position.headingAccuracy);
    sample = LocationSample(
      sessionId: sessionId!,
      latitude: position.latitude,
      longitude: position.longitude,
      horizontalAccuracyM: position.accuracy,
      speedMps: speed,
      speedAccuracyMps:
          LocationSample.nonNegativeOrNull(position.speedAccuracy),
      // GPS course is not a compass and stationary heading is not vehicle intent.
      courseDeg: speed == null || speed == 0
          ? null
          : LocationSample.courseOrNull(position.heading),
      courseAccuracyDeg: headingAccuracy == null || headingAccuracy > 180
          ? null
          : headingAccuracy,
      measuredAtUtcMs: position.timestamp.millisecondsSinceEpoch,
      deviceReceivedMonotonicMs: now,
    );
    phase = DriveSessionPhase.driving;
    blocker = null;
    _updatePrediction();
    _emit();
    if (!_queryPending &&
        (_lastCatalogCheck == null || now - _lastCatalogCheck! >= 15000)) {
      unawaited(_checkCoverage(generation, sample!));
    }
  }

  Future<void> _checkCoverage(int generation, LocationSample current) async {
    final client = _catalog;
    if (client == null) return;
    _queryPending = true;
    _lastCatalogCheck = _monotonicNow();
    final result = await client.coverage(current);
    if (_disposed || generation != _generation) return;
    _queryPending = false;
    if (sample == null || !_foreground) return;
    coverage = result;
    final bundle = result.bundle;
    if (result.status != CoverageStatus.supported ||
        bundle == null ||
        signalBaseUri == null) {
      _discardPipeline();
    } else {
      if (_activeCatalogVersion != bundle.catalogVersion) {
        _discardPipeline();
        _matcher = RoadMatcher(bundle);
        _activeCatalogVersion = bundle.catalogVersion;
        _pipeline = DrivingPipeline(
          signals: SignalStreamController(
            baseUri: signalBaseUri!,
            policy: bundle.predictionPolicy,
            monotonicNow: _monotonicNow,
            utcNow: _utcNow,
            syntheticFixture: bundle.syntheticFixture,
          ),
          policy: bundle.predictionPolicy,
          monotonicNow: _monotonicNow,
          utcNow: _utcNow,
          synthetic: bundle.syntheticFixture,
        )..start(sessionId!);
        _pipeline!.addListener(_emit);
        _updatePrediction();
      }
    }
    _emit();
  }

  void _updatePrediction() {
    final current = sample;
    final pipeline = _pipeline;
    final matcher = _matcher;
    if (current == null || pipeline == null || matcher == null) return;
    final result = matcher.update(current, _monotonicNow());
    final approach = result.approach;
    if (result.status == MatchingStatus.matched &&
        approach != null &&
        result.distanceM?.isValid == true) {
      final previous = _target;
      if (previous == null ||
          previous.sessionId != current.sessionId ||
          previous.provider != approach.provider ||
          previous.intersectionKey != approach.intersectionKey ||
          previous.approachKey != approach.approachKey ||
          previous.movement != approach.movement ||
          previous.catalogVersion != approach.catalogVersion) {
        _target = SignalTarget(
          sessionId: current.sessionId,
          targetGeneration: ++_targetGeneration,
          provider: approach.provider,
          intersectionKey: approach.intersectionKey,
          approachKey: approach.approachKey,
          movement: approach.movement,
          catalogVersion: approach.catalogVersion,
        );
      }
    } else if (_target != null) {
      _target = null;
      ++_targetGeneration;
    }
    unawaited(pipeline.update(
      location: current,
      target: _target,
      distanceM: _target == null ? null : result.distanceM,
    ));
  }

  void _invalidateMatch() {
    _lastCatalogCheck = null;
    _matcher?.clear();
    if (_target != null) ++_targetGeneration;
    _target = null;
    final pipeline = _pipeline;
    if (pipeline != null) {
      unawaited(pipeline.update(location: null, target: null));
    }
  }

  void _discardPipeline() {
    final pipeline = _pipeline;
    _pipeline = null;
    _matcher = null;
    _activeCatalogVersion = null;
    if (_target != null) ++_targetGeneration;
    _target = null;
    pipeline?.removeListener(_emit);
    pipeline?.dispose();
  }

  void checkFreshness() {
    if (!running || _disposed) return;
    final now = _monotonicNow();
    final current = sample;
    final received = current?.deviceReceivedMonotonicMs;
    final sourceAge = current == null
        ? 5000
        : _utcNow().millisecondsSinceEpoch - current.measuredAtUtcMs;
    if ((received != null &&
            (now < received ||
                now - received >= 5000 ||
                sourceAge < -1000 ||
                sourceAge >= 5000)) ||
        (received == null &&
            _acquiringSince != null &&
            now - _acquiringSince! >= 15000)) {
      sample = null;
      coverage = const CoverageResult(CoverageStatus.checking);
      blocker = LocationBlocker.staleLocation;
      phase = DriveSessionPhase.acquiringLocation;
      _invalidateMatch();
      _emit();
    }
  }

  void setForeground(bool foreground, {bool permissionDialog = false}) {
    _foreground = foreground;
    if (!foreground) {
      // iOS permission dialogs mark the app inactive. No stream exists yet.
      if (_permissionPending && permissionDialog) return;
      if (running || phase == DriveSessionPhase.requestingPermission) {
        ++_generation;
        _clearResources();
        phase = DriveSessionPhase.paused;
        _emit();
      }
    } else if (phase == DriveSessionPhase.paused && !_permissionPending) {
      unawaited(start(requestPermission: false));
    }
  }

  void stop() {
    ++_generation;
    _clearResources();
    blocker = null;
    phase = DriveSessionPhase.stopped;
    _emit();
  }

  void _clearResources() {
    _discardPipeline();
    unawaited(_positions?.cancel());
    unawaited(_services?.cancel());
    _positions = null;
    _services = null;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _catalog?.close();
    _catalog = null;
    _queryPending = false;
    _lastCatalogCheck = null;
    _acquiringSince = null;
    sample = null;
    sessionId = null;
    coverage = const CoverageResult(CoverageStatus.checking);
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _clearResources();
    _clock.stop();
    super.dispose();
  }
}
