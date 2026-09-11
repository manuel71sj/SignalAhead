#!/usr/bin/env python3
"""Audit an investigation-only CRS84 road/stop-line review bundle.

This is not an app catalog, map matcher, CRS converter, or operational gate.
Distances use GeographicLib's WGS84 ellipsoid. GeoJSON coordinate order is
longitude, latitude. Geographic line segments are intersected in their CRS84
coordinate plane, then segment lengths are measured geodesically in meters.
"""

import argparse
import json
import math
import sys
from pathlib import Path

from geographiclib.geodesic import Geodesic

RIGHTS = ("storage", "processing", "redistribution", "deviceMatching")
DIRECTIONS = {"nt", "et", "st", "wt", "ne", "se", "sw", "nw"}


class InvalidBundle(Exception):
    pass


def _id(value):
    if not isinstance(value, str) or not value.strip():
        raise InvalidBundle("MISSING_OR_INVALID_IDENTIFIER")
    return value


def _point(value):
    if not isinstance(value, list) or len(value) != 2:
        raise InvalidBundle("COORDINATES_MUST_BE_LONGITUDE_LATITUDE")
    if any(type(x) not in (int, float) or not math.isfinite(x) for x in value):
        raise InvalidBundle("NONFINITE_COORDINATE")
    if not -180 <= value[0] <= 180 or not -90 < value[1] < 90:
        raise InvalidBundle("COORDINATE_RANGE_OR_AXIS_ERROR")
    return tuple(value)


def _line(feature):
    geometry = feature.get("geometry", {})
    if geometry.get("type") != "LineString":
        raise InvalidBundle("LINESTRING_REQUIRED")
    points = [_point(x) for x in geometry.get("coordinates", [])]
    if len(points) < 2 or any(a == b for a, b in zip(points, points[1:])):
        raise InvalidBundle("DEGENERATE_LINE")
    if any(abs(a[0] - b[0]) >= 180 for a, b in zip(points, points[1:])):
        raise InvalidBundle("ANTIMERIDIAN_REQUIRES_SPLIT_GEOMETRY")
    return points


def _features(collection, identifier):
    if (
        not isinstance(collection, dict)
        or collection.get("type") != "FeatureCollection"
    ):
        raise InvalidBundle("FEATURE_COLLECTION_REQUIRED")
    features = collection.get("features")
    if not isinstance(features, list):
        raise InvalidBundle("FEATURE_LIST_REQUIRED")
    result = {}
    for feature in features:
        if not isinstance(feature, dict) or feature.get("type") != "Feature":
            raise InvalidBundle("GEOJSON_FEATURE_REQUIRED")
        properties = feature.get("properties")
        if not isinstance(properties, dict):
            raise InvalidBundle("FEATURE_PROPERTIES_REQUIRED")
        key = _id(properties.get(identifier))
        if key in result:
            raise InvalidBundle("DUPLICATE_FEATURE_IDENTIFIER")
        result[key] = {"properties": properties, "line": _line(feature)}
    return result


def _meters(a, b):
    return Geodesic.WGS84.Inverse(a[1], a[0], b[1], b[0])["s12"]


def _crossing(a, b, c, d):
    """Unique segment crossing; overlapping collinear lines are ambiguous."""
    rx, ry = b[0] - a[0], b[1] - a[1]
    sx, sy = d[0] - c[0], d[1] - c[1]
    qx, qy = c[0] - a[0], c[1] - a[1]
    determinant = rx * sy - ry * sx
    if determinant == 0:
        if qx * ry - qy * rx == 0:
            axis = 0 if abs(rx) >= abs(ry) else 1
            if max(min(a[axis], b[axis]), min(c[axis], d[axis])) <= min(
                max(a[axis], b[axis]), max(c[axis], d[axis])
            ):
                raise InvalidBundle("COLLINEAR_STOP_LINE")
        return None
    t = (qx * sy - qy * sx) / determinant
    u = (qx * ry - qy * rx) / determinant
    if 0 <= t <= 1 and 0 <= u <= 1:
        return (a[0] + t * rx, a[1] + t * ry)
    return None


def _stop_distance(road, stop):
    crossings = {}
    preceding_meters = 0.0
    for start, end in zip(road, road[1:]):
        for c, d in zip(stop, stop[1:]):
            point = _crossing(start, end, c, d)
            if point is not None:
                # Deduplicate a crossing at shared polyline vertices; rounding
                # is numerical identity (~sub-micrometer), not a GPS tolerance.
                key = tuple(round(x, 12) for x in point)
                distance = preceding_meters + _meters(start, point)
                if key in crossings and abs(crossings[key] - distance) > 0.000001:
                    raise InvalidBundle("ROAD_REVISITS_STOP_LINE")
                crossings[key] = distance
        preceding_meters += _meters(start, end)
    if len(crossings) != 1:
        raise InvalidBundle("STOP_LINE_NOT_UNIQUELY_ON_LINK")
    return next(iter(crossings.values()))


def _evidence(value):
    return isinstance(value, str) and bool(value.strip())


def _source_errors(source_id, sources):
    source = sources.get(source_id)
    if not isinstance(source, dict) or not _evidence(source.get("evidence")):
        return ["SOURCE_EVIDENCE_MISSING"]
    rights = source.get("rights", {})
    if not isinstance(rights, dict):
        return ["SOURCE_RIGHTS_LEDGER_REQUIRED"]
    return [
        "RIGHT_UNVERIFIED_" + right.upper()
        for right in RIGHTS
        if not isinstance(rights.get(right), dict)
        or rights[right].get("allowed") is not True
        or not _evidence(rights[right].get("evidence"))
    ]


def audit_bundle(bundle):
    if not isinstance(bundle, dict) or bundle.get("origin") not in (
        "recorded",
        "synthetic",
    ):
        raise InvalidBundle("EXPLICIT_DATA_ORIGIN_REQUIRED")
    if bundle.get("crs") not in ("OGC:CRS84", "unverified"):
        raise InvalidBundle("NORMALIZE_TO_CRS84_BEFORE_REVIEW")
    sources = bundle.get("sources")
    if not isinstance(sources, dict):
        raise InvalidBundle("SOURCE_RIGHTS_LEDGER_REQUIRED")
    roads = _features(bundle.get("roads"), "roadLinkId")
    stops = _features(bundle.get("stopLines"), "stopLineId")
    for field in ("catalog", "approaches", "routes"):
        if not isinstance(bundle.get(field), list):
            raise InvalidBundle("REVIEW_LIST_REQUIRED")
    if bundle["crs"] == "unverified" and (
        roads or stops or bundle["approaches"] or bundle["routes"]
    ):
        raise InvalidBundle("NORMALIZE_TO_CRS84_BEFORE_REVIEW")
    catalog = {}
    provider_ids = set()
    for entry in bundle.get("catalog", []):
        key = _id(entry.get("intersectionKey"))
        provider_key = (
            _id(entry.get("provider")),
            _id(entry.get("sourceIntersectionId")),
        )
        if key in catalog or provider_key in provider_ids:
            raise InvalidBundle("DUPLICATE_CATALOG_IDENTITY")
        _point(entry.get("coordinates"))
        catalog[key] = entry
        provider_ids.add(provider_key)

    nodes = {}
    for road in roads.values():
        p = road["properties"]
        for node, point in (
            (_id(p.get("fromNodeId")), road["line"][0]),
            (_id(p.get("toNodeId")), road["line"][-1]),
        ):
            if node in nodes and nodes[node] != point:
                raise InvalidBundle("SHARED_NODE_COORDINATE_MISMATCH")
            nodes[node] = point

    approaches = {}
    for candidate in bundle.get("approaches", []):
        key = _id(candidate.get("approachKey"))
        if key in approaches:
            raise InvalidBundle("DUPLICATE_APPROACH_IDENTITY")
        intersection = candidate.get("intersectionKey")
        road_id, stop_id = candidate.get("roadLinkId"), candidate.get("stopLineId")
        road, stop = roads.get(road_id), stops.get(stop_id)
        errors = []
        if intersection not in catalog:
            errors.append("INTERSECTION_NOT_IN_PROVIDER_CATALOG")
        if road is None:
            errors.append("ROAD_LINK_MISSING")
        if stop is None:
            errors.append("STOP_LINE_MISSING")
        if candidate.get("movement") != "straight":
            errors.append("MOVEMENT_NOT_IN_STRAIGHT_PILOT")
        if candidate.get("sourceDirectionCode") not in DIRECTIONS:
            errors.append("SOURCE_DIRECTION_UNKNOWN")
        for review in ("directionReview", "geometryReview"):
            value = candidate.get(review, {})
            if (
                not isinstance(value, dict)
                or value.get("verified") is not True
                or not _evidence(value.get("evidence"))
            ):
                errors.append(review.upper() + "_MISSING")
        distance = None
        if road and stop:
            rp, sp = road["properties"], stop["properties"]
            errors.extend(_source_errors(rp.get("source"), sources))
            errors.extend(_source_errors(sp.get("source"), sources))
            if sp.get("intersectionKey") != intersection:
                errors.append("STOP_LINE_INTERSECTION_MISMATCH")
            if type(rp.get("level")) is not int or type(sp.get("level")) is not int:
                errors.append("ROAD_LEVEL_UNVERIFIED")
            elif rp["level"] != sp["level"]:
                errors.append("GRADE_SEPARATED_STOP_LINE")
            if not errors:
                try:
                    distance = _stop_distance(road["line"], stop["line"])
                except InvalidBundle as error:
                    errors.append(str(error))
        approaches[key] = {
            "approachKey": key,
            "intersectionKey": intersection,
            "roadLinkId": road_id,
            "status": "review_candidate" if not errors else "unsupported",
            "reasons": sorted(set(errors)),
            "distanceFromLinkStartToStopLineMeters": distance,
        }

    reviewed_routes = []
    for route in bundle.get("routes", []):
        route_id = _id(route.get("id"))
        links = route.get("roadLinkIds")
        if not isinstance(links, list) or not links or len(links) != len(set(links)):
            raise InvalidBundle("ROUTE_REQUIRES_UNIQUE_ORDERED_LINKS")
        errors = []
        ordered = []
        previous = None
        for link in links:
            road = roads.get(link)
            if road is None:
                errors.append("ROUTE_LINK_MISSING")
                continue
            p = road["properties"]
            errors.extend(_source_errors(p.get("source"), sources))
            if type(p.get("level")) is not int:
                errors.append("ROAD_LEVEL_UNVERIFIED")
            if previous is not None and previous["toNodeId"] != p["fromNodeId"]:
                errors.append("DISCONNECTED_OR_REVERSED_ROUTE")
            if previous is not None and previous.get("level") != p.get("level"):
                errors.append("ROAD_LEVEL_TRANSITION_UNVERIFIED")
            previous = p
            on_link = [a for a in approaches.values() if a["roadLinkId"] == link]
            if any(a["status"] != "review_candidate" for a in on_link):
                errors.append("ROUTE_CONTAINS_UNSUPPORTED_APPROACH")
            ordered.extend(
                sorted(
                    (a for a in on_link if a["status"] == "review_candidate"),
                    key=lambda a: a["distanceFromLinkStartToStopLineMeters"],
                )
            )
        actual = [a["approachKey"] for a in ordered]
        if route.get("expectedApproachKeys") != actual:
            errors.append("GROUND_TRUTH_APPROACH_ORDER_MISMATCH")
        count = len({a["intersectionKey"] for a in ordered}) if not errors else 0
        reviewed_routes.append(
            {
                "id": route_id,
                "reasons": sorted(set(errors)),
                "derivedApproachKeys": actual,
                "reviewedIntersectionCount": count,
            }
        )

    represented = {a["intersectionKey"] for a in approaches.values()}
    center_only = [key for key in catalog if key not in represented]
    largest_route = max(
        (r["reviewedIntersectionCount"] for r in reviewed_routes), default=0
    )
    return {
        "origin": bundle["origin"],
        "operationalPredictionEnabled": False,
        "coordinateReferenceVerified": bundle["crs"] == "OGC:CRS84",
        "distanceModel": "WGS84 ellipsoidal geodesic; meters" if roads else None,
        "catalogIntersectionCount": len(catalog),
        "centerOnlyIntersections": center_only,
        "centerOnlyReason": "CENTER_POINT_IS_NOT_A_STOP_LINE" if center_only else None,
        "approaches": list(approaches.values()),
        "routes": reviewed_routes,
        "largestReviewedContinuousRouteIntersectionCount": largest_route,
        "pilotGeometryReviewTarget": 10,
        "pilotGeometryReviewTargetMet": bundle["origin"] == "recorded"
        and largest_route >= 10,
        "limitations": [
            "Synthetic review evidence never establishes a real pilot.",
            "Manual evidence references must be independently checked; this tool cannot grant licenses.",
            "Road travel follows fromNodeId to toNodeId and coordinate order; no nearest-intersection inference.",
            "This audit does not verify signal time, driving behavior, lane intent, or field safety.",
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    args = parser.parse_args(argv)
    try:

        def reject_constant(_value):
            raise InvalidBundle("NONFINITE_JSON")

        with args.input.open(encoding="utf-8") as handle:
            bundle = json.load(handle, parse_constant=reject_constant)
        report = audit_bundle(bundle)
        print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
        return 0 if report["pilotGeometryReviewTargetMet"] else 2
    except InvalidBundle as error:
        reason = str(error)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        reason = "INVALID_REVIEW_BUNDLE"
    print(
        json.dumps({"error": reason, "operationalPredictionEnabled": False}),
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
