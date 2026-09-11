import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/driving/driving_pipeline.dart';
import 'package:signalahead_mobile/location/location_sample.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';

import '../signals/signal_stream_test.dart' as transport;

void main() {
  late transport.FixtureServer server;
  late DrivingPipeline pipeline;
  var monotonic = 0;

  LocationSample location({double speed = 10, int sourceAgeMs = 0}) =>
      LocationSample(
        sessionId: 'drive',
        latitude: 37,
        longitude: 127,
        horizontalAccuracyM: 1,
        speedMps: speed,
        speedAccuracyMps: 0,
        courseDeg: speed == 0 ? null : 90,
        courseAccuracyDeg: 1,
        measuredAtUtcMs: server.now - sourceAgeMs,
        deviceReceivedMonotonicMs: monotonic,
      );

  Future<void> showGreen({int sourceAgeMs = 0}) async {
    await pipeline.update(
      location: location(sourceAgeMs: sourceAgeMs),
      target: transport.target('A'),
      distanceM: const NumericInterval(min: 13, max: 17),
    );
    await transport.until(() => server.peers.isNotEmpty);
    server.peers.single.send(server.snapshot('A'));
    await transport.until(
        () => pipeline.view.prediction?.status == PredictionStatus.possible);
  }

  setUp(() async {
    server = transport.FixtureServer();
    await server.start();
    monotonic = 0;
    pipeline = DrivingPipeline(
      signals: server.controller(),
      policy: transport.policy,
      monotonicNow: () => monotonic,
      utcNow: () => DateTime.fromMillisecondsSinceEpoch(server.now),
      synthetic: true,
    )..start('drive');
  });

  tearDown(() async {
    pipeline.dispose();
    await server.close();
  });

  test('old source position expires before a fresh signal and receipt',
      () async {
    await showGreen(sourceAgeMs: 4000);
    // Only the consumer's location deadline advances; the socket signal is
    // still current. Four seconds of source age cannot become a new 5s TTL.
    monotonic += 1100;
    expect(pipeline.signals.reading, isNotNull);
    expect(pipeline.view.signalState, SignalState.unknown);
    expect(pipeline.view.remainingMs, isNull);
    expect(pipeline.view.prediction, isNull);
    expect(pipeline.view.distanceM, isNull);
  });

  test('stopping commits speed and changed distance without optimistic flash',
      () async {
    await showGreen();
    final observed = <PredictionStatus?>[];
    pipeline.addListener(() => observed.add(pipeline.view.prediction?.status));
    await pipeline.update(
      location: location(speed: 0),
      target: transport.target('A'),
      distanceM: const NumericInterval(min: 1, max: 2),
    );
    expect(pipeline.view.signalState, SignalState.green);
    expect(pipeline.view.prediction?.reason, PredictionReason.stoppedOrSlow);
    expect(observed, isNot(contains(PredictionStatus.possible)));
    expect(observed, contains(PredictionStatus.unknown));
    expect(pipeline.view.distanceM?.min, 1);
  });
}
