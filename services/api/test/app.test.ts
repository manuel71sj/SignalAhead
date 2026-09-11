import { describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";

const baseEnv = {
  PORT: "3000",
  DATABASE_URL: "postgres://signalahead:signalahead@localhost:5432/signalahead",
  REDIS_URL: "redis://localhost:6379/0"
};

describe("health and readiness", () => {
  test("healthz only reports process liveness", async () => {
    const app = buildApp({ config: loadConfig({}) });
    const response = await app.inject({ method: "GET", url: "/healthz" });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ ok: true, service: "signalahead-api" });
  });

  test("readyz reports missing db and cache configuration", async () => {
    const app = buildApp({ config: loadConfig({ PORT: "3000" }) });
    const response = await app.inject({ method: "GET", url: "/readyz" });

    expect(response.statusCode).toBe(503);
    expect(response.json()).toMatchObject({
      ready: false,
      dependencies: { database: "missing_config", redis: "missing_config" },
      missingRequired: ["DATABASE_URL", "REDIS_URL"]
    });
  });

  test("readyz fails when Redis is unavailable but health remains independent", async () => {
    const app = buildApp({
      config: loadConfig(baseEnv),
      dependencies: {
        databasePing: async () => undefined,
        redisPing: async () => {
          throw new Error("redis offline");
        }
      }
    });

    const health = await app.inject({ method: "GET", url: "/healthz" });
    const ready = await app.inject({ method: "GET", url: "/readyz" });

    expect(health.statusCode).toBe(200);
    expect(ready.statusCode).toBe(503);
    expect(ready.json()).toMatchObject({
      ready: false,
      dependencies: { database: "ok", redis: "unavailable" }
    });
  });

  test("readyz succeeds with db and cache while provider keys remain explicit", async () => {
    const app = buildApp({
      config: loadConfig(baseEnv),
      dependencies: {
        databasePing: async () => undefined,
        redisPing: async () => undefined
      }
    });
    const response = await app.inject({ method: "GET", url: "/readyz" });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      ready: true,
      dependencies: { database: "ok", redis: "ok" },
      missingRequired: [],
      missingProviderKeys: ["NATIONAL_SERVICE_KEY", "SEOUL_API_KEY", "ULSAN_SERVICE_KEY"]
    });
  });
});
