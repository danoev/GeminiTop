#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path
from typing import List

from common import (
    CHUNK_2M,
    FirmwareError,
    build_script_uimage_from_clean,
    chunk_md5s,
    list_squashfs_paths,
    component_regions_from_metadata,
    decode_clean_script,
    encode_clean_script,
    md5_hex,
    mksquashfs,
    patch_ascii_md5,
    replace_region,
    replace_verify_md5s,
    require_tools,
    squashfs_bytes_used,
    split_chunk_sizes,
    write_json,
    read_json,
    DEFAULT_ISP_REGIONS,
)


def replace_md5_values_sequential(script_text: str, md5_values: List[str]) -> str:
    pat = re.compile(r'(if test "\$md5sum_value" = )([0-9a-f]{32})( ; then)')
    matches = list(pat.finditer(script_text))
    if len(matches) != len(md5_values):
        raise FirmwareError(
            f"Script has {len(matches)} md5 checks but {len(md5_values)} values were provided"
        )
    out = script_text
    for m, new in zip(matches, md5_values):
        out = out.replace(m.group(2), new, 1)
    return out


def should_exclude_common_junk(rel_path: Path) -> bool:
    name = rel_path.name
    low_name = name.lower()
    low_parts = [p.lower() for p in rel_path.parts]
    junk_dirs = {"__macosx", ".trashes", ".spotlight-v100", ".fseventsd", ".appledouble"}
    if name.startswith("._"):
        return True
    if name == ".DS_Store":
        return True
    if low_name in {"thumbs.db", "desktop.ini"}:
        return True
    if any(p in junk_dirs for p in low_parts):
        return True
    return False


def build_squashfs_components(package_dir: Path, component_regions: dict) -> dict:
    built = {}
    fs_root = package_dir / "filesystems"
    for pname in ("rootfs.", "spsdk.", "spapp."):
        reg = component_regions[pname]
        src_dir = fs_root / pname.rstrip(".")
        if not src_dir.exists():
            raise FirmwareError(f"Missing filesystem directory: {src_dir}")
        out_sqsh = package_dir / "_tmp" / f"{pname.rstrip('.')}.sqsh"
        out_sqsh.parent.mkdir(parents=True, exist_ok=True)
        original_sqsh = package_dir / "components" / f"{pname.rstrip('.')}.sqsh"
        original_paths = list_squashfs_paths(original_sqsh) if original_sqsh.exists() else set()

        proactive_exclude: List[Path] = []
        seen_exclude = set()
        for p in src_dir.rglob("*"):
            rel = p.relative_to(src_dir)
            rel_s = str(rel)
            if should_exclude_common_junk(rel) and rel_s not in original_paths and rel_s not in seen_exclude:
                proactive_exclude.append(rel)
                seen_exclude.add(rel_s)

        if proactive_exclude:
            print(
                f"[repack] {pname} proactively excluding {len(proactive_exclude)} common host junk file(s)/dir(s)"
            )

        print(f"[repack] mksquashfs {src_dir} -> {out_sqsh}")
        mksquashfs(src_dir, out_sqsh, exclude_paths=proactive_exclude)
        sqsh = out_sqsh.read_bytes()

        if len(sqsh) > reg.size:
            # Dynamic cleanup: ignore host-generated hidden files that were not in the original image.
            if original_sqsh.exists():
                exclude_hidden = []
                for p in src_dir.rglob("*"):
                    rel = str(p.relative_to(src_dir))
                    if not rel:
                        continue
                    if p.name.startswith(".") and rel not in original_paths and rel not in seen_exclude:
                        exclude_hidden.append(p)
                if exclude_hidden:
                    print(
                        f"[repack] {pname} overflow detected; rebuilding without {len(exclude_hidden)} "
                        f"new hidden file(s) not present in original image"
                    )
                    mksquashfs(src_dir, out_sqsh, exclude_paths=proactive_exclude + exclude_hidden)
                    sqsh = out_sqsh.read_bytes()

        if len(sqsh) > reg.size:
            used = squashfs_bytes_used(sqsh)
            raise FirmwareError(
                f"{pname} SquashFS too large: file=0x{len(sqsh):x}, bytes_used=0x{used:x}, "
                f"allocated=0x{reg.size:x}, overflow=0x{len(sqsh) - reg.size:x}"
            )
        print(f"[repack] {pname} squashfs size 0x{len(sqsh):x} / slot 0x{reg.size:x}")
        built[pname] = sqsh + (b"\x00" * (reg.size - len(sqsh)))
    return built


def patch_gemini(gemini_dir: Path, out_dir: Path) -> Path:
    print(f"[repack] GEMINI source folder: {gemini_dir}")
    meta = read_json(gemini_dir / "metadata.json")
    base_bin = gemini_dir / "_base" / "GEMINI_PACK.BIN"
    if not base_bin.exists():
        raise FirmwareError(f"Missing base binary: {base_bin}")

    bin_buf = bytearray(base_bin.read_bytes())
    header_size = int(meta["header_size"])
    payload_size = int(meta["payload_size"])

    regions = component_regions_from_metadata(meta)
    built = build_squashfs_components(gemini_dir, regions)

    # Patch filesystem regions.
    for pname in ("rootfs.", "spsdk.", "spapp."):
        reg = regions[pname]
        abs_reg = reg.__class__(reg.name, header_size + reg.offset, reg.size)
        replace_region(bin_buf, abs_reg, built[pname])
        print(f"[repack] patched GEMINI region {pname} at 0x{abs_reg.offset:x}")

    # Recompute md5 table entries (all components, including unchanged kernel/ecos/uboot2).
    component_region_bytes = {}
    for comp in meta["components"]:
        name = comp["name"]
        off = int(comp["offset"])
        size = int(comp["size"])
        blob = bytes(bin_buf[header_size + off : header_size + off + size])
        component_region_bytes[name] = blob
        patch_ascii_md5(bin_buf, int(comp["table_md5_offset"]), md5_hex(blob))
        print(f"[repack] GEMINI component md5 updated: {name}")

    # Patch main update script md5 constants.
    script_meta = meta["script"]
    script_clean_path = gemini_dir / "scripts" / "main_update_script.clean"
    if not script_clean_path.exists():
        raise FirmwareError(f"Missing script file: {script_clean_path}")

    script_text = decode_clean_script(script_clean_path.read_bytes())
    ordered_md5s: List[str] = []
    for pname in ("spapp.", "spsdk.", "rootfs.", "kernel", "uboot2", "ecos"):
        blob = component_region_bytes[pname]
        sizes = split_chunk_sizes(len(blob), CHUNK_2M)
        ordered_md5s.extend(chunk_md5s(blob, sizes))
    script_text = replace_md5_values_sequential(script_text, ordered_md5s)
    print(f"[repack] GEMINI main script md5 constants refreshed ({len(ordered_md5s)} checks)")

    rebuilt_clean = encode_clean_script(script_text)
    rebuilt_uimage = build_script_uimage_from_clean(rebuilt_clean, script_meta["uimage"] | {"name": script_meta["uimage_name"]})

    script_offset = int(script_meta["offset"])
    script_size = int(script_meta["size"])
    if len(rebuilt_uimage) > script_size:
        raise FirmwareError(
            f"Rebuilt GEMINI script too large: 0x{len(rebuilt_uimage):x} > slot 0x{script_size:x}"
        )
    script_padded = rebuilt_uimage + (b"\x00" * (script_size - len(rebuilt_uimage)))
    bin_buf[header_size + script_offset : header_size + script_offset + script_size] = script_padded
    print(f"[repack] GEMINI script patched at 0x{header_size + script_offset:x}")

    # Update payload MD5.
    payload_blob = bytes(bin_buf[header_size : header_size + payload_size])
    payload_md5 = md5_hex(payload_blob)
    patch_ascii_md5(bin_buf, int(meta["payload_md5_offset"]), payload_md5)
    print("[repack] GEMINI payload md5 updated")

    out_path = out_dir / "MODIFIED_GEMINI_PACK.BIN"
    out_path.write_bytes(bytes(bin_buf))

    write_json(
        out_dir / "repack_gemini_report.json",
        {
            "output": out_path.name,
            "payload_md5": payload_md5,
            "component_md5": {k: md5_hex(v) for k, v in component_region_bytes.items()},
        },
    )

    return out_path


def patch_isp(isp_dir: Path, out_dir: Path) -> Path:
    print(f"[repack] ISP source folder: {isp_dir}")
    meta = read_json(isp_dir / "metadata.json")
    base_bin = isp_dir / "_base" / "ISPBOOOT.BIN"
    if not base_bin.exists():
        raise FirmwareError(f"Missing base binary: {base_bin}")

    bin_buf = bytearray(base_bin.read_bytes())

    # Use metadata regions if present; fallback to known map.
    regions = {c["name"]: c for c in meta.get("components", [])}
    if not regions:
        regions = {k: {"name": k, "offset": v.offset, "size": v.size} for k, v in DEFAULT_ISP_REGIONS.items()}

    reg_objs = {
        name: DEFAULT_ISP_REGIONS.get(name)
        or DEFAULT_ISP_REGIONS["rootfs."].__class__(name, int(c["offset"]), int(c["size"]))
        for name, c in regions.items()
    }

    built = build_squashfs_components(isp_dir, reg_objs)
    for pname in ("rootfs.", "spsdk.", "spapp."):
        replace_region(bin_buf, reg_objs[pname], built[pname])
        print(f"[repack] patched ISP region {pname} at 0x{reg_objs[pname].offset:x}")

    # Patch script md5 constants for changed linux partitions.
    for script_key in ("isp_script_nand", "isp_script_emmc"):
        sm = meta["scripts"][script_key]
        clean_path = isp_dir / "scripts" / f"{script_key}.clean"
        if not clean_path.exists():
            raise FirmwareError(f"Missing script file: {clean_path}")

        script_text = decode_clean_script(clean_path.read_bytes())
        for pname in ("rootfs.", "spsdk.", "spapp."):
            blob = bytes(bin_buf[reg_objs[pname].offset : reg_objs[pname].offset + reg_objs[pname].size])
            sizes = split_chunk_sizes(len(blob), CHUNK_2M)
            md5s = chunk_md5s(blob, sizes)
            script_text = replace_verify_md5s(script_text, pname, md5s)
            print(f"[repack] {script_key} md5 checks updated for {pname} ({len(md5s)} checks)")

        rebuilt_clean = encode_clean_script(script_text)
        rebuilt_uimage = build_script_uimage_from_clean(rebuilt_clean, sm["uimage"] | {"name": sm["uimage_name"]})
        slot_offset = int(sm["offset"])
        slot_size = int(sm["size"])
        if len(rebuilt_uimage) > slot_size:
            raise FirmwareError(
                f"{script_key} rebuilt uImage too large: 0x{len(rebuilt_uimage):x} > slot 0x{slot_size:x}"
            )
        padded = rebuilt_uimage + (b"\x00" * (slot_size - len(rebuilt_uimage)))
        bin_buf[slot_offset : slot_offset + slot_size] = padded
        print(f"[repack] patched {script_key} at 0x{slot_offset:x}")

    out_path = out_dir / "MODIFIED_ISPBOOOT.BIN"
    out_path.write_bytes(bytes(bin_buf))

    write_json(
        out_dir / "repack_isp_report.json",
        {
            "output": out_path.name,
            "regions_md5": {
                k: md5_hex(bytes(bin_buf[v.offset : v.offset + v.size]))
                for k, v in reg_objs.items()
                if k in ("rootfs.", "spsdk.", "spapp.")
            },
        },
    )

    return out_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Repack modified firmware folders into BIN files")
    parser.add_argument("--workdir", default=".", help="Folder containing GEMINI_PACK and ISPBOOOT")
    parser.add_argument("--gemini-dir", default=None, help="Path to GEMINI_PACK folder (optional)")
    parser.add_argument("--isp-dir", default=None, help="Path to ISPBOOOT folder (optional)")
    parser.add_argument("--output", default="REPACKED", help="Output folder name/path for modified BINs")
    parser.add_argument("--clean-output", action="store_true", help="Remove output folder before writing")
    args = parser.parse_args()

    workdir = Path(args.workdir).resolve()
    gemini_dir = Path(args.gemini_dir).resolve() if args.gemini_dir else workdir / "GEMINI_PACK"
    isp_dir = Path(args.isp_dir).resolve() if args.isp_dir else workdir / "ISPBOOOT"

    if not gemini_dir.exists() or not isp_dir.exists():
        raise FirmwareError(
            f"Expected extracted folders. GEMINI={gemini_dir} exists={gemini_dir.exists()} "
            f"ISP={isp_dir} exists={isp_dir.exists()}. Run extract_firmware.py first."
        )

    out_dir = workdir / args.output
    if out_dir.exists() and args.clean_output:
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    require_tools("mksquashfs")

    print(f"[repack] output folder: {out_dir}")
    gem_out = patch_gemini(gemini_dir, out_dir)
    isp_out = patch_isp(isp_dir, out_dir)

    print("Repack complete:")
    print(f"- {gem_out}")
    print(f"- {isp_out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FirmwareError as exc:
        print(f"ERROR: {exc}")
        raise SystemExit(1)
