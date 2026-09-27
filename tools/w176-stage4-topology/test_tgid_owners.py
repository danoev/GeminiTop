"""TGID/process-owner regressions against disposable host proc fixtures."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path

from analyze_topology import InvalidCapture, analyze
from test_stage4_topology import Fixture, rewrite_checksum


class TGIDOwnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()
        shutil.rmtree(self.fixture.proc / "process/101")

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def add_group(self, leader: int, threads: int = 0, *, target: Path | None = None,
                  name: str = "fixture-owner", exe: str = "/tmp/sp/application/bin/Launcher") -> None:
        target = target or self.fixture.dev / "hc_mcu_dev"
        for ident in range(leader, leader + threads + 1):
            self.fixture.add_owner(ident, target)
            root = self.fixture.proc / "process" / str(ident)
            (root / "status").write_text(self.fixture.write_status(ident, leader))
            (root / "comm").write_text((name if ident == leader else "QThread") + "\n")
            (root / "exe").unlink()
            (root / "exe").symlink_to(exe)

    def completed(self):
        run = self.fixture.run(timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        root = self.fixture.output()
        self.assertEqual((root / "STATUS.txt").read_text().split("status=")[1].splitlines()[0], "COMPLETE")
        self.assertEqual((root / "COMPLETE").read_text(), "complete=1\n")
        report = analyze(root)
        self.assertEqual(report["capture_validation"], "PASS")
        return root

    def test_one_leader_twenty_threads_one_owner(self):
        self.add_group(700, 20)
        root = self.completed()
        owners = (root / "processes/owners.txt").read_text().splitlines()
        self.assertEqual(owners, ["700|700|10700|7|/dev/hc_mcu_dev"])
        self.assertIn("processes_inspected=1\n", (root / "SUMMARY.txt").read_text())
        self.assertIn("matched_owners=1\n", (root / "SUMMARY.txt").read_text())
        self.assertIn("fd_links_inspected=1\n", (root / "SUMMARY.txt").read_text())
        self.assertEqual((root / "processes/leaders.txt").read_text(), "700|700|10700\n")
        self.assertFalse((root / "processes/701-comm.txt").exists())

    def test_two_leaders_many_threads_two_owners(self):
        self.add_group(700, 20)
        self.add_group(800, 20, name="gocsdk", exe="/tmp/sp/usr/local/bin/gocsdk")
        root = self.completed()
        summary = (root / "SUMMARY.txt").read_text()
        for expected in ("processes_inspected=2", "matched_owners=2", "fd_links_inspected=2"):
            self.assertIn(expected, summary)
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 2)

    def test_one_owner_two_candidate_fds_one_metadata_group(self):
        self.add_group(700)
        (self.fixture.proc / "process/700/fd/7").unlink()
        for number, name in ((19, "ttyS4"), (24, "ttyS1")):
            (self.fixture.dev / name).write_text("")
            (self.fixture.proc / "process/700/fd" / str(number)).symlink_to(self.fixture.dev / name)
        root = self.completed()
        self.assertEqual(len(list((root / "processes").glob("700-*"))), 4)
        rows = (root / "processes/owners.txt").read_text().splitlines()
        self.assertEqual(len(rows), 2)
        self.assertIn("700|700|10700|19|/dev/ttyS4", rows)
        self.assertIn("700|700|10700|24|/dev/ttyS1", rows)
        self.assertIn("matched_owners=1", (root / "SUMMARY.txt").read_text())

    def test_sixteen_genuine_leaders_pass(self):
        for pid in range(700, 716):
            self.add_group(pid)
        root = self.completed()
        self.assertIn("matched_owners=16", (root / "SUMMARY.txt").read_text())
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 16)

    def test_seventeen_genuine_leaders_still_fail_closed(self):
        for pid in range(700, 717):
            self.add_group(pid)
        run = self.fixture.run(timeout=30)
        root = self.fixture.output()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("owner_limit", (root / "ERRORS.txt").read_text())
        self.assertFalse((root / "COMPLETE").exists())

    def test_malformed_missing_duplicate_nonnumeric_tgid_are_optional_skips(self):
        prefix = "Name:\tx\nState:\tS (sleeping)\n"
        for status in (prefix, prefix + "Tgid:\t700\nTgid:\t700\n", prefix + "Tgid:\tbogus\n",
                       prefix + "Tgid:\t700\n" + ("x" * 8200)):
            with self.subTest(status=status[:30]):
                fixture = Fixture()
                try:
                    shutil.rmtree(fixture.proc / "process/101")
                    fixture.add_owner(700, fixture.dev / "hc_mcu_dev")
                    (fixture.proc / "process/700/status").write_text(status)
                    self.assertEqual(fixture.run(timeout=30).returncode, 0)
                    root = fixture.output()
                    self.assertEqual((root / "processes/owners.txt").read_text(), "")
                    self.assertIn("pid_status_unusable:700", (root / "OPTIONAL.txt").read_text())
                    analyze(root)
                finally:
                    fixture.cleanup()

    def test_tgid_changes_after_metadata_discards_owner(self):
        self.add_group(700)
        marker = "                # Per-FD identity bracket; the whole group is still staged.\n"
        self.fixture.replace(marker,
            "                printf 'Name: x\\nState: S (sleeping)\\nTgid: 701\\nPid: 700\\n' > \"$PDIR/status\"\n" + marker)
        root = self.completed()
        self.assertEqual((root / "processes/owners.txt").read_text(), "")
        self.assertIn("owner_race_unusable:700:7", (root / "OPTIONAL.txt").read_text())

    def test_thread_disappears_or_leader_disappears(self):
        self.add_group(700, 1)
        (self.fixture.proc / "process/701/status").unlink()
        root = self.completed()
        self.assertIn("pid_status_unusable:701", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 1)

        fixture = Fixture()
        try:
            shutil.rmtree(fixture.proc / "process/101")
            fixture.add_owner(701, fixture.dev / "hc_mcu_dev")
            (fixture.proc / "process/701/status").write_text(fixture.write_status(701, 700))
            self.assertEqual(fixture.run(timeout=30).returncode, 0)
            root = fixture.output()
            self.assertEqual((root / "processes/owners.txt").read_text(), "")
            self.assertIn("processes_inspected=0", (root / "SUMMARY.txt").read_text())
            analyze(root)
        finally:
            fixture.cleanup()

    def test_leader_fd_directory_unavailable_is_optional_not_absence_proof(self):
        self.add_group(700)
        shutil.rmtree(self.fixture.proc / "process/700/fd")
        root = self.completed()
        self.assertEqual((root / "processes/owners.txt").read_text(), "")
        self.assertIn("leader_fd_unavailable:700", (root / "OPTIONAL.txt").read_text())
        self.assertEqual((root / "processes/leaders.txt").read_text(), "")
        self.assertIn("processes_inspected=0", (root / "SUMMARY.txt").read_text())

    def test_leader_pid_reuse_discards_owner(self):
        self.add_group(700)
        marker = "                # Per-FD identity bracket; the whole group is still staged.\n"
        replacement = self.fixture.write_stat(700, 999999).strip()
        self.fixture.replace(marker,
            f"                printf '%s\\n' '{replacement}' > \"$PDIR/stat\"\n" + marker)
        root = self.completed()
        self.assertEqual((root / "processes/owners.txt").read_text(), "")
        self.assertIn("owner_race_unusable", (root / "OPTIONAL.txt").read_text())

    def test_out_of_range_tgid_not_followed(self):
        self.add_group(700, 1)
        (self.fixture.proc / "process/701/status").write_text(self.fixture.write_status(701, 9000))
        root = self.completed()
        self.assertIn("pid_tgid_outside_scan:701", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 1)

    def test_same_exe_and_comm_two_real_processes_remain_distinct(self):
        self.add_group(700, name="same", exe="/tmp/sp/application/bin/Launcher")
        self.add_group(800, name="same", exe="/tmp/sp/application/bin/Launcher")
        root = self.completed()
        self.assertEqual(len((root / "processes/owners.txt").read_text().splitlines()), 2)
        self.assertIn("matched_owners=2", (root / "SUMMARY.txt").read_text())

    def test_physical_like_launcher_gocsdk_reaches_complete_and_libraries(self):
        for name in ("ttyS1", "ttyS2", "ttyS4"):
            (self.fixture.dev / name).write_text("")
        self.add_group(717, 20, target=self.fixture.dev / "ttyS4", name="Launcher")
        self.add_group(781, 20, target=self.fixture.dev / "ttyS2", name="gocsdk",
                       exe="/tmp/sp/usr/local/bin/gocsdk")
        (self.fixture.proc / "process/717/fd/24").symlink_to(self.fixture.dev / "ttyS1")
        root = self.completed()
        summary = (root / "SUMMARY.txt").read_text()
        for expected in ("matched_owners=2", "processes_inspected=2", "fd_links_inspected=3",
                         "library_bytes=98"):
            self.assertIn(expected, summary)
        for name in ("libappframework.so.1.0.0", "libappmcucommunication.so.1.0.0"):
            self.assertTrue((root / "files" / name).is_file())
        self.assertTrue((root / "capture-inventory.txt").is_file())
        self.assertTrue((root / "checksums.sha256").is_file())
        self.assertEqual(len((root / "processes/leaders.txt").read_text().splitlines()), 2)
        self.assertIn("717|717|10717|7|/dev/ttyS4", (root / "processes/owners.txt").read_text())
        self.assertIn("781|781|10781|7|/dev/ttyS2", (root / "processes/owners.txt").read_text())

    def test_analyser_rejects_checksum_valid_nontgid_owner(self):
        self.add_group(700)
        root = self.completed()
        owners = root / "processes/owners.txt"
        owners.write_text(owners.read_text().replace("700|700|", "700|701|"))
        rewrite_checksum(root, "processes/owners.txt")
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_analyser_rejects_inflated_process_count_and_nontgid_roster(self):
        self.add_group(700)
        root = self.completed()
        summary = root / "SUMMARY.txt"
        summary.write_text(summary.read_text().replace("processes_inspected=1", "processes_inspected=2"))
        rewrite_checksum(root, "SUMMARY.txt")
        with self.assertRaises(InvalidCapture):
            analyze(root)
        summary.write_text(summary.read_text().replace("processes_inspected=2", "processes_inspected=1"))
        rewrite_checksum(root, "SUMMARY.txt")
        roster = root / "processes/leaders.txt"
        roster.write_text("700|701|10700\n")
        rewrite_checksum(root, "processes/leaders.txt")
        with self.assertRaises(InvalidCapture):
            analyze(root)


@unittest.skipUnless(sys.platform.startswith("linux"), "native Linux proc semantics")
class NativeLinuxProcTests(unittest.TestCase):
    def test_addressable_tid_reports_common_tgid_and_shared_fd(self):
        release = threading.Event()
        ready = threading.Event()
        tid = []
        def worker():
            tid.append(threading.get_native_id())
            ready.set()
            release.wait(5)
        thread = threading.Thread(target=worker)
        with tempfile.NamedTemporaryFile() as handle:
            thread.start()
            try:
                self.assertTrue(ready.wait(2))
                leader = os.getpid()
                nonleader = tid[0]
                self.assertNotEqual(leader, nonleader)
                self.assertTrue(Path(f"/proc/{nonleader}/status").is_file())
                fields = dict(line.split(":", 1) for line in Path(f"/proc/{nonleader}/status").read_text().splitlines() if ":" in line)
                self.assertEqual(int(fields["Tgid"]), leader)
                self.assertEqual(int(fields["Pid"]), nonleader)
                self.assertNotIn(str(nonleader), os.listdir("/proc"))
                self.assertEqual(os.readlink(f"/proc/{leader}/fd/{handle.fileno()}"),
                                 os.readlink(f"/proc/{nonleader}/fd/{handle.fileno()}"))
            finally:
                release.set()
                thread.join(5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
