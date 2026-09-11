import Fastify, { type FastifyInstance } from "fastify";
import type { RuntimeConfig } from "./config.js";
import { readinessReport, type DependencyClients } from "./readiness.js";

export type AppOptions = {
  config: RuntimeConfig;
  dependencies?: DependencyClients;
};

export function buildApp(options: AppOptions): FastifyInstance {
  const app = Fastify({ logger: false });

  app.get("/healthz", async () => ({
    ok: true,
    service: "signalahead-api"
  }));

  app.get("/readyz", async (_request, reply) => {
    const report = await readinessReport(options.config, options.dependencies ?? {});
    if (!report.ready) {
      return reply.status(503).send(report);
    }
    return report;
  });

  return app;
}
