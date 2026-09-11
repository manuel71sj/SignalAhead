import type { FastifyInstance } from "fastify";
import type { CatalogStore } from "../catalog/catalogStore.js";
import type { CatalogIntersection } from "../catalog/types.js";

type BBox = { west: number; south: number; east: number; north: number };

function parseBbox(raw: unknown): BBox | null {
  if (typeof raw !== "string") {
    return null;
  }
  const parts = raw.split(",").map((value) => Number.parseFloat(value));
  if (parts.length !== 4 || parts.some((value) => !Number.isFinite(value))) {
    return null;
  }
  const [west, south, east, north] = parts as [number, number, number, number];
  if (west < -180 || east > 180 || south <= -90 || north >= 90 || west >= east || south >= north) {
    return null;
  }
  return { west, south, east, north };
}

function inBbox(intersection: CatalogIntersection, bbox: BBox): boolean {
  const [longitude, latitude] = intersection.coordinates;
  return longitude >= bbox.west && longitude <= bbox.east && latitude >= bbox.south && latitude <= bbox.north;
}

export function registerCatalogRoutes(app: FastifyInstance, catalogStore: CatalogStore): void {
  app.get("/v1/catalog", async (request, reply) => {
    const query = request.query as { bbox?: unknown };
    const bbox = parseBbox(query.bbox);
    if (bbox === null) {
      return reply.status(400).send({ error: "INVALID_BBOX", message: "bbox must be west,south,east,north in CRS84" });
    }

    const active = catalogStore.active;
    if (active === null) {
      return { catalogVersion: null, intersections: [], approaches: [] };
    }

    const intersections = active.intersections.filter((intersection) => inBbox(intersection, bbox));
    const intersectionKeys = new Set(intersections.map((intersection) => intersection.intersectionKey));
    const approaches = active.approaches.filter(
      (approach) => approach.enabledForOperation && intersectionKeys.has(approach.intersectionKey)
    );

    return { catalogVersion: active.catalogVersion, intersections, approaches };
  });
}
