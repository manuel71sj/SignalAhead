import type { ApproachCatalog, CatalogApproach, CatalogValidationIssue, DisabledRegion } from "./types.js";
import { validateCatalogForPublication } from "./validateCatalog.js";

export type PublishResult =
  | { published: true; catalogVersion: string }
  | { published: false; reason: "validation_failed"; issues: CatalogValidationIssue[] };

export type DisableResult =
  | { disabled: true; catalogVersion: string; invalidatedApproachKeys: string[] }
  | { disabled: false; reason: "no_active_catalog" | "not_found" };

function disabledCatalogVersion(catalogVersion: string): string {
  return `${catalogVersion}+disabled`;
}

function approachDisabled(approach: CatalogApproach, region: DisabledRegion): boolean {
  if (region.scope === "provider") {
    return approach.intersectionKey.startsWith(`${region.key}:`);
  }
  if (region.scope === "intersection") {
    return approach.intersectionKey === region.key;
  }
  return approach.approachKey === region.key;
}

export class CatalogStore {
  #active: ApproachCatalog | null = null;

  get active(): ApproachCatalog | null {
    return this.#active;
  }

  publish(catalog: ApproachCatalog): PublishResult {
    const validation = validateCatalogForPublication(catalog);
    if (!validation.valid) {
      return { published: false, reason: "validation_failed", issues: validation.issues };
    }
    this.#active = structuredClone(catalog);
    return { published: true, catalogVersion: catalog.catalogVersion };
  }

  disable(region: DisabledRegion): DisableResult {
    if (this.#active === null) {
      return { disabled: false, reason: "no_active_catalog" };
    }

    const invalidatedApproachKeys = this.#active.approaches
      .filter((approach) => approach.enabledForOperation && approachDisabled(approach, region))
      .map((approach) => approach.approachKey);
    if (invalidatedApproachKeys.length === 0) {
      return { disabled: false, reason: "not_found" };
    }

    const next = structuredClone(this.#active);
    next.catalogVersion = disabledCatalogVersion(next.catalogVersion);
    next.disabledRegions.push(region);
    next.approaches = next.approaches.map((approach) => {
      if (!invalidatedApproachKeys.includes(approach.approachKey)) {
        return approach;
      }
      return { ...approach, enabledForOperation: false };
    });
    this.#active = next;

    return { disabled: true, catalogVersion: next.catalogVersion, invalidatedApproachKeys };
  }
}
