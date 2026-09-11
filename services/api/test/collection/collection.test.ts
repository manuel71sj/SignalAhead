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
    rawStateCode: "protected-Movement-Allowed"
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

  test("opaque unverified IDs never establish lexical ordering or extend expiry", () => {
    const cache = new SignalEventCache();
    const eventA = observation("20260910185819", 21);
    expect(cache.apply(eventA, 100)).toBe("inserted");
    expect(cache.apply({ ...eventA, serverReceivedAtUtcMs: 200 }, 200)).toBe("duplicate");
    expect(cache.get(eventA.approachKey)?.expiresAtUtcMs).toBe(eventA.expiresAtUtcMs);
    const opaqueB = observation("20260910185818", 999);
    expect(cache.apply(opaqueB, 300)).toBe("unknown_order");
    expect(cache.get(eventA.approachKey)?.observation).toMatchObject({ sourceEventId: opaqueB.sourceEventId, timingQuality: "unverified", remainingAtSourceMs: null, expiresAtUtcMs: null });
  });

  test("only verified generation times can discard an older event", () => {
    const cache = new SignalEventCache();
    const initial: NationalObservation = { ...observation("opaque-z", 1000), timingQuality: "verified", sourceTimeKind: "generated", sourceObservedAtUtcMs: 100 };
    cache.apply(initial, 100);
    expect(cache.apply({ ...initial, sourceEventId: "opaque-zz", sourceObservedAtUtcMs: 99 }, 101)).toBe("older_ignored");
    expect(cache.get(initial.approachKey)?.observation.sourceObservedAtUtcMs).toBe(100);
    expect(cache.apply({ ...initial, sourceEventId: "opaque-a", sourceObservedAtUtcMs: 101 }, 102)).toBe("updated");
    expect(cache.get(initial.approachKey)?.observation.sourceEventId).toBe("opaque-a");
  });
});
