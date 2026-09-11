"""SA-03 contract replay checks; no app runtime or provider network."""

import copy
import importlib.util
import json
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("validate_replay.py")
SPEC = importlib.util.spec_from_file_location("validate_replay", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validate_replay)

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "fixtures" / "replay" / "golden-contract.json"


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class ReplayContractTests(unittest.TestCase):
    def test_golden_fixture_passes_contract_boundaries(self):
        result = validate_replay.validate(load_fixture())
        self.assertEqual(result["status"], "ok")
        self.assertGreaterEqual(result["scenarioCount"], 8)
        self.assertGreaterEqual(result["negativeCaseCount"], 4)

    def test_national_identity_must_keep_stdgcd_and_crsrdid(self):
        fixture = load_fixture()
        fixture["catalog"]["intersections"][0]["sourceIntersectionId"] = "1"
        with self.assertRaises(validate_replay.ContractError) as caught:
            validate_replay.validate(fixture)
        self.assertEqual(caught.exception.code, "IDENTIFIER_COLLISION")

    def test_unknown_signal_cannot_be_expected_possible(self):
        fixture = load_fixture()
        scenario = next(item for item in fixture["scenarios"] if item["id"] == "unknown-state-not-green")
        scenario["expected"]["status"] = "possible"
        with self.assertRaises(validate_replay.ContractError) as caught:
            validate_replay.validate(fixture)
        self.assertEqual(caught.exception.code, "SIGNAL_NOT_GREEN")

    def test_unapproved_policy_cannot_predict_possible(self):
        fixture = load_fixture()
        scenario = next(item for item in fixture["scenarios"] if item["id"] == "policy-uncalibrated")
        scenario["expected"]["status"] = "possible"
        scenario["expected"]["reason"] = "INTERVAL_OVERLAP"
        with self.assertRaises(validate_replay.ContractError) as caught:
            validate_replay.validate(fixture)
        self.assertEqual(caught.exception.code, "POLICY_UNCALIBRATED")

    def test_negative_remaining_sentinel_is_rejected(self):
        fixture = load_fixture()
        case = next(item for item in fixture["negativeCases"] if item["id"] == "negative-remaining-ms")
        altered = copy.deepcopy(case["payload"])
        altered["remainingAtSourceMs"] = -1
        catalog = validate_replay._index_catalog(fixture["catalog"])
        with self.assertRaises(validate_replay.ContractError) as caught:
            validate_replay._validate_signal(altered, catalog)
        self.assertEqual(caught.exception.code, "NEGATIVE_TIME")


if __name__ == "__main__":
    unittest.main()
