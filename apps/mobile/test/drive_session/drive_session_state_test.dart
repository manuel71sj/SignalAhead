import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:signalahead_mobile/drive_session/drive_session_state.dart';
import 'package:signalahead_mobile/location/location_gateway.dart';
import 'package:signalahead_mobile/location/location_sample.dart';
import 'package:signalahead_mobile/signals/catalog_client.dart';

class TestLocation implements LocationGateway {
  final updates = StreamController<Position>.broadcast();
  final services = StreamController<ServiceStatus>.broadcast();
  LocationBlocker? blocked;
  Completer<LocationBlocker?>? authorization;
  int requests = 0;
  int streams = 0;
  @override
  Future<LocationBlocker?> authorize({required bool requestPermission}) async {
    if (requestPermission) requests++;
    return authorization != null ? authorization!.future : blocked;
  }

  @override
  Stream<Position> positions() {
    streams++;
    return updates.stream;
  }

  @override
  Stream<ServiceStatus> serviceStatus() => services.stream;
  @override
  Future<void> openSettings() async {}
}

class TestCatalog implements CatalogClient {
  int queries = 0;
  bool closed = false;
  @override
  Future<CoverageResult> coverage(LocationSample sample) async {
    queries++;
    return const CoverageResult(CoverageStatus.unsupported);
  }

  @override
  void close() {
    closed = true;
  }
}

Position position(
        {double speed = -1, double heading = -1, DateTime? timestamp}) =>
    Position(
      longitude: 126.97,
      latitude: 37.52,
      timestamp: timestamp ?? DateTime.fromMillisecondsSinceEpoch(100000),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: heading,
      headingAccuracy: 5,
      speed: speed,
      speedAccuracy: 0.5,
    );

void main() {
  late TestLocation location;
  late TestCatalog catalog;
  late DriveSessionController controller;
  int monotonic = 0;
  setUp(() {
    monotonic = 0;
    location = TestLocation();
    catalog = TestCatalog();
    controller = DriveSessionController(
      location: location,
      createCatalogClient: () => catalog,
      utcNow: () => DateTime.fromMillisecondsSinceEpoch(100000),
      monotonicNow: () => monotonic,
    );
  });
  tearDown(() async {
    controller.dispose();
    await location.updates.close();
    await location.services.close();
  });

  test(
      'no permission or sensor work before start; stop cancels and discards delayed events',
      () async {
    expect(location.requests, 0);
    expect(location.streams, 0);
    await controller.start();
    location.updates.add(position());
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, DriveSessionPhase.driving);
    expect(controller.sample?.speedMps, isNull);
    expect(controller.coverage.status, CoverageStatus.unsupported);
    controller.stop();
    location.updates.add(position(speed: 5, heading: 90));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sample, isNull);
    expect(location.updates.hasListener, isFalse);
    expect(catalog.closed, isTrue);
    expect(controller.phase, DriveSessionPhase.stopped);
  });

  test('permission completion while inactive resumes instead of hanging',
      () async {
    location.authorization = Completer<LocationBlocker?>();
    final starting = controller.start();
    controller.setForeground(false, permissionDialog: true);
    location.authorization!.complete(null);
    await starting;
    expect(location.streams, 0);
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, DriveSessionPhase.acquiringLocation);
    expect(location.streams, 1);
  });

  test('stop during permission dialog cannot start a late sensor stream',
      () async {
    location.authorization = Completer<LocationBlocker?>();
    final starting = controller.start();
    controller.stop();
    location.authorization!.complete(null);
    await starting;
    expect(location.streams, 0);
    expect(controller.sessionId, isNull);
    expect(controller.phase, DriveSessionPhase.stopped);
  });

  test('resume rechecks revoked permission, never restores old location',
      () async {
    await controller.start();
    location.updates.add(position(speed: 0, heading: 90));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sample?.courseDeg, isNull);
    controller.setForeground(false);
    expect(controller.sample, isNull);
    expect(controller.phase, DriveSessionPhase.paused);
    location.blocked = LocationBlocker.permissionDeniedForever;
    controller.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, DriveSessionPhase.stopped);
    expect(controller.blocker, LocationBlocker.permissionDeniedForever);
    expect(controller.sample, isNull);
    expect(location.requests, 1);
  });

  test(
      'stale source location rejected and monotonic deadline clears accepted location',
      () async {
    await controller.start();
    location.updates
        .add(position(timestamp: DateTime.fromMillisecondsSinceEpoch(90000)));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sample, isNull);
    expect(catalog.queries, 0);
    location.updates.add(position(speed: 2, heading: 90));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sample, isNotNull);
    monotonic = 5000;
    controller.checkFreshness();
    expect(controller.sample, isNull);
    expect(controller.blocker, LocationBlocker.staleLocation);
  });
}
