import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import type pg from "pg";
import type { ApproachCatalog, CatalogValidationIssue, DisableCommand } from "./types.js";
import { validateCatalogForPublication } from "./validateCatalog.js";

export type PublishResult =
  | { published: true; catalogVersion: string }
  | { published: false; reason: "validation_failed"; issues: CatalogValidationIssue[] }
  | { published: false; reason: "version_exists" };
export type DisableResult =
  | { disabled: true; catalogVersion: string; invalidatedApproachKeys: string[] }
  | { disabled: false; reason: "no_active_catalog" | "not_found" | "invalid_command" | "invalid_catalog" };

const CATALOG_LOCK = 71309461;

export async function migrateCatalog(pool: pg.Pool): Promise<void> {
  const sourcePath = new URL("../../migrations/0001_catalog.sql", import.meta.url);
  const compiledPath = new URL("../../../migrations/0001_catalog.sql", import.meta.url);
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("select pg_advisory_xact_lock($1)", [CATALOG_LOCK]);
    await client.query(readFileSync(existsSync(sourcePath) ? sourcePath : compiledPath, "utf8"));
    await client.query("commit");
  } catch (error) {
    await client.query("rollback");
    throw error;
  } finally {
    client.release();
  }
}

export class CatalogStore {
  #active: ApproachCatalog | null = null;
  constructor(private readonly pool?: pg.Pool) {}

  async getActive(): Promise<ApproachCatalog | null> {
    if (this.pool === undefined) return this.#active === null ? null : structuredClone(this.#active);
    const result = await this.pool.query<{ payload: unknown }>("select payload from catalog_versions where active");
    const payload = result.rows[0]?.payload;
    // Old or externally written unsafe catalogs are never promoted just by loading them.
    return payload !== undefined && validateCatalogForPublication(payload).valid ? payload as ApproachCatalog : null;
  }

  async publish(document: unknown): Promise<PublishResult> {
    const validation = validateCatalogForPublication(document);
    if (!validation.valid) return { published: false, reason: "validation_failed", issues: validation.issues };
    const catalog = structuredClone(document as ApproachCatalog);
    if (this.pool === undefined) {
      if (this.#active?.catalogVersion === catalog.catalogVersion) return { published: false, reason: "version_exists" };
      this.#active = catalog;
      return { published: true, catalogVersion: catalog.catalogVersion };
    }
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      await client.query("select pg_advisory_xact_lock($1)", [CATALOG_LOCK]);
      const existing = await client.query("select 1 from catalog_versions where catalog_version = $1", [catalog.catalogVersion]);
      if (existing.rowCount !== 0) {
        await client.query("rollback");
        return { published: false, reason: "version_exists" };
      }
      await client.query("update catalog_versions set active = false where active");
      await client.query("insert into catalog_versions (catalog_version, payload, active) values ($1, $2::jsonb, true)", [catalog.catalogVersion, JSON.stringify(catalog)]);
      await client.query("commit");
      return { published: true, catalogVersion: catalog.catalogVersion };
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async disable(command: DisableCommand): Promise<DisableResult> {
    if (!["provider", "intersection", "approach"].includes(command.scope) || !command.key?.trim() || command.key.length > 512 || !command.evidence?.trim() || command.evidence.length > 4096 || !["RIGHTS_UNVERIFIED", "GEOMETRY_UNVERIFIED", "SIGNAL_UNAVAILABLE", "POLICY_DISABLED"].includes(command.reason)) {
      return { disabled: false, reason: "invalid_command" };
    }
    const client = await this.pool?.connect();
    try {
      if (client !== undefined) {
        await client.query("begin");
        await client.query("select pg_advisory_xact_lock($1)", [CATALOG_LOCK]);
      }
      const active = client === undefined ? this.#active : (await client.query<{ payload: ApproachCatalog }>("select payload from catalog_versions where active for update")).rows[0]?.payload;
      if (active == null) {
        if (client !== undefined) await client.query("rollback");
        return { disabled: false, reason: "no_active_catalog" };
      }
      if (!validateCatalogForPublication(active).valid) {
        if (client !== undefined) await client.query("rollback");
        return { disabled: false, reason: "invalid_catalog" };
      }
      const providerIntersections = new Set(active.intersections.filter((item) => item.provider === command.key).map((item) => item.intersectionKey));
      const matching = active.approaches.filter((approach) => command.scope === "approach" ? approach.approachKey === command.key : command.scope === "intersection" ? approach.intersectionKey === command.key : providerIntersections.has(approach.intersectionKey));
      if (matching.length === 0) {
        if (client !== undefined) await client.query("rollback");
        return { disabled: false, reason: "not_found" };
      }
      const next = structuredClone(active);
      const keys = new Set(matching.map((approach) => approach.approachKey));
      const invalidatedApproachKeys = matching.filter((approach) => approach.enabledForOperation).map((approach) => approach.approachKey);
      next.catalogVersion = `disabled-${randomUUID()}`;
      next.disabledRegions.push({ regionKey: `${command.scope}:${command.key}`, reason: command.reason, effectiveFromCatalogVersion: next.catalogVersion });
      for (const approach of next.approaches) if (keys.has(approach.approachKey)) approach.enabledForOperation = false;
      if (client !== undefined) {
        await client.query("update catalog_versions set active = false where active");
        await client.query("insert into catalog_versions (catalog_version, payload, active) values ($1, $2::jsonb, true)", [next.catalogVersion, JSON.stringify(next)]);
        await client.query("insert into catalog_disable_events (catalog_version, scope, key, reason, evidence) values ($1, $2, $3, $4, $5)", [next.catalogVersion, command.scope, command.key, command.reason, command.evidence]);
        await client.query("commit");
      } else {
        this.#active = next;
      }
      return { disabled: true, catalogVersion: next.catalogVersion, invalidatedApproachKeys };
    } catch (error) {
      if (client !== undefined) await client.query("rollback");
      throw error;
    } finally {
      client?.release();
    }
  }
}
