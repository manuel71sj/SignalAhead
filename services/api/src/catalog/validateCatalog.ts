import type { ApproachCatalog, CatalogApproach, CatalogValidationIssue, CatalogValidationResult, SourceLedger } from "./types.js";

const OPERATIONAL_MOVEMENTS = new Set(["straight"]);

function rightsAllowDeviceUse(source: SourceLedger): boolean {
  return source.rights.storage.allowed && source.rights.processing.allowed && source.rights.redistribution.allowed && source.rights.deviceMatching.allowed;
}

function coordinateIssue(coordinates: [number, number], key: string): CatalogValidationIssue | null {
  const [longitude, latitude] = coordinates;
  const valid = Number.isFinite(longitude) && Number.isFinite(latitude) && longitude >= -180 && longitude <= 180 && latitude > -90 && latitude < 90;
  if (valid) {
    return null;
  }
  return { code: "INVALID_COORDINATES", key, message: "Coordinates must be OGC:CRS84 [longitude, latitude] within valid ranges" };
}

function activeApproachIssues(approach: CatalogApproach, source: SourceLedger | undefined): CatalogValidationIssue[] {
  const issues: CatalogValidationIssue[] = [];
  if (source === undefined) {
    issues.push({ code: "MISSING_SOURCE", key: approach.approachKey, message: `Unknown source ${approach.source}` });
    return issues;
  }
  if (!rightsAllowDeviceUse(source)) {
    issues.push({ code: "UNVERIFIED_RIGHTS", key: approach.approachKey, message: "Source rights do not allow storage, processing, redistribution and device matching" });
  }
  if (!approach.directionReview.verified) {
    issues.push({ code: "UNVERIFIED_DIRECTION", key: approach.approachKey, message: "Direction review is not verified" });
  }
  if (!approach.geometryReview.verified) {
    issues.push({ code: "UNVERIFIED_GEOMETRY", key: approach.approachKey, message: "Geometry/stop-line review is not verified" });
  }
  if (!OPERATIONAL_MOVEMENTS.has(approach.movement)) {
    issues.push({ code: "UNSUPPORTED_MOVEMENT", key: approach.approachKey, message: "Only straight approaches may be enabled for initial operation" });
  }
  return issues;
}

function duplicateIssues(keys: string[], code: CatalogValidationIssue["code"], label: string): CatalogValidationIssue[] {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const key of keys) {
    if (seen.has(key)) {
      duplicates.add(key);
    }
    seen.add(key);
  }
  return [...duplicates].map((key) => ({ code, key, message: `Duplicate ${label} key ${key}` }));
}

export function validateCatalogForPublication(catalog: ApproachCatalog): CatalogValidationResult {
  const issues: CatalogValidationIssue[] = [];
  issues.push(...duplicateIssues(catalog.intersections.map((intersection) => intersection.intersectionKey), "DUPLICATE_KEY", "intersection"));
  issues.push(...duplicateIssues(catalog.approaches.map((approach) => approach.approachKey), "DUPLICATE_KEY", "approach"));

  const intersections = new Map(catalog.intersections.map((intersection) => [intersection.intersectionKey, intersection]));
  for (const intersection of catalog.intersections) {
    const issue = coordinateIssue(intersection.coordinates, intersection.intersectionKey);
    if (issue !== null) {
      issues.push(issue);
    }
    if (catalog.sources[intersection.source] === undefined) {
      issues.push({ code: "MISSING_SOURCE", key: intersection.intersectionKey, message: `Unknown source ${intersection.source}` });
    }
  }

  for (const approach of catalog.approaches) {
    if (!intersections.has(approach.intersectionKey)) {
      issues.push({ code: "MISSING_INTERSECTION", key: approach.approachKey, message: `Unknown intersection ${approach.intersectionKey}` });
    }
    if (approach.enabledForOperation) {
      issues.push(...activeApproachIssues(approach, catalog.sources[approach.source]));
    }
  }

  return { valid: issues.length === 0, issues };
}
