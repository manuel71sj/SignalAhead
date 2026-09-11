import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";
import { buildApp } from "../../src/app.js";
import { CatalogStore } from "../../src/catalog/catalogStore.js";
import type { ApproachCatalog } from "../../src/catalog/types.js";
import { SignalEventCache } from "../../src/collection/signalEventCache.js";
import { loadConfig } from "../../src/config.js";
import { StreamProtocol } from "../../src/realtime/protocol.js";
import type { NationalObservation } from "../../src/providers/national/types.js";

function catalog(): ApproachCatalog {
  const replay = JSON.parse(readFileSync(resolve(process.cwd(), "../..", "fixtures/replay/golden-contract.json"), "utf8")) as { catalog: ApproachCatalog };
  return replay.catalog;
}

function signal(approachKey = "national:1100000000:1:straight:eb", catalogVersion = "synthetic-contract-v1"): NationalObservation {
  return {
    schemaVersion: "sa-contract-1",
    kind: "SignalObservation",
    provider: "national",
    intersectionKey: "national:1100000000:1",
    approachKey,
    movement: "straight",
    signalState: "green",
    catalogVersion,
    sourceRevision: "20260910185819",
    sourceIntersectionId: "1100000000:1",
    sourceEventId: "20260910185819",
    sourceObservedAtUtcMs: null,
    sourceTimeKind: "unknown",
    serverReceivedAtUtcMs: 1,
    serverSentAtUtcMs: 1,
    remainingAtSourceMs: 21,
    expiresAtUtcMs: null,
    timingQuality: "unverified",
    unitEvidence: { sourceField: "ntStsgRmndCs", sourceUnit: "unknown", conversion: "not converted", evidence: "test" },
    rawStateCode: "protected-Movement-Allowed",
    sourceDirectionCode: "nt",
    rawRemainingValue: "21",
    disabledForPrediction: true,
    disabledReason: "UNVERIFIED_UNIT"
  };
}

describe("catalog and signal routes", () => {
  test("rejects invalid bbox and returns empty support instead of unlimited data", async () => {
    const app = buildApp({ config: loadConfig({}) });

    expect((await app.inject({ method: "GET", url: "/v1/catalog?bbox=bad" })).statusCode).toBe(400);
    const empty = await app.inject({ method: "GET", url: "/v1/catalog?bbox=120,30,121,31" });
    expect(empty.statusCode).toBe(200);
    expect(empty.json()).toEqual({ catalogVersion: null, intersections: [], approaches: [] });
  });

  test("returns supported catalog bundle inside bbox", async () => {
    const catalogStore = new CatalogStore();
    catalogStore.publish(catalog());
    const app = buildApp({ config: loadConfig({}), catalogStore });
    const response = await app.inject({ method: "GET", url: "/v1/catalog?bbox=126.9,37.5,127.0,37.6" });

    expect(response.statusCode).toBe(200);
    expect(response.json().catalogVersion).toBe("synthetic-contract-v1");
    expect(response.json().approaches).toEqual(
      expect.arrayContaining([expect.objectContaining({ approachKey: "national:1100000000:1:straight:eb" })])
    );
  });

  test("returns explicit signal unavailability for unknown targets and catalog mismatch", async () => {
    const signalCache = new SignalEventCache();
    signalCache.apply(signal(), 1);
    const app = buildApp({ config: loadConfig({}), signalCache });

    const unknown = await app.inject({ method: "GET", url: "/v1/signals?approachKey=missing&movement=straight" });
    const mismatch = await app.inject({ method: "GET", url: "/v1/signals?approachKey=national:1100000000:1:straight:eb&movement=straight&catalogVersion=old" });
    const current = await app.inject({ method: "GET", url: "/v1/signals?approachKey=national:1100000000:1:straight:eb&movement=straight&catalogVersion=synthetic-contract-v1" });

    expect(unknown.json()).toMatchObject({ available: false, reason: "TARGET_UNKNOWN" });
    expect(mismatch.json()).toMatchObject({ available: false, reason: "CATALOG_MISMATCH" });
    expect(current.json()).toMatchObject({ available: true, snapshot: { approachKey: "national:1100000000:1:straight:eb" } });
  });

  test("stream protocol starts a fresh epoch with full snapshot and monotonic sequence", () => {
    const signalCache = new SignalEventCache();
    signalCache.apply(signal(), 1);
    const first = new StreamProtocol();
    const second = new StreamProtocol();

    const firstMessage = first.nextSnapshot({ type: "subscribe", requestId: "a", approachKey: "national:1100000000:1:straight:eb", movement: "straight", catalogVersion: "synthetic-contract-v1" }, signalCache);
    const secondMessage = second.nextSnapshot({ type: "subscribe", requestId: "a", approachKey: "national:1100000000:1:straight:eb", movement: "straight", catalogVersion: "synthetic-contract-v1" }, signalCache);

    expect(firstMessage.type).toBe("snapshot");
    expect(firstMessage.sequence).toBe(1);
    expect(secondMessage.sequence).toBe(1);
    expect(secondMessage.streamEpoch).not.toBe(firstMessage.streamEpoch);
  });
});
