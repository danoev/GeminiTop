"""Process-lifecycle and coverage regressions using disposable proc fixtures."""
from __future__ import annotations

import shlex
import shutil
import unittest
from pathlib import Path

from analyze_topology import InvalidCapture, analyze
from test_stage4_topology import Fixture, rewrite_checksum


POST_MARKER = "        # Only a complete 0..127 scan of the same live leader is retained.\n"


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        shutil.rmtree(self.fixture.proc / "process/101")
        self.fixture.add_owner(700, self.fixture.dev / "hc_mcu_dev")

    def tearDown(self):
        self.fixture.cleanup()

    def completed(self):
        result = self.fixture.run(timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        root = self.fixture.output()
        self.assertEqual((root / "COMPLETE").read_text(), "complete=1\n")
        report = analyze(root)
        self.assertEqual(report["capture_validation"], "PASS")
        return root, report

    def assert_partial_discard(self, expected_optional: str):
        root, report = self.completed()
        self.assertIn(expected_optional, (root / "OPTIONAL.txt").read_text())
        self.assertIn("processes_inspected=0", (root / "SUMMARY.txt").read_text())
        self.assertIn("matched_owners=0", (root / "SUMMARY.txt").read_text())
        self.assertEqual((root / "processes/leaders.txt").read_text(), "")
        self.assertEqual((root / "processes/owners.txt").read_text(), "")
        self.assertEqual(list((root / "processes").glob("700-*")), [])
        self.assertEqual(report["process_fd_owner_coverage"], "PARTIAL")
        self.assertEqual(report["ownership_absence_claim"], "NOT_AVAILABLE")

    @staticmethod
    def status_change(pid: int, state: str = "Z", tgid: int | str | None = None) -> str:
        label = {"S": "sleeping", "Z": "zombie"}.get(state, "test state")
        value = f"Name:\tfixture\nState:\t{state} ({label})\nTgid:\t{pid if tgid is None else tgid}\nPid:\t{pid}\n"
        return f"printf '%s' {shlex.quote(value)} > \"$PDIR/status\"\n"

    def test_live_zero_match_is_inspected_without_global_absence_claim(self):
        (self.fixture.proc / "process/700/fd/7").unlink()
        root, report = self.completed()
        self.assertIn("processes_inspected=1", (root / "SUMMARY.txt").read_text())
        self.assertIn("matched_owners=0", (root / "SUMMARY.txt").read_text())
        self.assertIn("process_fd_coverage=COMPLETE", (root / "SUMMARY.txt").read_text())
        self.assertEqual((root / "processes/leaders.txt").read_text(), "700|700|10700\n")
        self.assertEqual(report["process_fd_owner_coverage"], "COMPLETE")
        self.assertEqual(report["ownership_absence_claim"], "NOT_ESTABLISHED_BEYOND_REVIEWED_SCAN")

    def test_live_one_and_multiple_fd_owner_snapshots(self):
        (self.fixture.dev / "ttyS1").write_text("")
        (self.fixture.proc / "process/700/fd/24").symlink_to(self.fixture.dev / "ttyS1")
        root, report = self.completed()
        self.assertIn("process_fd_coverage=COMPLETE", (root / "SUMMARY.txt").read_text())
        self.assertIn("matched_owners=1", (root / "SUMMARY.txt").read_text())
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 2)
        self.assertEqual(len(list((root / "processes").glob("700-*"))), 4)
        self.assertEqual(report["process_fd_owner_coverage"], "COMPLETE")

    def test_pre_scan_z_x_lower_x_never_counted(self):
        for state in ("Z", "X", "x"):
            with self.subTest(state=state):
                fixture = Fixture()
                try:
                    shutil.rmtree(fixture.proc / "process/101")
                    fixture.add_owner(700, fixture.dev / "hc_mcu_dev")
                    (fixture.proc / "process/700/status").write_text(fixture.write_status(700, state=state))
                    result = fixture.run(timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    root = fixture.output()
                    self.assertIn(f"process_leader_uninspectable:700:{state}", (root / "OPTIONAL.txt").read_text())
                    self.assertIn("processes_inspected=0", (root / "SUMMARY.txt").read_text())
                    self.assertEqual(analyze(root)["process_fd_owner_coverage"], "PARTIAL")
                finally:
                    fixture.cleanup()

    def test_missing_duplicate_malformed_unknown_state_are_partial(self):
        statuses = (
            "Name: x\nTgid: 700\n",
            "Name: x\nState: S (sleeping)\nState: S (sleeping)\nTgid: 700\n",
            "Name: x\nState: nonsense\nTgid: 700\n",
            "Name: x\nState: Q (unknown)\nTgid: 700\n",
        )
        for value in statuses:
            with self.subTest(value=value):
                fixture = Fixture()
                try:
                    shutil.rmtree(fixture.proc / "process/101")
                    fixture.add_owner(700, fixture.dev / "hc_mcu_dev")
                    (fixture.proc / "process/700/status").write_text(value)
                    result = fixture.run(timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    root = fixture.output()
                    self.assertIn("process_fd_coverage=PARTIAL", (root / "SUMMARY.txt").read_text())
                    self.assertEqual(analyze(root)["ownership_absence_claim"], "NOT_AVAILABLE")
                finally:
                    fixture.cleanup()

    def test_exit_between_pre_scan_and_fd_scan(self):
        marker = '        cleanup_leader_stage || { record_failure "leader_stage_cleanup:$PID"; break; }\n'
        self.fixture.replace(marker, "        " + self.status_change(700) + marker)
        self.assert_partial_discard("owner_race_unusable:700:7")

    def test_exit_during_fd_scan_discards_staged_owner_group(self):
        (self.fixture.dev / "ttyS1").write_text("")
        (self.fixture.proc / "process/700/fd/24").symlink_to(self.fixture.dev / "ttyS1")
        marker = '            FD_PATH="$PDIR/fd/$FD_NUMBER"\n'
        self.fixture.replace(marker, marker + '            if [ "$FD_NUMBER" -eq 20 ]; then ' + self.status_change(700).strip() + '; fi\n')
        self.assert_partial_discard("owner_race_unusable:700:24")

    def test_exit_immediately_before_post_scan_discards_all_staging(self):
        self.fixture.replace(POST_MARKER, "        " + self.status_change(700) + POST_MARKER)
        self.assert_partial_discard("process_leader_race:700")

    def test_leader_disappears_before_post_scan(self):
        self.fixture.replace(POST_MARKER, '        mv "$PDIR" "$PDIR.gone"\n' + POST_MARKER)
        self.assert_partial_discard("process_leader_race:700")

    def test_pid_reuse_and_tgid_change_before_post_scan(self):
        replacement = self.fixture.write_stat(700, 999999).strip()
        self.fixture.replace(POST_MARKER, f"        printf '%s\\n' {shlex.quote(replacement)} > \"$PDIR/stat\"\n" + POST_MARKER)
        self.assert_partial_discard("process_leader_race:700")

        fixture = Fixture()
        try:
            shutil.rmtree(fixture.proc / "process/101")
            fixture.add_owner(700, fixture.dev / "hc_mcu_dev")
            fixture.replace(POST_MARKER, "        " + self.status_change(700, "S", 701) + POST_MARKER)
            result = fixture.run(timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            root = fixture.output()
            self.assertIn("process_leader_race:700", (root / "OPTIONAL.txt").read_text())
            self.assertEqual((root / "processes/owners.txt").read_text(), "")
            self.assertEqual(analyze(root)["process_fd_owner_coverage"], "PARTIAL")
        finally:
            fixture.cleanup()

    def test_stable_positive_owner_retained_alongside_zombie_gap(self):
        (self.fixture.proc / "process/700/status").write_text(self.fixture.write_status(700, state="Z"))
        self.fixture.add_owner(800, self.fixture.dev / "hc_mcu_dev")
        root, report = self.completed()
        self.assertIn("matched_owners=1", (root / "SUMMARY.txt").read_text())
        self.assertIn("800|800|10800|7|/dev/hc_mcu_dev", (root / "processes/owners.txt").read_text())
        self.assertEqual(report["process_fd_owner_coverage"], "PARTIAL")
        self.assertEqual(report["evidence"]["production_owned_candidate_paths"], ["/dev/hc_mcu_dev"])

    def test_malformed_readlink_cleans_value_pair_and_marks_partial(self):
        self.fixture.command("readlink", "import os,sys\n"
                             "if sys.argv[1].endswith('/fd/7'):\n"
                             " print('malformed\\nsecond'); raise SystemExit(0)\n"
                             "os.execv('/usr/bin/readlink', ['readlink', *sys.argv[1:]])\n")
        root, report = self.completed()
        self.assertIn("fd_disappeared:700:7", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(report["process_fd_owner_coverage"], "PARTIAL")
        self.assertFalse((root / ".fd-link-before.tmp.value").exists())

    def test_analyser_rejects_checksum_valid_coverage_inconsistency(self):
        (self.fixture.proc / "process/700/status").write_text(self.fixture.write_status(700, state="Z"))
        root, _ = self.completed()
        summary = root / "SUMMARY.txt"
        summary.write_text(summary.read_text().replace("process_fd_coverage=PARTIAL", "process_fd_coverage=COMPLETE"))
        rewrite_checksum(root, "SUMMARY.txt")
        with self.assertRaises(InvalidCapture):
            analyze(root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
