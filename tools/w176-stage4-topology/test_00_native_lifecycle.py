"""Native Linux exited-leader regression; run before PID-intensive fixtures."""
from __future__ import annotations

import os
import select
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path

from analyze_topology import analyze
from test_stage4_topology import Fixture


HELPER = r"""
import ctypes, os, sys, threading, time
source, stop = sys.argv[1:]
def worker():
    descriptor = os.open(source, os.O_RDONLY)
    print(f"READY {threading.get_native_id()} {descriptor}", flush=True)
    while not os.path.exists(stop):
        time.sleep(0.05)
    os.close(descriptor)
threading.Thread(target=worker).start()
libc = ctypes.CDLL(None)
libc.pthread_exit.argtypes = [ctypes.c_void_p]
libc.pthread_exit(None)
"""


@unittest.skipUnless(sys.platform.startswith("linux"), "native Linux proc required")
class NativeExitedLeaderTests(unittest.TestCase):
    def test_exited_main_live_worker_fd_is_partial_not_absence(self):
        fixture = Fixture()
        child: subprocess.Popen[str] | None = None
        stop = fixture.root / "stop-native-worker"
        try:
            shutil.rmtree(fixture.proc / "process/101")
            candidate = fixture.dev / "ttyS1"
            candidate.write_text("harmless host fixture\n")
            child = subprocess.Popen(
                [sys.executable, "-c", HELPER, str(candidate), str(stop)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            assert child.stdout is not None
            ready, _, _ = select.select([child.stdout], [], [], 5)
            self.assertTrue(ready, "native helper did not become ready")
            line = child.stdout.readline().strip().split()
            self.assertEqual(line[:1], ["READY"])
            worker_tid, held_fd = map(int, line[1:])
            leader = child.pid
            self.assertLessEqual(leader, 4096, "helper must be inside reviewed numeric scan")
            self.assertNotEqual(worker_tid, leader)
            leader_status = Path(f"/proc/{leader}/status")
            for _ in range(100):
                if leader_status.exists() and "State:\tZ " in leader_status.read_text():
                    break
                time.sleep(0.02)
            self.assertIn("State:\tZ ", leader_status.read_text())
            self.assertTrue(Path(f"/proc/{leader}/fd").is_dir())
            self.assertEqual(os.listdir(f"/proc/{leader}/fd"), [])
            self.assertEqual(os.readlink(f"/proc/{worker_tid}/fd/{held_fd}"), str(candidate))

            fixture.replace(f"PROCESS_ROOT={fixture.proc / 'process'}", "PROCESS_ROOT=/proc")
            result = fixture.run(timeout=40)
            self.assertEqual(result.returncode, 0, result.stderr)
            root = fixture.output()
            self.assertIn(f"process_leader_uninspectable:{leader}:Z", (root / "OPTIONAL.txt").read_text())
            self.assertNotIn(f"{leader}|{leader}|", (root / "processes/leaders.txt").read_text())
            self.assertNotIn(f"{leader}|{leader}|", (root / "processes/owners.txt").read_text())
            self.assertIn("process_fd_coverage=PARTIAL", (root / "SUMMARY.txt").read_text())
            report = analyze(root)
            self.assertEqual(report["capture_validation"], "PASS")
            self.assertEqual(report["process_fd_owner_coverage"], "PARTIAL")
            self.assertEqual(report["ownership_absence_claim"], "NOT_AVAILABLE")
        finally:
            stop.touch()
            if child is not None:
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
                if child.stdout is not None:
                    child.stdout.close()
                if child.stderr is not None:
                    child.stderr.close()
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
