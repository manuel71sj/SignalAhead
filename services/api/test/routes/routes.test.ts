import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { once } from "node:events";
import WebSocket from "ws";
import { describe, expect, test } from "vitest";
import { buildApp } from "../../src/app.js";
import { CatalogStore } from "../../src/catalog/catalogStore.js";
import type { ApproachCatalog } from "../../src/catalog/types.js";
import { SignalEventCache } from "../../src/collection/signalEventCache.js";
import { loadConfig } from "../../src/config.js";
import { parseClientMessage, type StreamMessage } from "../../src/realtime/protocol.js";
import { signalResult } from "../../src/routes/signals.js";
import type { NationalObservation } from "../../src/providers/national/types.js";

// Test-only injection exercises future verified data paths without exposing a
// synthetic publication bypass in CatalogStore or the operator CLI.
class FixtureStore extends CatalogStore {
  readonly catalog: ApproachCatalog;
  constructor() {
    super();
    const replay = JSON.parse(readFileSync(resolve(process.cwd(), "../..", "fixtures/replay/golden-contract.json"), "utf8")) as { catalog: ApproachCatalog };
    this.catalog = replay.catalog;
  }
  override async getActive(): Promise<ApproachCatalog> { return this.catalog; }
}

function signal(now: number, expires = now + 2000): NationalObservation {
  return {
    schemaVersion: "sa-contract-1", kind: "SignalObservation", provider: "national",
    intersectionKey: "national:1100000000:1", approachKey: "national:1100000000:1:straight:eb",
    movement: "straight", signalState: "green", catalogVersion: "synthetic-contract-v1",
    sourceRevision: "synthetic-test", sourceIntersectionId: "1100000000:1", sourceEventId: null,
    sourceObservedAtUtcMs: now, sourceTimeKind: "generated", serverReceivedAtUtcMs: now, serverSentAtUtcMs: now,
    remainingAtSourceMs: 2000, expiresAtUtcMs: expires, timingQuality: "verified",
    unitEvidence: { sourceField: "synthetic-duration", sourceUnit: "ms", conversion: "identity for synthetic test only", evidence: "test fixture, not operational evidence" }, rawStateCode: null
  };
}

async function message(socket: WebSocket): Promise<StreamMessage> {
  const [data] = await once(socket, "message", { signal: AbortSignal.timeout(3000) });
  return JSON.parse(String(data)) as StreamMessage;
}

describe("catalog and signal safety routes", () => {
  test("rejects partial numeric, world-size and malformed bbox; default is unsupported", async () => {
    const app = buildApp({ config: loadConfig({}) });
    try {
      for (const bbox of ["bad", "126x,37,127,38", "-180,-89,180,89", "126,37,,38", "126,38,127,37"]) {
        expect((await app.inject({ method: "GET", url: `/v1/catalog?bbox=${bbox}` })).statusCode).toBe(400);
      }
      const empty = await app.inject({ method: "GET", url: "/v1/catalog?bbox=120,30,121,31" });
      expect(empty.json()).toEqual({ catalogVersion: null, intersections: [], approaches: [] });
    } finally { await app.close(); }
  });

  test("catalog, enablement, unknown timing and expiry all precede snapshot availability", () => {
    const store = new FixtureStore();
    const cache = new SignalEventCache();
    const observation = signal(1000, 1500);
    cache.apply(observation, 1000);
    const get = (version: unknown, now = 1000) => signalResult(observation.approachKey, "straight", version, store.catalog, cache, now);
    expect(get(store.catalog.catalogVersion)).toMatchObject({ available: true });
    expect(get(undefined)).toMatchObject({ available: false, reason: "CATALOG_MISMATCH" });
    expect(get("old")).toMatchObject({ available: false, reason: "CATALOG_MISMATCH" });
    expect(get(store.catalog.catalogVersion, 1500)).toMatchObject({ available: false, reason: "SIGNAL_EXPIRED" });
    store.catalog.approaches[0]!.enabledForOperation = false;
    expect(get(store.catalog.catalogVersion)).toMatchObject({ available: false, reason: "TARGET_UNKNOWN" });
    store.catalog.approaches[0]!.enabledForOperation = true;
    cache.apply({ ...observation, timingQuality: "unverified", sourceObservedAtUtcMs: null, sourceTimeKind: "unknown", remainingAtSourceMs: null, expiresAtUtcMs: null }, 1100);
    expect(get(store.catalog.catalogVersion)).toMatchObject({ available: false, reason: "TIMING_UNVERIFIED" });
    expect(signalResult(observation.approachKey, "straight", observation.catalogVersion, null, cache)).toMatchObject({ available: false, reason: "CATALOG_UNAVAILABLE" });
  });

  test("HTTP requires a version and cannot return cached unknown national timing", async () => {
    const store = new FixtureStore();
    const cache = new SignalEventCache();
    cache.apply({ ...signal(Date.now()), timingQuality: "unverified", sourceTimeKind: "unknown", remainingAtSourceMs: null, expiresAtUtcMs: null }, Date.now());
    const app = buildApp({ config: loadConfig({}), catalogStore: store, signalCache: cache });
    try {
      const target = "/v1/signals?approachKey=national:1100000000:1:straight:eb&movement=straight";
      expect((await app.inject({ url: target })).statusCode).toBe(400);
      expect((await app.inject({ url: `${target}&catalogVersion=synthetic-contract-v1` })).json()).toMatchObject({ available: false, reason: "TIMING_UNVERIFIED", snapshot: null });
    } finally { await app.close(); }
  });

  test("malformed JSON and oversized identity are rejected without exceptions", () => {
    for (const raw of ["{", "null", "[]", JSON.stringify({ type: "unsubscribe", requestId: "" }), JSON.stringify({ type: "unsubscribe", requestId: "x".repeat(129) })]) expect(parseClientMessage(raw)).toBeNull();
  });

  test("real websocket survives malformed JSON, supplies initial state, expires and invalidates", async () => {
    const store = new FixtureStore();
    const cache = new SignalEventCache();
    const app = buildApp({ config: loadConfig({}), catalogStore: store, signalCache: cache });
    const address = await app.listen({ host: "127.0.0.1", port: 0 });
    const socket = new WebSocket(address.replace("http:", "ws:") + "/v1/stream");
    try {
      await once(socket, "open", { signal: AbortSignal.timeout(3000) });
      let pending = message(socket);
      socket.send("{");
      expect(await pending).toMatchObject({ type: "error", error: "INVALID_MESSAGE" });
      const now = Date.now();
      cache.apply(signal(now, now + 600), now);
      pending = message(socket);
      socket.send(JSON.stringify({ type: "subscribe", requestId: "one", approachKey: "national:1100000000:1:straight:eb", movement: "straight", catalogVersion: "synthetic-contract-v1" }));
      const initial = await pending;
      expect(initial).toMatchObject({ type: "snapshot", requestId: "one", snapshot: { remainingAtSourceMs: 2000 } });
      const expired = await message(socket);
      expect(expired).toMatchObject({ type: "unavailable", reason: "SIGNAL_EXPIRED" });
      expect(expired.sequence).toBeGreaterThan(initial.sequence);
      pending = message(socket);
      store.catalog.catalogVersion = "new-version";
      expect(await pending).toMatchObject({ type: "unavailable", reason: "CATALOG_MISMATCH" });
    } finally { socket.terminate(); await app.close(); }
  });

  test("websocket rate bound closes abusive connections", async () => {
    const app = buildApp({ config: loadConfig({}) });
    const address = await app.listen({ host: "127.0.0.1", port: 0 });
    const socket = new WebSocket(address.replace("http:", "ws:") + "/v1/stream");
    try {
      await once(socket, "open", { signal: AbortSignal.timeout(3000) });
      const closed = once(socket, "close", { signal: AbortSignal.timeout(3000) });
      for (let index = 0; index < 21; index++) socket.send(JSON.stringify({ type: "unsubscribe", requestId: "one" }));
      expect((await closed)[0]).toBe(1008);
    } finally { socket.terminate(); await app.close(); }
  });
});
