import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { buildApp } from "./app.js";
import { CatalogStore } from "./catalog/catalogStore.js";
import type { ApproachCatalog } from "./catalog/types.js";
import { SignalEventCache } from "./collection/signalEventCache.js";
import { loadConfig } from "./config.js";
import type { NationalObservation } from "./providers/national/types.js";

// A separate executable, never imported by the production API entrypoint.
if (process.env.NODE_ENV === "production") throw new Error("Synthetic replay is development-only");
const fixtureRoot = new URL("../../../fixtures/replay/", import.meta.url);
type Scene = { id: string; label: string; signalState: NationalObservation["signalState"]; remainingMs: number; distanceMinM: number; distanceMaxM: number; speedMinMps: number; speedMaxMps: number; publish: boolean; unverified?: boolean; secondTarget?: boolean; ambiguous?: boolean };
const fixture = JSON.parse(readFileSync(fileURLToPath(new URL("driving-runtime.json", fixtureRoot)), "utf8")) as { origin: string; policy: Record<string, number>; scenes: Scene[] };
const golden = JSON.parse(readFileSync(fileURLToPath(new URL("golden-contract.json", fixtureRoot)), "utf8")) as { origin: string; catalog: ApproachCatalog };
if (fixture.origin !== "synthetic" || golden.origin !== "synthetic" || fixture.scenes.length === 0 || fixture.scenes.length > 32) throw new Error("Explicit synthetic fixture required");
for (const scene of fixture.scenes) {
  if (![scene.remainingMs, scene.distanceMinM, scene.distanceMaxM, scene.speedMinMps, scene.speedMaxMps].every(value => Number.isFinite(value) && value >= 0) || scene.distanceMinM > scene.distanceMaxM || scene.speedMinMps > scene.speedMaxMps) throw new Error("Invalid replay input interval");
}
// A second authored national target exercises identity changes without pretending
// that the fixture's unrelated city providers use the national adapter.
const firstIntersection = golden.catalog.intersections.find(item => item.intersectionKey === "national:1100000000:1")!;
const firstApproach = golden.catalog.approaches.find(item => item.approachKey === "national:1100000000:1:straight:eb")!;
golden.catalog.intersections.push({ ...firstIntersection, intersectionKey: "national:1100000000:2", sourceIntersectionId: "1100000000:2", rawSourceIdentity: { stdgCd: "1100000000", crsrdId: "2" }, name: "synthetic replay target B" });
golden.catalog.approaches.push({ ...firstApproach, intersectionKey: "national:1100000000:2", approachKey: "national:1100000000:2:straight:eb" });
class SyntheticReplayCatalog extends CatalogStore {
  override async getActive(): Promise<ApproachCatalog> { return golden.catalog; }
}
const store = new SyntheticReplayCatalog();
const cache = new SignalEventCache();
const config = loadConfig({ PORT: process.env.PORT ?? "3090" });
const app = buildApp({ config, catalogStore: store, signalCache: cache });
const sessionId = `synthetic-${randomUUID()}`;
let generation = 0;
let selected: Scene | null = null;
let selectedAt = 0;
let lastPublishedAt = -1;
let publishedGeneration = -1;

function targetFor(scene: Scene) {
  const approach = golden.catalog.approaches.find(item => item.enabledForOperation && item.movement === "straight" && item.intersectionKey === (scene.secondTarget ? "national:1100000000:2" : "national:1100000000:1"));
  const intersection = golden.catalog.intersections.find(item => item.intersectionKey === approach?.intersectionKey);
  if (!approach || !intersection || intersection.provider !== "national") throw new Error("Replay fixture target is missing");
  return { approach, intersection };
}
function publish(now: number) {
  const scene = selected;
  if (scene === null || (!scene.publish && publishedGeneration === generation) || now <= lastPublishedAt) return;
  const remaining = Math.max(0, scene.remainingMs - (now - selectedAt));
  const { approach, intersection } = targetFor(scene);
  const observation: NationalObservation = {
    schemaVersion: "sa-contract-1", kind: "SignalObservation", provider: "national",
    intersectionKey: intersection.intersectionKey, approachKey: approach.approachKey,
    movement: "straight", signalState: scene.signalState, catalogVersion: golden.catalog.catalogVersion,
    sourceRevision: "synthetic-driving-runtime-v1", sourceIntersectionId: intersection.sourceIntersectionId,
    sourceEventId: `${sessionId}:${generation}:${now}`, sourceObservedAtUtcMs: scene.unverified ? null : now,
    sourceTimeKind: scene.unverified ? "unknown" : "generated", serverReceivedAtUtcMs: now, serverSentAtUtcMs: now,
    remainingAtSourceMs: scene.unverified ? null : remaining,
    expiresAtUtcMs: scene.unverified ? null : now + Math.min(2500, remaining),
    timingQuality: scene.unverified ? "unverified" : "verified",
    unitEvidence: { sourceField: "authoredRuntimeRemaining", sourceUnit: "ms", conversion: "identity; authored synthetic input", evidence: "Development replay only, not a provider observation or operational unit approval" },
    rawStateCode: `synthetic-${scene.signalState}`,
  };
  const result = cache.apply(observation, now);
  if (result === "invalid") throw new Error("Replay observation violates canonical contract");
  lastPublishedAt = now;
  publishedGeneration = generation;
}
function current() {
  const scene = selected;
  if (!scene) return { origin: "synthetic", sessionId, generation, scene: null };
  const { approach, intersection } = targetFor(scene);
  return { origin: "synthetic", sessionId, generation, scene, policy: fixture.policy,
    target: { sessionId, targetGeneration: generation, provider: intersection.provider, intersectionKey: intersection.intersectionKey, approachKey: approach.approachKey, movement: "straight", catalogVersion: golden.catalog.catalogVersion } };
}
app.get("/__replay", async (_request, reply) => reply.header("Cache-Control", "no-store").send({ origin: "synthetic", scenes: fixture.scenes.map(({ id, label }) => ({ id, label })), current: current() }));
app.post<{ Params: { id: string } }>("/__replay/select/:id", async (request, reply) => {
  const scene = fixture.scenes.find(item => item.id === request.params.id);
  if (!scene) return reply.status(404).send({ error: "UNKNOWN_REPLAY_SCENE" });
  selected = scene;
  generation++;
  selectedAt = Date.now();
  publish(selectedAt);
  return reply.header("Cache-Control", "no-store").send(current());
});
const timer = setInterval(() => publish(Date.now()), 1000);
app.addHook("onClose", async () => { clearInterval(timer); });
const shutdown = () => { void app.close(); };
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
await app.listen({ host: "127.0.0.1", port: config.port });
console.log(`Synthetic replay only: http://127.0.0.1:${config.port}/__replay`);
