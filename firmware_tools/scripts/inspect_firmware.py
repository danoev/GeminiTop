#!/usr/bin/env python3
"""Read-only, target-neutral firmware archive inspection.

The inspector never executes image content and never writes extracted firmware
into the repository.  ZIP members are streamed to a temporary file solely to
permit bounded random-access inspection; the temporary file is deleted on exit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import os
import re
import signal
import shutil
import struct
import subprocess
import tempfile
import threading
import zipfile
import zlib
from pathlib import Path
from typing import BinaryIO, Dict, Iterable, Iterator, List, Optional, Tuple


UIMAGE_MAGIC = b"\x27\x05\x19\x56"
SQUASHFS_MAGIC = b"hsqs"
ELF_MAGIC = b"\x7fELF"
MAX_MEMBER_BYTES = 1024 * 1024 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_COMPRESSION_RATIO = 1000
MAX_MAGIC_HITS = 4096
SQUASHFS_INVALID_TABLE = (1 << 64) - 1
SQUASHFS_COMPRESSION_IDS = frozenset(range(1, 7))
UNSQUASHFS_LIST_TIMEOUT_SECONDS = 30
UNSQUASHFS_CAT_TIMEOUT_SECONDS = 10
UNSQUASHFS_LIST_STDOUT_LIMIT = 8 * 1024 * 1024
UNSQUASHFS_STDERR_LIMIT = 64 * 1024
MAX_ELF_BYTES = 64 * 1024 * 1024


class InspectionError(RuntimeError):
    """Raised for malformed or unsafe-to-process input."""


def _hash_stream(stream: BinaryIO) -> Tuple[str, str, int]:
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    size = 0
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        size += len(chunk)
        md5.update(chunk)
        sha256.update(chunk)
    return md5.hexdigest(), sha256.hexdigest(), size


def hash_file(path: Path) -> Dict[str, object]:
    with path.open("rb") as stream:
        md5, sha256, size = _hash_stream(stream)
    return {"size": size, "md5": md5, "sha256": sha256}


def _safe_zip_members(archive: zipfile.ZipFile) -> List[zipfile.ZipInfo]:
    selected: List[zipfile.ZipInfo] = []
    total = 0
    for info in archive.infolist():
        normalized = info.filename.replace("\\", "/")
        parts = [part for part in normalized.split("/") if part]
        if normalized.startswith("/") or ".." in parts:
            raise InspectionError(f"unsafe ZIP member path: {info.filename!r}")
        if info.is_dir():
            continue
        if info.file_size > MAX_MEMBER_BYTES:
            raise InspectionError(f"ZIP member exceeds {MAX_MEMBER_BYTES} bytes: {info.filename}")
        total += info.file_size
        if total > MAX_ARCHIVE_BYTES:
            raise InspectionError("ZIP uncompressed size exceeds safety limit")
        ratio = info.file_size / max(info.compress_size, 1)
        if ratio > MAX_COMPRESSION_RATIO:
            raise InspectionError(f"suspicious ZIP compression ratio for {info.filename}")
        selected.append(info)
    return selected


def _find_all(blob: mmap.mmap, needle: bytes) -> Iterator[int]:
    start = 0
    count = 0
    while count < MAX_MAGIC_HITS:
        offset = blob.find(needle, start)
        if offset < 0:
            return
        yield offset
        count += 1
        start = offset + 1


def _parse_uimage(blob: mmap.mmap, offset: int) -> Dict[str, object]:
    remaining = len(blob) - offset
    result: Dict[str, object] = {"offset": offset, "valid": False}
    if remaining < 64:
        result["error"] = "truncated header"
        return result
    header = blob[offset : offset + 64]
    fields = struct.unpack(">7I4B32s", header)
    magic, hcrc, timestamp, size, load, entry, dcrc, os_id, arch, kind, comp, raw_name = fields
    name = raw_name.split(b"\0", 1)[0].decode("ascii", "replace")
    result.update(
        {
            "name": name,
            "data_size": size,
            "total_size": size + 64,
            "timestamp": timestamp,
            "load_address": load,
            "entry_address": entry,
            "os": os_id,
            "architecture": arch,
            "image_type": kind,
            "compression": comp,
        }
    )
    if magic != int.from_bytes(UIMAGE_MAGIC, "big"):
        result["error"] = "invalid magic"
        return result
    if size > remaining - 64:
        result["error"] = "declared data exceeds member bounds"
        return result
    check_header = bytearray(header)
    check_header[4:8] = b"\0\0\0\0"
    header_crc_ok = (zlib.crc32(check_header) & 0xFFFFFFFF) == hcrc
    result["header_crc_ok"] = header_crc_ok
    if not header_crc_ok:
        result["data_crc_ok"] = None
        result["error"] = "header CRC validation failed"
        return result
    data_crc_ok = (zlib.crc32(blob[offset + 64 : offset + 64 + size]) & 0xFFFFFFFF) == dcrc
    result["data_crc_ok"] = data_crc_ok
    result["valid"] = data_crc_ok
    if not result["valid"]:
        result["error"] = "CRC validation failed"
    return result


def _parse_squashfs(blob: mmap.mmap, offset: int) -> Dict[str, object]:
    result: Dict[str, object] = {"offset": offset, "valid": False}
    if len(blob) - offset < 96:
        result["error"] = "truncated superblock"
        return result
    fields = struct.unpack("<5I6H8Q", blob[offset : offset + 96])
    (
        magic,
        inode_count,
        mkfs_time,
        block_size,
        fragments,
        compression,
        block_log,
        flags,
        id_count,
        major,
        minor,
        root_inode,
        bytes_used,
        id_table,
        xattr_table,
        inode_table,
        directory_table,
        fragment_table,
        lookup_table,
    ) = fields
    remaining = len(blob) - offset
    block_ok = (
        4096 <= block_size <= 1024 * 1024
        and block_size & (block_size - 1) == 0
        and block_log == block_size.bit_length() - 1
    )
    bounds_ok = 96 <= bytes_used <= remaining
    version_ok = major == 4 and minor == 0
    counts_ok = inode_count > 0 and id_count > 0 and fragments <= inode_count
    compression_ok = compression in SQUASHFS_COMPRESSION_IDS

    def required_table_ok(value: int) -> bool:
        return 96 <= value < bytes_used

    def optional_table_ok(value: int) -> bool:
        return value == SQUASHFS_INVALID_TABLE or required_table_ok(value)

    tables_ok = False
    root_inode_ok = False
    if bounds_ok:
        required_tables = (inode_table, directory_table, id_table)
        tables_ok = all(required_table_ok(value) for value in required_tables)
        tables_ok = tables_ok and inode_table <= directory_table <= id_table
        if fragments:
            tables_ok = tables_ok and required_table_ok(fragment_table)
            tables_ok = tables_ok and directory_table <= fragment_table <= id_table
        else:
            tables_ok = tables_ok and optional_table_ok(fragment_table)
        tables_ok = tables_ok and optional_table_ok(xattr_table) and optional_table_ok(lookup_table)
        root_inode_block = root_inode >> 16
        root_inode_ok = root_inode_block < bytes_used - inode_table
    result.update(
        {
            "inode_count": inode_count,
            "mkfs_time": mkfs_time,
            "block_size": block_size,
            "block_log": block_log,
            "fragments": fragments,
            "compression_id": compression,
            "flags": flags,
            "id_count": id_count,
            "version": f"{major}.{minor}",
            "bytes_used": bytes_used,
            "bounds_ok": bounds_ok,
            "compression_ok": compression_ok,
            "counts_ok": counts_ok,
            "tables_ok": tables_ok,
            "root_inode_ok": root_inode_ok,
        }
    )
    result["valid"] = (
        block_ok
        and bounds_ok
        and version_ok
        and counts_ok
        and compression_ok
        and tables_ok
        and root_inode_ok
    )
    if not result["valid"]:
        result["error"] = "invalid SquashFS version, geometry, compression, counts, tables, or bounds"
    return result


_COMPONENT_NAME = re.compile(rb"^[A-Za-z0-9_.-]{1,31}$")
_ASCII_MD5 = re.compile(rb"^[0-9a-fA-F]{32}$")


def _component_record(blob: mmap.mmap, table_offset: int, payload_base: int) -> Optional[Dict[str, object]]:
    if table_offset < 0 or table_offset + 0x50 > len(blob):
        return None
    raw_name = blob[table_offset : table_offset + 0x20].split(b"\0", 1)[0]
    raw_md5 = blob[table_offset + 0x20 : table_offset + 0x40]
    if not _COMPONENT_NAME.fullmatch(raw_name) or not _ASCII_MD5.fullmatch(raw_md5):
        return None
    _unused, rel_offset, size, _unused2 = struct.unpack(
        "<IIII", blob[table_offset + 0x40 : table_offset + 0x50]
    )
    absolute = payload_base + rel_offset
    if size <= 0 or absolute < payload_base or absolute + size > len(blob):
        return None
    component = blob[absolute : absolute + size]
    calculated_md5 = hashlib.md5(component).hexdigest()
    table_md5 = raw_md5.decode("ascii").lower()
    return {
        "name": raw_name.decode("ascii"),
        "table_offset": table_offset,
        "relative_offset": rel_offset,
        "absolute_offset": absolute,
        "size": size,
        "table_md5": table_md5,
        "calculated_md5": calculated_md5,
        "md5_ok": calculated_md5 == table_md5,
    }


def _discover_component_tables(blob: mmap.mmap, payload_bases: Iterable[int]) -> List[Dict[str, object]]:
    candidates: List[Dict[str, object]] = []
    # Records in known Gemini containers are 0x80-byte aligned. The table
    # location itself is discovered; no product-specific table offset is used.
    for table_offset in range(0, min(len(blob), 1024 * 1024), 0x10):
        for payload_base in payload_bases:
            first = _component_record(blob, table_offset, payload_base)
            if first is None:
                continue
            records = [first]
            next_offset = table_offset + 0x80
            while len(records) < 64:
                record = _component_record(blob, next_offset, payload_base)
                if record is None:
                    break
                records.append(record)
                next_offset += 0x80
            if len(records) >= 2:
                key = (table_offset, payload_base)
                if not any((item["table_offset"], item["payload_base"]) == key for item in candidates):
                    candidates.append(
                        {
                            "table_offset": table_offset,
                            "payload_base": payload_base,
                            "record_size": 0x80,
                            "components": records,
                        }
                    )
    # Scanning can rediscover suffixes of the same contiguous table. Keep the
    # maximal table and discard candidates whose record offsets are a subset.
    maximal: List[Dict[str, object]] = []
    for candidate in sorted(candidates, key=lambda item: len(item["components"]), reverse=True):
        offsets = {component["table_offset"] for component in candidate["components"]}
        if any(
            candidate["payload_base"] == kept["payload_base"]
            and offsets.issubset({component["table_offset"] for component in kept["components"]})
            for kept in maximal
        ):
            continue
        maximal.append(candidate)
    for table in maximal:
        table["valid"] = all(component["md5_ok"] for component in table["components"])
        if not table["valid"]:
            table["error"] = "one or more component MD5 values do not match"
    return sorted(maximal, key=lambda item: (item["payload_base"], item["table_offset"]))


def _container_metadata(blob: mmap.mmap) -> Optional[Dict[str, object]]:
    if len(blob) < 0x100 or blob[:6] != b"GEMINI":
        return None
    result: Dict[str, object] = {"format": "GEMINI", "magic": "GEMINI"}
    result["variant"] = blob[0x40:0x60].split(b"\0", 1)[0].decode("ascii", "replace")
    result["version"] = blob[0x80:0xA0].split(b"\0", 1)[0].decode("ascii", "replace")
    result["payload_name"] = blob[0xC0:0xE0].split(b"\0", 1)[0].decode("ascii", "replace")
    if len(blob) >= 0xE0:
        payload_size = struct.unpack_from("<I", blob, 0xD8)[0]
        header_size = struct.unpack_from("<I", blob, 0xDC)[0]
        valid = header_size >= 64 and header_size <= len(blob) and payload_size <= len(blob) - header_size
        result["declared_header_size"] = header_size
        result["declared_payload_size"] = payload_size
        result["declared_bounds_ok"] = valid
        if valid:
            result["payload_sha256"] = hashlib.sha256(blob[header_size : header_size + payload_size]).hexdigest()
            tables = _discover_component_tables(blob, [header_size])
            result["component_tables"] = [table for table in tables if table["valid"]]
            result["rejected_component_tables"] = [table for table in tables if not table["valid"]]
    return result


def _hardware_clues(blob: mmap.mmap) -> List[str]:
    clues = []
    needles = (
        b"GEMINI",
        b"8368-XU",
        b"fts_ts",
        b"FocalTech",
        b"appinfo.rc",
        b"HcCar",
        b"DayNightMode",
        b"as_spaudiotrack",
        b"apple_carplay_server",
    )
    for needle in needles:
        if blob.find(needle) >= 0:
            clues.append(needle.decode("ascii"))
    return clues


def _partition_signature(container: Optional[Dict[str, object]], filesystems: List[Dict[str, object]]) -> str:
    layout: object
    tables = container.get("component_tables", []) if container else []
    if tables:
        layout = [
            {"name": c["name"], "offset": c["relative_offset"], "size": c["size"]}
            for c in tables[0]["components"]
        ]
    else:
        layout = [{"offset": fs["offset"], "bytes_used": fs.get("bytes_used")} for fs in filesystems]
    encoded = json.dumps(layout, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _run_limited(
    command: List[str], timeout_seconds: int, stdout_limit: int, stderr_limit: int
) -> Dict[str, object]:
    """Run a metadata reader with bounded time and captured output."""
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True
    )
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": stdout_limit, "stderr": stderr_limit}
    overflow: List[str] = []

    def kill_process_group() -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            try:
                process.kill()
            except OSError:
                pass

    def read_pipe(name: str, pipe: BinaryIO) -> None:
        while True:
            chunk = pipe.read(64 * 1024)
            if not chunk:
                return
            remaining = limits[name] - len(buffers[name])
            if remaining > 0:
                buffers[name].extend(chunk[:remaining])
            if len(chunk) > remaining:
                overflow.append(name)
                kill_process_group()
                return

    threads = [
        threading.Thread(target=read_pipe, args=("stdout", process.stdout), daemon=True),
        threading.Thread(target=read_pipe, args=("stderr", process.stderr), daemon=True),
    ]
    for thread in threads:
        thread.start()
    timed_out = False
    try:
        returncode = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_process_group()
        returncode = process.wait()
    for thread in threads:
        thread.join(timeout=1)
    if any(thread.is_alive() for thread in threads):
        overflow.append("pipe lifetime")
        kill_process_group()
        for thread in threads:
            thread.join(timeout=1)
    if process.stdout:
        process.stdout.close()
    if process.stderr:
        process.stderr.close()
    failure = None
    if timed_out:
        failure = f"timed out after {timeout_seconds} seconds"
    elif overflow:
        failure = f"output limit exceeded for {', '.join(sorted(set(overflow)))}"
    return {
        "returncode": returncode,
        "stdout": bytes(buffers["stdout"]),
        "stderr": bytes(buffers["stderr"]),
        "failure": failure,
    }


def _inventory_squashfs(path: Path, offset: int) -> Dict[str, object]:
    tool = shutil.which("unsquashfs")
    if not tool:
        return {
            "status": "UNAVAILABLE",
            "reason": "unsquashfs is not installed; superblock metadata remains available",
            "entries": [],
            "elf_entries": [],
        }
    listed = _run_limited(
        [tool, "-lln", "-o", str(offset), str(path)],
        UNSQUASHFS_LIST_TIMEOUT_SECONDS,
        UNSQUASHFS_LIST_STDOUT_LIMIT,
        UNSQUASHFS_STDERR_LIMIT,
    )
    if listed["failure"]:
        return {
            "status": "UNAVAILABLE",
            "reason": f"unsquashfs listing {listed['failure']}",
            "entries": [],
            "elf_entries": [],
        }
    if listed["returncode"] != 0:
        return {
            "status": "UNAVAILABLE",
            "reason": f"unsquashfs listing failed with exit code {listed['returncode']}",
            "entries": [],
            "elf_entries": [],
        }
    entries: List[Dict[str, object]] = []
    elf_entries: List[Dict[str, object]] = []
    skipped_elf_checks: List[Dict[str, str]] = []
    for raw_line in listed["stdout"].splitlines():
        line = raw_line.decode("utf-8", "replace")
        parts = line.split(None, 5)
        if len(parts) != 6 or not parts[0] or parts[0][0] not in "-dlbcps":
            continue
        mode, owner, raw_size, modified_date, modified_time, raw_path = parts
        prefix = "squashfs-root"
        if raw_path == prefix:
            relative = "."
        elif raw_path.startswith(prefix + "/"):
            relative = raw_path[len(prefix) + 1 :]
        else:
            continue
        try:
            size = int(raw_size)
        except ValueError:
            size = None
        entry = {
            "path": relative,
            "type": mode[0],
            "mode": mode,
            "owner": owner,
            "size": size,
            "modified": f"{modified_date} {modified_time}",
        }
        entries.append(entry)
        if mode[0] != "-" or size is None or size > MAX_ELF_BYTES:
            continue
        content = _run_limited(
            [tool, "-cat", "-o", str(offset), str(path), relative],
            UNSQUASHFS_CAT_TIMEOUT_SECONDS,
            size + 1,
            UNSQUASHFS_STDERR_LIMIT,
        )
        if content["failure"]:
            skipped_elf_checks.append({"path": relative, "reason": str(content["failure"])})
            continue
        if content["returncode"] != 0:
            skipped_elf_checks.append(
                {"path": relative, "reason": f"unsquashfs cat exited {content['returncode']}"}
            )
            continue
        content_bytes = content["stdout"]
        if len(content_bytes) != size:
            skipped_elf_checks.append({"path": relative, "reason": "listed size did not match streamed size"})
            continue
        if content_bytes.startswith(ELF_MAGIC):
            elf_entries.append(
                {
                    "path": relative,
                    "size": len(content_bytes),
                    "sha256": hashlib.sha256(content_bytes).hexdigest(),
                }
            )
    return {
        "status": "PARTIAL" if skipped_elf_checks else "COMPLETE",
        "reason": "one or more regular files could not be boundedly inspected" if skipped_elf_checks else None,
        "entries": entries,
        "elf_entries": elf_entries,
        "skipped_elf_checks": skipped_elf_checks,
    }


def inspect_binary(path: Path, logical_name: str) -> Dict[str, object]:
    if path.stat().st_size == 0:
        return {
            "name": logical_name,
            **hash_file(path),
            "container": None,
            "embedded_images": [],
            "rejected_uimage_candidates": [],
            "filesystems": [],
            "rejected_squashfs_candidates": [],
            "partition_signature": _partition_signature(None, []),
            "hardware_clues": [],
            "elf_inventory": {"status": "COMPLETE", "reason": None, "entries": []},
        }
    with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as blob:
        uimages = [_parse_uimage(blob, offset) for offset in _find_all(blob, UIMAGE_MAGIC)]
        filesystems = [_parse_squashfs(blob, offset) for offset in _find_all(blob, SQUASHFS_MAGIC)]
        container = _container_metadata(blob)
        valid_filesystems = [entry for entry in filesystems if entry["valid"]]
        elf_entries: List[Dict[str, object]] = []
        inventory_statuses: List[str] = []
        for filesystem in valid_filesystems:
            inventory = _inventory_squashfs(path, int(filesystem["offset"]))
            inventory_statuses.append(str(inventory["status"]))
            filesystem["inventory"] = {
                "status": inventory["status"],
                "reason": inventory.get("reason"),
                "entries": inventory["entries"],
                "skipped_elf_checks": inventory.get("skipped_elf_checks", []),
            }
            for elf in inventory["elf_entries"]:
                elf_entries.append({"filesystem_offset": filesystem["offset"], **elf})
        if all(status == "COMPLETE" for status in inventory_statuses):
            elf_status = "COMPLETE"
            elf_reason = None
        elif inventory_statuses and all(status == "UNAVAILABLE" for status in inventory_statuses):
            elf_status = "UNAVAILABLE"
            elf_reason = "the SquashFS inventory backend was unavailable for every filesystem"
        else:
            elf_status = "PARTIAL"
            elf_reason = "one or more filesystem ELF inventories were unavailable or partial"
        return {
            "name": logical_name,
            **hash_file(path),
            "container": container,
            "embedded_images": [entry for entry in uimages if entry["valid"]],
            "rejected_uimage_candidates": [entry for entry in uimages if not entry["valid"]],
            "filesystems": valid_filesystems,
            "rejected_squashfs_candidates": [entry for entry in filesystems if not entry["valid"]],
            "partition_signature": _partition_signature(
                container, valid_filesystems
            ),
            "hardware_clues": _hardware_clues(blob),
            "elf_inventory": {
                "status": elf_status,
                "reason": elf_reason,
                "entries": elf_entries,
            },
        }


def _copy_member_to_temp(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> Path:
    handle = tempfile.NamedTemporaryFile(prefix="geminitop-fw-", suffix=".bin", delete=False)
    temp_path = Path(handle.name)
    try:
        with handle, archive.open(info, "r") as source:
            copied = 0
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                copied += len(chunk)
                if copied > info.file_size or copied > MAX_MEMBER_BYTES:
                    raise InspectionError(f"ZIP member expanded beyond declared bounds: {info.filename}")
                handle.write(chunk)
        if copied != info.file_size:
            raise InspectionError(f"ZIP member size mismatch: {info.filename}")
        return temp_path
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def inspect_input(path: Path) -> Dict[str, object]:
    if not path.is_file():
        raise InspectionError(f"input is not a regular file: {path}")
    archive_meta = hash_file(path)
    report: Dict[str, object] = {
        "schema_version": 1,
        "mode": "read-only-metadata",
        "source": {"name": path.name, **archive_meta},
        "members": [],
        "warnings": [],
    }
    if zipfile.is_zipfile(path):
        report["source"]["type"] = "zip"
        with zipfile.ZipFile(path, "r") as archive:
            members = _safe_zip_members(archive)
            for info in members:
                member_meta: Dict[str, object] = {
                    "name": info.filename,
                    "size": info.file_size,
                    "compressed_size": info.compress_size,
                    "crc32": f"{info.CRC:08x}",
                }
                with archive.open(info, "r") as member_stream:
                    md5, sha256, actual_size = _hash_stream(member_stream)
                if actual_size != info.file_size:
                    raise InspectionError(f"ZIP member size mismatch: {info.filename}")
                member_meta.update({"md5": md5, "sha256": sha256})
                if info.filename.lower().endswith(".bin"):
                    temp_path = _copy_member_to_temp(archive, info)
                    try:
                        member_meta["inspection"] = inspect_binary(temp_path, info.filename)
                    finally:
                        temp_path.unlink(missing_ok=True)
                report["members"].append(member_meta)
    else:
        report["source"]["type"] = "binary"
        report["members"].append({"name": path.name, "inspection": inspect_binary(path, path.name)})
    return report


def validate_output_path(input_path: Path, output_path: Path) -> None:
    """Refuse any output pathname that resolves to the input inode."""
    resolved_input = input_path.resolve(strict=True)
    resolved_output = output_path.resolve(strict=False)
    if resolved_output == resolved_input:
        raise InspectionError("output path aliases the input")
    if output_path.exists() or output_path.is_symlink():
        try:
            if os.path.samefile(resolved_input, output_path):
                raise InspectionError("output path aliases the input inode")
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Safely inspect firmware archives without extraction or execution")
    parser.add_argument("input", type=Path, help="ZIP archive or BIN image")
    parser.add_argument("--output", type=Path, help="Write commit-safe JSON metadata here")
    args = parser.parse_args()
    input_path = args.input.resolve()
    if args.output:
        validate_output_path(input_path, args.output)
    report = inspect_input(input_path)
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
    except (InspectionError, zipfile.BadZipFile, OSError) as exc:
        print(f"ERROR: {exc}", file=os.sys.stderr)
        raise SystemExit(2)
