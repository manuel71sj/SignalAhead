export 'signal_deadline.dart';

const _maximumExactInteger = 9007199254740991;

enum SignalState { green, yellow, red, flashing, unknown }

enum TimingQuality { verified, unverified }

enum PredictionStatus { possible, unlikely, unknown }

enum PredictionReason {
  sessionInactive('SESSION_INACTIVE'),
  policyUncalibrated('POLICY_UNCALIBRATED'),
  signalStale('SIGNAL_STALE'),
  timingUnverified('TIMING_UNVERIFIED'),
  locationInvalid('LOCATION_INVALID'),
  targetAmbiguous('TARGET_AMBIGUOUS'),
  signalNotGreen('SIGNAL_NOT_GREEN'),
  stoppedOrSlow('STOPPED_OR_SLOW'),
  intervalOverlap('INTERVAL_OVERLAP');

  const PredictionReason(this.code);
  final String code;
}

/// Nullable bounds are retained until evaluation, where missing data fails closed.
class NumericInterval {
  const NumericInterval({required this.min, required this.max});

  final double? min;
  final double? max;

  bool get isValid =>
      _finiteNonNegative(min) && _finiteNonNegative(max) && min! <= max!;
}

class IntervalMs {
  const IntervalMs({required this.earliestMs, required this.latestMs});

  final int? earliestMs;
  final int? latestMs;

  bool get isValid =>
      _validDuration(earliestMs) &&
      _validDuration(latestMs) &&
      earliestMs! <= latestMs!;

  Map<String, Object?> toJson() => {
        'earliestMs': earliestMs,
        'latestMs': latestMs,
      };
}

/// Operational approval and all calibrated values must be supplied explicitly.
/// A fixture policy cannot authorize an operational input, even if serialized.
class PredictionPolicy {
  const PredictionPolicy({
    required this.policyVersion,
    required this.approvedForOperation,
    required this.maxSignalAgeMs,
    required this.clockSkewBudgetMs,
    required this.minimumSpeedMps,
    required this.maxHorizontalAccuracyM,
    required this.extraSafetyMarginMs,
    required this.measurementEvidence,
  }) : syntheticFixtureOnly = false;

  const PredictionPolicy.syntheticFixture({
    required this.maxSignalAgeMs,
    required this.clockSkewBudgetMs,
    required this.minimumSpeedMps,
    required this.maxHorizontalAccuracyM,
    required this.extraSafetyMarginMs,
  })  : policyVersion = 'synthetic-fixture-only',
        approvedForOperation = false,
        measurementEvidence =
            'Synthetic test values; not operational evidence.',
        syntheticFixtureOnly = true;

  final String? policyVersion;
  final bool? approvedForOperation;
  final int? maxSignalAgeMs;
  final int? clockSkewBudgetMs;
  final double? minimumSpeedMps;
  final double? maxHorizontalAccuracyM;
  final int? extraSafetyMarginMs;
  final String? measurementEvidence;
  final bool syntheticFixtureOnly;

  bool get isValid =>
      policyVersion != null &&
      policyVersion!.trim().isNotEmpty &&
      measurementEvidence != null &&
      measurementEvidence!.trim().isNotEmpty &&
      _validDuration(maxSignalAgeMs) &&
      maxSignalAgeMs! > 0 &&
      _validDuration(clockSkewBudgetMs) &&
      _finitePositive(minimumSpeedMps) &&
      _finitePositive(maxHorizontalAccuracyM) &&
      _validDuration(extraSafetyMarginMs);

  Map<String, Object?> toJson() => {
        'schemaVersion': 'sa-contract-1',
        'kind': 'PredictionPolicy',
        'policyVersion': policyVersion,
        'approvedForOperation': approvedForOperation,
        'maxSignalAgeMs': maxSignalAgeMs,
        'clockSkewBudgetMs': clockSkewBudgetMs,
        'minimumSpeedMps': minimumSpeedMps,
        'maxHorizontalAccuracyM': maxHorizontalAccuracyM,
        'extraSafetyMarginMs': extraSafetyMarginMs,
        'measurementEvidence': measurementEvidence,
      };
}

/// All intervals are normalized to the same decision instant by the caller.
/// In particular, greenRemainingMs is the deadline's remainingMs, not a source
/// countdown. signalFresh must include the deadline's strict TTL check.
class PredictionInput {
  const PredictionInput({
    required this.sessionActive,
    required this.targetMatched,
    required this.signalState,
    required this.signalFresh,
    required this.timingQuality,
    required this.locationValid,
    required this.horizontalAccuracyM,
    required this.distanceM,
    required this.speedMps,
    required this.greenRemainingMs,
    this.syntheticFixture = false,
  });

  final bool? sessionActive;
  final bool? targetMatched;
  final SignalState? signalState;
  final bool? signalFresh;
  final TimingQuality? timingQuality;
  final bool? locationValid;
  final double? horizontalAccuracyM;
  final NumericInterval? distanceM;
  final NumericInterval? speedMps;
  final IntervalMs? greenRemainingMs;
  final bool syntheticFixture;
}

class PredictionResult {
  const PredictionResult._({
    required this.status,
    required this.reason,
    required this.signalStateAtDecision,
    this.arrivalIntervalMs,
    this.greenRemainingIntervalMs,
  });

  final PredictionStatus status;
  final PredictionReason reason;
  final IntervalMs? arrivalIntervalMs;
  final IntervalMs? greenRemainingIntervalMs;
  final SignalState signalStateAtDecision;

  Map<String, Object?> toJson() => {
        'schemaVersion': 'sa-contract-1',
        'kind': 'PredictionResult',
        'status': status.name,
        'reason': reason.code,
        'arrivalIntervalMs': arrivalIntervalMs?.toJson(),
        'greenRemainingIntervalMs': greenRemainingIntervalMs?.toJson(),
        'signalStateAtDecision': signalStateAtDecision.name,
      };
}

bool _finiteNonNegative(double? value) =>
    value != null && value.isFinite && value >= 0;

bool _finitePositive(double? value) => _finiteNonNegative(value) && value! > 0;

bool _validDuration(int? value) =>
    value != null && value >= 0 && value <= _maximumExactInteger;

/// SA-10 strict interval comparison. No clock, I/O, probability or phase guessing.
PredictionResult evaluatePrediction(
    PredictionInput input, PredictionPolicy? policy) {
  final signalState = input.signalState ?? SignalState.unknown;
  PredictionResult unknown(PredictionReason reason,
          {IntervalMs? arrival, IntervalMs? green}) =>
      PredictionResult._(
        status: PredictionStatus.unknown,
        reason: reason,
        signalStateAtDecision: signalState,
        arrivalIntervalMs: arrival,
        greenRemainingIntervalMs: green,
      );

  if (input.sessionActive != true) {
    return unknown(PredictionReason.sessionInactive);
  }
  if (policy == null ||
      !policy.isValid ||
      (policy.syntheticFixtureOnly
          ? !input.syntheticFixture
          : policy.approvedForOperation != true)) {
    return unknown(PredictionReason.policyUncalibrated);
  }
  if (input.signalFresh != true) {
    return unknown(PredictionReason.signalStale);
  }
  final green = input.greenRemainingMs;
  if (input.timingQuality != TimingQuality.verified ||
      green == null ||
      !green.isValid) {
    return unknown(PredictionReason.timingUnverified);
  }
  // A possible phase-end already lies at/before now: do not guess its color.
  if (green.earliestMs! <= 0) {
    return unknown(PredictionReason.signalStale);
  }

  final distance = input.distanceM;
  final speed = input.speedMps;
  if (input.locationValid != true ||
      !_finitePositive(input.horizontalAccuracyM) ||
      input.horizontalAccuracyM! > policy.maxHorizontalAccuracyM! ||
      distance == null ||
      !distance.isValid ||
      distance.min! <= 0 ||
      speed == null ||
      !speed.isValid) {
    // Includes uncertainty touching/crossing the stopline, not merely dMax < 0.
    return unknown(PredictionReason.locationInvalid, green: green);
  }
  IntervalMs? arrival;
  if (speed.min! > 0) {
    final earliest = distance.min! / speed.max! * 1000;
    final latest = distance.max! / speed.min! * 1000;
    if (!earliest.isFinite ||
        !latest.isFinite ||
        latest > _maximumExactInteger ||
        latest + policy.extraSafetyMarginMs! > _maximumExactInteger) {
      return unknown(PredictionReason.locationInvalid, green: green);
    }
    // Outward rounding cannot manufacture an optimistic interval separation.
    arrival = IntervalMs(earliestMs: earliest.floor(), latestMs: latest.ceil());
  }
  if (input.targetMatched != true) {
    return unknown(PredictionReason.targetAmbiguous, green: green);
  }
  if (signalState != SignalState.green) {
    return unknown(PredictionReason.signalNotGreen, green: green);
  }
  if (speed.min! <= 0 || speed.min! < policy.minimumSpeedMps!) {
    return unknown(PredictionReason.stoppedOrSlow, green: green);
  }

  final status =
      arrival!.latestMs! + policy.extraSafetyMarginMs! < green.earliestMs!
          ? PredictionStatus.possible
          : arrival.earliestMs! > green.latestMs!
              ? PredictionStatus.unlikely
              : PredictionStatus.unknown;

  // Canonical sa-contract-1 requires a reason even for classified outcomes and
  // provides no success reason. INTERVAL_OVERLAP is diagnostic only for unknown;
  // consumers must branch on status before interpreting reason.
  return PredictionResult._(
    status: status,
    reason: PredictionReason.intervalOverlap,
    signalStateAtDecision: signalState,
    arrivalIntervalMs: arrival,
    greenRemainingIntervalMs: green,
  );
}
