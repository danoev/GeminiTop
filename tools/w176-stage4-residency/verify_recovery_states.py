#!/usr/bin/env python3
"""Check the 20 interrupted-state decision rows against exercised cases."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent
FIELDS = (
    "state", "boundary", "marker", "fresh_install", "verify", "uninstall",
    "replay", "auto_delete", "manual_review",
)
PASS_LINE = re.compile(r"^PASS ([a-z0-9_]+)$")
BAD_LINE = re.compile(r"^(?:FAIL|SKIP|PARTIAL|XFAIL|NOT RUN) ([a-z0-9_]+)$")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, default=ROOT / "recovery_states.psv")
    parser.add_argument("--log", type=Path, action="append", required=True)
    arguments = parser.parse_args()

    with arguments.matrix.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="|")
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("recovery matrix header does not match required schema")
        rows = list(reader)
    if len(rows) != 20:
        raise ValueError(f"recovery matrix has {len(rows)} rows, expected 20")

    observed: Counter[str] = Counter()
    disallowed: Counter[str] = Counter()
    for path in arguments.log:
        for line in path.read_text(encoding="utf-8").splitlines():
            match = PASS_LINE.fullmatch(line)
            if match:
                observed[match.group(1)] += 1
            match = BAD_LINE.fullmatch(line)
            if match:
                disallowed[match.group(1)] += 1

    passed = failed = 0
    for index, row in enumerate(rows):
        state = chr(ord("A") + index)
        if row["state"] != state or not row["boundary"]:
            raise ValueError(f"missing, duplicate, or out-of-order state {state}")
        if not re.fullmatch(r"[a-z0-9_]+", row["marker"]):
            raise ValueError(f"invalid marker for state {state}")
        expected = {
            "fresh_install": "NO", "verify": "NO",
            "uninstall": "YES" if state == "M" else "NO",
            "replay": "NO", "auto_delete": "NO", "manual_review": "YES",
        }
        if any(row[key] != value for key, value in expected.items()):
            raise ValueError(f"invalid recovery decision for state {state}")
        if observed[row["marker"]] == 1 and not disallowed[row["marker"]]:
            passed += 1
        else:
            failed += 1
            print(f"FAIL state={state} marker={row['marker']} "
                  f"pass={observed[row['marker']]} disallowed={disallowed[row['marker']]}")
    print(f"RECOVERY_STATES=20 PASS={passed} FAIL={failed} SKIP=0 PARTIAL=0")
    return 0 if passed == 20 and failed == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"recovery verification error: {error}", file=sys.stderr)
        sys.exit(2)
