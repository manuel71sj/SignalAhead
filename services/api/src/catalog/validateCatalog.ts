import { validateCatalogShape } from "../contracts.js";
import type { ApproachCatalog, CatalogValidationIssue, CatalogValidationResult, Coordinate, RoadFeature, StopLineFeature } from "./types.js";

export type CatalogValidationMode = "operational" | "synthetic-verification";
type AddIssue = (code: CatalogValidationIssue["code"], key: string, message: string) => void;

function meters(a: Coordinate, b: Coordinate): number {
  const radians = Math.PI / 180;
  const dLat = (b[1] - a[1]) * radians;
  const dLon = (b[0] - a[0]) * radians;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * radians) * Math.cos(b[1] * radians) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371008.8 * Math.asin(Math.sqrt(Math.min(1, h)));
}

// The audit's CRS84 short-segment intersection convention. Collinear overlap is
// never a unique stop crossing. Shared vertices count once, but a road revisiting
// the same crossing at a different distance is still ambiguous.
function uniqueCrossing(road: Coordinate[], stop: Coordinate[]): boolean {
  const crossings = new Map<string, number>();
  let preceding = 0;
  for (let i = 1; i < road.length; i++) {
    const a = road[i - 1]!;
    const b = road[i]!;
    const rx = b[0] - a[0], ry = b[1] - a[1];
    for (let j = 1; j < stop.length; j++) {
      const c = stop[j - 1]!, d = stop[j]!;
      const sx = d[0] - c[0], sy = d[1] - c[1];
      const qx = c[0] - a[0], qy = c[1] - a[1];
      const determinant = rx * sy - ry * sx;
      const tolerance = 1e-12 * Math.hypot(rx, ry) * Math.hypot(sx, sy);
      if (Math.abs(determinant) <= tolerance) {
        if (Math.abs(qx * ry - qy * rx) <= tolerance) {
          const axis = Math.abs(rx) >= Math.abs(ry) ? 0 : 1;
          if (Math.max(Math.min(a[axis], b[axis]), Math.min(c[axis], d[axis])) <= Math.min(Math.max(a[axis], b[axis]), Math.max(c[axis], d[axis]))) return false;
        }
        continue;
      }
      const t = (qx * sy - qy * sx) / determinant;
      const u = (qx * ry - qy * rx) / determinant;
      if (t < 0 || t > 1 || u < 0 || u > 1) continue;
      const point: Coordinate = [a[0] + t * rx, a[1] + t * ry];
      const key = `${point[0].toFixed(12)},${point[1].toFixed(12)}`;
      const distance = preceding + meters(a, point);
      const previous = crossings.get(key);
      if (previous !== undefined && Math.abs(previous - distance) > 0.000001) return false;
      crossings.set(key, distance);
      if (crossings.size > 1) return false;
    }
    preceding += meters(a, b);
  }
  return crossings.size === 1;
}

function geometryIndices(catalog: ApproachCatalog, mode: CatalogValidationMode, add: AddIssue): { roads: Map<string, RoadFeature>; stops: Map<string, StopLineFeature> } | null {
  const spatial = catalog.spatial;
  if (spatial === undefined) return null;
  const features = [...spatial.roads.features, ...spatial.stopLines.features];
  if (features.reduce((total, feature) => total + feature.geometry.coordinates.length, 0) > 4096) {
    add("GEOMETRY_LIMIT", "spatial", "A complete region must contain at most 4096 total vertices; never truncate its graph");
    return null;
  }
  const operationalTargets = mode === "operational" && catalog.approaches.some((approach) => approach.enabledForOperation);
  for (const policy of [spatial.matchingPolicy, spatial.predictionPolicy]) {
    if (!policy.policyVersion.trim() || !policy.measurementEvidence.trim() || (operationalTargets && !policy.approvedForOperation)) add("UNVERIFIED_POLICY", "spatial", "Explicit measured matching and prediction policies require operational approval");
    if (Object.values(policy).some((value) => typeof value === "number" && !Number.isFinite(value))) add("UNVERIFIED_POLICY", "spatial", "Policy thresholds must be finite");
  }
  const roads = new Map<string, RoadFeature>();
  const stops = new Map<string, StopLineFeature>();
  const nodes = new Map<string, { point: Coordinate; level: number }>();
  const intersectionKeys = new Set(catalog.intersections.map((intersection) => intersection.intersectionKey));
  for (const feature of features) {
    const properties = feature.properties;
    const key = "roadLinkId" in properties ? properties.roadLinkId : properties.stopLineId;
    const source = Object.hasOwn(catalog.sources, properties.source) ? catalog.sources[properties.source] : undefined;
    if (source === undefined) add("MISSING_SOURCE", key, "Geometry source must resolve in the source ledger");
    else if (Object.values(source.rights).some((right) => !right.allowed || !right.evidence.trim())) add("UNVERIFIED_RIGHTS", key, "All geometry, including branches and stop barriers, requires documented rights");
    if (Object.values(properties).some((value) => typeof value === "string" && !value.trim())) add("INVALID_GEOMETRY", key, "Geometry identifiers must be nonblank");
    if (!Number.isSafeInteger(properties.level)) add("INVALID_GEOMETRY", key, "Geometry level must be an exactly represented integer");
    const points = feature.geometry.coordinates;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1]!, b = points[i]!;
      // A 1% conservative inflation keeps the short-segment spherical check
      // inside the 2km supported computational range, not a surveying claim.
      if ((a[0] === b[0] && a[1] === b[1]) || Math.abs(a[0] - b[0]) >= 180 || meters(a, b) * 1.01 >= 2000) {
        add("INVALID_GEOMETRY", key, "Segments must be nondegenerate, below 2km and must not cross the antimeridian");
        break;
      }
    }
  }
  for (const road of spatial.roads.features) {
    const properties = road.properties;
    if (roads.has(properties.roadLinkId)) add("DUPLICATE_KEY", properties.roadLinkId, "Duplicate road identifier");
    roads.set(properties.roadLinkId, road);
    for (const [nodeId, point] of [[properties.fromNodeId, road.geometry.coordinates[0]!], [properties.toNodeId, road.geometry.coordinates.at(-1)!]] as const) {
      const previous = nodes.get(nodeId);
      if (previous !== undefined && (previous.point[0] !== point[0] || previous.point[1] !== point[1] || previous.level !== properties.level)) add("INVALID_GEOMETRY", nodeId, "Shared directed nodes must have identical coordinates and level");
      nodes.set(nodeId, { point, level: properties.level });
    }
  }
  for (const stop of spatial.stopLines.features) {
    if (stops.has(stop.properties.stopLineId)) add("DUPLICATE_KEY", stop.properties.stopLineId, "Duplicate stop-line identifier");
    stops.set(stop.properties.stopLineId, stop);
    if (!intersectionKeys.has(stop.properties.intersectionKey)) add("MISSING_INTERSECTION", stop.properties.stopLineId, "Stop line must reference a catalog intersection");
  }
  return { roads, stops };
}

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
  const add: AddIssue = (code, key, message) => { issues.push({ code, key, message }); };
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
  const geometry = geometryIndices(catalog, mode, add);
  // Never enter pairwise geometry work after a malformed or oversized graph.
  const geometrySafe = geometry !== null && !issues.some((issue) => ["INVALID_GEOMETRY", "GEOMETRY_LIMIT", "DUPLICATE_KEY"].includes(issue.code));
  const crossings = new Map<string, Map<string, boolean>>();
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
      if (ledger !== undefined && Object.values(ledger.rights).some((right) => !right.allowed || right.evidence.trim().length === 0)) add("UNVERIFIED_RIGHTS", approach.approachKey, "All source rights require affirmative documented permission");
    }
    if (!approach.directionReview.verified || !approach.directionReview.evidence.trim()) add("UNVERIFIED_DIRECTION", approach.approachKey, "Direction review is unverified");
    if (!approach.geometryReview.verified || !approach.geometryReview.evidence.trim() || approach.roadLinkId === null || approach.stopLineId === null || approach.level === null) add("UNVERIFIED_GEOMETRY", approach.approachKey, "Reviewed road link, stop line and level are required");
    if (approach.movement !== "straight") add("UNSUPPORTED_MOVEMENT", approach.approachKey, "Only straight movement is supported");
    // Legacy center-only replay catalogs still exercise non-spatial contracts.
    // They can never enable operational targets or become a driving bundle.
    if (catalog.spatial === undefined && mode === "synthetic-verification") continue;
    const road = approach.roadLinkId === null ? undefined : geometry?.roads.get(approach.roadLinkId);
    const stop = approach.stopLineId === null ? undefined : geometry?.stops.get(approach.stopLineId);
    if (!geometrySafe || road === undefined || stop === undefined) {
      add("UNSUPPORTED_GEOMETRY", approach.approachKey, "Complete bounded road and stop-line geometry is required");
      continue;
    }
    if (road.properties.level !== approach.level || stop.properties.level !== approach.level || stop.properties.intersectionKey !== approach.intersectionKey) {
      add("UNVERIFIED_GEOMETRY", approach.approachKey, "Road, approach and stop line must agree on level and intersection identity");
      continue;
    }
    let roadCrossings = crossings.get(road.properties.roadLinkId);
    if (roadCrossings === undefined) { roadCrossings = new Map(); crossings.set(road.properties.roadLinkId, roadCrossings); }
    let crossing = roadCrossings.get(stop.properties.stopLineId);
    if (crossing === undefined) {
      crossing = uniqueCrossing(road.geometry.coordinates, stop.geometry.coordinates);
      roadCrossings.set(stop.properties.stopLineId, crossing);
    }
    if (!crossing) add("UNVERIFIED_GEOMETRY", approach.approachKey, "Stop line must cross its directed road exactly once without collinear overlap or revisiting");
  }
  return { valid: issues.length === 0, issues };
}
