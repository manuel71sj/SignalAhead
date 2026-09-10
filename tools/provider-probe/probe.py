#!/usr/bin/env python3
"""SA-01 evidence collection, not a signal adapter or a prediction service.

Python 3.9+ standard library only. Run --help for commands. A live collection
requires NATIONAL_SERVICE_KEY and a reviewed, single-use request allocation.
No source timestamps, signal units, or traffic cycles are inferred.
"""

import argparse
import hashlib
import json
import math
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

BASE_URL = "https://apis.data.go.kr/B551982/rti"
ENDPOINTS = ("crsrd_map_info", "tl_drct_info")
MAX_BYTES = 2 * 1024 * 1024  # Transport guard, not a product timing policy.
CREDENTIAL_NAMES = ("NATIONAL_SERVICE_KEY", "SEOUL_API_KEY", "ULSAN_SERVICE_KEY")
SIGNAL_FIELDS = {
    direction + movement + suffix
    for direction in ("nt", "et", "st", "wt", "ne", "se", "sw", "nw")
    for movement in ("Bssg", "Bcsg", "Ltsg", "Pdsg", "Stsg", "Utsg")
    for suffix in ("RmndCs", "SttsNm")
}
PUBLIC_FIELDS = {
    "stdgCd",
    "lclgvNm",
    "crsrdId",
    "crsrdNm",
    "crsrdEngNm",
    "mapCtptIntLat",
    "mapCtptIntLot",
    "laneWdth",
    "lmtSpdTypeNm",
    "lmtSpd",
    "totDt",
    "regDt",
} | SIGNAL_FIELDS
AUTH_CODES = {"20", "30", "31", "K20", "K21", "K30", "K31", "K32", "K33"}
QUOTA_CODES = {"22", "23", "K22"}


class ProbeError(Exception):
    """Only static, credential-free reason codes cross the CLI boundary."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProbeError("REDIRECT_REFUSED")


def _json(raw):
    def invalid_constant(_value):
        raise ValueError("nonfinite JSON")

    return json.loads(raw, parse_constant=invalid_constant)


def _positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def _interval(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


def _scrub(value, secrets):
    # Only scalar allowlisted public fields reach this function. Drop URLs in
    # their entirety, rather than trying to enumerate authentication query keys.
    if value is None or isinstance(value, (int, float, bool)):
        return value
    if not isinstance(value, str) or len(value) > 1024:
        raise ProbeError("INVALID_PUBLIC_FIELD")
    value = re.sub(r"https?://\S+", "[REDACTED_URL]", value, flags=re.I)
    for secret in secrets:
        if secret:
            variants = {secret, urllib.parse.unquote(secret)}
            variants |= {urllib.parse.quote(s, safe="") for s in variants}
            for variant in sorted(variants, key=len, reverse=True):
                value = re.sub(re.escape(variant), "[REDACTED]", value, flags=re.I)
    return value


def _integer(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]{1,12}", str(value)):
        raise ProbeError("INVALID_PAGINATION")
    return int(value)


def _xml_value(element):
    if not len(element):
        return element.text or ""
    result = {}
    for child in element:
        if child.tag in result:
            previous = result[child.tag]
            if not isinstance(previous, list):
                previous = [previous]
            previous.append(_xml_value(child))
            result[child.tag] = previous
        else:
            result[child.tag] = _xml_value(child)
    return result


def _decode(raw, status, secrets):
    if status in (401, 403):
        return {"outcome": "authentication_error"}
    if status == 429:
        return {"outcome": "quota_exceeded"}
    if status != 200:
        return {"outcome": "http_error"}
    if len(raw) > MAX_BYTES:
        return {"outcome": "response_too_large"}
    try:
        text = raw.decode("utf-8-sig")
        if text.lstrip().startswith("<"):
            if re.search(r"<!DOCTYPE|<!ENTITY", text, re.I):
                raise ProbeError("UNSAFE_XML")
            root = ET.fromstring(text)
            if root.tag != "response":
                raise ProbeError("INVALID_ENVELOPE")
            envelope = _xml_value(root)
            wire_format = "xml"
        else:
            envelope = _json(text)
            if isinstance(envelope, dict) and "response" in envelope:
                envelope = envelope["response"]
            wire_format = "json"
        if not isinstance(envelope, dict) or not isinstance(
            envelope.get("header"), dict
        ):
            raise ProbeError("INVALID_ENVELOPE")
        code = envelope["header"].get("resultCode")
        if not isinstance(code, str) or not re.fullmatch(r"K?[0-9]{1,3}", code):
            raise ProbeError("UNRECOGNIZED_RESULT_CODE")
        result = {"wireFormat": wire_format, "resultCode": code}
        if code != "K0":
            result["outcome"] = (
                "authentication_error"
                if code in AUTH_CODES
                else "quota_exceeded"
                if code in QUOTA_CODES
                else "empty"
                if code in ("K3", "K03")
                else "provider_error"
            )
            return result
        body = envelope.get("body")
        if not isinstance(body, dict):
            raise ProbeError("INVALID_ENVELOPE")
        total, page, rows = (
            _integer(body.get(k)) for k in ("totalCount", "pageNo", "numOfRows")
        )
        if page == 0 or rows == 0:
            raise ProbeError("INVALID_PAGINATION")
        container = body.get("items")
        if container in (None, ""):
            items = []
        elif isinstance(container, dict):
            items = container.get("item", [])
            if items in (None, ""):
                items = []
            elif isinstance(items, dict):
                items = [items]
        else:
            raise ProbeError("INVALID_ITEMS")
        if not isinstance(items, list) or not all(isinstance(x, dict) for x in items):
            raise ProbeError("INVALID_ITEMS")
        if len(items) > rows or (total == 0 and items):
            raise ProbeError("INVALID_PAGINATION")
        clean = []
        omitted = 0
        for item in items:
            if not all(
                isinstance(item.get(k), str) and item[k] for k in ("stdgCd", "crsrdId")
            ):
                raise ProbeError("MISSING_INTERSECTION_ID")
            clean.append(
                {k: _scrub(v, secrets) for k, v in item.items() if k in PUBLIC_FIELDS}
            )
            omitted += len(item.keys() - PUBLIC_FIELDS)
        return {
            **result,
            "outcome": "ok" if clean else "empty",
            "totalCount": total,
            "pageNo": page,
            "numOfRows": rows,
            "items": clean,
            "omittedFieldCount": omitted,
        }
    except (ValueError, UnicodeError, ET.ParseError, ProbeError, RecursionError):
        # Provider messages/bodies may echo credentials; never log parse errors.
        return {"outcome": "invalid_response"}


class Evidence:
    def __init__(self, output, origin, endpoint, secrets):
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.stream = (output / "observations.jsonl").open("x", encoding="utf-8")
        self.output = output
        self.origin = origin
        self.endpoint = endpoint
        self.secrets = secrets
        self.first_seen = {}
        self.counts = Counter()
        self.intersections = set()
        self.last_elapsed = -1

    def observe(self, raw, status, elapsed_ms, **metadata):
        if not math.isfinite(elapsed_ms) or elapsed_ms < self.last_elapsed:
            raise ProbeError("NONMONOTONIC_CAPTURE")
        self.last_elapsed = elapsed_ms
        result = (
            _decode(raw, status, self.secrets)
            if raw is not None
            else {"outcome": metadata.pop("failure")}
        )
        for item in result.get("items", []):
            identity = (item["stdgCd"], item["crsrdId"])
            self.intersections.add(identity)
            fingerprint = hashlib.sha256(
                json.dumps(item, sort_keys=True, ensure_ascii=False).encode()
            ).hexdigest()
            key = (*identity, fingerprint)
            repeated = key in self.first_seen
            first = self.first_seen.setdefault(key, elapsed_ms)
            item["probeObservation"] = {
                "payloadFingerprint": fingerprint,
                "repeatedPayload": repeated,
                "firstSeenElapsedMs": first,
                "elapsedSinceFirstSeenMs": elapsed_ms - first,
                "sourceEventId": None,
            }
        record = {
            "origin": self.origin,
            "endpoint": self.endpoint,
            "elapsedMs": elapsed_ms,
            "httpStatus": status,
            "timingQuality": "unverified",
            "sourceTimeKind": "unknown",
            **metadata,
            **result,
        }
        self.counts[result["outcome"]] += 1
        self.stream.write(
            json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n"
        )
        self.stream.flush()
        return result

    def finish(self, stop_reason):
        self.stream.close()
        summary = {
            "origin": self.origin,
            "endpoint": self.endpoint,
            "stopReason": stop_reason,
            "observations": dict(self.counts),
            "intersectionCount": len(self.intersections),
            "intersections": [
                {"stdgCd": a, "crsrdId": b} for a, b in sorted(self.intersections)
            ],
            "operationalPredictionEnabled": False,
            "verifiedCompleteCycles": None,
            "limitations": [
                "RTT and receive intervals are not source data age or field signal error.",
                "Payload fingerprints are not provider event IDs; older events cannot yet be ordered.",
                "Units, direction semantics, timezone, sentinels and freshness remain unverified.",
                "Pagination is not an atomic signal snapshot; page coverage needs review.",
                "Collection completion does not prove three full signal cycles or pilot eligibility.",
            ],
        }
        (self.output / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        return summary


def _approval(args):
    try:
        approval = _json(args.approval.read_bytes())
        required = {
            "provider",
            "evidenceRef",
            "expiresAtUtc",
            "allocatedRequests",
            "minIntervalSeconds",
            "sampleStorageAllowed",
            "stdgCd",
            "allowedEndpoints",
        }
        if not isinstance(approval, dict) or approval.keys() != required:
            raise ProbeError("APPROVAL_FIELDS_INVALID")
        endpoints = approval["allowedEndpoints"]
        if (
            not isinstance(endpoints, list)
            or not endpoints
            or not all(isinstance(x, str) and x in ENDPOINTS for x in endpoints)
            or len(endpoints) != len(set(endpoints))
        ):
            raise ProbeError("APPROVAL_ENDPOINTS_INVALID")
        expires = datetime.fromisoformat(
            approval["expiresAtUtc"].replace("Z", "+00:00")
        )
        allocation = approval["allocatedRequests"]
        interval = approval["minIntervalSeconds"]
        if (
            approval["provider"] != "national"
            or approval["sampleStorageAllowed"] is not True
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", approval["evidenceRef"])
            or approval["stdgCd"] != args.stdg_cd
            or args.endpoint not in approval["allowedEndpoints"]
            or type(allocation) is not int
            or allocation < args.rounds * args.max_pages
            or type(interval) not in (int, float)
            or not math.isfinite(interval)
            or interval <= 0
            or args.interval < interval
            or expires.utcoffset() is None
            or expires <= datetime.now(timezone.utc)
        ):
            raise ProbeError("APPROVAL_INVALID_OR_INSUFFICIENT")
        return approval, expires
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        raise ProbeError("APPROVAL_INVALID_OR_MISSING") from None


def _collect(args, secrets):
    if not secrets[0]:
        raise ProbeError("NATIONAL_SERVICE_KEY_MISSING")
    approval, expires = _approval(args)
    if _scrub(approval["evidenceRef"], secrets) != approval["evidenceRef"]:
        raise ProbeError("APPROVAL_CONTAINS_CREDENTIAL")
    if args.stdg_cd is not None and not re.fullmatch(r"[0-9]{10}", args.stdg_cd):
        raise ProbeError("INVALID_STDG_CD")
    evidence = Evidence(args.output, "recorded-unverified", args.endpoint, secrets)
    reason = "collection_complete"
    exit_code = 0
    try:
        # Consume the entire operator-reserved allocation once. A crashed run
        # cannot silently reset its budget. The operator accounts for other users.
        receipt = args.approval.with_name(args.approval.name + ".used")
        try:
            fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise ProbeError("APPROVAL_ALREADY_USED") from None
        with os.fdopen(fd, "w") as claim:
            json.dump(
                {
                    "evidenceRef": approval["evidenceRef"],
                    "reservedRequests": approval["allocatedRequests"],
                },
                claim,
            )
        opener = urllib.request.build_opener(NoRedirect())
        started = time.monotonic()
        next_request = started
        for _round in range(args.rounds):
            total = None
            for page in range(1, args.max_pages + 1):
                time.sleep(max(0, next_request - time.monotonic()))
                if datetime.now(timezone.utc) >= expires:
                    raise ProbeError("APPROVAL_EXPIRED")
                parameters = {
                    "serviceKey": urllib.parse.unquote(secrets[0]),
                    "pageNo": page,
                    "numOfRows": args.rows,
                    "type": "json",
                }
                if args.stdg_cd is not None:
                    parameters["stdgCd"] = args.stdg_cd
                query = urllib.parse.urlencode(parameters)
                request = urllib.request.Request(
                    BASE_URL + "/" + args.endpoint + "?" + query,
                    headers={"Accept": "application/json, application/xml"},
                )
                before = time.monotonic()
                sent_utc = int(time.time() * 1000)
                next_request = before + args.interval
                failure, raw, status = None, None, None
                try:
                    with opener.open(request, timeout=20) as response:
                        status = response.status
                        raw = response.read(MAX_BYTES + 1)
                except urllib.error.HTTPError as error:
                    status = error.code
                    error.close()
                    raw = b""
                except (TimeoutError, socket.timeout):
                    failure = "timeout"
                except urllib.error.URLError as error:
                    failure = (
                        "timeout"
                        if isinstance(error.reason, (TimeoutError, socket.timeout))
                        else "transport_error"
                    )
                after = time.monotonic()
                result = evidence.observe(
                    raw,
                    status,
                    (after - started) * 1000,
                    failure=failure,
                    requestPage=page,
                    round=_round + 1,
                    requestedStdgCd=args.stdg_cd,
                    requestedRows=args.rows,
                    sentAtUtcMs=sent_utc,
                    receivedAtUtcMs=int(time.time() * 1000),
                    roundTripMs=(after - before) * 1000,
                )
                if result["outcome"] not in ("ok", "empty"):
                    reason, exit_code = result["outcome"], 1
                    return exit_code, evidence.finish(reason)
                if "totalCount" not in result:
                    if page != 1:
                        raise ProbeError("MISSING_PAGE_ITEMS")
                    break  # Provider no-data result, not a successful page response.
                if result["pageNo"] != page or result["numOfRows"] != args.rows:
                    raise ProbeError("PAGINATION_MISMATCH")
                if total is not None and total != result["totalCount"]:
                    raise ProbeError("TOTAL_COUNT_CHANGED")
                total = result["totalCount"]
                expected_count = min(args.rows, max(0, total - (page - 1) * args.rows))
                if len(result["items"]) != expected_count:
                    raise ProbeError("MISSING_PAGE_ITEMS")
                if args.stdg_cd is not None and any(
                    item["stdgCd"] != args.stdg_cd for item in result["items"]
                ):
                    raise ProbeError("REGIONAL_FILTER_MISMATCH")
                if page * args.rows >= total:
                    break
            else:
                raise ProbeError("PAGE_LIMIT_REACHED")
    except ProbeError as error:
        reason, exit_code = str(error), 2
    except KeyboardInterrupt:
        reason, exit_code = "INTERRUPTED", 130
    except OSError:
        reason, exit_code = "LOCAL_OR_TRANSPORT_IO_ERROR", 2
    return exit_code, evidence.finish(reason)


def _replay(args, secrets):
    if args.input.stat().st_size > MAX_BYTES:
        raise ProbeError("FIXTURE_TOO_LARGE")
    fixture = _json(args.input.read_bytes())
    if (
        not isinstance(fixture, dict)
        or fixture.get("origin") != "synthetic"
        or fixture.get("endpoint") not in ENDPOINTS
        or not isinstance(fixture.get("responses"), list)
        or not fixture["responses"]
    ):
        raise ProbeError("SYNTHETIC_FIXTURE_REQUIRED")
    evidence = Evidence(args.output, "synthetic", fixture["endpoint"], secrets)
    reason = "replay_complete"
    try:
        for sample in fixture["responses"]:
            raw = sample["payload"]
            raw = (
                raw.encode()
                if isinstance(raw, str)
                else json.dumps(raw, allow_nan=False).encode()
            )
            if (
                type(sample["httpStatus"]) is not int
                or not 100 <= sample["httpStatus"] <= 599
            ):
                raise ProbeError("INVALID_FIXTURE_STATUS")
            elapsed = sample["elapsedMs"]
            if type(elapsed) not in (int, float):
                raise ProbeError("INVALID_FIXTURE_TIME")
            evidence.observe(raw, sample["httpStatus"], elapsed)
    except (ValueError, TypeError, KeyError, ProbeError):
        reason = "INVALID_SYNTHETIC_FIXTURE"
    return (0 if reason == "replay_complete" else 2), evidence.finish(reason)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "preflight", help="Report credential presence only; no network or secret values"
    )
    live = commands.add_parser(
        "collect",
        help="Collect national raw-unit evidence with a single-use approved allocation",
    )
    live.add_argument("--endpoint", choices=ENDPOINTS, required=True)
    live.add_argument(
        "--stdg-cd",
        help="10-digit region; omission requires an allocation with stdgCd=null for nationwide discovery",
    )
    live.add_argument(
        "--approval",
        type=Path,
        required=True,
        help="Reviewed allocation JSON; never include a service key",
    )
    live.add_argument("--rows", type=_positive, required=True)
    live.add_argument(
        "--max-pages",
        type=_positive,
        required=True,
        help="Per round; incomplete coverage exits nonzero",
    )
    live.add_argument(
        "--rounds",
        type=_positive,
        required=True,
        help="Polling rounds, NOT verified signal cycles",
    )
    live.add_argument(
        "--interval",
        type=_interval,
        required=True,
        help="Minimum seconds between ALL request starts, including pages",
    )
    live.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New private directory; existing directories are never overwritten",
    )
    replay = commands.add_parser(
        "replay",
        help="Inspect explicitly synthetic JSON/XML responses without network access",
    )
    replay.add_argument("--input", type=Path, required=True)
    replay.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    secrets = [os.environ.get(name, "") for name in CREDENTIAL_NAMES]
    if args.command == "preflight":
        blockers = [
            "LIVE_APPROVAL_AND_QUOTA_REQUIRED",
            "REAL_SAMPLES_AND_FIELD_VALIDATION_REQUIRED",
        ]
        if not secrets[0]:
            blockers.insert(0, "NATIONAL_SERVICE_KEY_MISSING")
        result = {
            "credentialPresent": {
                k: bool(v) for k, v in zip(CREDENTIAL_NAMES, secrets)
            },
            "operationalPredictionEnabled": False,
            "blockers": blockers,
        }
        print(json.dumps(result, ensure_ascii=False))
        return 2
    try:
        code, summary = (
            _collect(args, secrets)
            if args.command == "collect"
            else _replay(args, secrets)
        )
        print(json.dumps(summary, ensure_ascii=False))
        return code
    except ProbeError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
    except (OSError, ValueError, TypeError, RecursionError):
        # Never stringify exceptions that can contain URLs, paths or responses.
        print(json.dumps({"error": "LOCAL_INPUT_OR_OUTPUT_ERROR"}), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
