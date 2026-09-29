"""Mutation checks for the host-only matrix and recovery ledgers."""

from __future__ import annotations

import contextlib
import csv
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import verify_matrix
import verify_recovery_states


ROOT = Path(__file__).resolve().parent


class MatrixVerifierTests(unittest.TestCase):
    def check_one(self, module, matrix_name: str) -> None:
        with (ROOT / matrix_name).open(newline="", encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream, delimiter="|"))
        markers = sorted({row["marker"] for row in rows})
        self.assertNotIn("OPEN", markers)
        with tempfile.TemporaryDirectory(prefix="w176-matrix-check-") as directory:
            log = Path(directory) / "test.log"

            def verify(lines: list[str]) -> int:
                log.write_text("\n".join(lines) + "\n", encoding="utf-8")
                with patch.object(sys, "argv", ["verifier", "--log", str(log)]):
                    with contextlib.redirect_stdout(io.StringIO()):
                        return module.main()

            good = [f"PASS {marker}" for marker in markers]
            self.assertEqual(verify(good), 0)
            self.assertEqual(verify(good[1:]), 1)
            self.assertEqual(verify(good + [good[0]]), 1)
            for status in ("FAIL", "SKIP", "PARTIAL", "XFAIL", "NOT RUN"):
                with self.subTest(status=status):
                    self.assertEqual(verify(good + [f"{status} {markers[0]}"]), 1)

    def test_required_88_scenarios_fail_closed(self) -> None:
        self.check_one(verify_matrix, "matrix.psv")

    def test_twenty_recovery_states_fail_closed(self) -> None:
        self.check_one(verify_recovery_states, "recovery_states.psv")


if __name__ == "__main__":
    unittest.main()
