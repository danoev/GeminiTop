#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List

from common import (
    CHUNK_2M,
    DEFAULT_GEMINI_HEADER,
    DEFAULT_ISP_REGIONS,
    DEFAULT_ISP_SCRIPT_SLOTS,
    FirmwareError,
    chunk_md5s,
    decode_clean_script,
    extract_clean_script_from_uimage,
    md5_hex,
    parse_gemini_components,
    read_uimage,
    split_chunk_sizes,
)


@dataclass
class ValidationResult:
    target: str
    ok: bool
    checks: List[str]
    errors: List[str]


def parse_verify_block_md5s(script_text: str, partition_name: str) -> Dict[str, List[str] | List[int]]:
    start_pat = re.compile(
        rf"^echo verifying\s+{re.escape(partition_name)}\s+\.\.\.\s*$", re.MULTILINE
    )
    m = start_pat.search(script_text)
    if not m:
        raise FirmwareError(f"Missing verify block for '{partition_name}'")

    nxt = re.search(r"^echo verifying\s+.+\s+\.\.\.\s*$", script_text[m.end() :], re.MULTILINE)
    end = m.end() + nxt.start() if nxt else len(script_text)
    block = script_text[m.start() : end]

    sizes = [int(x, 16) for x in re.findall(r"md5sum \$isp_ram_addr 0x([0-9a-fA-F]+) md5sum_value", block)]
    md5s = re.findall(r'if test "\$md5sum_value" = ([0-9a-f]{32}) ; then', block)

    if len(sizes) != len(md5s):
        raise FirmwareError(
            f"Verify block '{partition_name}' has size/hash count mismatch ({len(sizes)} vs {len(md5s)})"
        )

    return {"sizes": sizes, "md5s": md5s}


def validate_gemini(path: Path) -> ValidationResult:
    checks: List[str] = []
    errors: List[str] = []
    data = path.read_bytes()
    hdr = DEFAULT_GEMINI_HEADER

    payload_size = int.from_bytes(data[0xD8:0xDC], "little")
    header_size = int.from_bytes(data[0xDC:0xE0], "little")
    if payload_size and header_size:
        hdr = hdr.__class__(
            header_size=header_size,
            payload_size=payload_size,
            payload_md5_offset=hdr.payload_md5_offset,
            component_table_offset=hdr.component_table_offset,
            component_record_size=hdr.component_record_size,
            component_count=hdr.component_count,
        )

    embedded_payload_md5 = data[hdr.payload_md5_offset : hdr.payload_md5_offset + 32].decode("ascii", errors="ignore")
    calc_payload_md5 = md5_hex(data[hdr.header_size : hdr.header_size + hdr.payload_size])
    if embedded_payload_md5 != calc_payload_md5:
        errors.append(
            f"Payload MD5 mismatch: embedded={embedded_payload_md5} calc={calc_payload_md5}"
        )
    else:
        checks.append("Payload MD5 OK")

    components = parse_gemini_components(data, hdr)
    comp_bytes = {}
    for c in components:
        name = c["name"]
        blob = data[hdr.header_size + c["offset"] : hdr.header_size + c["offset"] + c["size"]]
        comp_bytes[name] = blob
        calc = md5_hex(blob)
        if calc != c["md5"]:
            errors.append(f"Component {name} md5 mismatch: table={c['md5']} calc={calc}")
        else:
            checks.append(f"Component {name} md5 OK")

    # Main script region follows last component.
    script_rel = max(c["offset"] + c["size"] for c in components)
    script_size = hdr.payload_size - script_rel
    script_blob = data[hdr.header_size + script_rel : hdr.header_size + script_rel + script_size]
    try:
        script_info, _ = read_uimage(script_blob)
        checks.append(f"main script uImage CRC OK ({script_info['name']})")
        script_clean = extract_clean_script_from_uimage(script_blob)
        script_text = decode_clean_script(script_clean)

        expected_all: List[str] = []
        for pname in ("spapp.", "spsdk.", "rootfs.", "kernel", "uboot2", "ecos"):
            sizes = split_chunk_sizes(len(comp_bytes[pname]), CHUNK_2M)
            expected_all.extend(chunk_md5s(comp_bytes[pname], sizes))
        found_all = re.findall(r'if test "\$md5sum_value" = ([0-9a-f]{32}) ; then', script_text)
        if found_all != expected_all:
            errors.append("main script md5 sequence does not match GEMINI payload bytes")
        else:
            checks.append("main script md5 sequence OK")
    except Exception as exc:
        errors.append(f"main script parse/verify failed: {exc}")

    return ValidationResult(str(path), not errors, checks, errors)


def validate_isp(path: Path) -> ValidationResult:
    checks: List[str] = []
    errors: List[str] = []
    data = path.read_bytes()

    region_bytes = {
        name: data[reg.offset : reg.offset + reg.size]
        for name, reg in DEFAULT_ISP_REGIONS.items()
    }

    for key, slot in DEFAULT_ISP_SCRIPT_SLOTS.items():
        script_blob = data[slot.offset : slot.offset + slot.size]
        try:
            info, _ = read_uimage(script_blob)
            checks.append(f"{key} uImage CRC OK ({info['name']})")
            script_clean = extract_clean_script_from_uimage(script_blob)
            script_text = decode_clean_script(script_clean)

            for pname in ("rootfs.", "spsdk.", "spapp."):
                parsed = parse_verify_block_md5s(script_text, pname)
                sizes = parsed["sizes"]
                expected = parsed["md5s"]
                actual = chunk_md5s(region_bytes[pname], sizes)
                if actual != expected:
                    errors.append(f"{key} {pname} md5 checks do not match ISP payload bytes")
                else:
                    checks.append(f"{key} {pname} md5 checks OK")
        except Exception as exc:
            errors.append(f"{key} parse/verify failed: {exc}")

    return ValidationResult(str(path), not errors, checks, errors)


def print_result(res: ValidationResult) -> None:
    status = "PASS" if res.ok else "FAIL"
    print(f"[{status}] {res.target}")
    for c in res.checks:
        print(f"  - OK: {c}")
    for e in res.errors:
        print(f"  - ERR: {e}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate original/modified GEMINI/ISP firmware images")
    parser.add_argument("--workdir", default=".", help="Folder containing BIN files")
    parser.add_argument("--gemini", default=None, help="Path to GEMINI_PACK.BIN (optional)")
    parser.add_argument("--isp", default=None, help="Path to ISPBOOOT.BIN (optional)")
    parser.add_argument("--gemini-mod", default=None, help="Path to modified GEMINI bin (optional)")
    parser.add_argument("--isp-mod", default=None, help="Path to modified ISP bin (optional)")
    parser.add_argument("--json", default=None, help="Optional path to write JSON report")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()

    targets = []
    gemini = Path(args.gemini) if args.gemini else workdir / "GEMINI_PACK.BIN"
    isp = Path(args.isp) if args.isp else workdir / "ISPBOOOT.BIN"
    gem_mod = Path(args.gemini_mod) if args.gemini_mod else workdir / "REPACKED" / "MODIFIED_GEMINI_PACK.BIN"
    isp_mod = Path(args.isp_mod) if args.isp_mod else workdir / "REPACKED" / "MODIFIED_ISPBOOOT.BIN"

    if gemini.exists():
        targets.append(("gemini", gemini))
    if isp.exists():
        targets.append(("isp", isp))
    if gem_mod.exists():
        targets.append(("gemini", gem_mod))
    if isp_mod.exists():
        targets.append(("isp", isp_mod))

    if not targets:
        raise FirmwareError("No firmware files found to validate")

    results: List[ValidationResult] = []
    for kind, p in targets:
        if kind == "gemini":
            results.append(validate_gemini(p))
        else:
            results.append(validate_isp(p))

    for r in results:
        print_result(r)

    if args.json:
        out = Path(args.json)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            json.dumps(
                [
                    {
                        "target": r.target,
                        "ok": r.ok,
                        "checks": r.checks,
                        "errors": r.errors,
                    }
                    for r in results
                ],
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    return 0 if all(r.ok for r in results) else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FirmwareError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
