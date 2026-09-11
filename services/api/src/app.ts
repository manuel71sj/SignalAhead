import Fastify, { type FastifyInstance } from "fastify";
import { CatalogStore } from "./catalog/catalogStore.js";
import { SignalEventCache } from "./collection/signalEventCache.js";
import type { RuntimeConfig } from "./config.js";
import { readinessReport, type DependencyClients } from "./readiness.js";
import { registerCatalogRoutes } from "./routes/catalog.js";
import { registerSignalRoutes } from "./routes/signals.js";
import { registerStreamRoutes } from "./routes/stream.js";

export type AppOptions = {
  config: RuntimeConfig;
  dependencies?: DependencyClients;
  catalogStore?: CatalogStore;
  signalCache?: SignalEventCache;
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

  const catalogStore = options.catalogStore ?? new CatalogStore();
  const signalCache = options.signalCache ?? new SignalEventCache();
  registerCatalogRoutes(app, catalogStore);
  registerSignalRoutes(app, signalCache);
  registerStreamRoutes(app, signalCache);

  return app;
}
