import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { describe, expect, test } from "vitest";
import { CatalogStore, migrateCatalog } from "../../src/catalog/catalogStore.js";
import type { ApproachCatalog } from "../../src/catalog/types.js";
import { validateCatalogForPublication } from "../../src/catalog/validateCatalog.js";

function goldenCatalog(): ApproachCatalog {
  const replay = JSON.parse(readFileSync(resolve(process.cwd(), "../..", "fixtures/replay/golden-contract.json"), "utf8")) as { catalog: ApproachCatalog };
  return replay.catalog;
}

function disabledTestCatalog(version = "test-disabled"): ApproachCatalog {
  const catalog = goldenCatalog();
  catalog.catalogVersion = version;
  for (const source of Object.values(catalog.sources)) source.origin = "recorded";
  for (const approach of catalog.approaches) approach.enabledForOperation = false;
  return catalog;
}

function drivingCatalog(): ApproachCatalog {
  return JSON.parse(readFileSync(resolve(process.cwd(), "../..", "fixtures/spatial/driving-catalog.json"), "utf8")) as ApproachCatalog;
}

// An in-memory test of approval predicates, NOT a recorded catalog or evidence
// artifact. The checked-in driving fixture remains entirely synthetic/unapproved.
function approvedTestCatalog(): ApproachCatalog {
  const catalog = drivingCatalog();
  catalog.catalogVersion = "unit-test-approval-predicates";
  for (const source of Object.values(catalog.sources)) source.origin = "recorded";
  catalog.spatial!.matchingPolicy.approvedForOperation = true;
  catalog.spatial!.predictionPolicy.approvedForOperation = true;
  return catalog;
}

describe("catalog publication safety", () => {
  test("synthetic verification cannot publish an operational catalog", async () => {
    const store = new CatalogStore();
    const catalog = goldenCatalog();
    expect(validateCatalogForPublication(catalog, "synthetic-verification").valid).toBe(true);
    expect(await store.publish(catalog)).toMatchObject({ published: false, reason: "validation_failed" });
    expect(await store.getActive()).toBeNull();
  });

  test.each([null, [], {}, { approaches: [] }, { ...goldenCatalog(), unexpected: true }])("malformed JSON shapes fail closed", async (raw) => {
    expect(validateCatalogForPublication(raw).valid).toBe(false);
    expect(await new CatalogStore().publish(raw)).toMatchObject({ published: false, reason: "validation_failed" });
  });

  test("rejected publication preserves the active version and geometry references are not geometry", async () => {
    const store = new CatalogStore();
    expect(await store.publish(disabledTestCatalog())).toMatchObject({ published: true });
    const invalid = disabledTestCatalog("unsafe");
    invalid.approaches[0]!.enabledForOperation = true;
    invalid.approaches[0]!.directionReview.verified = false;
    invalid.sources[invalid.approaches[0]!.source]!.rights.deviceMatching.allowed = false;
    const result = await store.publish(invalid);
    expect(result).toMatchObject({ published: false, reason: "validation_failed" });
    expect(validateCatalogForPublication(invalid).issues.map((issue) => issue.code)).toEqual(expect.arrayContaining(["UNSUPPORTED_GEOMETRY", "UNVERIFIED_DIRECTION", "UNVERIFIED_RIGHTS"]));
    expect((await store.getActive())?.catalogVersion).toBe("test-disabled");
  });

  test("operator disable creates a unique version with schema-valid disable history", async () => {
    const store = new CatalogStore();
    await store.publish(disabledTestCatalog());
    const command = { scope: "intersection" as const, key: "national:1100000000:1", reason: "POLICY_DISABLED" as const, evidence: "test operator action" };
    const first = await store.disable(command);
    const second = await store.disable(command);
    expect(first.disabled).toBe(true);
    expect(second.disabled).toBe(true);
    if (!first.disabled || !second.disabled) throw new Error("Disable failed");
    expect(first.catalogVersion).not.toBe(second.catalogVersion);
    const active = await store.getActive();
    expect(validateCatalogForPublication(active).valid).toBe(true);
    expect(active?.disabledRegions.at(-1)).toMatchObject({ regionKey: "intersection:national:1100000000:1", reason: "POLICY_DISABLED", effectiveFromCatalogVersion: second.catalogVersion });
  });

  test("synthetic complete geometry is verifiable but never publishable, even with approval flags", async () => {
    const catalog = drivingCatalog();
    expect(validateCatalogForPublication(catalog, "synthetic-verification")).toEqual({ valid: true, issues: [] });
    catalog.spatial!.matchingPolicy.approvedForOperation = true;
    catalog.spatial!.predictionPolicy.approvedForOperation = true;
    expect(await new CatalogStore().publish(catalog)).toMatchObject({ published: false, issues: expect.arrayContaining([expect.objectContaining({ code: "SYNTHETIC_SOURCE" })]) });
  });

  test("reviewed geometry publishes atomically and disabling retains the entire graph and policies", async () => {
    const catalog = approvedTestCatalog();
    const store = new CatalogStore();
    expect(await store.publish(catalog)).toEqual({ published: true, catalogVersion: catalog.catalogVersion });
    const disabled = await store.disable({ scope: "approach", key: "synthetic:west-approach", reason: "POLICY_DISABLED", evidence: "Unit-test operator disable" });
    expect(disabled).toMatchObject({ disabled: true, invalidatedApproachKeys: ["synthetic:west-approach"] });
    const active = await store.getActive();
    expect(active?.catalogVersion).not.toBe(catalog.catalogVersion);
    expect(active?.spatial).toEqual(catalog.spatial);
    expect(active?.approaches.find((approach) => approach.approachKey === "synthetic:west-approach")?.enabledForOperation).toBe(false);
    expect(active?.approaches.find((approach) => approach.approachKey === "synthetic:eastward-approach")?.enabledForOperation).toBe(true);
  });

  test.each([
    ["missing stop", (catalog: ApproachCatalog) => { catalog.spatial!.stopLines.features.shift(); }],
    ["wrong intersection", (catalog: ApproachCatalog) => { catalog.spatial!.stopLines.features[0]!.properties.intersectionKey = "synthetic:i2"; }],
    ["wrong level", (catalog: ApproachCatalog) => { catalog.spatial!.stopLines.features[0]!.properties.level = 1; }],
    ["unknown geometry source", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[0]!.properties.source = "unknown"; }],
    ["duplicate road", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features.push(structuredClone(catalog.spatial!.roads.features[0]!)); }],
    ["shared node mismatch", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[1]!.geometry.coordinates[0]![0] += 0.00001; }],
    ["collinear stop", (catalog: ApproachCatalog) => { catalog.spatial!.stopLines.features[0]!.geometry.coordinates = [[126.9992, 37], [126.9998, 37]]; }],
    ["two stop crossings", (catalog: ApproachCatalog) => { catalog.spatial!.stopLines.features[0]!.geometry.coordinates = [[126.9992, 36.9999], [126.9992, 37.0001], [126.9998, 37.0001], [126.9998, 36.9999]]; }],
    ["road revisits crossing", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[0]!.geometry.coordinates = [[126.999, 37], [126.9999, 37], [126.999, 37], [127, 37]]; }],
    ["oversized segment", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[5]!.geometry.coordinates[0]![0] = 126; }],
    ["antimeridian segment", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[5]!.geometry.coordinates = [[179.999, 37], [-179.999, 37]]; }],
    ["pole", (catalog: ApproachCatalog) => { catalog.spatial!.roads.features[5]!.geometry.coordinates[0]![1] = 90; }],
    ["unapproved matching", (catalog: ApproachCatalog) => { catalog.spatial!.matchingPolicy.approvedForOperation = false; }],
    ["unapproved prediction", (catalog: ApproachCatalog) => { catalog.spatial!.predictionPolicy.approvedForOperation = false; }],
    ["missing measurements", (catalog: ApproachCatalog) => { catalog.spatial!.matchingPolicy.measurementEvidence = " "; }],
    ["missing rights", (catalog: ApproachCatalog) => { catalog.sources.synthetic!.rights.deviceMatching.allowed = false; }],
    ["unbounded history", (catalog: ApproachCatalog) => { catalog.spatial!.matchingPolicy.maxHistoryAgeMs = 30001; }],
    ["unbounded radius", (catalog: ApproachCatalog) => { catalog.spatial!.matchingPolicy.candidateSearchRadiusM = 2001; }],
    ["nonfinite threshold", (catalog: ApproachCatalog) => { catalog.spatial!.matchingPolicy.geometryErrorM = Infinity; }]
  ] as const)("rejects %s without replacing a valid active graph", async (_name, mutate) => {
    const store = new CatalogStore();
    const accepted = approvedTestCatalog();
    await store.publish(accepted);
    const rejected = approvedTestCatalog();
    rejected.catalogVersion = "rejected";
    mutate(rejected);
    expect(await store.publish(rejected)).toMatchObject({ published: false, reason: "validation_failed" });
    expect((await store.getActive())?.catalogVersion).toBe(accepted.catalogVersion);
  });

  test("total vertices are bounded across features before crossing calculations", () => {
    const catalog = drivingCatalog();
    catalog.spatial!.roads.features[0]!.geometry.coordinates = Array.from({ length: 4096 }, (_, index): [number, number] => [126.999 + index * 0.0000001, 37]);
    expect(validateCatalogForPublication(catalog, "synthetic-verification")).toMatchObject({ valid: false, issues: expect.arrayContaining([expect.objectContaining({ code: "GEOMETRY_LIMIT" })]) });
  });

  test("one crossing at a shared polyline vertex is not counted twice", () => {
    const catalog = drivingCatalog();
    catalog.spatial!.roads.features[0]!.geometry.coordinates = [[126.999, 37], [126.9998, 37], [127, 37]];
    catalog.spatial!.stopLines.features[0]!.geometry.coordinates = [[126.9998, 36.9999], [126.9998, 37], [126.9998, 37.0001]];
    expect(validateCatalogForPublication(catalog, "synthetic-verification")).toEqual({ valid: true, issues: [] });
  });
});

describe.skipIf(!process.env.TEST_DATABASE_URL)("PostgreSQL publication transaction", () => {
  test("persists history across stores and rolls back publication when disable audit fails", async () => {
    const schema = `catalog_test_${randomUUID().replaceAll("-", "")}`;
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    await admin.query(`create schema ${schema}`);
    const pool = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL, options: `-c search_path=${schema}` });
    try {
      await migrateCatalog(pool);
      const store = new CatalogStore(pool);
      expect(await store.publish(disabledTestCatalog("first"))).toMatchObject({ published: true });
      expect(await store.publish(disabledTestCatalog("second"))).toMatchObject({ published: true });
      expect((await new CatalogStore(pool).getActive())?.catalogVersion).toBe("second");
      expect(await store.publish(disabledTestCatalog("first"))).toEqual({ published: false, reason: "version_exists" });
      expect((await pool.query("select count(*)::int as count from catalog_versions")).rows[0].count).toBe(2);
      await pool.query("alter table catalog_disable_events add constraint reject_test_audit check (evidence <> 'reject')");
      await expect(store.disable({ scope: "provider", key: "national", reason: "POLICY_DISABLED", evidence: "reject" })).rejects.toThrow();
      expect((await store.getActive())?.catalogVersion).toBe("second");
      expect((await pool.query("select count(*)::int as count from catalog_versions")).rows[0].count).toBe(2);
      const disabled = await store.disable({ scope: "provider", key: "national", reason: "POLICY_DISABLED", evidence: "operator test" });
      expect(disabled.disabled).toBe(true);
      expect((await pool.query("select count(*)::int as count from catalog_disable_events")).rows[0].count).toBe(1);
      expect((await pool.query("select count(*)::int as count from catalog_versions where active")).rows[0].count).toBe(1);
    } finally {
      await pool.end();
      await admin.query(`drop schema ${schema} cascade`);
      await admin.end();
    }
  });
});
