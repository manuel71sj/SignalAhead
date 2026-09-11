import { describe, expect, test } from "vitest";
import { RequestBudget, retryDelayMs } from "../../src/collection/requestBudget.js";
import { nationalRequestPlan } from "../../src/collection/sharedRequests.js";
import { SignalEventCache } from "../../src/collection/signalEventCache.js";
import type { NationalObservation } from "../../src/providers/national/types.js";

function observation(sourceEventId: string, remainingAtSourceMs: number): NationalObservation {
  return {
    schemaVersion: "sa-contract-1",
    kind: "SignalObservation",
    provider: "national",
    intersectionKey: "national:1100000000:1",
    approachKey: "national:1100000000:1:straight:nt",
    movement: "straight",
    signalState: "green",
    catalogVersion: "test",
    sourceRevision: sourceEventId,
    sourceIntersectionId: "1100000000:1",
    sourceEventId,
    sourceObservedAtUtcMs: null,
    sourceTimeKind: "unknown",
    serverReceivedAtUtcMs: 0,
    serverSentAtUtcMs: 0,
    remainingAtSourceMs,
    expiresAtUtcMs: 1000 + remainingAtSourceMs,
    timingQuality: "unverified",
    unitEvidence: {
      sourceField: "ntStsgRmndCs",
      sourceUnit: "unknown",
      conversion: "not converted",
      evidence: "test"
    },
    rawStateCode: "protected-Movement-Allowed",
    sourceDirectionCode: "nt",
    rawRemainingValue: String(remainingAtSourceMs),
    disabledForPrediction: true,
    disabledReason: "UNVERIFIED_UNIT"
  };
}

describe("national collection controls", () => {
  test("shares one source request across many same-region subscribers", () => {
    const subscriptions = Array.from({ length: 100 }, (_, index) => ({
      subscriptionId: `subscriber-${index}`,
      provider: "national" as const,
      stdgCd: "1100000000"
    }));

    expect(nationalRequestPlan(subscriptions, 100)).toEqual([{ stdgCd: "1100000000", pageNo: 1, numOfRows: 100 }]);
  });

  test("blocks collection when quota is unconfigured and charges retries", () => {
    const unconfigured = new RequestBudget({ dailyLimit: null, perSecondLimit: null, dayStartedAtUtcMs: 0 });
    const configured = new RequestBudget({ dailyLimit: 2, perSecondLimit: 10, dayStartedAtUtcMs: 0 });

    expect(unconfigured.reserve(0)).toEqual({ allowed: false, reason: "quota_unconfigured", retryAfterMs: null });
    expect(configured.reserve(0)).toMatchObject({ allowed: true, remainingDaily: 1 });
    expect(configured.reserve(100)).toMatchObject({ allowed: true, remainingDaily: 0 });
    expect(configured.reserve(200)).toEqual({ allowed: false, reason: "daily_exhausted", retryAfterMs: null });
    expect(retryDelayMs(10, null)).toBe(60_000);
    expect(retryDelayMs(1, 120_000)).toBe(60_000);
  });

  test("does not extend cached event expiry on duplicates and ignores older events", () => {
    const cache = new SignalEventCache();
    const eventA = observation("20260910185819", 21);
    const duplicateA = observation("20260910185819", 21);
    const olderB = observation("20260910185818", 999);
    const newC = observation("20260910185820", 5);

    expect(cache.apply(eventA, 100)).toBe("inserted");
    const firstExpiry = cache.get(eventA.approachKey)?.expiresAtUtcMs;

    expect(cache.apply(duplicateA, 200)).toBe("duplicate");
    expect(cache.get(eventA.approachKey)?.expiresAtUtcMs).toBe(firstExpiry);

    expect(cache.apply(olderB, 300)).toBe("older_ignored");
    expect(cache.get(eventA.approachKey)?.observation.sourceEventId).toBe("20260910185819");

    expect(cache.apply(newC, 400)).toBe("updated");
    expect(cache.get(eventA.approachKey)?.observation.sourceEventId).toBe("20260910185820");
  });
});
