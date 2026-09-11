import 'package:flutter_test/flutter_test.dart';
import 'package:signalahead_mobile/prediction/prediction.dart';

const fixturePolicy = PredictionPolicy.syntheticFixture(
  maxSignalAgeMs: 30000,
  clockSkewBudgetMs: 100,
  minimumSpeedMps: 0.1,
  maxHorizontalAccuracyM: 10,
  extraSafetyMarginMs: 0,
);

PredictionInput input({
  bool? sessionActive = true,
  bool? targetMatched = true,
  SignalState? signalState = SignalState.green,
  bool? signalFresh = true,
  TimingQuality? timingQuality = TimingQuality.verified,
  bool? locationValid = true,
  double? horizontalAccuracyM = 1,
  NumericInterval? distanceM = const NumericInterval(min: 13, max: 17),
  NumericInterval? speedMps = const NumericInterval(min: 1, max: 1),
  IntervalMs? greenRemainingMs =
      const IntervalMs(earliestMs: 20000, latestMs: 26000),
  bool syntheticFixture = true,
}) =>
    PredictionInput(
      sessionActive: sessionActive,
      targetMatched: targetMatched,
      signalState: signalState,
      signalFresh: signalFresh,
      timingQuality: timingQuality,
      locationValid: locationValid,
      horizontalAccuracyM: horizontalAccuracyM,
      distanceM: distanceM,
      speedMps: speedMps,
      greenRemainingMs: greenRemainingMs,
      syntheticFixture: syntheticFixture,
    );

PredictionPolicy operationalPolicy({
  bool? approvedForOperation = true,
  double? minimumSpeedMps = 0.1,
  double? maxHorizontalAccuracyM = 10,
  int? extraSafetyMarginMs = 0,
  String? measurementEvidence = 'Explicit evidence supplied by test harness',
}) =>
    PredictionPolicy(
      policyVersion: 'test-operational-gate',
      approvedForOperation: approvedForOperation,
      maxSignalAgeMs: 30000,
      clockSkewBudgetMs: 100,
      minimumSpeedMps: minimumSpeedMps,
      maxHorizontalAccuracyM: maxHorizontalAccuracyM,
      extraSafetyMarginMs: extraSafetyMarginMs,
      measurementEvidence: measurementEvidence,
    );

void expectUnknown(PredictionResult result, PredictionReason reason) {
  expect(result.status, PredictionStatus.unknown);
  expect(result.reason, reason);
}

void main() {
  group('SA-10 named interval scenarios', () {
    test('[13,17]s arrival before [20,26]s green is possible', () {
      final result = evaluatePrediction(input(), fixturePolicy);
      expect(result.status, PredictionStatus.possible);
      expect(result.arrivalIntervalMs!.earliestMs, 13000);
      expect(result.arrivalIntervalMs!.latestMs, 17000);
      expect(
          evaluatePrediction(input(), fixturePolicy).toJson(), result.toJson());
    });

    test('[22,26]s arrival after [12,18]s green is unlikely', () {
      final result = evaluatePrediction(
        input(
          distanceM: const NumericInterval(min: 22, max: 26),
          greenRemainingMs:
              const IntervalMs(earliestMs: 12000, latestMs: 18000),
        ),
        fixturePolicy,
      );
      expect(result.status, PredictionStatus.unlikely);
    });

    test('[13,20]s touching [20,26]s is unknown, not possible', () {
      expectUnknown(
        evaluatePrediction(
          input(distanceM: const NumericInterval(min: 13, max: 20)),
          fixturePolicy,
        ),
        PredictionReason.intervalOverlap,
      );
    });

    test('same geometry with unverified timing fails closed', () {
      expectUnknown(
        evaluatePrediction(
            input(timingQuality: TimingQuality.unverified), fixturePolicy),
        PredictionReason.timingUnverified,
      );
    });

    test('zero speed has reachable STOPPED_OR_SLOW reason', () {
      expectUnknown(
        evaluatePrediction(
          input(speedMps: const NumericInterval(min: 0, max: 0)),
          fixturePolicy,
        ),
        PredictionReason.stoppedOrSlow,
      );
    });
  });

  test('speed uncertainty uses fastest earliest and slowest latest', () {
    final result = evaluatePrediction(
      input(
          distanceM: const NumericInterval(min: 26, max: 34),
          speedMps: const NumericInterval(min: 2, max: 4)),
      fixturePolicy,
    );
    expect(result.arrivalIntervalMs!.earliestMs, 6500);
    expect(result.arrivalIntervalMs!.latestMs, 17000);
    expect(result.status, PredictionStatus.possible);
  });

  test('earliest arrival rounds down rather than manufacturing unlikely', () {
    expectUnknown(
      evaluatePrediction(
        input(
          distanceM: const NumericInterval(min: 10.0001, max: 11),
          greenRemainingMs: const IntervalMs(earliestMs: 9000, latestMs: 10000),
        ),
        fixturePolicy,
      ),
      PredictionReason.intervalOverlap,
    );
  });

  test('latest arrival rounds up and margin equality is not possible', () {
    expectUnknown(
      evaluatePrediction(
        input(distanceM: const NumericInterval(min: 13, max: 19.9999)),
        fixturePolicy,
      ),
      PredictionReason.intervalOverlap,
    );
    expectUnknown(
      evaluatePrediction(input(), operationalPolicy(extraSafetyMarginMs: 3000)),
      PredictionReason.intervalOverlap,
    );
  });

  test('arrival equality at green latest is not unlikely', () {
    expectUnknown(
      evaluatePrediction(
        input(distanceM: const NumericInterval(min: 26, max: 30)),
        fixturePolicy,
      ),
      PredictionReason.intervalOverlap,
    );
  });

  test('stopline uncertainty touching or crossing zero fails closed', () {
    for (final distance in [
      const NumericInterval(min: 0, max: 5),
      const NumericInterval(min: -2, max: 5),
      const NumericInterval(min: 0, max: 0),
    ]) {
      expectUnknown(
          evaluatePrediction(input(distanceM: distance), fixturePolicy),
          PredictionReason.locationInvalid);
    }
  });

  test('missing, nonfinite, negative and reversed sensor intervals fail closed',
      () {
    for (final invalid in <NumericInterval?>[
      null,
      const NumericInterval(min: null, max: 1),
      const NumericInterval(min: 1, max: null),
      const NumericInterval(min: double.nan, max: 2),
      const NumericInterval(min: 1, max: double.infinity),
      const NumericInterval(min: -1, max: 2),
      const NumericInterval(min: 3, max: 2),
    ]) {
      expectUnknown(evaluatePrediction(input(speedMps: invalid), fixturePolicy),
          PredictionReason.locationInvalid);
      expectUnknown(
          evaluatePrediction(input(distanceM: invalid), fixturePolicy),
          PredictionReason.locationInvalid);
    }
    expectUnknown(
      evaluatePrediction(input(horizontalAccuracyM: null), fixturePolicy),
      PredictionReason.locationInvalid,
    );
    expectUnknown(
      evaluatePrediction(input(horizontalAccuracyM: 10.01), fixturePolicy),
      PredictionReason.locationInvalid,
    );
    expectUnknown(
      evaluatePrediction(input(locationValid: null), fixturePolicy),
      PredictionReason.locationInvalid,
    );
  });

  test('zero-crossing and below-threshold speed intervals are stopped/slow',
      () {
    for (final speed in [
      const NumericInterval(min: 0, max: 2),
      const NumericInterval(min: 0.05, max: 1),
    ]) {
      expectUnknown(evaluatePrediction(input(speedMps: speed), fixturePolicy),
          PredictionReason.stoppedOrSlow);
    }
  });

  test('missing or malformed green timing is unverified; zero is expired', () {
    for (final green in <IntervalMs?>[
      null,
      const IntervalMs(earliestMs: null, latestMs: 20000),
      const IntervalMs(earliestMs: -1, latestMs: 20000),
      const IntervalMs(earliestMs: 21000, latestMs: 20000),
    ]) {
      expectUnknown(
          evaluatePrediction(input(greenRemainingMs: green), fixturePolicy),
          PredictionReason.timingUnverified);
    }
    expectUnknown(
      evaluatePrediction(
        input(
            greenRemainingMs: const IntervalMs(earliestMs: 0, latestMs: 26000)),
        fixturePolicy,
      ),
      PredictionReason.signalStale,
    );
  });

  test('non-green states preserve color but never produce an arrival verdict',
      () {
    for (final state in [
      SignalState.yellow,
      SignalState.red,
      SignalState.flashing,
      SignalState.unknown,
    ]) {
      final result =
          evaluatePrediction(input(signalState: state), fixturePolicy);
      expectUnknown(result, PredictionReason.signalNotGreen);
      expect(result.signalStateAtDecision, state);
    }
  });

  test(
      'reason priority follows session, policy, signal, location, target, color, speed',
      () {
    const stopped = NumericInterval(min: 0, max: 0);
    expectUnknown(
      evaluatePrediction(input(sessionActive: false, signalFresh: false), null),
      PredictionReason.sessionInactive,
    );
    expectUnknown(evaluatePrediction(input(signalFresh: false), null),
        PredictionReason.policyUncalibrated);
    expectUnknown(
      evaluatePrediction(
          input(
              signalFresh: false,
              timingQuality: TimingQuality.unverified,
              locationValid: false),
          fixturePolicy),
      PredictionReason.signalStale,
    );
    expectUnknown(
      evaluatePrediction(
          input(timingQuality: TimingQuality.unverified, locationValid: false),
          fixturePolicy),
      PredictionReason.timingUnverified,
    );
    expectUnknown(
      evaluatePrediction(
          input(locationValid: false, targetMatched: false), fixturePolicy),
      PredictionReason.locationInvalid,
    );
    expectUnknown(
      evaluatePrediction(
          input(
              targetMatched: false,
              signalState: SignalState.red,
              speedMps: stopped),
          fixturePolicy),
      PredictionReason.targetAmbiguous,
    );
    expectUnknown(
      evaluatePrediction(input(signalState: SignalState.red, speedMps: stopped),
          fixturePolicy),
      PredictionReason.signalNotGreen,
    );
  });

  test('uncalibrated or missing policy cannot authorize prediction', () {
    for (final policy in <PredictionPolicy?>[
      null,
      operationalPolicy(approvedForOperation: false),
      operationalPolicy(approvedForOperation: null),
      operationalPolicy(minimumSpeedMps: null),
      operationalPolicy(minimumSpeedMps: 0),
      operationalPolicy(minimumSpeedMps: double.nan),
      operationalPolicy(maxHorizontalAccuracyM: double.infinity),
      operationalPolicy(extraSafetyMarginMs: null),
      operationalPolicy(extraSafetyMarginMs: -1),
      operationalPolicy(measurementEvidence: ''),
    ]) {
      expectUnknown(evaluatePrediction(input(), policy),
          PredictionReason.policyUncalibrated);
    }
  });

  test('synthetic approval is explicit and cannot leak to production input',
      () {
    expectUnknown(
        evaluatePrediction(input(syntheticFixture: false), fixturePolicy),
        PredictionReason.policyUncalibrated);
    expect(evaluatePrediction(input(), fixturePolicy).status,
        PredictionStatus.possible);
    expect(
        evaluatePrediction(input(syntheticFixture: false), operationalPolicy())
            .status,
        PredictionStatus.possible);
  });

  test('overflowing arrival calculations fail closed rather than throw', () {
    expectUnknown(
      evaluatePrediction(
        input(distanceM: const NumericInterval(min: 1e307, max: 1e308)),
        fixturePolicy,
      ),
      PredictionReason.locationInvalid,
    );
  });
}
