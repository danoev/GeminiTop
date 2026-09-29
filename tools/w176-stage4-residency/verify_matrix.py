#!/usr/bin/env python3
"""Require every named Stage-4B safety scenario to appear once as PASS."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent
FIELDS = ("id", "requirement", "marker", "evidence", "test_script", "expected")
EVIDENCE = {"REAL-LINUX", "DISPOSABLE-MOUNT", "SYNTHETIC-DETERMINISTIC", "STATIC"}
PASS_LINE = re.compile(r"^PASS ([a-z0-9_]+)$")
BAD_LINE = re.compile(r"^(?:FAIL|SKIP|PARTIAL|XFAIL|NOT RUN) ([a-z0-9_]+)$")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, default=ROOT / "matrix.psv")
    parser.add_argument("--log", type=Path, action="append", required=True)
    arguments = parser.parse_args()

    with arguments.matrix.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="|")
        if tuple(reader.fieldnames or ()) != FIELDS:
            raise ValueError("matrix header does not match required schema")
        rows = list(reader)
    if len(rows) != 88:
        raise ValueError(f"matrix has {len(rows)} rows, expected 88")

    seen_ids: set[str] = set()
    for number, row in enumerate(rows, 1):
        expected_id = f"M{number:02d}"
        if row["id"] != expected_id or row["id"] in seen_ids:
            raise ValueError(f"missing, duplicate or out-of-order matrix ID {expected_id}")
        seen_ids.add(row["id"])
        if not row["requirement"] or row["expected"] != "PASS":
            raise ValueError(f"invalid requirement or expected result: {row['id']}")
        if row["evidence"] not in EVIDENCE:
            raise ValueError(f"invalid evidence class: {row['id']}")
        if not (ROOT / row["test_script"]).is_file():
            raise ValueError(f"missing test script: {row['id']}")
        if row["marker"] != "OPEN" and not re.fullmatch(r"[a-z0-9_]+", row["marker"]):
            raise ValueError(f"invalid marker: {row['id']}")

    observed: Counter[str] = Counter()
    disallowed: Counter[str] = Counter()
    for log_path in arguments.log:
        for line in log_path.read_text(encoding="utf-8").splitlines():
            match = PASS_LINE.fullmatch(line)
            if match:
                observed[match.group(1)] += 1
            match = BAD_LINE.fullmatch(line)
            if match:
                disallowed[match.group(1)] += 1

    pass_count = fail_count = partial_count = 0
    for row in rows:
        marker = row["marker"]
        if marker == "OPEN":
            partial_count += 1
            print(f"PARTIAL {row['id']} {row['requirement']} (no test marker)")
        elif observed[marker] != 1 or disallowed[marker]:
            fail_count += 1
            print(f"FAIL {row['id']} {row['requirement']} "
                  f"(marker {marker}: {observed[marker]} PASS, {disallowed[marker]} disallowed)")
        else:
            pass_count += 1
    print(f"REQUIRED_MATRIX={len(rows)} PASS={pass_count} FAIL={fail_count} SKIP=0 PARTIAL={partial_count}")
    return 0 if pass_count == 88 and fail_count == 0 and partial_count == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"matrix verification error: {error}", file=sys.stderr)
        sys.exit(2)
