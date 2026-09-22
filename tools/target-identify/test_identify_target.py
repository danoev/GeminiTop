from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "identify_target.py"
SPEC = importlib.util.spec_from_file_location("identify_target", MODULE_PATH)
assert SPEC and SPEC.loader
IDENTIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTIFY)


PROFILE = {
    "id": "reference",
    "profile_kind": "reference",
    "match": {
        "identity.hardware": "GEMINI",
        "mtd.nvm_bytes": 8388608,
        "touch.name": "fts_ts",
        "touch.event": "event3",
    },
}


class TargetIdentificationTests(unittest.TestCase):
    def test_complete_matching_manifest(self):
        evidence = {
            "identity.hardware": "GEMINI",
            "mtd.nvm_bytes": 8388608,
            "touch.name": "fts_ts",
            "touch.event": "event3",
        }
        comparison = IDENTIFY.compare_profile(PROFILE, evidence)
        self.assertEqual(comparison["result"], "MATCH")

    def test_missing_probe_fields_are_unknown(self):
        comparison = IDENTIFY.compare_profile(PROFILE, {"identity.hardware": "GEMINI"})
        self.assertEqual(comparison["result"], "UNKNOWN")
        self.assertIn("UNKNOWN", [field["result"] for field in comparison["fields"]])

    def test_different_nvm_and_touch_are_different(self):
        evidence = {
            "identity.hardware": "GEMINI",
            "mtd.nvm_bytes": 16777216,
            "touch.name": "goodix_ts",
            "touch.event": "event2",
        }
        comparison = IDENTIFY.compare_profile(PROFILE, evidence)
        self.assertEqual(comparison["result"], "DIFFERENT")
        different = {field["field"] for field in comparison["fields"] if field["result"] == "DIFFERENT"}
        self.assertEqual(different, {"mtd.nvm_bytes", "touch.name", "touch.event"})

    def test_output_never_claims_qd507_confirmation(self):
        report = IDENTIFY.identify({}, [PROFILE])
        self.assertNotIn("QD507 confirmed", json.dumps(report))

    def test_probe_directory_parses_runtime_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "uname.txt").write_text("Linux Gemini 4.9.217 #1 armv7l GNU/Linux\n")
            (root / "cpuinfo.txt").write_text("Hardware\t: GEMINI\n")
            (root / "mtd.txt").write_text('mtd12: 00800000 00020000 "nvm"\n')
            (root / "framebuffer.txt").write_text("virtual_size=1920,1440\nbits_per_pixel=32\n")
            (root / "input-devices.txt").write_text('N: Name="fts_ts"\nH: Handlers=kbd event3\n\n')
            evidence = IDENTIFY.parse_probe_directory(root)
        self.assertEqual(evidence["mtd.nvm_bytes"], 8388608)
        self.assertEqual(evidence["framebuffer.virtual_height"], 1440)
        self.assertEqual(evidence["touch.name"], "fts_ts")

    def test_hex_nvm_summary_is_preserved_and_normalized(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage1-summary.txt").write_text("mtd.nvm_hex=00800000\n")
            (root / "mtd.txt").write_text('mtd12: 00800000 00020000 "nvm"\n')
            evidence = IDENTIFY.parse_probe_directory(root)
        self.assertEqual(evidence["mtd.nvm_hex"], "00800000")
        self.assertEqual(evidence["mtd.nvm_bytes"], 8388608)
        self.assertNotIn("conflicts", evidence)

    def test_summary_raw_conflict_is_unknown_and_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stage1-summary.txt").write_text(
                "identity.hardware=OTHER\nmtd.nvm_hex=01000000\n"
            )
            (root / "cpuinfo.txt").write_text("Hardware\t: GEMINI\n")
            (root / "mtd.txt").write_text('mtd12: 00800000 00020000 "nvm"\n')
            evidence = IDENTIFY.parse_probe_directory(root)
        self.assertEqual(evidence["identity.hardware"], "UNKNOWN")
        self.assertEqual(evidence["mtd.nvm_bytes"], "UNKNOWN")
        self.assertEqual(evidence["mtd.nvm_hex"], "01000000")
        self.assertEqual(
            {item["field"] for item in evidence["conflicts"]},
            {"identity.hardware", "mtd.nvm_bytes"},
        )
        comparison = IDENTIFY.compare_profile(PROFILE, evidence)
        results = {item["field"]: item["result"] for item in comparison["fields"]}
        self.assertEqual(results["identity.hardware"], "UNKNOWN")
        self.assertEqual(results["mtd.nvm_bytes"], "UNKNOWN")


if __name__ == "__main__":
    unittest.main()
