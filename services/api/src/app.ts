import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import pg from "pg";
import { CatalogStore } from "./catalog/catalogStore.js";
import { SignalEventCache } from "./collection/signalEventCache.js";
import type { RuntimeConfig } from "./config.js";
import { readinessReport, type DependencyClients } from "./readiness.js";
import { registerCatalogRoutes } from "./routes/catalog.js";
import { registerSignalRoutes } from "./routes/signals.js";
import { registerStreamRoutes } from "./routes/stream.js";
import { registerTimeRoutes } from "./routes/time.js";

export type AppOptions = {
  config: RuntimeConfig;
  dependencies?: DependencyClients;
  catalogStore?: CatalogStore;
  signalCache?: SignalEventCache;
};

export function buildApp(options: AppOptions): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 2048, requestTimeout: 5000 });
  const pool = options.catalogStore === undefined && options.config.databaseUrl !== null ? new pg.Pool({ connectionString: options.config.databaseUrl, max: 5, connectionTimeoutMillis: 1500, query_timeout: 1500, statement_timeout: 1500 }) : undefined;
  pool?.on("error", () => { /* Requests fail closed; never log connection credentials. */ });
  if (pool !== undefined) app.addHook("onClose", async () => { await pool.end(); });
  const catalogStore = options.catalogStore ?? new CatalogStore(pool);
  const signalCache = options.signalCache ?? new SignalEventCache();
  const dependencies: DependencyClients = { ...options.dependencies };
  if (pool !== undefined && dependencies.databasePing === undefined) dependencies.databasePing = async () => { await pool.query("select catalog_version from catalog_versions limit 1"); };

  app.get("/healthz", async () => ({ ok: true, service: "signalahead-api" }));
  app.get("/readyz", async (_request, reply) => {
    const report = await readinessReport(options.config, dependencies);
    return report.ready ? report : reply.status(503).send(report);
  });

  app.register(async (routes) => {
    // Register the websocket hooks before declaring any upgrade route.
    await routes.register(websocket, { options: { maxPayload: 2048, perMessageDeflate: false } });
    registerCatalogRoutes(routes, catalogStore);
    registerTimeRoutes(routes);
    registerSignalRoutes(routes, signalCache, catalogStore);
    registerStreamRoutes(routes, signalCache, catalogStore);
  });
  return app;
}
