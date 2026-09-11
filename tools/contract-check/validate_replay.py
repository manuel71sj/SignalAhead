#!/usr/bin/env python3
"""Validate SA-03 replay fixtures without network, credentials or app runtimes."""

import argparse
import json
import sys
from pathlib import Path

MOVEMENTS = {"straight", "left", "uturn", "bus", "bicycle", "pedestrian"}
SIGNAL_STATES = {"green", "yellow", "red", "flashing", "unknown"}
TIME_KINDS = {"generated", "transmitted", "unknown"}
TIMING_QUALITY = {"verified", "unverified"}
REASONS = {
    "TIMING_UNVERIFIED",
    "SIGNAL_STALE",
    "SIGNAL_NOT_GREEN",
    "LOCATION_INVALID",
    "TARGET_AMBIGUOUS",
    "STOPPED_OR_SLOW",
    "INTERVAL_OVERLAP",
    "POLICY_UNCALIBRATED",
    "SESSION_INACTIVE",
}


class ContractError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _load(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _require(condition, code, message):
    if not condition:
        raise ContractError(code, message)


def _nonnegative_ms(value, field, nullable=False):
    if value is None and nullable:
        return
    if not isinstance(value, int) or isinstance(value, bool):
        raise ContractError("NEGATIVE_TIME", f"{field} must be an integer ms value")
    if value < 0:
        raise ContractError("NEGATIVE_TIME", f"{field} must not be negative or sentinel encoded")


def _validate_signal(payload, catalog):
    required = {
        "schemaVersion",
        "kind",
        "provider",
        "intersectionKey",
        "approachKey",
        "movement",
        "signalState",
        "catalogVersion",
        "sourceRevision",
        "sourceIntersectionId",
        "sourceEventId",
        "sourceObservedAtUtcMs",
        "sourceTimeKind",
        "serverReceivedAtUtcMs",
        "serverSentAtUtcMs",
        "remainingAtSourceMs",
        "expiresAtUtcMs",
        "timingQuality",
        "unitEvidence",
    }
    missing = sorted(required - set(payload))
    _require(not missing, "UNVERIFIED_UNIT" if "unitEvidence" in missing else "INVALID_SIGNAL", f"missing signal fields: {missing}")
    _require(payload["kind"] == "SignalObservation", "INVALID_SIGNAL", "not a SignalObservation")
    _require(payload["movement"] in MOVEMENTS, "INVALID_SIGNAL", "invalid movement")
    _require(payload["signalState"] in SIGNAL_STATES, "INVALID_SIGNAL", "invalid signalState")
    _require(payload["sourceTimeKind"] in TIME_KINDS, "INVALID_SIGNAL", "invalid sourceTimeKind")
    _require(payload["timingQuality"] in TIMING_QUALITY, "INVALID_SIGNAL", "invalid timingQuality")
    for field in ("sourceObservedAtUtcMs", "remainingAtSourceMs", "expiresAtUtcMs"):
        _nonnegative_ms(payload[field], field, nullable=True)
    for field in ("serverReceivedAtUtcMs", "serverSentAtUtcMs"):
        _nonnegative_ms(payload[field], field)
    _require(payload["serverSentAtUtcMs"] >= payload["serverReceivedAtUtcMs"], "NEGATIVE_TIME", "serverSentAtUtcMs before receive")

    if payload["provider"] == "national":
        _require(":" in payload["sourceIntersectionId"], "IDENTIFIER_COLLISION", "national sourceIntersectionId must preserve stdgCd:crsrdId")

    unit = payload["unitEvidence"]
    _require(isinstance(unit, dict), "UNVERIFIED_UNIT", "unitEvidence must be object")
    _require(unit.get("sourceUnit") in {"ms", "centisecond", "second"}, "UNVERIFIED_UNIT", "source unit must be verified")
    _require(bool(unit.get("conversion")) and bool(unit.get("evidence")), "UNVERIFIED_UNIT", "unit conversion evidence required")

    intersections = catalog["intersectionsByKey"]
    approaches = catalog["approachesByKey"]
    _require(payload["intersectionKey"] in intersections, "TARGET_AMBIGUOUS", "signal intersection not in catalog")
    _require(payload["approachKey"] in approaches, "TARGET_AMBIGUOUS", "signal approach not in catalog")
    approach = approaches[payload["approachKey"]]
    _require(approach["intersectionKey"] == payload["intersectionKey"], "TARGET_AMBIGUOUS", "approach/intersection mismatch")
    _require(approach["movement"] == payload["movement"], "TARGET_AMBIGUOUS", "approach/movement mismatch")
    return payload


def _validate_location(payload):
    required = {
        "schemaVersion",
        "kind",
        "sessionId",
        "latitude",
        "longitude",
        "horizontalAccuracyM",
        "speedMps",
        "speedAccuracyMps",
        "courseDeg",
        "courseAccuracyDeg",
        "measuredAtUtcMs",
        "deviceReceivedMonotonicMs",
    }
    missing = sorted(required - set(payload))
    _require(not missing, "INVALID_LOCATION", f"missing location fields: {missing}")
    _require(payload["kind"] == "LocationSample", "INVALID_LOCATION", "not a LocationSample")
    _require(-90 < payload["latitude"] < 90, "INVALID_LOCATION", "latitude out of range")
    _require(-180 <= payload["longitude"] <= 180, "INVALID_LOCATION", "longitude out of range")
    _require(payload["horizontalAccuracyM"] > 0, "LOCATION_INVALID", "horizontal accuracy must be positive")
    for field in ("speedMps", "speedAccuracyMps", "courseDeg", "courseAccuracyDeg"):
        value = payload[field]
        _require(value is None or value >= 0, "INVALID_LOCATION", f"{field} must be null or nonnegative")
    _nonnegative_ms(payload["measuredAtUtcMs"], "measuredAtUtcMs")
    _nonnegative_ms(payload["deviceReceivedMonotonicMs"], "deviceReceivedMonotonicMs")
    return payload


def _index_catalog(catalog):
    _require(catalog["schemaVersion"] == "sa-contract-1", "INVALID_CATALOG", "catalog schema version mismatch")
    by_key = {}
    by_provider_source = {}
    for item in catalog["intersections"]:
        key = item["intersectionKey"]
        _require(key not in by_key, "IDENTIFIER_COLLISION", f"duplicate intersectionKey {key}")
        provider_source = (item["provider"], item["sourceIntersectionId"])
        _require(provider_source not in by_provider_source, "IDENTIFIER_COLLISION", f"duplicate provider/sourceIntersectionId {provider_source}")
        if item["provider"] == "national":
            raw = item.get("rawSourceIdentity", {})
            _require(raw.get("stdgCd") and raw.get("crsrdId"), "IDENTIFIER_COLLISION", "national raw identity must include stdgCd and crsrdId")
            _require(item["sourceIntersectionId"] == f"{raw['stdgCd']}:{raw['crsrdId']}", "IDENTIFIER_COLLISION", "national identity must be stdgCd:crsrdId")
        by_key[key] = item
        by_provider_source[provider_source] = item

    approaches = {}
    for approach in catalog["approaches"]:
        key = approach["approachKey"]
        _require(key not in approaches, "IDENTIFIER_COLLISION", f"duplicate approachKey {key}")
        _require(approach["intersectionKey"] in by_key, "TARGET_AMBIGUOUS", f"unknown intersection for {key}")
        if approach["enabledForOperation"]:
            _require(approach["movement"] == "straight", "POLICY_UNCALIBRATED", "initial operation only enables straight")
            _require(approach["directionReview"]["verified"] is True, "TARGET_AMBIGUOUS", "direction review required")
            _require(approach["geometryReview"]["verified"] is True, "TARGET_AMBIGUOUS", "geometry review required")
        approaches[key] = approach
    return {"intersectionsByKey": by_key, "approachesByKey": approaches}


def _latest_events(events, catalog):
    last = -1
    signal = None
    location = None
    session_active = False
    for event in events:
        _require(event["atMonotonicMs"] >= last, "NEGATIVE_TIME", "events must be monotonic")
        last = event["atMonotonicMs"]
        if event["type"] == "signal":
            signal = _validate_signal(event["payload"], catalog)
        elif event["type"] == "location":
            location = _validate_location(event["payload"])
        elif event["type"] == "session":
            session_active = bool(event["payload"].get("active"))
    return session_active, signal, location


def _validate_expected_result(expected):
    _require(expected["kind"] == "PredictionResult", "INVALID_RESULT", "expected must be PredictionResult")
    _require(expected["status"] in {"possible", "unlikely", "unknown"}, "INVALID_RESULT", "invalid expected status")
    _require(expected["reason"] in REASONS, "INVALID_RESULT", "invalid reason")
    for field in ("arrivalIntervalMs", "greenRemainingIntervalMs"):
        interval = expected[field]
        if interval is not None:
            _nonnegative_ms(interval["earliestMs"], f"{field}.earliestMs")
            _nonnegative_ms(interval["latestMs"], f"{field}.latestMs")
            _require(interval["earliestMs"] <= interval["latestMs"], "NEGATIVE_TIME", f"{field} earliest > latest")


def _validate_scenario(scenario, policies, catalog):
    policy = policies.get(scenario["policyVersion"])
    if policy is None:
        raise ContractError("POLICY_UNCALIBRATED", "unknown policy")
    _require(scenario["targetApproachKey"] in catalog["approachesByKey"], "TARGET_AMBIGUOUS", "target approach not in catalog")
    session_active, signal, location = _latest_events(scenario["events"], catalog)
    expected = scenario["expected"]
    _validate_expected_result(expected)

    if not session_active:
        _require(expected["status"] == "unknown" and expected["reason"] == "SESSION_INACTIVE", "SESSION_INACTIVE", "inactive session must be unknown")
        return
    if not policy["approvedForOperation"]:
        _require(expected["status"] == "unknown" and expected["reason"] == "POLICY_UNCALIBRATED", "POLICY_UNCALIBRATED", "unapproved policy must gate prediction")
        return
    if signal is None or location is None:
        raise ContractError("TARGET_AMBIGUOUS", "scenario needs signal and location")
    if signal["approachKey"] != scenario["targetApproachKey"]:
        _require(expected["status"] == "unknown" and expected["reason"] == "TARGET_AMBIGUOUS", "TARGET_AMBIGUOUS", "mismatched target must be ambiguous")
        return
    if location["horizontalAccuracyM"] > policy["maxHorizontalAccuracyM"]:
        _require(expected["status"] == "unknown" and expected["reason"] == "LOCATION_INVALID", "LOCATION_INVALID", "bad location must be invalid")
        return
    if signal["signalState"] != "green":
        _require(expected["status"] != "possible" and expected["reason"] == "SIGNAL_NOT_GREEN", "SIGNAL_NOT_GREEN", "non-green cannot be possible")
        return
    if signal["timingQuality"] != "verified" or signal["sourceTimeKind"] == "unknown" or signal["remainingAtSourceMs"] is None:
        _require(expected["status"] == "unknown" and expected["reason"] == "TIMING_UNVERIFIED", "TIMING_UNVERIFIED", "unverified timing cannot be possible")
        return
    if signal["remainingAtSourceMs"] == 0:
        _require(expected["status"] != "possible", "INTERVAL_OVERLAP", "remaining zero cannot be possible")
        return
    _require(expected["status"] == "possible", "INTERVAL_OVERLAP", "verified green overlap fixture should be possible")


def _validate_negative(case, catalog):
    try:
        payload = case["payload"]
        if payload.get("kind") == "SignalObservation":
            _validate_signal(payload, catalog)
        elif payload.get("kind") == "LocationSample":
            _validate_location(payload)
        elif payload.get("provider") == "national" and payload.get("sourceIntersectionId") == "1":
            raise ContractError("IDENTIFIER_COLLISION", "raw local national ID is incomplete")
        else:
            raise ContractError("INVALID_NEGATIVE_CASE", "negative payload was not understood")
    except ContractError as error:
        _require(error.code == case["expectedError"], error.code, f"{case['id']} expected {case['expectedError']} got {error.code}")
        return
    raise ContractError("NEGATIVE_CASE_PASSED", f"{case['id']} unexpectedly passed")


def validate(fixture):
    _require(fixture["schemaVersion"] == "sa-contract-1", "INVALID_FIXTURE", "fixture schema version mismatch")
    _require(fixture["origin"] in {"synthetic", "recorded"}, "INVALID_FIXTURE", "invalid origin")
    catalog = _index_catalog(fixture["catalog"])
    policies = {item["policyVersion"]: item for item in fixture["policies"]}
    _require(len(policies) == len(fixture["policies"]), "POLICY_UNCALIBRATED", "duplicate policyVersion")
    for scenario in fixture["scenarios"]:
        _validate_scenario(scenario, policies, catalog)
    for case in fixture["negativeCases"]:
        _validate_negative(case, catalog)
    return {"status": "ok", "scenarioCount": len(fixture["scenarios"]), "negativeCaseCount": len(fixture["negativeCases"])}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path("fixtures/replay/golden-contract.json"))
    args = parser.parse_args(argv)
    try:
        result = validate(_load(args.input))
    except (OSError, json.JSONDecodeError, KeyError, ContractError) as error:
        code = getattr(error, "code", "INVALID_FIXTURE")
        print(json.dumps({"status": "error", "code": code, "message": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
