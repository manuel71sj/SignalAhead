import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:signalahead_mobile/drive_session/drive_session_state.dart';
import 'package:signalahead_mobile/location/location_gateway.dart';
import 'package:signalahead_mobile/location/location_sample.dart';
import 'package:signalahead_mobile/map_matching/driving_bundle.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';
import 'package:signalahead_mobile/signals/catalog_client.dart';

import '../drive_session/drive_session_state_test.dart' show TestLocation;
import '../signals/signal_stream_test.dart' as transport;

class FixtureCatalog implements CatalogClient {
  FixtureCatalog(this.bundle);
  final DrivingBundle bundle;
  @override
  Future<CoverageResult> coverage(LocationSample sample) async =>
      CoverageResult(CoverageStatus.supported, bundle: bundle);
  @override
  void close() {}
}

void main() {
  test('matched native session subscribes, then permission loss revokes result',
      () async {
    final fixture = jsonDecode(
        await File('../../fixtures/spatial/driving-catalog.json')
            .readAsString()) as Map<String, dynamic>;
    final bundle = DrivingBundle.fromJson(fixture, syntheticFixture: true);
    final server = transport.FixtureServer();
    await server.start();
    final location = TestLocation();
    final controller = DriveSessionController(
      location: location,
      createCatalogClient: () => FixtureCatalog(bundle),
      signalBaseUri: server.uri,
      utcNow: () => DateTime.fromMillisecondsSinceEpoch(server.now),
      monotonicNow: () => server.watch.elapsedMilliseconds,
    );
    addTearDown(() async {
      controller.dispose();
      await location.updates.close();
      await location.services.close();
      await server.close();
    });
    await controller.start();
    // Three forward measurements on the authored north approach establish
    // course/history confidence. Nothing is selected from the nearby center.
    for (final latitude in [37.0009, 37.00085, 37.0008]) {
      location.updates.add(Position(
        latitude: latitude,
        longitude: 127,
        timestamp: DateTime.fromMillisecondsSinceEpoch(server.now),
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 180,
        headingAccuracy: 1,
        speed: 10,
        speedAccuracy: 0.5,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 550));
    }
    await transport.until(() => server.peers.isNotEmpty);
    final snapshot = server.snapshot('i1', lifetime: 20000)
      ..['provider'] = 'synthetic'
      ..['intersectionKey'] = 'synthetic:i1'
      ..['approachKey'] = 'synthetic:north-approach'
      ..['catalogVersion'] = bundle.catalogVersion;
    server.peers.single.send(snapshot);
    await transport.until(() =>
        controller.drivingView?.prediction?.status ==
        PredictionStatus.possible);
    expect(controller.drivingView?.signalState, SignalState.green);
    expect(controller.drivingView?.synthetic, isTrue);

    controller.setForeground(false);
    expect(controller.sample, isNull);
    expect(controller.drivingView, isNull);
    location.blocked = LocationBlocker.permissionDenied;
    controller.setForeground(true);
    await transport.until(() => controller.phase == DriveSessionPhase.stopped);
    expect(controller.blocker, LocationBlocker.permissionDenied);
    expect(controller.drivingView, isNull);
    expect(location.updates.hasListener, isFalse);
  });
}
