import { Redis } from "ioredis";
import pg from "pg";
import type { RuntimeConfig } from "./config.js";

export type DependencyStatus = "ok" | "missing_config" | "unavailable";

export type ReadinessReport = {
  ready: boolean;
  dependencies: {
    database: DependencyStatus;
    redis: DependencyStatus;
  };
  missingRequired: string[];
  missingProviderKeys: string[];
};

export type DependencyClients = {
  databasePing?: (databaseUrl: string) => Promise<void>;
  redisPing?: (redisUrl: string) => Promise<void>;
};

async function defaultDatabasePing(databaseUrl: string): Promise<void> {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 1 });
  try {
    await pool.query("select 1");
  } finally {
    await pool.end();
  }
}

async function defaultRedisPing(redisUrl: string): Promise<void> {
  const redis = new Redis(redisUrl, { lazyConnect: true, maxRetriesPerRequest: 0 });
  try {
    await redis.connect();
    await redis.ping();
  } finally {
    redis.disconnect();
  }
}

async function checkDatabase(config: RuntimeConfig, ping: (databaseUrl: string) => Promise<void>): Promise<DependencyStatus> {
  if (config.databaseUrl === null) {
    return "missing_config";
  }
  try {
    await ping(config.databaseUrl);
    return "ok";
  } catch {
    return "unavailable";
  }
}

async function checkRedis(config: RuntimeConfig, ping: (redisUrl: string) => Promise<void>): Promise<DependencyStatus> {
  if (config.redisUrl === null) {
    return "missing_config";
  }
  try {
    await ping(config.redisUrl);
    return "ok";
  } catch {
    return "unavailable";
  }
}

export async function readinessReport(
  config: RuntimeConfig,
  clients: DependencyClients = {}
): Promise<ReadinessReport> {
  const [database, redis] = await Promise.all([
    checkDatabase(config, clients.databasePing ?? defaultDatabasePing),
    checkRedis(config, clients.redisPing ?? defaultRedisPing)
  ]);
  const ready = database === "ok" && redis === "ok" && config.missingRequired.length === 0;

  return {
    ready,
    dependencies: { database, redis },
    missingRequired: config.missingRequired,
    missingProviderKeys: config.missingProviderKeys
  };
}
