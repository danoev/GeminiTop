#!/usr/bin/env python3
"""Compare a Stage-1 probe with cautious, evidence-scoped target profiles."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping


VALID_RESULTS = {"MATCH", "DIFFERENT", "UNKNOWN"}


class IdentificationError(RuntimeError):
    pass


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _first_match(text: str, pattern: str) -> Any:
    match = re.search(pattern, text, re.MULTILINE | re.IGNORECASE)
    return match.group(1) if match else None


def _parse_summary(path: Path) -> Dict[str, Any]:
    summary: Dict[str, Any] = {}
    summary_file = path / "stage1-summary.txt"
    if not summary_file.exists():
        return summary
    for raw_line in _read(summary_file).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not value:
            continue
        if key.endswith("_hex"):
            if re.fullmatch(r"[0-9a-fA-F]+", value):
                summary[key] = value.lower()
        elif re.fullmatch(r"[0-9]+", value):
            summary[key] = int(value)
        else:
            summary[key] = value
    if "mtd.nvm_hex" in summary:
        summary["mtd.nvm_bytes"] = int(summary["mtd.nvm_hex"], 16)
    virtual_size = summary.get("framebuffer.virtual_size")
    if isinstance(virtual_size, str) and re.fullmatch(r"\d+,\d+", virtual_size):
        width, height = (int(part) for part in virtual_size.split(",", 1))
        summary["framebuffer.virtual_width"] = width
        summary["framebuffer.virtual_height"] = height
    return summary


def parse_probe_directory(path: Path) -> Dict[str, Any]:
    summary = _parse_summary(path)

    uname = _read(path / "uname.txt")
    cpuinfo = _read(path / "cpuinfo.txt")
    mtd = _read(path / "mtd.txt")
    fb = _read(path / "framebuffer.txt")
    inputs = _read(path / "input-devices.txt")
    applications = _read(path / "applications.txt") + "\n" + _read(path / "services.txt")
    usb_hash = _read(path / "usb-handlers.sha256").strip() or _read(path / "usb-handler.sha256").strip()
    appinfo_hash = _read(path / "appinfo.sha256").strip()
    appinfo = _read(path / "appinfo.rc")

    raw_evidence: Dict[str, Any] = {}
    raw_evidence["identity.hardware"] = _first_match(cpuinfo, r"^Hardware\s*:\s*(.+)$")
    raw_evidence["kernel.release"] = _first_match(uname, r"Linux\s+\S+\s+([^\s]+)")
    nvm_hex = _first_match(mtd, r'^mtd\d+:\s+([0-9a-f]+)\s+[0-9a-f]+\s+"nvm"')
    if nvm_hex:
        raw_evidence["mtd.nvm_bytes"] = int(nvm_hex, 16)
    partitions = re.findall(r'^mtd\d+:\s+([0-9a-f]+)\s+([0-9a-f]+)\s+"([^"]+)"', mtd, re.MULTILINE | re.IGNORECASE)
    if partitions:
        canonical = "\n".join(f"{name}:{size.lower()}:{erase.lower()}" for size, erase, name in partitions)
        raw_evidence["mtd.partition_signature"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    geometry = re.search(r"geometry\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", fb)
    if geometry:
        raw_evidence["framebuffer.width"] = int(geometry.group(1))
        raw_evidence["framebuffer.height"] = int(geometry.group(2))
        raw_evidence["framebuffer.virtual_width"] = int(geometry.group(3))
        raw_evidence["framebuffer.virtual_height"] = int(geometry.group(4))
        raw_evidence["framebuffer.bits_per_pixel"] = int(geometry.group(5))
    virtual_size = _first_match(fb, r"^virtual_size=(\d+,\d+)$")
    if virtual_size:
        virtual_width, virtual_height = (int(part) for part in virtual_size.split(",", 1))
        raw_evidence["framebuffer.virtual_width"] = virtual_width
        raw_evidence["framebuffer.virtual_height"] = virtual_height
    raw_bpp = _first_match(fb, r"^bits_per_pixel=(\d+)$")
    if raw_bpp:
        raw_evidence["framebuffer.bits_per_pixel"] = int(raw_bpp)
    blocks = re.finditer(r'N:\s+Name="([^"]+)"(?:(?!\n\n).)*?H:\s+Handlers=([^\n]+)', inputs, re.DOTALL)
    for block in blocks:
        if "touch" in block.group(1).lower() or "fts" in block.group(1).lower():
            raw_evidence["touch.name"] = block.group(1)
            event = re.search(r"\bevent\d+\b", block.group(2))
            if event:
                raw_evidence["touch.event"] = event.group(0)
            break
    if usb_hash:
        raw_evidence["usb_handler.sha256"] = usb_hash.split()[0]
        handlers = []
        for line in usb_hash.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
                handlers.append({"sha256": parts[0].lower(), "path": parts[1].lstrip("* ")})
        if handlers:
            raw_evidence["usb_handlers"] = handlers
    if appinfo:
        raw_evidence["appinfo.present"] = True
        if appinfo_hash:
            raw_evidence["appinfo.sha256"] = appinfo_hash.split()[0]
        clues = [clue for clue in ("GEMINI", "8368-XU") if clue.lower() in appinfo.lower()]
        if clues:
            raw_evidence["identity.product_clues"] = clues
    names = sorted(
        {
            name
            for name in ("Launcher", "apple_carplay_server", "networkmanager", "aa_manager_service")
            if re.search(rf"\b{re.escape(name)}\b", applications)
        }
    )
    if names:
        raw_evidence["applications"] = names

    raw_evidence = {key: value for key, value in raw_evidence.items() if value is not None}
    evidence: Dict[str, Any] = dict(raw_evidence)
    conflicts = []
    for key, summary_value in summary.items():
        if key in raw_evidence and raw_evidence[key] != summary_value:
            conflicts.append(
                {
                    "field": key,
                    "summary": summary_value,
                    "raw": raw_evidence[key],
                    "result": "UNKNOWN",
                }
            )
            evidence[key] = "UNKNOWN"
        else:
            evidence[key] = summary_value
    if conflicts:
        evidence["conflicts"] = conflicts
    return evidence


def validate_complete_probe_directory(path: Path) -> None:
    """Require the transactional Stage-1 success contract before identification."""
    status_path = path / "STATUS.txt"
    complete_path = path / "COMPLETE"
    errors_path = path / "ERRORS.txt"
    if not status_path.is_file() or status_path.is_symlink():
        raise IdentificationError("probe STATUS.txt is missing, non-regular, or a symlink")
    if not complete_path.is_file() or complete_path.is_symlink():
        raise IdentificationError("probe COMPLETE marker is missing, non-regular, or a symlink")
    values: Dict[str, List[str]] = {}
    for raw_line in _read(status_path).splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values.setdefault(key, []).append(value)
    required = {"schema": "1", "status": "COMPLETE", "mandatory_failures": "0"}
    for key, expected in required.items():
        if values.get(key) != [expected]:
            raise IdentificationError(f"probe STATUS.txt does not have exactly {key}={expected}")
    if _read(complete_path).strip() != "complete=1":
        raise IdentificationError("probe COMPLETE marker has unexpected content")
    if not errors_path.is_file() or errors_path.is_symlink() or errors_path.stat().st_size != 0:
        raise IdentificationError("probe ERRORS.txt is missing, non-regular, a symlink, or non-empty")


def load_probe(path: Path) -> Dict[str, Any]:
    if path.is_dir():
        validate_complete_probe_directory(path)
        return parse_probe_directory(path)
    try:
        data = json.loads(_read(path))
    except json.JSONDecodeError as exc:
        raise IdentificationError(f"probe JSON is malformed: {exc}") from exc
    if not isinstance(data, dict):
        raise IdentificationError("probe JSON must be an object")
    return data.get("evidence", data)


def _compare_value(key: str, expected: Any, observed: Mapping[str, Any]) -> str:
    if key.endswith(".contains"):
        actual_key = key[: -len(".contains")]
        actual = observed.get(actual_key)
        if actual is None or actual == "UNKNOWN":
            return "UNKNOWN"
        if not isinstance(actual, list):
            return "DIFFERENT"
        return "MATCH" if all(item in actual for item in expected) else "DIFFERENT"
    if key not in observed or observed[key] == "UNKNOWN":
        return "UNKNOWN"
    return "MATCH" if observed[key] == expected else "DIFFERENT"


def compare_profile(profile: Mapping[str, Any], observed: Mapping[str, Any]) -> Dict[str, Any]:
    expected = profile.get("match", {})
    if not isinstance(expected, dict):
        raise IdentificationError(f"profile {profile.get('id')} has invalid match data")
    fields = [
        {"field": key, "expected": value, "observed": observed.get(key[: -len('.contains')] if key.endswith('.contains') else key), "result": _compare_value(key, value, observed)}
        for key, value in sorted(expected.items())
    ]
    results = [field["result"] for field in fields]
    if "DIFFERENT" in results:
        overall = "DIFFERENT"
    elif fields and all(result == "MATCH" for result in results):
        overall = "MATCH"
    else:
        overall = "UNKNOWN"
    assert overall in VALID_RESULTS
    profile_kind = profile.get("profile_kind")
    if profile_kind == "physical-target":
        caution = (
            "A MATCH identifies the recorded installed-target fingerprint only; "
            "it does not confirm a marketing board identifier or firmware compatibility."
        )
    else:
        caution = "A reference MATCH indicates similarity only; it does not confirm a board identifier."
    return {
        "profile_id": profile.get("id"),
        "profile_kind": profile_kind,
        "result": overall,
        "fields": fields,
        "caution": caution,
    }


def load_profiles(root: Path) -> List[Dict[str, Any]]:
    profiles = []
    for path in sorted(root.glob("*/profile.json")):
        data = json.loads(_read(path))
        if isinstance(data, dict):
            profiles.append(data)
    if not profiles:
        raise IdentificationError(f"no profiles found under {root}")
    return profiles


def identify(probe: Mapping[str, Any], profiles: Iterable[Mapping[str, Any]]) -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "evidence": dict(probe),
        "comparisons": [compare_profile(profile, probe) for profile in profiles],
        "conclusion": "No marketing board identifier is confirmed by this comparison.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare a Stage-1 probe with known reference profiles")
    parser.add_argument("probe", type=Path, help="Probe directory or normalized JSON")
    parser.add_argument("--profiles", type=Path, default=Path(__file__).resolve().parents[2] / "targets")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = identify(load_probe(args.probe.resolve()), load_profiles(args.profiles.resolve()))
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IdentificationError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
