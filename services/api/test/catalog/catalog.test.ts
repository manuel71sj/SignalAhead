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
