import type { FastifyInstance } from "fastify";
import type { CatalogStore } from "../catalog/catalogStore.js";
import type { ApproachCatalog } from "../catalog/types.js";
import type { SignalEventCache } from "../collection/signalEventCache.js";
import type { NationalObservation } from "../providers/national/types.js";

export type SignalUnavailableReason = "TARGET_UNKNOWN" | "MOVEMENT_UNSUPPORTED" | "SIGNAL_EXPIRED" | "CATALOG_MISMATCH" | "TIMING_UNVERIFIED" | "SIGNAL_UNKNOWN" | "CATALOG_UNAVAILABLE";
export type SignalResult = { available: true; reason: null; approachKey: string; snapshot: NationalObservation } | { available: false; reason: SignalUnavailableReason; approachKey: string; snapshot: null };
export const MAX_SIGNAL_AGE_MS = 5000;

export function signalResult(approachKey: string, movement: unknown, catalogVersion: unknown, active: ApproachCatalog | null, cache: SignalEventCache, now = Date.now()): SignalResult {
  const unavailable = (reason: SignalUnavailableReason): SignalResult => ({ available: false, reason, approachKey, snapshot: null });
  if (movement !== "straight") return unavailable("MOVEMENT_UNSUPPORTED");
  if (active === null) return unavailable("CATALOG_UNAVAILABLE");
  if (catalogVersion !== active.catalogVersion) return unavailable("CATALOG_MISMATCH");
  const approach = active.approaches.find((item) => item.approachKey === approachKey && item.enabledForOperation && item.movement === "straight");
  if (approach === undefined) return unavailable("TARGET_UNKNOWN");
  const intersection = active.intersections.find((item) => item.intersectionKey === approach.intersectionKey);
  const cached = cache.get(approachKey);
  if (cached === undefined || intersection === undefined) return unavailable("TARGET_UNKNOWN");
  const signal = cached.observation;
  if (signal.catalogVersion !== active.catalogVersion || signal.intersectionKey !== intersection.intersectionKey || signal.provider !== intersection.provider || signal.sourceIntersectionId !== intersection.sourceIntersectionId || signal.movement !== "straight") return unavailable("CATALOG_MISMATCH");
  if (signal.timingQuality !== "verified" || signal.unitEvidence.sourceUnit === "unknown" || signal.sourceTimeKind !== "generated" || signal.sourceObservedAtUtcMs === null || signal.remainingAtSourceMs === null || signal.expiresAtUtcMs === null) return unavailable("TIMING_UNVERIFIED");
  // Flashing is a current state, never a green crossing prediction.
  if (signal.signalState === "unknown") return unavailable("SIGNAL_UNKNOWN");
  if (signal.sourceObservedAtUtcMs > signal.serverReceivedAtUtcMs || signal.serverReceivedAtUtcMs > signal.serverSentAtUtcMs || signal.serverSentAtUtcMs > now || now - signal.sourceObservedAtUtcMs > MAX_SIGNAL_AGE_MS || now - signal.serverReceivedAtUtcMs > MAX_SIGNAL_AGE_MS || signal.expiresAtUtcMs <= now || signal.sourceObservedAtUtcMs + signal.remainingAtSourceMs <= now) return unavailable("SIGNAL_EXPIRED");
  return { available: true, reason: null, approachKey, snapshot: signal };
}

export function registerSignalRoutes(app: FastifyInstance, signalCache: SignalEventCache, catalogStore: CatalogStore): void {
  app.get("/v1/signals", async (request, reply) => {
    const query = request.query as { approachKey?: unknown; movement?: unknown; catalogVersion?: unknown };
    if (typeof query.approachKey !== "string" || !query.approachKey.trim() || query.approachKey.length > 512) return reply.status(400).send({ error: "INVALID_APPROACH_KEY" });
    if (typeof query.catalogVersion !== "string" || !query.catalogVersion.trim() || query.catalogVersion.length > 512) return reply.status(400).send({ error: "INVALID_CATALOG_VERSION" });
    try {
      return signalResult(query.approachKey, query.movement, query.catalogVersion, await catalogStore.getActive(), signalCache);
    } catch {
      return reply.status(503).send({ available: false, reason: "CATALOG_UNAVAILABLE", approachKey: query.approachKey, snapshot: null });
    }
  });
}
