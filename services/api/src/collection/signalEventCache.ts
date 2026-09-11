import type { NationalObservation } from "../providers/national/types.js";

export type CacheApplyResult = "inserted" | "duplicate" | "older_ignored" | "updated" | "unknown_order";

export type CachedSignal = {
  observation: NationalObservation;
  firstSeenAtUtcMs: number;
  lastSeenAtUtcMs: number;
  expiresAtUtcMs: number | null;
  fingerprint: string;
};

function fingerprint(observation: NationalObservation): string {
  return [
    observation.provider,
    observation.sourceIntersectionId,
    observation.sourceDirectionCode,
    observation.sourceEventId ?? "unknown-event",
    observation.rawStateCode ?? "unknown-state",
    observation.rawRemainingValue ?? "unknown-remaining"
  ].join("|");
}

function sourceOrder(observation: NationalObservation): string | null {
  return observation.sourceEventId;
}

export class SignalEventCache {
  readonly #signals = new Map<string, CachedSignal>();

  get(key: string): CachedSignal | undefined {
    return this.#signals.get(key);
  }

  apply(observation: NationalObservation, nowUtcMs: number): CacheApplyResult {
    const current = this.#signals.get(observation.approachKey);
    const nextFingerprint = fingerprint(observation);
    if (current === undefined) {
      this.#signals.set(observation.approachKey, {
        observation,
        firstSeenAtUtcMs: nowUtcMs,
        lastSeenAtUtcMs: nowUtcMs,
        expiresAtUtcMs: observation.expiresAtUtcMs,
        fingerprint: nextFingerprint
      });
      return "inserted";
    }

    if (current.fingerprint === nextFingerprint) {
      current.lastSeenAtUtcMs = nowUtcMs;
      return "duplicate";
    }

    const currentOrder = sourceOrder(current.observation);
    const nextOrder = sourceOrder(observation);
    if (currentOrder !== null && nextOrder !== null && nextOrder < currentOrder) {
      current.lastSeenAtUtcMs = nowUtcMs;
      return "older_ignored";
    }

    const result: CacheApplyResult = currentOrder === null || nextOrder === null || nextOrder === currentOrder ? "unknown_order" : "updated";
    this.#signals.set(observation.approachKey, {
      observation,
      firstSeenAtUtcMs: nowUtcMs,
      lastSeenAtUtcMs: nowUtcMs,
      expiresAtUtcMs: observation.expiresAtUtcMs,
      fingerprint: nextFingerprint
    });
    return result;
  }
}
