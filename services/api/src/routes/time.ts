import type { FastifyInstance, FastifyRequest } from "fastify";

/** Bounds server processing separately from the client's monotonic HTTP RTT. */
export function registerTimeRoutes(app: FastifyInstance): void {
  const received = new WeakMap<FastifyRequest, number>();
  app.get("/v1/time", {
    onRequest: async (request) => { received.set(request, Date.now()); },
  }, async (request, reply) => {
    const serverReceivedAtUtcMs = received.get(request)!;
    const serverSentAtUtcMs = Date.now();
    // Do not conceal a server wall-clock rollback by clamping either stamp.
    // The client rejects inverted or uncertain calibration samples.
    return reply.header("Cache-Control", "no-store").send({ serverReceivedAtUtcMs, serverSentAtUtcMs });
  });
}
