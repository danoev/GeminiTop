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
    "mtdblock12", "mtd12", "class_block", "proc_self_fd", "libc_link", "loader_link",
    "libc_file", "loader_file", "libc_resolved", "sys_dev_block",
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


def elf32_exports(data):
    """Return defined exports only from a structurally loadable ARM libc image."""
    if (len(data) < 52 or data[:4] != b"\x7fELF"
            or data[4:7] != b"\x01\x01\x01"):
        return None
    if (struct.unpack_from("<HHI", data, 16) != (3, 40, 1)
            or struct.unpack_from("<H", data, 40)[0] != 52):
        return None
    phoff = struct.unpack_from("<I", data, 28)[0]
    phentsize, phcount = struct.unpack_from("<HH", data, 42)
    if phentsize != 32 or not 0 < phcount <= 256 or phoff < 52 \
            or phoff + phentsize * phcount > len(data):
        return None
    loads, dynamics = [], []
    for index in range(phcount):
        kind, offset, address, _, filesz, memsz, flags, align = struct.unpack_from(
            "<IIIIIIII", data, phoff + index * phentsize)
        if kind not in (1, 2):  # PT_NULL fields, in particular, are undefined.
            continue
        if (offset > len(data) or filesz > len(data) - offset or filesz > memsz
                or address + memsz > 0xffffffff):
            return None
        if kind == 1:  # PT_LOAD
            if align not in (0, 1) and ((align & (align - 1))
                                         or (address - offset) % align):
                return None
            if loads and address < loads[-1][1]:
                return None
            loads.append((offset, address, filesz, memsz, flags))
        elif kind == 2:  # PT_DYNAMIC
            dynamics.append((offset, address, filesz))
    ordered = sorted(loads, key=lambda item: item[1])
    if any(a[1] + a[3] > b[1] for a, b in zip(ordered, ordered[1:])):
        return None
    if not loads or len(dynamics) != 1 or dynamics[0][2] < 8 \
            or dynamics[0][2] % 8:
        return None

    def loaded(offset, address, size):
        return any(offset >= lo and size <= length - (offset - lo)
                   and address == va + offset - lo
                   for lo, va, length, _, _ in loads if offset - lo <= length)

    def executable_symbol(value, size):
        # AAELF32 marks a Thumb function by setting bit 0 in st_value.
        # The instruction address is value with that bit stripped.
        start = value & ~1
        if not value or ((value & 1) == 0 and (start & 3) != 0):
            return False
        extent = size if size else 1  # Zero-size symbols still need an entry byte.
        return any((flags & 1) and start >= address
                   and extent <= filesz - (start - address)
                   and offset + (start - address) < len(data)
                   for offset, address, filesz, _, flags in loads
                   if start - address <= filesz)

    dynoff, dynaddr, dynsize = dynamics[0]
    if not loaded(dynoff, dynaddr, dynsize):
        return None
    tags = {}
    terminated = False
    for offset in range(dynoff, dynoff + dynsize, 8):
        tag, value = struct.unpack_from("<II", data, offset)
        if tag == 0:  # DT_NULL
            terminated = True
            break
        if tag in (5, 6, 10, 11, 14):
            if tag in tags:
                return None
            tags[tag] = value
    if not terminated or set(tags) != {5, 6, 10, 11, 14} or tags[11] != 16:
        return None
    shoff = struct.unpack_from("<I", data, 32)[0]
    entsize, count = struct.unpack_from("<HH", data, 46)
    if entsize < 40 or count == 0 or count > 4096 or shoff + entsize * count > len(data):
        return None
    sections = []
    for i in range(count):
        off = shoff + i * entsize
        typ = struct.unpack_from("<I", data, off + 4)[0]
        flags, address, start, size, link = struct.unpack_from("<IIIII", data, off + 8)
        entry = struct.unpack_from("<I", data, off + 36)[0]
        if start > len(data) or size > len(data) - start:
            return None
        sections.append((typ, flags, address, start, size, link, entry))
    dynsyms = [s for s in sections if s[0] == 11]
    if len(dynsyms) != 1:
        return None
    _, _, address, start, size, link, entry = dynsyms[0]
    if entry < 16 or size % entry or link >= count or size // entry > 65536:
        return None
    if tags[6] != address or not loaded(start, address, size):
        return None
    strings = sections[link]
    if (strings[0] != 3 or tags[5] != strings[2] or tags[10] != strings[4]
            or not loaded(strings[3], strings[2], strings[4])):
        return None
    table = data[strings[3]:strings[3] + strings[4]]
    soname = tags[14]
    if soname >= len(table) or table.find(b"\0", soname) < 0 \
            or table[soname:table.find(b"\0", soname)] != b"libc.so.6":
        return None
    found = set()
    for index in range(size // entry):
        name = struct.unpack_from("<I", data, start + index * entry)[0]
        if name >= len(table):
            return None
        end = table.find(b"\0", name)
        if end < 0:
            return None
        value, symbol_size = struct.unpack_from("<II", data, start + index * entry + 4)
        info, other, shndx = struct.unpack_from("<BBH", data, start + index * entry + 12)
        binding, kind, visibility = info >> 4, info & 15, other & 3
        symbol = table[name:end]
        if (symbol not in (b"memfd_create", b"execveat", b"fexecve")
                or binding not in (1, 2) or kind != 2 or visibility not in (0, 3)
                or shndx == 0):
            continue
        if shndx >= count:
            return None
        section = sections[shndx]
        extent = symbol_size if symbol_size else 1
        code_address = value & ~1
        if (section[0] != 1 or not (section[1] & 4)
                or code_address < section[2]
                or extent > section[4] - (code_address - section[2])
                or not loaded(section[3], section[2], section[4])
                or not executable_symbol(value, symbol_size)):
            return None
        found.add(symbol)
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


def linux_dev_numbers(value):
    """Decode Linux dev_t without depending on the analyser host OS."""
    dev = int(value)
    if dev < 0 or dev >= 1 << 64:
        raise ValueError("invalid Linux st_dev")
    return ((dev >> 8 & 0xfff) | (dev >> 32 & ~0xfff),
            (dev & 0xff) | (dev >> 12 & ~0xff))


def mount_option_tokens(field):
    """Parse an unnormalised /proc mount option field, or reject it."""
    if not field or any(not char.isprintable() or char.isspace() for char in field):
        return None
    tokens = field.split(",")
    if (any(not token or token.startswith("=") or token.endswith("=")
            for token in tokens) or len(tokens) != len(set(tokens))):
        return None
    return tuple(tokens)


def mount_view_fields(data):
    """Preserve exact space-separated fields; never erase literal controls."""
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return None
    if (not text.endswith("\n") or any(
            char != "\n" and (not char.isprintable()
                                or (char.isspace() and char != " ")) for char in text)):
        return None
    lines = text[:-1].split("\n")
    if any(not line for line in lines):
        return None
    return [line.split(" ") for line in lines]


def mount_text_field(field):
    """Accept visible proc text, preserving rather than decoding octal escapes."""
    if not field or any(not char.isprintable() or char.isspace() for char in field):
        return False
    index = 0
    while index < len(field):
        if field[index] == "\\":
            if (index + 4 > len(field) or
                    any(char not in "01234567" for char in field[index + 1:index + 4])):
                return False
            index += 4
        else:
            index += 1
    return True


def mount_decimal(field):
    """A proc decimal field has ASCII digits only; zero is syntactically valid."""
    return re.fullmatch(r"[0-9]+", field) is not None


def proc_mounts_record(fields):
    """Validate all six raw /proc/mounts fields before NVM interpretation."""
    if len(fields) != 6:
        return False
    source, point, fstype, options, dump, pass_number = fields
    return (all(mount_text_field(value) for value in (source, point, fstype))
            and mount_option_tokens(options) is not None
            and mount_decimal(dump) and mount_decimal(pass_number))


def mountinfo_record(fields):
    """Validate required and open-ended optional mountinfo fields."""
    separator = len(fields) - 4
    if separator < 6 or fields[separator] != "-" or "-" in fields[6:separator]:
        return False
    if (not mount_decimal(fields[0]) or not mount_decimal(fields[1]) or
            re.fullmatch(r"[0-9]+:[0-9]+", fields[2]) is None):
        return False
    if not all(mount_text_field(fields[index]) for index in (3, 4, separator + 1,
                                                              separator + 2)):
        return False
    if (mount_option_tokens(fields[5]) is None or
            mount_option_tokens(fields[separator + 3]) is None):
        return False
    for field in fields[6:separator]:
        tag, colon, value = field.partition(":")
        if not mount_text_field(tag) or (colon and not mount_text_field(value)):
            return False
    return True


def mount_presentation(files, objects):
    """Classify NVM association; a missing physical link cannot be confirmed."""

    def writable_options(field):
        options = mount_option_tokens(field)
        return options is not None and options.count("rw") == 1 and "ro" not in options

    path = "/tmp/sp/media/flash/nvm"
    mounts = mount_view_fields(files["mounts/proc-mounts.txt"])
    infos = mount_view_fields(files["mounts/mountinfo.txt"])
    if mounts is None or infos is None:
        return "CONTRADICTORY"
    if any(not proc_mounts_record(r) for r in mounts):
        return "CONTRADICTORY"
    if any(not mountinfo_record(r) for r in infos):
        return "CONTRADICTORY"
    mount = [r for r in mounts if r[1] == path]
    info = [r for r in infos if r[4] == path]
    if not mount and not info:
        return "UNKNOWN"
    if len(mount) != 1 or len(info) != 1:
        return "CONTRADICTORY"
    m, i = mount[0], info[0]
    if (m[0] != "/dev/mtdblock12" or m[2] != "yaffs2"
            or not writable_options(m[3])):
        return "CONTRADICTORY"
    sep = len(i) - 4
    if (i[3] != "/" or
            not writable_options(i[5]) or not writable_options(i[sep + 3])
            or i[sep + 1:sep + 3] !=
            ["yaffs2", "/dev/mtdblock12"]):
        return "CONTRADICTORY"
    major, minor = map(int, i[2].split(":"))
    partial = False

    def fields(label, expected_type=None):
        nonlocal partial
        raw = objects.get(label, "ABSENT")
        if raw == "ABSENT":
            partial = True
            return None
        parts = raw.split("|")
        if len(parts) != 8 or (expected_type and parts[0] != expected_type):
            raise ValueError("contradictory object type")
        return parts

    try:
        media = fields("media", "symbolic link")
        if media and objects.get("media.link", "").rstrip("/") != "/tmp/sp/media":
            return "CONTRADICTORY"
        nvm = fields("nvm", "directory")
        if nvm and linux_dev_numbers(nvm[1]) != (major, minor):
            return "CONTRADICTORY"
        node = fields("mtdblock12", "block special file")
        if node and (int(node[6], 16), int(node[7], 16)) != (major, minor):
            return "CONTRADICTORY"
        if objects.get("mtdblock12.link"):
            return "CONTRADICTORY"
        assoc = fields("sys_dev_block", "symbolic link")
        class_block = fields("class_block", "symbolic link")
        if assoc and not objects.get("sys_dev_block.link", "").rstrip("/").endswith(
                "/mtdblock12"):
            return "CONTRADICTORY"
        if class_block and not objects.get("class_block.link", "").rstrip("/").endswith(
                "/mtdblock12"):
            return "CONTRADICTORY"
        if assoc and class_block:
            dev_link = objects.get("sys_dev_block.link", "")
            class_link = objects.get("class_block.link", "")
            dev_path = os.path.normpath(os.path.join("/sys/dev/block", dev_link))
            class_path = os.path.normpath(os.path.join("/sys/class/block", class_link))
            if (dev_path != class_path or not dev_path.startswith("/sys/devices/")
                    or not dev_path.endswith("/mtdblock12")):
                return "CONTRADICTORY"
        mtd = fields("mtd12")
        if mtd and mtd[0] not in ("directory", "symbolic link"):
            return "CONTRADICTORY"
        if mtd and mtd[0] == "symbolic link" and not objects.get(
                "mtd12.link", "").rstrip("/").endswith("/mtd12"):
            return "CONTRADICTORY"
        mtd_lines = rows(files["mounts/proc-mtd.txt"], "proc-mtd")
        mtd12 = [line for line in mtd_lines if line.startswith("mtd12:")]
        if len(mtd12) != 1:
            return "CONTRADICTORY"
        match = re.fullmatch(r'mtd12: ([0-9a-fA-F]+) ([0-9a-fA-F]+) "([^"]+)"',
                             mtd12[0])
        if not match or int(match[1], 16) != 8388608 or match[3] != "nvm":
            return "CONTRADICTORY"
        erase_size = int(match[2], 16)
        for attr, expected in (("name", "nvm"), ("size", "8388608"),
                               ("dev", "90:24"), ("erasesize", str(erase_size))):
            key = f"metadata/mtd12-{attr}.txt"
            if key not in files:
                partial = True
            elif files[key].decode("ascii", "strict").strip() != expected:
                return "CONTRADICTORY"
        # The captured sibling type is part of the same MTD association.
        # A different recognized MTD family is incomplete evidence for this
        # NAND/YAFFS2 presentation; malformed data is contradictory.
        type_data = files.get("metadata/mtd12-type.txt")
        if type_data is None:
            partial = True
        else:
            mtd_type = type_data.decode("ascii", "strict")
            if not re.fullmatch(r"(absent|ram|rom|nor|nand|dataflash|ubi|mlc-nand|unknown)\n",
                                mtd_type):
                return "CONTRADICTORY"
            if mtd_type not in ("nand\n", "mlc-nand\n"):
                partial = True
    except (ValueError, UnicodeDecodeError, OverflowError):
        return "CONTRADICTORY"
    return "PARTIAL" if partial else "CONFIRMED"


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
        if label == "libc_resolved":
            if value not in ("UNKNOWN", "/lib/libc-2.30.so"):
                raise InvalidCapture("unsafe libc resolution")
        elif not label.endswith(".link") and value != "ABSENT" and len(value.split("|")) != 8:
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
    libc_copy = files.get("userspace/libc-2.30.so")
    libc_link = objects.get("libc_link", "").split("|")
    libc_file = objects.get("libc_file", "").split("|")
    libc_target = objects.get("libc_link.link")
    libc_provenance = (
        libc_copy is not None and libc_link[0] == "symbolic link"
        and libc_target in ("libc-2.30.so", "/lib/libc-2.30.so")
        and objects.get("libc_resolved") == "/lib/libc-2.30.so"
        and len(libc_file) == 8 and libc_file[0] == "regular file"
        and libc_file[4].isdigit() and int(libc_file[4]) == len(libc_copy)
    )
    names = elf32_exports(libc_copy) if libc_provenance else None
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
        "NVM_MOUNT_PRESENTATION": mount_presentation(files, objects),
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
