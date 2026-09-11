export type RightDecision = { allowed: boolean; evidence: string };

export type SourceLedger = {
  sourceId: string;
  provider: string;
  revision: string;
  origin: "synthetic" | "recorded" | "official";
  crs: string;
  rights: {
    storage: RightDecision;
    processing: RightDecision;
    redistribution: RightDecision;
    deviceMatching: RightDecision;
  };
  evidence: string;
};

export type CatalogIntersection = {
  intersectionKey: string;
  provider: string;
  sourceIntersectionId: string;
  rawSourceIdentity: Record<string, unknown>;
  name: string | null;
  coordinates: [number, number];
  source: string;
};

export type CatalogApproach = {
  approachKey: string;
  intersectionKey: string;
  movement: "straight" | "left" | "uturn" | "bus" | "bicycle" | "pedestrian";
  enabledForOperation: boolean;
  roadLinkId: string;
  stopLineId: string;
  level: number;
  sourceDirectionCode: "nt" | "et" | "st" | "wt" | "ne" | "se" | "sw" | "nw";
  directionReview: { verified: boolean; evidence: string };
  geometryReview: { verified: boolean; evidence: string };
  source: string;
};

export type DisabledRegion = {
  scope: "provider" | "intersection" | "approach";
  key: string;
  reason: "RIGHTS_UNVERIFIED" | "GEOMETRY_UNVERIFIED" | "DIRECTION_UNVERIFIED" | "OPERATION_PAUSED";
  evidence: string;
};

export type ApproachCatalog = {
  schemaVersion: "sa-contract-1";
  kind: "ApproachCatalog";
  catalogVersion: string;
  sources: Record<string, SourceLedger>;
  intersections: CatalogIntersection[];
  approaches: CatalogApproach[];
  disabledRegions: DisabledRegion[];
};

export type CatalogValidationIssue = {
  code:
    | "INVALID_COORDINATES"
    | "MISSING_SOURCE"
    | "MISSING_INTERSECTION"
    | "UNVERIFIED_RIGHTS"
    | "UNVERIFIED_DIRECTION"
    | "UNVERIFIED_GEOMETRY"
    | "UNSUPPORTED_MOVEMENT"
    | "DUPLICATE_KEY";
  key: string;
  message: string;
};

export type CatalogValidationResult = {
  valid: boolean;
  issues: CatalogValidationIssue[];
};
