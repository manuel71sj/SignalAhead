import { validateSignalShape } from "../contracts.js";
import type { NationalObservation } from "../providers/national/types.js";

export type CacheApplyResult = "inserted" | "duplicate" | "older_ignored" | "updated" | "unknown_order" | "invalid";
export type CachedSignal = {
  observation: NationalObservation;
  firstSeenAtUtcMs: number;
  lastSeenAtUtcMs: number;
  expiresAtUtcMs: number | null;
  fingerprint: string;
};

export class SignalEventCache {
  readonly #signals = new Map<string, CachedSignal>();

  get(key: string): CachedSignal | undefined {
    return this.#signals.get(key);
  }

  apply(observation: NationalObservation, nowUtcMs: number): CacheApplyResult {
    if (!validateSignalShape(observation) || !Number.isSafeInteger(nowUtcMs) || nowUtcMs < 0) return "invalid";
    if ([observation.sourceObservedAtUtcMs, observation.serverReceivedAtUtcMs, observation.serverSentAtUtcMs, observation.remainingAtSourceMs, observation.expiresAtUtcMs].some((value) => value !== null && !Number.isSafeInteger(value))) return "invalid";
    const current = this.#signals.get(observation.approachKey);
    const { serverReceivedAtUtcMs: _received, serverSentAtUtcMs: _sent, ...event } = observation;
    const fingerprint = JSON.stringify(event);
    if (current?.fingerprint === fingerprint) {
      current.lastSeenAtUtcMs = nowUtcMs;
      return "duplicate";
    }
    // Provider event IDs are opaque identifiers, never sortable timestamps. Only a
    // verified generation time establishes ordering; totDt currently proves neither.
    const nextOrder = observation.timingQuality === "verified" && observation.sourceTimeKind === "generated" ? observation.sourceObservedAtUtcMs : null;
    const currentOrder = current?.observation.timingQuality === "verified" && current.observation.sourceTimeKind === "generated" ? current.observation.sourceObservedAtUtcMs : null;
    if (current !== undefined && currentOrder != null && nextOrder !== null && current.observation.catalogVersion === observation.catalogVersion && nextOrder < currentOrder) return "older_ignored";
    const result: CacheApplyResult = current === undefined ? "inserted" : currentOrder == null || nextOrder === null || nextOrder === currentOrder ? "unknown_order" : "updated";
    const stored = structuredClone(observation);
    if (result === "unknown_order") {
      stored.timingQuality = "unverified";
      stored.remainingAtSourceMs = null;
      stored.expiresAtUtcMs = null;
    }
    if (current === undefined && this.#signals.size >= 10000) {
      const oldest = this.#signals.keys().next().value;
      if (oldest !== undefined) this.#signals.delete(oldest);
    }
    this.#signals.set(observation.approachKey, { observation: stored, firstSeenAtUtcMs: nowUtcMs, lastSeenAtUtcMs: nowUtcMs, expiresAtUtcMs: stored.expiresAtUtcMs, fingerprint });
    return result;
  }
}
