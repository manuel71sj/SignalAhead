import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";
import { CatalogStore } from "../../src/catalog/catalogStore.js";
import type { ApproachCatalog } from "../../src/catalog/types.js";
import { validateCatalogForPublication } from "../../src/catalog/validateCatalog.js";

function goldenCatalog(): ApproachCatalog {
  const replay = JSON.parse(readFileSync(resolve(process.cwd(), "../..", "fixtures/replay/golden-contract.json"), "utf8")) as { catalog: ApproachCatalog };
  return replay.catalog;
}

function copyCatalog(): ApproachCatalog {
  return structuredClone(goldenCatalog());
}

describe("catalog publication", () => {
  test("accepts the checked golden catalog as an atomic version", () => {
    const store = new CatalogStore();
    const catalog = copyCatalog();

    expect(validateCatalogForPublication(catalog)).toEqual({ valid: true, issues: [] });
    expect(store.publish(catalog)).toEqual({ published: true, catalogVersion: "synthetic-contract-v1" });
    expect(store.active?.catalogVersion).toBe("synthetic-contract-v1");
  });

  test("rejects axis-swapped or out-of-range coordinates without replacing active catalog", () => {
    const store = new CatalogStore();
    const initial = copyCatalog();
    const invalid = copyCatalog();
    invalid.catalogVersion = "bad-axis";
    invalid.intersections[0]!.coordinates = [37.5231971, 126.9713254];

    expect(store.publish(initial)).toMatchObject({ published: true });
    const rejected = store.publish(invalid);

    expect(rejected).toMatchObject({ published: false, reason: "validation_failed" });
    expect(rejected.published === false ? rejected.issues.map((issue) => issue.code) : []).toContain("INVALID_COORDINATES");
    expect(store.active?.catalogVersion).toBe("synthetic-contract-v1");
  });

  test("rejects active approaches without direction, stop-line geometry or rights evidence", () => {
    const invalid = copyCatalog();
    invalid.catalogVersion = "bad-review";
    invalid.sources["synthetic-catalog"]!.rights.deviceMatching.allowed = false;
    invalid.approaches[0]!.directionReview.verified = false;
    invalid.approaches[0]!.geometryReview.verified = false;
    invalid.approaches[0]!.movement = "left";

    expect(validateCatalogForPublication(invalid).issues.map((issue) => issue.code)).toEqual(
      expect.arrayContaining(["UNVERIFIED_RIGHTS", "UNVERIFIED_DIRECTION", "UNVERIFIED_GEOMETRY", "UNSUPPORTED_MOVEMENT"])
    );
  });

  test("disables an active intersection immediately and bumps catalog version", () => {
    const store = new CatalogStore();
    const catalog = copyCatalog();
    expect(store.publish(catalog)).toMatchObject({ published: true });

    const result = store.disable({
      scope: "intersection",
      key: "national:1100000000:1",
      reason: "OPERATION_PAUSED",
      evidence: "operator disabled during SA-06 test"
    });

    expect(result).toEqual({
      disabled: true,
      catalogVersion: "synthetic-contract-v1+disabled",
      invalidatedApproachKeys: ["national:1100000000:1:straight:eb"]
    });
    expect(store.active?.approaches.find((approach) => approach.approachKey === "national:1100000000:1:straight:eb")?.enabledForOperation).toBe(false);
  });
});
