import type { FastifyInstance } from "fastify";
import type { SignalEventCache } from "../collection/signalEventCache.js";

type SignalUnavailableReason = "TARGET_UNKNOWN" | "MOVEMENT_UNSUPPORTED" | "SIGNAL_EXPIRED" | "CATALOG_MISMATCH";

function unavailable(reason: SignalUnavailableReason, approachKey: string) {
  return { available: false, reason, approachKey, snapshot: null };
}

export function registerSignalRoutes(app: FastifyInstance, signalCache: SignalEventCache): void {
  app.get("/v1/signals", async (request, reply) => {
    const query = request.query as { approachKey?: unknown; movement?: unknown; catalogVersion?: unknown };
    if (typeof query.approachKey !== "string" || query.approachKey.length === 0) {
      return reply.status(400).send({ error: "INVALID_APPROACH_KEY" });
    }
    if (query.movement !== "straight") {
      return unavailable("MOVEMENT_UNSUPPORTED", query.approachKey);
    }

    const cached = signalCache.get(query.approachKey);
    if (cached === undefined) {
      return unavailable("TARGET_UNKNOWN", query.approachKey);
    }
    if (typeof query.catalogVersion === "string" && cached.observation.catalogVersion !== query.catalogVersion) {
      return unavailable("CATALOG_MISMATCH", query.approachKey);
    }
    if (cached.expiresAtUtcMs !== null && cached.expiresAtUtcMs <= Date.now()) {
      return unavailable("SIGNAL_EXPIRED", query.approachKey);
    }

    return { available: true, reason: null, approachKey: query.approachKey, snapshot: cached.observation };
  });
}
