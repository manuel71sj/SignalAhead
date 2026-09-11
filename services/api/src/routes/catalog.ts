import type { FastifyInstance } from "fastify";
import type { CatalogStore } from "../catalog/catalogStore.js";

type BBox = { west: number; south: number; east: number; north: number };

export function parseBbox(raw: unknown): BBox | null {
  if (typeof raw !== "string" || raw.length > 128) return null;
  const fields = raw.split(",");
  if (fields.length !== 4 || fields.some((value) => !/^-?(?:\d+(?:\.\d+)?|\.\d+)$/u.test(value))) return null;
  const [west, south, east, north] = fields.map(Number) as [number, number, number, number];
  if (![west, south, east, north].every(Number.isFinite) || west < -180 || east > 180 || south <= -90 || north >= 90 || west >= east || south >= north || east - west > 1 || north - south > 1) return null;
  return { west, south, east, north };
}

export function registerCatalogRoutes(app: FastifyInstance, catalogStore: CatalogStore): void {
  app.get<{ Querystring: { bbox?: unknown } }>("/v1/catalog", async (request, reply) => {
    const bbox = parseBbox(request.query.bbox);
    if (bbox === null) return reply.status(400).send({ error: "INVALID_BBOX", message: "bbox must be CRS84 west,south,east,north with at most one degree per axis" });
    let active;
    try {
      active = await catalogStore.getActive();
    } catch {
      return reply.status(503).send({ error: "CATALOG_UNAVAILABLE", catalogVersion: null, intersections: [], approaches: [] });
    }
    if (active === null) return { catalogVersion: null, intersections: [], approaches: [] };
    const inBounds = new Set(active.intersections.filter(({ coordinates: [longitude, latitude] }) => longitude >= bbox.west && longitude <= bbox.east && latitude >= bbox.south && latitude <= bbox.north).map((item) => item.intersectionKey));
    const approaches = active.approaches.filter((approach) => approach.enabledForOperation && approach.movement === "straight" && inBounds.has(approach.intersectionKey));
    if (approaches.length > 1000) return reply.status(413).send({ error: "BBOX_RESULT_LIMIT" });
    const supported = new Set(approaches.map((approach) => approach.intersectionKey));
    const intersections = active.intersections.filter((intersection) => supported.has(intersection.intersectionKey));
    return { catalogVersion: active.catalogVersion, intersections, approaches };
  });
}
