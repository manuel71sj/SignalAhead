import { describe, expect, test } from "vitest";
import { evaluatePrediction, type PredictionInput, type PredictionPolicyInput } from "../../src/prediction/evaluatePrediction.js";

const policy: PredictionPolicyInput = { approvedForOperation: true, minimumSpeedMps: 0.1, decisionMarginMs: 0 };

function input(overrides: Partial<PredictionInput> = {}): PredictionInput {
  return {
    sessionActive: true,
    targetMatched: true,
    signalState: "green",
    signalFresh: true,
    timingQuality: "verified",
    distanceM: { min: 13, max: 17 },
    speedMps: { min: 1, max: 1 },
    greenRemainingMs: { earliestMs: 20_000, latestMs: 26_000 },
    ...overrides
  };
}

describe("prediction engine", () => {
  test("evaluates deterministic interval examples", () => {
    expect(evaluatePrediction(input(), policy).status).toBe("possible");
    expect(evaluatePrediction(input({ distanceM: { min: 22, max: 26 }, greenRemainingMs: { earliestMs: 12_000, latestMs: 18_000 } }), policy).status).toBe("unlikely");
    expect(evaluatePrediction(input({ distanceM: { min: 13, max: 20 }, greenRemainingMs: { earliestMs: 20_000, latestMs: 26_000 } }), policy).status).toBe("unknown");
  });

  test("does not allow optimistic predictions for invalid timing, policy or signal colors", () => {
    expect(evaluatePrediction(input({ timingQuality: "unverified" }), policy)).toMatchObject({ status: "unknown", reason: "TIMING_UNVERIFIED" });
    expect(evaluatePrediction(input(), { ...policy, approvedForOperation: false })).toMatchObject({ status: "unknown", reason: "POLICY_UNCALIBRATED" });
    for (const signalState of ["yellow", "red", "flashing", "unknown"] as const) {
      expect(evaluatePrediction(input({ signalState }), policy)).toMatchObject({ status: "unknown", reason: "SIGNAL_NOT_GREEN" });
    }
  });

  test("rejects zero, NaN, negative and stale values", () => {
    expect(evaluatePrediction(input({ speedMps: { min: 0, max: 0 } }), policy)).toMatchObject({ status: "unknown", reason: "LOCATION_INVALID" });
    expect(evaluatePrediction(input({ distanceM: { min: Number.NaN, max: 20 } }), policy)).toMatchObject({ status: "unknown", reason: "LOCATION_INVALID" });
    expect(evaluatePrediction(input({ greenRemainingMs: { earliestMs: -1, latestMs: 10 } }), policy)).toMatchObject({ status: "unknown", reason: "TIMING_UNVERIFIED" });
    expect(evaluatePrediction(input({ signalFresh: false }), policy)).toMatchObject({ status: "unknown", reason: "SIGNAL_STALE" });
  });

  test("uses strict less-than for possible boundary", () => {
    const result = evaluatePrediction(input({ distanceM: { min: 10, max: 20 }, greenRemainingMs: { earliestMs: 20_000, latestMs: 26_000 } }), policy);
    expect(result).toMatchObject({ status: "unknown", reason: "INTERVAL_OVERLAP" });
  });
});
