"""Behavioral boundaries for investigation evidence, never live-provider tests."""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from datetime import datetime, timedelta, timezone
from http.client import HTTPMessage
from pathlib import Path
from unittest.mock import patch

module_spec = importlib.util.spec_from_file_location(
    "probe", Path(__file__).with_name("probe.py")
)
assert module_spec is not None and module_spec.loader is not None
probe = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(probe)


class Response(io.BytesIO):
    status = 200


def payload(page=1, total=1, items=None):
    if items is None:
        items = [{"stdgCd": "0000000000", "crsrdId": str(page), "ntStsgRmndCs": "0"}]
    return json.dumps(
        {
            "header": {"resultCode": "K0"},
            "body": {
                "pageNo": str(page),
                "numOfRows": "1",
                "totalCount": str(total),
                "items": {"item": items},
            },
        }
    ).encode()


class ProbeTests(unittest.TestCase):
    def __init__(self, methodName="runTest"):
        super().__init__(methodName)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def setUp(self):
        environment = patch.dict(
            os.environ, {name: "" for name in probe.CREDENTIAL_NAMES}
        )
        environment.start()
        self.addCleanup(environment.stop)

    def run_cli(self, arguments):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = probe.main(arguments)
        return code, out.getvalue(), err.getvalue()

    def allocation(self, **overrides):
        approval = {
            "provider": "national",
            "evidenceRef": "synthetic-test-only",
            "expiresAtUtc": (
                datetime.now(timezone.utc) + timedelta(hours=1)
            ).isoformat(),
            "allocatedRequests": 2,
            "minIntervalSeconds": 0.001,
            "sampleStorageAllowed": True,
            "stdgCd": "0000000000",
            "allowedEndpoints": ["tl_drct_info"],
        }
        approval.update(overrides)
        path = self.root / "approval.json"
        path.write_text(json.dumps(approval))
        return path

    def live_args(self, approval, output="live", pages="2", rounds="1"):
        return [
            "collect",
            "--endpoint",
            "tl_drct_info",
            "--stdg-cd",
            "0000000000",
            "--approval",
            str(approval),
            "--rows",
            "1",
            "--max-pages",
            pages,
            "--rounds",
            rounds,
            "--interval",
            "0.001",
            "--output",
            str(self.root / output),
        ]

    def test_replay_retains_first_seen_after_repeat_and_intervening_payload(self):
        fixture = (
            Path(__file__).resolve().parents[2]
            / "fixtures/providers/national/synthetic-sequence.json"
        )
        target = self.root / "replay"
        code, out, err = self.run_cli(
            ["replay", "--input", str(fixture), "--output", str(target)]
        )
        self.assertEqual((code, err), (0, ""))
        records = [
            json.loads(line)
            for line in (target / "observations.jsonl").read_text().splitlines()
        ]
        self.assertEqual(
            [
                records[n]["items"][0]["probeObservation"]["elapsedSinceFirstSeenMs"]
                for n in (0, 1, 3)
            ],
            [0, 1000, 3000],
        )
        self.assertEqual(records[2]["items"][0]["ntStsgRmndCs"], "0")
        self.assertEqual(records[0]["items"][0]["ntStsgRmndCs"], "36001")
        self.assertEqual(
            [x["outcome"] for x in records[4:]],
            ["empty", "authentication_error", "quota_exceeded", "invalid_response"],
        )
        self.assertTrue(
            all(
                x["origin"] == "synthetic" and x["timingQuality"] == "unverified"
                for x in records
            )
        )
        summary = json.loads(out)
        self.assertFalse(summary["operationalPredictionEnabled"])
        self.assertIsNone(summary["verifiedCompleteCycles"])
        self.assertNotIn(
            "must-not-be-saved", (target / "observations.jsonl").read_text()
        )

    def test_public_fields_cannot_echo_encoded_credentials_or_authentication_urls(self):
        secret = "synthetic/key+value="
        raw = payload(
            items=[
                {
                    "stdgCd": "0000000000",
                    "crsrdId": "A",
                    "ntStsgRmndCs": None,
                    "crsrdNm": "synthetic%2Fkey%2Bvalue%3D",
                    "lclgvNm": "https://example.invalid/?unexpectedAuth=private",
                    "regId": "private-person",
                    "unknownNested": {"serviceKey": secret},
                }
            ]
        )
        result = probe._decode(raw, 200, [secret])
        saved = json.dumps(result)
        for prohibited in (
            secret,
            "synthetic%2F",
            "unexpectedAuth",
            "private-person",
            "unknownNested",
        ):
            self.assertNotIn(prohibited, saved)
        self.assertIsNone(result["items"][0]["ntStsgRmndCs"])
        unsafe_xml = b'<!DOCTYPE response [<!ENTITY secret "private">]><response>&secret;</response>'
        self.assertEqual(
            probe._decode(unsafe_xml, 200, [])["outcome"], "invalid_response"
        )

    def test_missing_key_or_unallocated_budget_never_opens_network(self):
        approval = self.allocation(allocatedRequests=1)
        with patch.object(probe.urllib.request, "build_opener") as transport:
            code, _, err = self.run_cli(self.live_args(approval))
            self.assertEqual(code, 2)
            self.assertIn("NATIONAL_SERVICE_KEY_MISSING", err)
            os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
            code, _, err = self.run_cli(self.live_args(approval))
            self.assertEqual(code, 2)
            self.assertIn("APPROVAL_INVALID_OR_INSUFFICIENT", err)
            transport.assert_not_called()
        self.assertFalse((self.root / "approval.json.used").exists())

    def test_expired_approval_never_consumes_allocation(self):
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation(expiresAtUtc="2000-01-01T00:00:00Z")
        with patch.object(probe.urllib.request, "build_opener") as transport:
            code, _, _ = self.run_cli(self.live_args(approval))
            self.assertEqual(code, 2)
            transport.assert_not_called()
        self.assertFalse((self.root / "approval.json.used").exists())

    def test_pagination_and_single_use_allocation_survive_reexecution(self):
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation()
        with patch.object(probe.urllib.request, "build_opener") as transport:
            transport.return_value.open.side_effect = [
                Response(payload(1, 2)),
                Response(payload(2, 2)),
            ]
            code, out, err = self.run_cli(self.live_args(approval))
            self.assertEqual((code, err), (0, ""))
            self.assertEqual(json.loads(out)["intersectionCount"], 2)
            self.assertEqual(transport.return_value.open.call_count, 2)
            again, out, _ = self.run_cli(self.live_args(approval, output="second"))
            self.assertEqual(again, 2)
            self.assertEqual(json.loads(out)["stopReason"], "APPROVAL_ALREADY_USED")
            self.assertEqual(transport.return_value.open.call_count, 2)

    def test_quota_failure_stops_without_retry_or_following_page(self):
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation()
        with patch.object(probe.urllib.request, "build_opener") as transport:
            transport.return_value.open.side_effect = urllib.error.HTTPError(
                "https://example.invalid/?serviceKey=synthetic-key",
                429,
                "echo synthetic-key",
                HTTPMessage(),
                io.BytesIO(b"synthetic-key"),
            )
            code, out, err = self.run_cli(self.live_args(approval))
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out)["stopReason"], "quota_exceeded")
            self.assertEqual(transport.return_value.open.call_count, 1)
            self.assertNotIn("synthetic-key", out + err)

    def test_page_cap_is_incomplete_not_collection_success(self):
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation()
        with patch.object(probe.urllib.request, "build_opener") as transport:
            transport.return_value.open.return_value = Response(payload(1, 3))
            code, out, _ = self.run_cli(self.live_args(approval, pages="1"))
            self.assertEqual(code, 2)
            self.assertEqual(json.loads(out)["stopReason"], "PAGE_LIMIT_REACHED")
            self.assertEqual(transport.return_value.open.call_count, 1)

    def test_recorded_no_data_response_does_not_abort_following_poll(self):
        fixture_path = (
            Path(__file__).resolve().parents[2]
            / "fixtures/providers/national/recorded-empty-k3.json"
        )
        fixture = json.loads(fixture_path.read_text())
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation()
        with patch.object(probe.urllib.request, "build_opener") as transport:
            transport.return_value.open.side_effect = [
                Response(json.dumps(fixture["payload"]).encode()),
                Response(payload()),
            ]
            code, out, err = self.run_cli(
                self.live_args(approval, pages="1", rounds="2")
            )
        self.assertEqual((code, err), (0, ""))
        summary = json.loads(out)
        self.assertEqual(summary["observations"], {"empty": 1, "ok": 1})
        self.assertEqual(summary["intersectionCount"], 1)

    def test_nationwide_discovery_requires_explicit_unscoped_allocation(self):
        os.environ["NATIONAL_SERVICE_KEY"] = "synthetic-key"
        approval = self.allocation()
        arguments = self.live_args(approval)
        region_index = arguments.index("--stdg-cd")
        del arguments[region_index : region_index + 2]
        with patch.object(probe.urllib.request, "build_opener") as transport:
            code, _, _ = self.run_cli(arguments)
            self.assertEqual(code, 2)
            transport.assert_not_called()
            self.allocation(stdgCd=None)
            transport.return_value.open.side_effect = [
                Response(payload(1, 2)),
                Response(
                    payload(
                        2, 2, [{"stdgCd": "1100000000", "crsrdId": "different-region"}]
                    )
                ),
            ]
            code, out, err = self.run_cli(arguments)
        self.assertEqual((code, err), (0, ""))
        regions = {item["stdgCd"] for item in json.loads(out)["intersections"]}
        self.assertEqual(regions, {"0000000000", "1100000000"})

    def test_redirect_never_forwards_service_key(self):
        with self.assertRaisesRegex(probe.ProbeError, "REDIRECT_REFUSED"):
            probe.NoRedirect().redirect_request(
                probe.urllib.request.Request("https://example.invalid/"),
                io.BytesIO(),
                302,
                "",
                HTTPMessage(),
                "http://other.invalid/",
            )


if __name__ == "__main__":
    unittest.main()
