#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from common import (
    DEFAULT_GEMINI_HEADER,
    DEFAULT_ISP_REGIONS,
    DEFAULT_ISP_SCRIPT_SLOTS,
    FirmwareError,
    ensure_dir,
    extract_clean_script_from_uimage,
    parse_gemini_components,
    read_uimage,
    require_tools,
    unsquashfs,
    verify_squashfs_magic,
    write_json,
)


def extract_gemini(workdir: Path, gemini_bin: Path, force: bool) -> None:
    print(f"[extract] GEMINI source: {gemini_bin}")
    out_dir = workdir / "GEMINI_PACK"
    if out_dir.exists() and force:
        shutil.rmtree(out_dir)
    if out_dir.exists() and not force:
        raise FirmwareError(f"{out_dir} already exists. Use --force to overwrite.")

    ensure_dir(out_dir)
    ensure_dir(out_dir / "components")
    ensure_dir(out_dir / "filesystems")
    ensure_dir(out_dir / "scripts")
    ensure_dir(out_dir / "_base")

    data = gemini_bin.read_bytes()
    hdr = DEFAULT_GEMINI_HEADER

    payload_size = int.from_bytes(data[0xD8:0xDC], "little")
    header_size = int.from_bytes(data[0xDC:0xE0], "little")
    if payload_size:
        hdr = hdr.__class__(
            header_size=header_size,
            payload_size=payload_size,
            payload_md5_offset=hdr.payload_md5_offset,
            component_table_offset=hdr.component_table_offset,
            component_record_size=hdr.component_record_size,
            component_count=hdr.component_count,
        )

    components = parse_gemini_components(data, hdr)
    if not components:
        raise FirmwareError("Failed to parse GEMINI component table")

    component_meta = []
    for comp in components:
        comp_name = comp["name"]
        comp_off = comp["offset"]
        comp_size = comp["size"]
        abs_start = hdr.header_size + comp_off
        abs_end = abs_start + comp_size
        blob = data[abs_start:abs_end]

        ext = ".sqsh" if comp_name in {"rootfs.", "spsdk.", "spapp."} else ".bin"
        out_blob = out_dir / "components" / f"{comp_name.rstrip('.')}{ext}"
        out_blob.write_bytes(blob)
        print(f"[extract] GEMINI component {comp_name} -> {out_blob.name} ({len(blob)} bytes)")

        if ext == ".sqsh":
            verify_squashfs_magic(blob, comp_name)
            fs_dst = out_dir / "filesystems" / comp_name.rstrip(".")
            print(f"[extract] unsquashfs {comp_name} -> {fs_dst}")
            unsquashfs(out_blob, fs_dst)

        component_meta.append(
            {
                "name": comp_name,
                "offset": comp_off,
                "size": comp_size,
                "table_md5": comp["md5"],
                "table_md5_offset": comp["md5_offset"],
            }
        )

    # Main update script is stored after the last component.
    comp_end = max(c["offset"] + c["size"] for c in component_meta)
    script_rel_off = comp_end
    script_rel_size = hdr.payload_size - comp_end
    if script_rel_size <= 0:
        raise FirmwareError("Invalid GEMINI script region size")
    script_abs_off = hdr.header_size + script_rel_off
    script_blob = data[script_abs_off : script_abs_off + script_rel_size]
    script_clean = extract_clean_script_from_uimage(script_blob)
    script_info, _ = read_uimage(script_blob)
    print(f"[extract] GEMINI main script uImage: {script_info['name']}")

    (out_dir / "scripts" / "main_update_script.uimage").write_bytes(script_blob)
    (out_dir / "scripts" / "main_update_script.clean").write_bytes(script_clean)

    shutil.copy2(gemini_bin, out_dir / "_base" / "GEMINI_PACK.BIN")

    payload_md5 = data[hdr.payload_md5_offset : hdr.payload_md5_offset + 32].decode("ascii", errors="ignore")
    write_json(
        out_dir / "metadata.json",
        {
            "format": "GEMINI_PACK",
            "source_bin": gemini_bin.name,
            "header_size": hdr.header_size,
            "payload_size": hdr.payload_size,
            "payload_md5_offset": hdr.payload_md5_offset,
            "payload_md5": payload_md5,
            "components": component_meta,
            "script": {
                "name": "main_update_script",
                "offset": script_rel_off,
                "size": script_rel_size,
                "uimage_name": script_info["name"],
                "uimage": {
                    "timestamp": script_info["timestamp"],
                    "load_addr": script_info["load_addr"],
                    "entry_addr": script_info["entry_addr"],
                    "os": script_info["os"],
                    "arch": script_info["arch"],
                    "type": script_info["type"],
                    "comp": script_info["comp"],
                },
            },
        },
    )
    print(f"[extract] GEMINI metadata -> {out_dir / 'metadata.json'}")


def extract_isp(workdir: Path, isp_bin: Path, force: bool) -> None:
    print(f"[extract] ISP source: {isp_bin}")
    out_dir = workdir / "ISPBOOOT"
    if out_dir.exists() and force:
        shutil.rmtree(out_dir)
    if out_dir.exists() and not force:
        raise FirmwareError(f"{out_dir} already exists. Use --force to overwrite.")

    ensure_dir(out_dir)
    ensure_dir(out_dir / "components")
    ensure_dir(out_dir / "filesystems")
    ensure_dir(out_dir / "scripts")
    ensure_dir(out_dir / "_base")

    data = isp_bin.read_bytes()

    component_meta = []
    for name, reg in DEFAULT_ISP_REGIONS.items():
        blob = data[reg.offset : reg.offset + reg.size]
        out_blob = out_dir / "components" / f"{name.rstrip('.')}.sqsh"
        out_blob.write_bytes(blob)
        print(f"[extract] ISP component {name} -> {out_blob.name} ({len(blob)} bytes)")
        verify_squashfs_magic(blob, name)
        print(f"[extract] unsquashfs {name} -> {out_dir / 'filesystems' / name.rstrip('.')}")
        unsquashfs(out_blob, out_dir / "filesystems" / name.rstrip("."))
        component_meta.append({"name": name, "offset": reg.offset, "size": reg.size})

    script_meta = {}
    for name, slot in DEFAULT_ISP_SCRIPT_SLOTS.items():
        blob = data[slot.offset : slot.offset + slot.size]
        clean = extract_clean_script_from_uimage(blob)
        info, _ = read_uimage(blob)
        print(f"[extract] ISP script {name} uImage: {info['name']}")

        (out_dir / "scripts" / f"{name}.uimage").write_bytes(blob)
        (out_dir / "scripts" / f"{name}.clean").write_bytes(clean)

        script_meta[name] = {
            "offset": slot.offset,
            "size": slot.size,
            "uimage_name": info["name"],
            "uimage": {
                "timestamp": info["timestamp"],
                "load_addr": info["load_addr"],
                "entry_addr": info["entry_addr"],
                "os": info["os"],
                "arch": info["arch"],
                "type": info["type"],
                "comp": info["comp"],
            },
        }

    shutil.copy2(isp_bin, out_dir / "_base" / "ISPBOOOT.BIN")

    write_json(
        out_dir / "metadata.json",
        {
            "format": "ISPBOOOT",
            "source_bin": isp_bin.name,
            "components": component_meta,
            "scripts": script_meta,
        },
    )
    print(f"[extract] ISP metadata -> {out_dir / 'metadata.json'}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract GEMINI_PACK.BIN and ISPBOOOT.BIN")
    parser.add_argument("--workdir", default=".", help="Output folder where GEMINI_PACK and ISPBOOOT will be created")
    parser.add_argument("--gemini-bin", default=None, help="Path to source GEMINI bin (optional)")
    parser.add_argument("--isp-bin", default=None, help="Path to source ISP bin (optional)")
    parser.add_argument("--force", action="store_true", help="Overwrite existing GEMINI_PACK/ISPBOOOT folders")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()
    gemini_bin = Path(args.gemini_bin).resolve() if args.gemini_bin else workdir / "GEMINI_PACK.BIN"
    isp_bin = Path(args.isp_bin).resolve() if args.isp_bin else workdir / "ISPBOOOT.BIN"

    if not gemini_bin.exists() or not isp_bin.exists():
        raise FirmwareError(
            f"Missing source bin(s). GEMINI={gemini_bin} exists={gemini_bin.exists()} "
            f"ISP={isp_bin} exists={isp_bin.exists()}"
        )

    require_tools("unsquashfs")

    print(f"[extract] output workdir: {workdir}")
    extract_gemini(workdir, gemini_bin, args.force)
    extract_isp(workdir, isp_bin, args.force)

    print("Extraction complete:")
    print(f"- {workdir / 'GEMINI_PACK'}")
    print(f"- {workdir / 'ISPBOOOT'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FirmwareError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
