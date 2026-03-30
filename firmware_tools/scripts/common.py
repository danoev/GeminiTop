#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import re
import struct
import subprocess
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

UIMAGE_MAGIC = 0x27051956
SQUASHFS_MAGIC = b"hsqs"
CHUNK_2M = 0x200000


class FirmwareError(RuntimeError):
    pass


@dataclass(frozen=True)
class Region:
    name: str
    offset: int
    size: int


@dataclass(frozen=True)
class GeminiHeader:
    header_size: int
    payload_size: int
    payload_md5_offset: int
    component_table_offset: int
    component_record_size: int
    component_count: int


DEFAULT_GEMINI_HEADER = GeminiHeader(
    header_size=0x400,
    payload_size=0x4523800,
    payload_md5_offset=0xEA,
    component_table_offset=0xC80,
    component_record_size=0x80,
    component_count=6,
)


DEFAULT_ISP_REGIONS = {
    "rootfs.": Region("rootfs.", 0x937800, 0x3B4000),
    "spsdk.": Region("spsdk.", 0xCEB800, 0x2844000),
    "spapp.": Region("spapp.", 0x352F800, 0x1159000),
}


DEFAULT_ISP_SCRIPT_SLOTS = {
    "isp_script_nand": Region("isp_script_nand", 0x5545C00, 0xB000),
    "isp_script_emmc": Region("isp_script_emmc", 0x5550C00, 0x8400),
}


def require_tools(*tool_names: str) -> None:
    for tool in tool_names:
        if not shutil_which(tool):
            raise FirmwareError(f"Missing required tool: {tool}")


def shutil_which(name: str) -> str | None:
    return subprocess.run(
        ["bash", "-lc", f"command -v {name}"],
        check=False,
        capture_output=True,
        text=True,
    ).stdout.strip() or None


def md5_hex(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def md5_file(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_uimage(blob: bytes) -> Tuple[dict, bytes]:
    if len(blob) < 64:
        raise FirmwareError("uImage blob too small")
    header = blob[:64]
    (
        magic,
        hcrc,
        timestamp,
        data_size,
        load_addr,
        entry_addr,
        dcrc,
        os_id,
        arch_id,
        image_type,
        comp,
    ) = struct.unpack(">7I4B", header[:32])
    name = header[32:64].split(b"\x00", 1)[0].decode("ascii", errors="ignore")

    if magic != UIMAGE_MAGIC:
        raise FirmwareError(f"Invalid uImage magic: 0x{magic:08x}")

    header_zero_crc = bytearray(header)
    header_zero_crc[4:8] = b"\x00\x00\x00\x00"
    calc_hcrc = zlib.crc32(header_zero_crc) & 0xFFFFFFFF
    if calc_hcrc != hcrc:
        raise FirmwareError(
            f"uImage header CRC mismatch for '{name}': have {hcrc:08x}, calc {calc_hcrc:08x}"
        )

    data = blob[64 : 64 + data_size]
    if len(data) != data_size:
        raise FirmwareError("uImage data truncated")

    calc_dcrc = zlib.crc32(data) & 0xFFFFFFFF
    if calc_dcrc != dcrc:
        raise FirmwareError(
            f"uImage data CRC mismatch for '{name}': have {dcrc:08x}, calc {calc_dcrc:08x}"
        )

    info = {
        "magic": magic,
        "hcrc": hcrc,
        "timestamp": timestamp,
        "size": data_size,
        "load_addr": load_addr,
        "entry_addr": entry_addr,
        "dcrc": dcrc,
        "os": os_id,
        "arch": arch_id,
        "type": image_type,
        "comp": comp,
        "name": name,
    }
    return info, data


def build_uimage(name: str, data: bytes, template: dict | None = None) -> bytes:
    # Reuse original metadata defaults for script image compatibility.
    timestamp = int(template.get("timestamp", 0)) if template else 0
    load_addr = int(template.get("load_addr", 0)) if template else 0
    entry_addr = int(template.get("entry_addr", 0)) if template else 0
    os_id = int(template.get("os", 5)) if template else 5
    arch_id = int(template.get("arch", 2)) if template else 2
    image_type = int(template.get("type", 6)) if template else 6
    comp = int(template.get("comp", 0)) if template else 0

    dcrc = zlib.crc32(data) & 0xFFFFFFFF
    name_bytes = name.encode("ascii", errors="ignore")[:32].ljust(32, b"\x00")

    header_wo_hcrc = struct.pack(
        ">7I4B32s",
        UIMAGE_MAGIC,
        0,
        timestamp,
        len(data),
        load_addr,
        entry_addr,
        dcrc,
        os_id,
        arch_id,
        image_type,
        comp,
        name_bytes,
    )
    hcrc = zlib.crc32(header_wo_hcrc) & 0xFFFFFFFF
    header = bytearray(header_wo_hcrc)
    struct.pack_into(">I", header, 4, hcrc)
    return bytes(header) + data


def decode_clean_script(clean_bytes: bytes) -> str:
    if len(clean_bytes) < 2:
        raise FirmwareError("Script clean file too short")
    declared = struct.unpack(">H", clean_bytes[:2])[0]
    body = clean_bytes[2:]
    if declared != len(body):
        # Accept plain-text script if user edited manually.
        try:
            return clean_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise FirmwareError("Unable to decode clean script") from exc
    return body.decode("utf-8", errors="replace")


def encode_clean_script(script_text: str) -> bytes:
    data = script_text.encode("utf-8")
    if len(data) > 0xFFFF:
        raise FirmwareError("Script text exceeds 16-bit clean prefix length")
    return struct.pack(">H", len(data)) + data


def build_script_uimage_from_clean(clean_bytes: bytes, template: dict) -> bytes:
    text = decode_clean_script(clean_bytes)
    text_bytes = text.encode("utf-8")
    data = struct.pack(">I", len(text_bytes)) + b"\x00\x00\x00\x00" + text_bytes
    return build_uimage(template["name"], data, template=template)


def extract_clean_script_from_uimage(uimage_blob: bytes) -> bytes:
    info, data = read_uimage(uimage_blob)
    del info
    if len(data) < 8:
        raise FirmwareError("Script uImage data too short")
    text_len = struct.unpack(">I", data[:4])[0]
    if len(data) < 8 + text_len:
        raise FirmwareError("Script uImage text length invalid")
    text = data[8 : 8 + text_len]
    if text_len > 0xFFFF:
        raise FirmwareError("Script text too long for clean format")
    return struct.pack(">H", len(text)) + text


def parse_gemini_components(bin_data: bytes, hdr: GeminiHeader) -> List[dict]:
    components = []
    base = hdr.component_table_offset
    for i in range(hdr.component_count):
        off = base + i * hdr.component_record_size
        rec = bin_data[off : off + hdr.component_record_size]
        if len(rec) < hdr.component_record_size:
            raise FirmwareError("GEMINI component table truncated")

        name = rec[0:0x20].split(b"\x00", 1)[0].decode("ascii", errors="ignore")
        md5_s = rec[0x20:0x40].decode("ascii", errors="ignore").strip("\x00")
        _, comp_off, comp_size, _ = struct.unpack("<IIII", rec[0x40:0x50])
        if not name:
            continue
        components.append(
            {
                "index": i,
                "name": name,
                "table_offset": off,
                "md5_offset": off + 0x20,
                "offset": comp_off,
                "size": comp_size,
                "md5": md5_s,
            }
        )
    return components


def patch_ascii_md5(buf: bytearray, offset: int, md5_value: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{32}", md5_value):
        raise FirmwareError(f"Invalid MD5 string: {md5_value}")
    buf[offset : offset + 32] = md5_value.encode("ascii")


def split_chunk_sizes(total: int, chunk_size: int = CHUNK_2M) -> List[int]:
    sizes = []
    remain = total
    while remain > 0:
        take = min(chunk_size, remain)
        sizes.append(take)
        remain -= take
    return sizes


def chunk_md5s(region_bytes: bytes, sizes: Iterable[int]) -> List[str]:
    out: List[str] = []
    pos = 0
    for s in sizes:
        out.append(md5_hex(region_bytes[pos : pos + s]))
        pos += s
    return out


def replace_verify_md5s(script_text: str, partition_name: str, md5_values: List[str]) -> str:
    start_pat = re.compile(
        rf"^echo verifying\s+{re.escape(partition_name)}\s+\.\.\.\s*$", re.MULTILINE
    )
    m = start_pat.search(script_text)
    if not m:
        raise FirmwareError(f"Could not find verify block for partition '{partition_name}'")

    block_start = m.start()
    next_m = re.search(r"^echo verifying\s+.+\s+\.\.\.\s*$", script_text[m.end() :], re.MULTILINE)
    block_end = m.end() + next_m.start() if next_m else len(script_text)

    block = script_text[block_start:block_end]
    md5_pat = re.compile(r'(if test "\$md5sum_value" = )([0-9a-f]{32})( ; then)')
    matches = list(md5_pat.finditer(block))
    if len(matches) != len(md5_values):
        raise FirmwareError(
            f"Verify block '{partition_name}' has {len(matches)} md5 checks, expected {len(md5_values)}"
        )

    new_block = block
    for old, new_val in zip(matches, md5_values):
        new_block = new_block.replace(old.group(2), new_val, 1)

    return script_text[:block_start] + new_block + script_text[block_end:]


def unsquashfs(src_sqsh: Path, dst_dir: Path) -> None:
    dst_dir.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["unsquashfs", "-d", str(dst_dir), str(src_sqsh)]
    run_checked(cmd)


def mksquashfs(src_dir: Path, dst_sqsh: Path, exclude_paths: List[Path] | None = None) -> None:
    dst_sqsh.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "mksquashfs",
        str(src_dir),
        str(dst_sqsh),
        "-comp",
        "lzo",
        "-Xalgorithm",
        "lzo1x_999",
        "-Xcompression-level",
        "9",
        "-b",
        "32768",
        "-noappend",
        "-all-root",
        "-no-exports",
        "-no-progress",
    ]
    if exclude_paths:
        cmd.extend(["-e", *[str(p) for p in exclude_paths]])
    run_checked(cmd)


def squashfs_bytes_used(blob: bytes) -> int:
    if len(blob) < 0x30:
        raise FirmwareError("SquashFS blob too small for superblock parsing")
    return struct.unpack_from("<Q", blob, 0x28)[0]


def list_squashfs_paths(image_path: Path) -> Set[str]:
    proc = subprocess.run(
        ["unsquashfs", "-ll", str(image_path)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise FirmwareError(
            f"Could not list SquashFS paths for {image_path}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )

    out: Set[str] = set()
    for raw in proc.stdout.splitlines():
        line = raw.strip()
        if "squashfs-root" not in line:
            continue
        left = line.split(" -> ", 1)[0]
        token = None
        for t in left.split():
            if t.startswith("squashfs-root"):
                token = t
                break
        if token is None:
            continue
        if token == "squashfs-root":
            out.add("")
        elif token.startswith("squashfs-root/"):
            out.add(token[len("squashfs-root/") :])
    return out


def run_checked(cmd: List[str]) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise FirmwareError(
            f"Command failed: {' '.join(cmd)}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def replace_region(buf: bytearray, region: Region, payload: bytes) -> None:
    if len(payload) > region.size:
        raise FirmwareError(
            f"Payload for {region.name} too large: 0x{len(payload):x} > 0x{region.size:x}"
        )
    start = region.offset
    end = start + region.size
    if end > len(buf):
        raise FirmwareError(f"Region {region.name} outside destination binary")
    padded = payload + (b"\x00" * (region.size - len(payload)))
    buf[start:end] = padded


def component_regions_from_metadata(meta: dict) -> Dict[str, Region]:
    out = {}
    for c in meta["components"]:
        out[c["name"]] = Region(c["name"], int(c["offset"]), int(c["size"]))
    return out


def verify_squashfs_magic(blob: bytes, region_name: str) -> None:
    if not blob.startswith(SQUASHFS_MAGIC):
        raise FirmwareError(f"Region {region_name} does not start with SquashFS magic")


def temp_file_path(suffix: str = "") -> Path:
    f = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    p = Path(f.name)
    f.close()
    return p
