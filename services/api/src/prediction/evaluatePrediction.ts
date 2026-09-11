export type PredictionStatus = "possible" | "unlikely" | "unknown";
export type PredictionReason =
  | "SESSION_INACTIVE"
  | "POLICY_UNCALIBRATED"
  | "SIGNAL_STALE"
  | "TIMING_UNVERIFIED"
  | "LOCATION_INVALID"
  | "TARGET_AMBIGUOUS"
  | "SIGNAL_NOT_GREEN"
  | "STOPPED_OR_SLOW"
  | "INTERVAL_OVERLAP";

export type IntervalMs = { earliestMs: number; latestMs: number };

export type PredictionInput = {
  sessionActive: boolean;
  targetMatched: boolean;
  signalState: "green" | "yellow" | "red" | "flashing" | "unknown";
  signalFresh: boolean;
  timingQuality: "verified" | "unverified";
  distanceM: { min: number; max: number } | null;
  speedMps: { min: number; max: number } | null;
  greenRemainingMs: IntervalMs | null;
};

export type PredictionPolicyInput = {
  approvedForOperation: boolean;
  minimumSpeedMps: number;
  decisionMarginMs: number;
};

export type PredictionResult = {
  schemaVersion: "sa-contract-1";
  kind: "PredictionResult";
  status: PredictionStatus;
  reason: PredictionReason;
  arrivalIntervalMs: IntervalMs | null;
  greenRemainingIntervalMs: IntervalMs | null;
  signalStateAtDecision: PredictionInput["signalState"];
};

function finiteNonNegative(value: number): boolean {
  return Number.isFinite(value) && value >= 0;
}

function validInterval(interval: IntervalMs | null): interval is IntervalMs {
  return interval !== null && finiteNonNegative(interval.earliestMs) && finiteNonNegative(interval.latestMs) && interval.earliestMs <= interval.latestMs;
}

function unknown(reason: PredictionReason, signalState: PredictionInput["signalState"], arrivalIntervalMs: IntervalMs | null = null, greenRemainingIntervalMs: IntervalMs | null = null): PredictionResult {
  return {
    schemaVersion: "sa-contract-1",
    kind: "PredictionResult",
    status: "unknown",
    reason,
    arrivalIntervalMs,
    greenRemainingIntervalMs,
    signalStateAtDecision: signalState
  };
}

function arrivalInterval(input: PredictionInput, policy: PredictionPolicyInput): IntervalMs | null {
  if (input.distanceM === null || input.speedMps === null) {
    return null;
  }
  const { min: dMin, max: dMax } = input.distanceM;
  const { min: vMin, max: vMax } = input.speedMps;
  if (!finiteNonNegative(dMin) || !finiteNonNegative(dMax) || dMin > dMax || !Number.isFinite(vMin) || !Number.isFinite(vMax)) {
    return null;
  }
  if (vMin <= 0 || vMax <= 0 || vMin > vMax || vMin < policy.minimumSpeedMps) {
    return null;
  }
  return {
    earliestMs: Math.ceil((Math.max(0, dMin) / vMax) * 1000),
    latestMs: Math.ceil((dMax / vMin) * 1000)
  };
}

export function evaluatePrediction(input: PredictionInput, policy: PredictionPolicyInput): PredictionResult {
  if (!input.sessionActive) {
    return unknown("SESSION_INACTIVE", input.signalState);
  }
  if (!policy.approvedForOperation || !finiteNonNegative(policy.decisionMarginMs) || !finiteNonNegative(policy.minimumSpeedMps)) {
    return unknown("POLICY_UNCALIBRATED", input.signalState);
  }
  if (!input.signalFresh) {
    return unknown("SIGNAL_STALE", input.signalState);
  }
  if (input.timingQuality !== "verified" || !validInterval(input.greenRemainingMs)) {
    return unknown("TIMING_UNVERIFIED", input.signalState);
  }

  const arrival = arrivalInterval(input, policy);
  if (arrival === null) {
    return unknown("LOCATION_INVALID", input.signalState, null, input.greenRemainingMs);
  }
  if (!input.targetMatched) {
    return unknown("TARGET_AMBIGUOUS", input.signalState, arrival, input.greenRemainingMs);
  }
  if (input.signalState !== "green") {
    return unknown("SIGNAL_NOT_GREEN", input.signalState, arrival, input.greenRemainingMs);
  }
  if (input.speedMps !== null && input.speedMps.min < policy.minimumSpeedMps) {
    return unknown("STOPPED_OR_SLOW", input.signalState, arrival, input.greenRemainingMs);
  }

  if (arrival.latestMs + policy.decisionMarginMs < input.greenRemainingMs.earliestMs) {
    return { schemaVersion: "sa-contract-1", kind: "PredictionResult", status: "possible", reason: "INTERVAL_OVERLAP", arrivalIntervalMs: arrival, greenRemainingIntervalMs: input.greenRemainingMs, signalStateAtDecision: input.signalState };
  }
  if (arrival.earliestMs > input.greenRemainingMs.latestMs) {
    return { schemaVersion: "sa-contract-1", kind: "PredictionResult", status: "unlikely", reason: "INTERVAL_OVERLAP", arrivalIntervalMs: arrival, greenRemainingIntervalMs: input.greenRemainingMs, signalStateAtDecision: input.signalState };
  }
  return unknown("INTERVAL_OVERLAP", input.signalState, arrival, input.greenRemainingMs);
}
