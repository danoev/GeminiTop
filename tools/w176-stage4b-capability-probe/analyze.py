#!/usr/bin/env python3
"""Validate a Stage-4B metadata transaction; never claim runtime execution."""

import argparse
import hashlib
import json
import os
import re
import stat
import struct
from pathlib import Path, PurePosixPath

MANDATORY = {
    "COMPLETE": 64, "STATUS.txt": 1024, "ERRORS.txt": 8192,
    "OPTIONAL.txt": 8192, "SUMMARY.txt": 2048,
    "CAPABILITIES.txt": 2048, "INVENTORY.txt": 4096,
    "checksums.sha256": 8192, "kernel/uname.txt": 4096,
    "kernel/proc-version.txt": 8192, "kernel/osrelease.txt": 1024,
    "kernel/filesystems.txt": 16384, "mounts/proc-mounts.txt": 65536,
    "mounts/mountinfo.txt": 131072, "mounts/proc-mtd.txt": 16384,
    "metadata/objects.txt": 16384,
}
OPTIONAL = {
    "kernel/proc-config.gz": 262144,
    "kernel/boot-config.txt": 524288,
    "kernel/symbol-names.txt": 8192,
    "userspace/libc-2.30.so": 1048576,
    "userspace/ld-2.30.so": 131072,
    **{f"metadata/mtd12-{key}.txt": 4096
       for key in ("name", "type", "size", "erasesize", "dev")},
}
OBJECT_LABELS = {
    "proc_config", "boot_config", "kallsyms", "media", "nvm",
    "mtdblock12", "mtd12", "proc_self_fd", "libc_link", "loader_link",
    "libc_file", "loader_file", "sys_dev_block",
}
LIMITS = MANDATORY | OPTIONAL
EVIDENCE = set(LIMITS) - {"COMPLETE", "STATUS.txt", "INVENTORY.txt", "checksums.sha256"}
SHA_LINE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_.\-/]+)")


class InvalidCapture(ValueError):
    pass


def path_parts(name):
    if not isinstance(name, str) or not name or "\\" in name or "\x00" in name:
        raise InvalidCapture("unsafe path")
    p = PurePosixPath(name)
    if p.is_absolute() or p.as_posix() != name or any(x in ("", ".", "..") for x in p.parts):
        raise InvalidCapture(f"unsafe path: {name!r}")
    return p.parts


def file_bytes(root, name):
    parts = path_parts(name)
    path = root
    for index, part in enumerate(parts):
        path /= part
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode):
            raise InvalidCapture(f"symlink in {name}")
        if index < len(parts) - 1 and not stat.S_ISDIR(mode):
            raise InvalidCapture(f"non-directory parent in {name}")
    meta = os.lstat(path)
    if not stat.S_ISREG(meta.st_mode) or meta.st_size > LIMITS[name]:
        raise InvalidCapture(f"invalid type or size: {name}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (meta.st_dev, meta.st_ino):
            raise InvalidCapture(f"changed file: {name}")
        data = os.read(fd, LIMITS[name] + 1)
    finally:
        os.close(fd)
    if len(data) > LIMITS[name] or len(data) != opened.st_size:
        raise InvalidCapture(f"growing file: {name}")
    return data


def rows(data, label):
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        raise InvalidCapture(f"non-text {label}") from exc
    if not text.endswith("\n"):
        raise InvalidCapture(f"unterminated {label}")
    return text.splitlines()


def kv(data, label, keys):
    result = {}
    for row in rows(data, label):
        if row.count("=") != 1:
            raise InvalidCapture(f"malformed {label}")
        key, value = row.split("=", 1)
        if key in result or key not in keys:
            raise InvalidCapture(f"duplicate/unknown {label} key")
        result[key] = value
    if set(result) != set(keys):
        raise InvalidCapture(f"incomplete {label}")
    return result


def elf32_dynsymbols(data):
    """Return complete ELF32 ARM dynamic symbol names, or None if unverifiable."""
    if len(data) < 52 or data[:4] != b"\x7fELF" or data[4:6] != b"\x01\x01":
        return None
    if struct.unpack_from("<H", data, 18)[0] != 40:
        return None
    shoff = struct.unpack_from("<I", data, 32)[0]
    entsize, count = struct.unpack_from("<HH", data, 46)
    if entsize < 40 or count == 0 or count > 4096 or shoff + entsize * count > len(data):
        return None
    sections = []
    for i in range(count):
        off = shoff + i * entsize
        typ = struct.unpack_from("<I", data, off + 4)[0]
        start, size, link = struct.unpack_from("<III", data, off + 16)
        entry = struct.unpack_from("<I", data, off + 36)[0]
        if start > len(data) or size > len(data) - start:
            return None
        sections.append((typ, start, size, link, entry))
    dynsyms = [s for s in sections if s[0] == 11]
    if len(dynsyms) != 1:
        return None
    _, start, size, link, entry = dynsyms[0]
    if entry < 16 or size % entry or link >= count or size // entry > 65536:
        return None
    strings = sections[link]
    if strings[0] != 3:
        return None
    table = data[strings[1]:strings[1] + strings[2]]
    found = set()
    for index in range(size // entry):
        name = struct.unpack_from("<I", data, start + index * entry)[0]
        if name >= len(table):
            return None
        end = table.find(b"\0", name)
        if end < 0:
            return None
        found.add(table[name:end])
    return found


def config_lines(data, compressed):
    if compressed:
        import gzip
        try:
            # Host-only decompression; bound expansion to 1 MiB.
            with gzip.GzipFile(fileobj=__import__("io").BytesIO(data)) as stream:
                data = stream.read(1048577)
        except (OSError, EOFError):
            return None
        if len(data) > 1048576:
            return None
    try:
        return set(data.decode("ascii", "strict").splitlines())
    except UnicodeDecodeError:
        return None


def mount_confirmed(files):
    try:
        mount_rows = rows(files["mounts/proc-mounts.txt"], "mounts")
        info_rows = rows(files["mounts/mountinfo.txt"], "mountinfo")
    except InvalidCapture:
        return False
    mount = [r.split() for r in mount_rows if len(r.split()) >= 4
             and r.split()[1] == "/tmp/sp/media/flash/nvm"]
    info = [r.split() for r in info_rows if " - " in r
            and len(r.split()) >= 10 and r.split()[4] == "/tmp/sp/media/flash/nvm"]
    return (len(mount) == 1 and mount[0][0] == "/dev/mtdblock12"
            and mount[0][2] == "yaffs2" and "rw" in mount[0][3].split(",")
            and len(info) == 1 and info[0][3] == "/"
            and "rw" in info[0][5].split(",")
            and info[0][-3:-1] == ["yaffs2", "/dev/mtdblock12"])


def analyze(root):
    root = Path(root).absolute()
    for component in (root, *root.parents):
        if stat.S_ISLNK(os.lstat(component).st_mode):
            raise InvalidCapture("symlink in capture-root ancestry")
    if not root.is_dir():
        raise InvalidCapture("capture root is not a real directory")
    actual = set()
    actual_dirs = set()
    for here, dirs, names in os.walk(root, followlinks=False):
        for item in dirs + names:
            path = Path(here) / item
            if stat.S_ISLNK(os.lstat(path).st_mode):
                raise InvalidCapture("symlink in capture")
        for name in dirs:
            actual_dirs.add((Path(here) / name).relative_to(root).as_posix())
        for name in names:
            rel = (Path(here) / name).relative_to(root).as_posix()
            if rel not in LIMITS:
                raise InvalidCapture(f"unexpected output: {rel}")
            actual.add(rel)
    if actual_dirs != {"kernel", "mounts", "metadata", "userspace"}:
        raise InvalidCapture("unexpected or missing output directory")
    if not set(MANDATORY).issubset(actual):
        raise InvalidCapture("missing mandatory output")
    if sum(os.lstat(root / name).st_size for name in actual) > 3072 * 1024:
        raise InvalidCapture("total output exceeds cap")
    files = {name: file_bytes(root, name) for name in actual}
    if files["COMPLETE"] != b"complete=1\n":
        raise InvalidCapture("false COMPLETE")
    status = kv(files["STATUS.txt"], "STATUS",
                ("schema", "scope", "status", "mandatory_failures", "optional_unknowns"))
    if status != {
        "schema": "1", "scope": "w176-stage4b-capability-metadata",
        "status": "COMPLETE", "mandatory_failures": "0",
        "optional_unknowns": status["optional_unknowns"],
    } or not status["optional_unknowns"].isdigit() or files["ERRORS.txt"]:
        raise InvalidCapture("invalid transaction status")
    summary = kv(files["SUMMARY.txt"], "SUMMARY",
                 ("schema", "scope", "sealed_runtime_execution",
                  "feature_syscalls.invoked", "nvm.writes", "device_streams.opened"))
    if summary != {
        "schema": "1", "scope": "w176-stage4b-capability-metadata",
        "sealed_runtime_execution": "NOT_TESTED", "feature_syscalls.invoked": "0",
        "nvm.writes": "0", "device_streams.opened": "0",
    }:
        raise InvalidCapture("invalid summary")
    capabilities = kv(files["CAPABILITIES.txt"], "CAPABILITIES",
                      ("schema", "max_final_kib", "config_proc_max", "config_boot_max",
                       "kallsyms_prefix_max", "libc_max", "loader_max",
                       "all_sources_exact_allowlist", "producer_status_checked",
                       "output_write_ceiling"))
    if capabilities != {
        "schema": "1", "max_final_kib": "3072", "config_proc_max": "262144",
        "config_boot_max": "524288", "kallsyms_prefix_max": "524288",
        "libc_max": "1048576", "loader_max": "131072",
        "all_sources_exact_allowlist": "1", "producer_status_checked": "1",
        "output_write_ceiling": "NOT_CLAIMED",
    }:
        raise InvalidCapture("invalid capabilities")
    inventory = rows(files["INVENTORY.txt"], "INVENTORY")
    if len(inventory) != len(set(inventory)) or set(inventory) != actual - {
            "COMPLETE", "STATUS.txt", "INVENTORY.txt", "checksums.sha256"}:
        raise InvalidCapture("inventory mismatch")
    manifest = {}
    for row in rows(files["checksums.sha256"], "checksums"):
        match = SHA_LINE.fullmatch(row)
        if not match or match[2] in manifest:
            raise InvalidCapture("malformed/duplicate checksum")
        manifest[match[2]] = match[1]
    if set(manifest) != actual - {"checksums.sha256"}:
        raise InvalidCapture("checksum coverage mismatch")
    for name, expected in manifest.items():
        if hashlib.sha256(files[name]).hexdigest() != expected:
            raise InvalidCapture(f"checksum mismatch: {name}")
    optionals = rows(files["OPTIONAL.txt"], "OPTIONAL") if files["OPTIONAL.txt"] else []
    if len(optionals) != int(status["optional_unknowns"]):
        raise InvalidCapture("optional count mismatch")
    seen_optionals = set()
    for index, row in enumerate(optionals, 1):
        prefix = f"optional.{index}="
        if not row.startswith(prefix) or len(row) > 320 or not re.fullmatch(
                r"[A-Za-z0-9_:-]+", row[len(prefix):]):
            raise InvalidCapture("malformed optional record")
        if row[len(prefix):] in seen_optionals:
            raise InvalidCapture("duplicate optional record")
        seen_optionals.add(row[len(prefix):])
    expected_optional_labels = {
        "kernel/proc-config.gz": "proc_config",
        "kernel/boot-config.txt": "boot_config",
        "kernel/symbol-names.txt": "kallsyms",
        "userspace/libc-2.30.so": "libc_file",
        "userspace/ld-2.30.so": "loader_file",
        **{f"metadata/mtd12-{key}.txt": f"mtd12_{key}"
           for key in ("name", "type", "size", "erasesize", "dev")},
    }
    for name, label in expected_optional_labels.items():
        if name not in files and not any(value.startswith(label + ":") for value in seen_optionals):
            raise InvalidCapture(f"missing optional explanation: {name}")
    objects = {}
    for row in rows(files["metadata/objects.txt"], "objects"):
        if "|" not in row:
            raise InvalidCapture("malformed object record")
        label, value = row.split("|", 1)
        base = label[:-5] if label.endswith(".link") else label
        if base not in OBJECT_LABELS or label in objects or not value or len(value) > 4096:
            raise InvalidCapture("unknown/duplicate object record")
        if not label.endswith(".link") and value != "ABSENT" and len(value.split("|")) != 8:
            raise InvalidCapture("malformed object stat")
        objects[label] = value
    if not OBJECT_LABELS.difference({"sys_dev_block"}).issubset(objects):
        raise InvalidCapture("missing object metadata")
    for label in objects:
        if label.endswith(".link") and (objects.get(label[:-5], "").split("|", 1)[0]
                                        != "symbolic link"):
            raise InvalidCapture("link without symlink metadata")
    cfg_proc = None
    cfg_boot = None
    if "kernel/proc-config.gz" in files:
        cfg_proc = config_lines(files["kernel/proc-config.gz"], True)
    if "kernel/boot-config.txt" in files:
        cfg_boot = config_lines(files["kernel/boot-config.txt"], False)
    cfg = None if cfg_proc is not None and cfg_boot is not None and cfg_proc != cfg_boot \
        else cfg_proc if cfg_proc is not None else cfg_boot
    symbols = set()
    if "kernel/symbol-names.txt" in files:
        for row in rows(files["kernel/symbol-names.txt"], "symbols") if files["kernel/symbol-names.txt"] else []:
            if not re.fullmatch(r"[A-Za-z0-9_]+", row):
                raise InvalidCapture("unsafe symbol")
            symbols.add(row)
    names = elf32_dynsymbols(files["userspace/libc-2.30.so"]) if "userspace/libc-2.30.so" in files else None
    wrappers = {
        name: ("UNKNOWN" if names is None else
               "OBSERVED" if name.encode() in names else "NOT_OBSERVED")
        for name in ("memfd_create", "execveat", "fexecve")
    }
    has = lambda suffix: any(x == suffix or x.endswith("_" + suffix) for x in symbols)
    identity = (
        files["kernel/osrelease.txt"].strip() == b"4.9.217"
        and b"Linux version 4.9.217" in files["kernel/proc-version.txt"]
        and b"armv7" in files["kernel/uname.txt"].lower()
    )
    return {
        "CAPTURE": "COMPLETE",
        "KERNEL_IDENTITY": "CONFIRMED" if identity else "UNKNOWN",
        "UPSTREAM_4_9_MEMFD_COMPATIBILITY": "REFERENCE_ONLY",
        "TARGET_MEMFD_SUPPORT": "SUPPORTED_BY_METADATA" if cfg and "CONFIG_TMPFS=y" in cfg
            and has("memfd_create") else "UNKNOWN",
        "TARGET_SEALING_SUPPORT": "SUPPORTED_BY_METADATA" if cfg and "CONFIG_TMPFS=y" in cfg
            and has("shmem_add_seals") and has("shmem_get_seals") else "UNKNOWN",
        "TARGET_EXECVEAT_SUPPORT": "SUPPORTED_BY_METADATA" if has("execveat") else "UNKNOWN",
        **{f"TARGET_LIBC_WRAPPER_{name.upper()}": value for name, value in wrappers.items()},
        "NVM_MOUNT_PRESENTATION": "CONFIRMED" if mount_confirmed(files) else "UNKNOWN",
        "SEALED_RUNTIME_EXECUTION": "NOT_TESTED",
        "EXECUTION_HIGH": "OPEN",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture")
    parser.add_argument("--json", help="optional result path (not inside capture)")
    args = parser.parse_args()
    try:
        result = analyze(args.capture)
    except (InvalidCapture, OSError, KeyError, ValueError) as exc:
        parser.exit(2, f"INVALID CAPTURE: {exc}\n")
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json:
        target = Path(args.json).absolute()
        capture = Path(args.capture).absolute().resolve()
        if capture == target or capture in target.parents:
            parser.exit(2, "analysis output cannot be inside capture\n")
        target.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


if __name__ == "__main__":
    main()
