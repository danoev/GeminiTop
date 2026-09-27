#!/usr/bin/env python3
"""Validate and conservatively classify a returned Stage-4A transaction."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path


REQUIRED = (
    "COMPLETE",
    "STATUS.txt",
    "ERRORS.txt",
    "CAPABILITIES.txt",
    "SUMMARY.txt",
    "capture-inventory.txt",
    "checksums.sha256",
    "network/proc-net-dev.txt",
    "network/interfaces.txt",
    "devices/device-nodes.txt",
    "processes/owners.txt",
    "files/libappframework.so.1.0.0",
    "files/libappmcucommunication.so.1.0.0",
)
INTERESTING_STRINGS = (
    b"HcCar",
    b"HcProtocol",
    b"iLLLightStatus",
    b"hc_protocol_initialize",
    b"hc_init",
    b"hc_mcu_read",
    b"notify_car_event",
    b"notify_canbox_event",
    b"/dev/canbox_protocol_dev",
    b"/dev/hc_mcu_dev",
    b"/dev/ttyS1",
)


class InvalidCapture(ValueError):
    pass


def _regular(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise InvalidCapture(f"required regular non-symlink file missing: {relative}")
    return path


def _read_text(root: Path, relative: str, limit: int = 1_048_576) -> str:
    path = _regular(root, relative)
    data = path.read_bytes()
    if len(data) > limit:
        raise InvalidCapture(f"file exceeds analyser limit: {relative}")
    return data.decode("utf-8", "replace")


def _parse_unique_kv(text: str, wanted: set[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in wanted:
            if key in result:
                raise InvalidCapture(f"duplicate status key: {key}")
            result[key] = value
    return result


def _verify_checksums(root: Path) -> int:
    count = 0
    for number, line in enumerate(_read_text(root, "checksums.sha256").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\x00]+)", line)
        if not match:
            raise InvalidCapture(f"invalid checksum line {number}")
        digest, relative = match.groups()
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise InvalidCapture(f"unsafe checksum path at line {number}")
        path = _regular(root, relative)
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            raise InvalidCapture(f"checksum mismatch: {relative}")
        count += 1
    if count == 0:
        raise InvalidCapture("empty checksum manifest")
    return count


def analyze(root: Path) -> dict[str, object]:
    root = root.resolve(strict=True)
    for relative in REQUIRED:
        _regular(root, relative)
    status = _parse_unique_kv(
        _read_text(root, "STATUS.txt"), {"status", "mandatory_failures"}
    )
    if status != {"status": "COMPLETE", "mandatory_failures": "0"}:
        raise InvalidCapture("transaction status is not a unique clean COMPLETE")
    if _read_text(root, "COMPLETE").strip() != "complete=1":
        raise InvalidCapture("invalid COMPLETE marker")
    if _regular(root, "ERRORS.txt").stat().st_size != 0:
        raise InvalidCapture("ERRORS.txt is not empty")
    checksum_count = _verify_checksums(root)

    interfaces = _read_text(root, "network/interfaces.txt")
    devices = _read_text(root, "devices/device-nodes.txt")
    owners = _read_text(root, "processes/owners.txt")

    # Linux ARPHRD_CAN is 280. A name alone is not promoted to confirmed raw CAN.
    raw_can = bool(re.search(r"(?m)^[A-Za-z0-9_.:-]+\.type=280\s*$", interfaces))
    proprietary_names = ("canbox_protocol_dev", "hc_mcu_dev", "ttyS1")
    proprietary_paths = {
        f"/dev/{name}"
        for name in proprietary_names
        if re.search(rf"(?m)^.*\/{re.escape(name)}\|", devices)
    }
    owned_paths = {
        f"/dev/{name}"
        for name in proprietary_names
        if f"/dev/{name}" in proprietary_paths
        and re.search(rf"(?m)^\d+\|\d+\|\d+\|.*\/{re.escape(name)}$", owners)
    }

    library_hits: dict[str, list[str]] = {}
    for relative in (
        "files/libappframework.so.1.0.0",
        "files/libappmcucommunication.so.1.0.0",
    ):
        data = _regular(root, relative).read_bytes()
        library_hits[relative] = [value.decode("ascii") for value in INTERESTING_STRINGS if value in data]

    translated = bool(owned_paths) or (
        bool(proprietary_paths)
        and any(library_hits.values())
    )
    if raw_can and translated:
        case = "CASE C"
        description = "hybrid raw-CAN and translated MCU/proprietary evidence"
    elif raw_can:
        case = "CASE A"
        description = "raw CAN exposed to Linux"
    elif translated:
        case = "CASE B"
        description = "MCU/proprietary translated interface evidence"
    else:
        case = "CASE D"
        description = "insufficient evidence"

    return {
        "schema": 1,
        "capture_validation": "PASS",
        "verified_checksums": checksum_count,
        "classification": case,
        "description": description,
        "evidence": {
            "raw_can_interface_type_280": "CONFIRMED" if raw_can else "NOT_OBSERVED",
            "candidate_proprietary_paths": sorted(proprietary_paths),
            "production_owned_candidate_paths": sorted(owned_paths),
            "library_string_hits": library_hits,
        },
        "limits": {
            "device_stream_content": "NOT_COLLECTED",
            "can_frames": "NOT_COLLECTED",
            "mcu_commands": "NOT_SENT",
            "installed_target_conclusion": "requires this capture to have come from the installed W176",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.capture)
    except (InvalidCapture, OSError) as exc:
        parser.exit(2, f"invalid Stage-4A capture: {exc}\n")
    output = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
