import { validateCatalogShape } from "../contracts.js";
import type { ApproachCatalog, CatalogValidationIssue, CatalogValidationResult } from "./types.js";

export type CatalogValidationMode = "operational" | "synthetic-verification";

export function validateCatalogForPublication(document: unknown, mode: CatalogValidationMode = "operational"): CatalogValidationResult {
  if (!validateCatalogShape(document)) {
    return {
      valid: false,
      issues: (validateCatalogShape.errors ?? []).map((error) => ({
        code: "INVALID_SCHEMA", key: error.instancePath, message: error.message ?? "Invalid catalog JSON"
      }))
    };
  }
  const catalog = document as ApproachCatalog;
  const issues: CatalogValidationIssue[] = [];
  const add = (code: CatalogValidationIssue["code"], key: string, message: string) => { issues.push({ code, key, message }); };
  const seen = new Set<string>();
  for (const entity of [...catalog.intersections, ...catalog.approaches]) {
    const key = "approachKey" in entity ? entity.approachKey : entity.intersectionKey;
    if (seen.has(key)) add("DUPLICATE_KEY", key, "Duplicate catalog key");
    seen.add(key);
  }
  for (const [key, source] of Object.entries(catalog.sources)) {
    if (source.sourceId !== key) add("INVALID_SOURCE_IDENTITY", key, "Source ledger key must match sourceId");
    if (source.crs !== "OGC:CRS84") add("INVALID_COORDINATES", key, "Only verified OGC:CRS84 coordinates are supported");
    if (mode === "operational" && source.origin === "synthetic") add("SYNTHETIC_SOURCE", key, "Synthetic sources cannot be published operationally");
    if (mode === "synthetic-verification" && source.origin !== "synthetic") add("SYNTHETIC_SOURCE", key, "Verification mode accepts only synthetic sources");
  }
  const intersections = new Map(catalog.intersections.map((item) => [item.intersectionKey, item]));
  for (const intersection of catalog.intersections) {
    if (!Object.hasOwn(catalog.sources, intersection.source)) add("MISSING_SOURCE", intersection.intersectionKey, "Unknown intersection source");
    if (intersection.intersectionKey !== `${intersection.provider}:${intersection.sourceIntersectionId}`) add("INVALID_SOURCE_IDENTITY", intersection.intersectionKey, "Intersection key must preserve complete provider identity");
  }
  for (const approach of catalog.approaches) {
    const intersection = intersections.get(approach.intersectionKey);
    const source = Object.hasOwn(catalog.sources, approach.source) ? catalog.sources[approach.source] : undefined;
    if (intersection === undefined) add("MISSING_INTERSECTION", approach.approachKey, "Unknown approach intersection");
    if (source === undefined) add("MISSING_SOURCE", approach.approachKey, "Unknown approach source");
    if (!approach.enabledForOperation) continue;
    const intersectionSource = intersection !== undefined && Object.hasOwn(catalog.sources, intersection.source) ? catalog.sources[intersection.source] : undefined;
    for (const ledger of [source, intersectionSource]) {
      if (ledger !== undefined && Object.values(ledger.rights).some((right) => !right.allowed || right.evidence.trim().length === 0)) {
        add("UNVERIFIED_RIGHTS", approach.approachKey, "All source rights require affirmative documented permission");
      }
    }
    if (!approach.directionReview.verified || !approach.directionReview.evidence.trim()) add("UNVERIFIED_DIRECTION", approach.approachKey, "Direction review is unverified");
    if (!approach.geometryReview.verified || !approach.geometryReview.evidence.trim() || approach.roadLinkId === null || approach.stopLineId === null || approach.level === null) add("UNVERIFIED_GEOMETRY", approach.approachKey, "Reviewed road link, stop line and level are required");
    if (approach.movement !== "straight") add("UNSUPPORTED_MOVEMENT", approach.approachKey, "Only straight movement is supported");
    // This contract carries identifiers, not geometry. Review booleans cannot supply a
    // directed road polyline and crossing stop line to the device matcher.
    if (mode === "operational") add("UNSUPPORTED_GEOMETRY", approach.approachKey, "Operational geometry resolution is unavailable; publish this approach disabled");
  }
  return { valid: issues.length === 0, issues };
}
