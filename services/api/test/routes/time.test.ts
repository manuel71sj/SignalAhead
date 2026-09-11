import { describe, expect, test, vi } from "vitest";
import { buildApp } from "../../src/app.js";
import { loadConfig } from "../../src/config.js";

describe("HTTP clock calibration", () => {
  test("real HTTP exchange returns uncached UTC stamps bounded by client receipt", async () => {
    const app = buildApp({ config: loadConfig({}) });
    const address = await app.listen({ host: "127.0.0.1", port: 0 });
    try {
      const sent = Date.now();
      const response = await fetch(`${address}/v1/time`);
      const body = await response.json() as { serverReceivedAtUtcMs: number; serverSentAtUtcMs: number };
      const received = Date.now();
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(Number.isSafeInteger(body.serverReceivedAtUtcMs)).toBe(true);
      expect(Number.isSafeInteger(body.serverSentAtUtcMs)).toBe(true);
      expect(body.serverReceivedAtUtcMs).toBeGreaterThanOrEqual(sent);
      expect(body.serverSentAtUtcMs).toBeGreaterThanOrEqual(body.serverReceivedAtUtcMs);
      expect(body.serverSentAtUtcMs).toBeLessThanOrEqual(received);
    } finally { await app.close(); }
  });

  test("receipt is captured before handler work and clock rollback stays visible", async () => {
    const app = buildApp({ config: loadConfig({}) });
    let now = 1000;
    app.addHook("preHandler", async () => { now = 900; });
    await app.ready();
    const clock = vi.spyOn(Date, "now").mockImplementation(() => now);
    try {
      const response = await app.inject({ url: "/v1/time" });
      expect(response.json()).toEqual({ serverReceivedAtUtcMs: 1000, serverSentAtUtcMs: 900 });
    } finally { clock.mockRestore(); await app.close(); }
  });
});
