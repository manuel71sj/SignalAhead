import copy
import importlib.util
import json
import unittest
from pathlib import Path

module_spec = importlib.util.spec_from_file_location(
    "audit", Path(__file__).with_name("audit.py")
)
assert module_spec is not None and module_spec.loader is not None
audit = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(audit)

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "spatial"


class SpatialAuditTests(unittest.TestCase):
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)
        self.bundle = json.loads(
            (FIXTURES / "synthetic-directed-routes.json").read_text()
        )

    def approach(self, key="west-approach"):
        return next(
            a
            for a in audit.audit_bundle(self.bundle)["approaches"]
            if a["approachKey"] == key
        )

    def test_metric_distance_follows_polyline_not_center_or_chord(self):
        self.assertAlmostEqual(
            self.approach()["distanceFromLinkStartToStopLineMeters"], 71.21, delta=0.05
        )
        coordinates = self.bundle["roads"]["features"][0]["geometry"]["coordinates"]
        coordinates.insert(0, [126.999, 36.999])
        self.assertAlmostEqual(
            self.approach()["distanceFromLinkStartToStopLineMeters"], 182.19, delta=0.05
        )

    def test_latitude_longitude_swap_is_rejected(self):
        self.bundle["roads"]["features"][0]["geometry"]["coordinates"][0].reverse()
        with self.assertRaisesRegex(
            audit.InvalidBundle, "COORDINATE_RANGE_OR_AXIS_ERROR"
        ):
            audit.audit_bundle(self.bundle)

    def test_opposite_parallel_and_upper_paths_do_not_take_nearby_approaches(self):
        routes = {r["id"]: r for r in audit.audit_bundle(self.bundle)["routes"]}
        self.assertEqual(
            routes["opposite-direction"]["derivedApproachKeys"], ["east-approach"]
        )
        self.assertEqual(routes["parallel-not-main"]["derivedApproachKeys"], [])
        self.assertEqual(routes["overpass-not-ground"]["derivedApproachKeys"], [])
        self.bundle["approaches"][0]["roadLinkId"] = "parallel"
        self.assertIn("STOP_LINE_NOT_UNIQUELY_ON_LINK", self.approach()["reasons"])
        self.bundle["approaches"][0]["roadLinkId"] = "upper"
        self.assertIn("GRADE_SEPARATED_STOP_LINE", self.approach()["reasons"])
        self.assertIsNone(self.approach()["distanceFromLinkStartToStopLineMeters"])

    def test_reversed_or_disconnected_route_is_not_continuous(self):
        route = self.bundle["routes"][0]
        route["roadLinkIds"] = ["west", "east"]
        route["expectedApproachKeys"] = ["west-approach", "east-approach"]
        result = audit.audit_bundle(self.bundle)["routes"][0]
        self.assertIn("DISCONNECTED_OR_REVERSED_ROUTE", result["reasons"])
        self.assertEqual(result["reviewedIntersectionCount"], 0)

    def test_consecutive_intersections_require_ground_truth_order(self):
        self.assertEqual(
            audit.audit_bundle(self.bundle)["routes"][0]["reviewedIntersectionCount"], 2
        )
        self.bundle["routes"][0]["expectedApproachKeys"].reverse()
        result = audit.audit_bundle(self.bundle)["routes"][0]
        self.assertIn("GROUND_TRUTH_APPROACH_ORDER_MISMATCH", result["reasons"])
        self.assertEqual(result["reviewedIntersectionCount"], 0)

    def test_link_level_transition_requires_separate_review(self):
        self.bundle["roads"]["features"][1]["properties"]["level"] = 1
        self.bundle["stopLines"]["features"][1]["properties"]["level"] = 1
        result = audit.audit_bundle(self.bundle)["routes"][0]
        self.assertIn("ROAD_LEVEL_TRANSITION_UNVERIFIED", result["reasons"])
        self.assertEqual(result["reviewedIntersectionCount"], 0)

    def test_unknown_rights_and_missing_direction_evidence_block_distance(self):
        right = self.bundle["sources"]["synthetic"]["rights"]["deviceMatching"]
        right["allowed"] = None
        self.assertIn("RIGHT_UNVERIFIED_DEVICEMATCHING", self.approach()["reasons"])
        self.assertIsNone(self.approach()["distanceFromLinkStartToStopLineMeters"])
        right["allowed"] = True
        self.bundle["approaches"][0]["directionReview"]["evidence"] = " "
        self.assertIn("DIRECTIONREVIEW_MISSING", self.approach()["reasons"])
        self.assertIsNone(self.approach()["distanceFromLinkStartToStopLineMeters"])

    def test_missing_or_other_intersection_stop_line_is_unsupported(self):
        stop = self.bundle["approaches"][0]
        stop["stopLineId"] = "absent"
        self.assertIn("STOP_LINE_MISSING", self.approach()["reasons"])
        stop["stopLineId"] = "next-stop"
        self.assertIn("STOP_LINE_INTERSECTION_MISMATCH", self.approach()["reasons"])

    def test_multiple_stop_crossings_are_ambiguous(self):
        self.bundle["stopLines"]["features"][0]["geometry"]["coordinates"] = [
            [126.9992, 36.9999],
            [126.9992, 37.0001],
            [126.9998, 37.0001],
            [126.9998, 36.9999],
        ]
        self.assertIn("STOP_LINE_NOT_UNIQUELY_ON_LINK", self.approach()["reasons"])

    def test_recorded_centers_cannot_create_stop_lines_or_invent_datum(self):
        bundle = json.loads((FIXTURES / "recorded-national-centers.json").read_text())
        result = audit.audit_bundle(bundle)
        self.assertEqual(result["centerOnlyReason"], "CENTER_POINT_IS_NOT_A_STOP_LINE")
        self.assertFalse(result["coordinateReferenceVerified"])
        self.assertFalse(result["pilotGeometryReviewTargetMet"])
        self.assertFalse(result["operationalPredictionEnabled"])
        self.assertIsNone(result["distanceModel"])
        bundle["roads"] = self.bundle["roads"]
        with self.assertRaisesRegex(
            audit.InvalidBundle, "NORMALIZE_TO_CRS84_BEFORE_REVIEW"
        ):
            audit.audit_bundle(bundle)

    def test_ten_synthetic_intersections_never_establish_real_pilot(self):
        bundle = copy.deepcopy(self.bundle)
        bundle["catalog"], bundle["approaches"] = [], []
        bundle["roads"]["features"], bundle["stopLines"]["features"] = [], []
        road_links, expected_approaches = [], []
        route = {
            "id": "synthetic-ten",
            "roadLinkIds": road_links,
            "expectedApproachKeys": expected_approaches,
        }
        bundle["routes"] = [route]
        for i in range(10):
            key = f"i{i}"
            start, end, stop_x = (
                round(127 + i * 0.001, 6),
                round(127 + (i + 1) * 0.001, 6),
                round(127 + i * 0.001 + 0.0008, 6),
            )
            bundle["catalog"].append(
                {
                    "intersectionKey": key,
                    "provider": "synthetic",
                    "sourceIntersectionId": key,
                    "coordinates": [end, 37],
                }
            )
            road = copy.deepcopy(self.bundle["roads"]["features"][0])
            road["properties"].update(
                roadLinkId=key, fromNodeId=f"n{i}", toNodeId=f"n{i + 1}"
            )
            road["geometry"]["coordinates"] = [[start, 37], [end, 37]]
            bundle["roads"]["features"].append(road)
            stop = copy.deepcopy(self.bundle["stopLines"]["features"][0])
            stop["properties"].update(stopLineId=key, intersectionKey=key)
            stop["geometry"]["coordinates"] = [[stop_x, 36.9999], [stop_x, 37.0001]]
            bundle["stopLines"]["features"].append(stop)
            approach = copy.deepcopy(self.bundle["approaches"][0])
            approach.update(
                approachKey=key, intersectionKey=key, roadLinkId=key, stopLineId=key
            )
            bundle["approaches"].append(approach)
            road_links.append(key)
            expected_approaches.append(key)
        result = audit.audit_bundle(bundle)
        self.assertEqual(result["largestReviewedContinuousRouteIntersectionCount"], 10)
        self.assertFalse(result["pilotGeometryReviewTargetMet"])
        self.assertFalse(result["operationalPredictionEnabled"])


if __name__ == "__main__":
    unittest.main()
