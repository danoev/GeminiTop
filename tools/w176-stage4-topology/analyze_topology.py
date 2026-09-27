#!/usr/bin/env python3
"""Validate and conservatively classify a returned Stage-4A transaction."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path, PurePosixPath


FIXED_EVIDENCE = {
    "COMPLETE",
    "STATUS.txt",
    "ERRORS.txt",
    "OPTIONAL.txt",
    "CAPABILITIES.txt",
    "SUMMARY.txt",
    "capture-inventory.txt",
    "network/proc-net-dev.txt",
    "network/interfaces.txt",
    "devices/device-nodes.txt",
    "processes/owners.txt",
    "files/libappframework.so.1.0.0",
    "files/libappmcucommunication.so.1.0.0",
}
LIBRARY_LIMITS = {
    "files/libappframework.so.1.0.0": 393_216,
    "files/libappmcucommunication.so.1.0.0": 327_680,
}
FIXED_LIMITS = {
    "COMPLETE": 64,
    "STATUS.txt": 4_096,
    "ERRORS.txt": 65_536,
    "OPTIONAL.txt": 65_536,
    "CAPABILITIES.txt": 16_384,
    "SUMMARY.txt": 4_096,
    "capture-inventory.txt": 131_072,
    "checksums.sha256": 65_536,
    "network/proc-net-dev.txt": 65_536,
    "network/interfaces.txt": 262_144,
    "devices/device-nodes.txt": 65_536,
    "processes/owners.txt": 131_072,
    **LIBRARY_LIMITS,
}
DEVICE_PATHS = {
    "/dev/canbox_protocol_dev",
    "/dev/hc_mcu_dev",
    *(f"/dev/can{number}" for number in range(8)),
    *(f"/dev/ttyS{number}" for number in range(8)),
}
INTERFACE_ATTRIBUTES = {"type", "operstate", "mtu", "flags", "uevent", "address", "device", "device/driver"}
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


def _capture_root(root: Path) -> Path:
    absolute = root.absolute()
    metadata = os.lstat(absolute)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise InvalidCapture("capture root must be a real directory, not a symlink")
    return absolute.resolve(strict=True)


def _relative_parts(relative: str) -> tuple[str, ...]:
    if not isinstance(relative, str) or not relative or "\x00" in relative or "\\" in relative:
        raise InvalidCapture(f"unsafe evidence path: {relative!r}")
    logical = PurePosixPath(relative)
    if logical.is_absolute() or any(part in {"", ".", ".."} for part in logical.parts):
        raise InvalidCapture(f"unsafe evidence path: {relative!r}")
    if logical.as_posix() != relative:
        raise InvalidCapture(f"ambiguous evidence path: {relative!r}")
    return logical.parts


def _safe_regular(root: Path, relative: str, limit: int) -> Path:
    parts = _relative_parts(relative)
    current = root
    for index, part in enumerate(parts):
        current = current / part
        metadata = os.lstat(current)
        if stat.S_ISLNK(metadata.st_mode):
            raise InvalidCapture(f"symlink component in evidence path: {relative}")
        if index < len(parts) - 1:
            if not stat.S_ISDIR(metadata.st_mode):
                raise InvalidCapture(f"non-directory parent in evidence path: {relative}")
        elif not stat.S_ISREG(metadata.st_mode):
            raise InvalidCapture(f"evidence is not a regular file: {relative}")
    resolved = current.resolve(strict=True)
    try:
        if os.path.commonpath((str(root), str(resolved))) != str(root):
            raise InvalidCapture(f"evidence escapes capture root: {relative}")
    except ValueError as exc:
        raise InvalidCapture(f"evidence containment failed: {relative}") from exc
    if metadata.st_size > limit:
        raise InvalidCapture(f"file exceeds analyser limit: {relative}")
    return current


def _read_bytes(root: Path, relative: str, limit: int) -> bytes:
    path = _safe_regular(root, relative, limit)
    with path.open("rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise InvalidCapture(f"file grew beyond analyser limit: {relative}")
    return data


def _read_text(root: Path, relative: str, limit: int) -> str:
    return _read_bytes(root, relative, limit).decode("utf-8", "strict")


def _parse_exact_kv(text: str, expected: set[str], label: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        if "=" not in line:
            raise InvalidCapture(f"malformed {label} line {number}")
        key, value = line.split("=", 1)
        if key not in expected or key in result or not value:
            raise InvalidCapture(f"unexpected/duplicate {label} key: {key}")
        result[key] = value
    if set(result) != expected:
        raise InvalidCapture(f"incomplete {label} schema")
    return result


def _owner_limit(relative: str) -> int:
    if re.fullmatch(r"processes/[1-9][0-9]*-comm\.txt", relative):
        return 4_096
    if re.fullmatch(r"processes/[1-9][0-9]*-cmdline\.bin", relative):
        return 16_384
    if re.fullmatch(r"processes/[1-9][0-9]*-exe\.txt", relative):
        return 4_097
    if re.fullmatch(r"processes/[1-9][0-9]*-maps\.txt", relative):
        return 65_536
    raise InvalidCapture(f"invalid dynamic owner output path: {relative}")


def _parse_inventory(root: Path) -> tuple[set[str], dict[int, set[str]]]:
    text = _read_text(root, "capture-inventory.txt", FIXED_LIMITS["capture-inventory.txt"])
    outputs: set[str] = set()
    labels: set[str] = set()
    owner_kinds: dict[int, set[str]] = {}
    fixed = {
        "proc_net_dev": ("TEXT", "network/proc-net-dev.txt", "/proc/net/dev"),
        "appframework": ("COPY", "files/libappframework.so.1.0.0", "/application/lib/libappframework.so.1.0.0"),
        "appmcu": ("COPY", "files/libappmcucommunication.so.1.0.0", "/application/lib/libappmcucommunication.so.1.0.0"),
    }
    seen_fixed: set[str] = set()
    for number, line in enumerate(text.splitlines(), 1):
        fields = line.split("|")
        if len(fields) != 6:
            raise InvalidCapture(f"malformed inventory line {number}")
        label, kind, state, source, size_text, output = fields
        if label in labels or output in outputs or state != "OK" or not source:
            raise InvalidCapture(f"duplicate/invalid inventory line {number}")
        labels.add(label)
        outputs.add(output)
        if not size_text.isdigit():
            raise InvalidCapture(f"invalid inventory size at line {number}")
        if label in fixed:
            expected_kind, expected_output, source_suffix = fixed[label]
            if kind != expected_kind or output != expected_output or not source.endswith(source_suffix):
                raise InvalidCapture(f"invalid fixed inventory row: {label}")
            seen_fixed.add(label)
        else:
            match = re.fullmatch(r"owner_(comm|cmdline|exe|maps)_([1-9][0-9]*)", label)
            if not match or kind != "OWNER":
                raise InvalidCapture(f"unexpected inventory row: {label}")
            owner_kind, pid_text = match.groups()
            pid = int(pid_text)
            suffix = {"comm": "comm.txt", "cmdline": "cmdline.bin", "exe": "exe.txt", "maps": "maps.txt"}[owner_kind]
            source_suffix = f"/{pid}/{owner_kind if owner_kind != 'exe' else 'exe'}"
            if output != f"processes/{pid}-{suffix}" or not source.endswith(source_suffix):
                raise InvalidCapture(f"invalid owner inventory row: {label}")
            owner_kinds.setdefault(pid, set()).add(owner_kind)
        limit = FIXED_LIMITS[output] if output in FIXED_LIMITS else _owner_limit(output)
        path = _safe_regular(root, output, limit)
        if path.stat().st_size != int(size_text):
            raise InvalidCapture(f"inventory size mismatch: {output}")
    if seen_fixed != set(fixed):
        raise InvalidCapture("fixed inventory rows are incomplete")
    for pid, kinds in owner_kinds.items():
        if kinds != {"comm", "cmdline", "exe", "maps"}:
            raise InvalidCapture(f"owner inventory group incomplete: {pid}")
    return outputs, owner_kinds


def _expected_limit(relative: str) -> int:
    return FIXED_LIMITS[relative] if relative in FIXED_LIMITS else _owner_limit(relative)


def _verify_checksums(root: Path, expected: set[str]) -> int:
    text = _read_text(root, "checksums.sha256", FIXED_LIMITS["checksums.sha256"])
    declared: dict[str, str] = {}
    for number, line in enumerate(text.splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\x00]+)", line)
        if not match:
            raise InvalidCapture(f"invalid checksum line {number}")
        digest, relative = match.groups()
        _relative_parts(relative)
        if relative in declared:
            raise InvalidCapture(f"duplicate checksum path: {relative}")
        if relative not in expected:
            raise InvalidCapture(f"unexpected checksum path: {relative}")
        declared[relative] = digest
    missing = expected - set(declared)
    if missing:
        raise InvalidCapture(f"missing checksum coverage: {sorted(missing)}")
    for relative in sorted(expected):
        path = _safe_regular(root, relative, _expected_limit(relative))
        actual = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(65_536), b""):
                actual.update(block)
        if actual.hexdigest() != declared[relative]:
            raise InvalidCapture(f"checksum mismatch: {relative}")
    return len(declared)


def _reject_unexpected_files(root: Path, expected: set[str]) -> None:
    allowed = expected | {"checksums.sha256"}
    found: set[str] = set()
    directories = 0
    files = 0
    for current, names, filenames in os.walk(root, followlinks=False):
        directories += 1
        if directories > 16:
            raise InvalidCapture("capture directory-count limit exceeded")
        current_path = Path(current)
        for name in names:
            metadata = os.lstat(current_path / name)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise InvalidCapture("non-directory or symlink in capture tree")
        for name in filenames:
            files += 1
            if files > 128:
                raise InvalidCapture("capture file-count limit exceeded")
            path = current_path / name
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise InvalidCapture("non-regular or symlink file in capture tree")
            found.add(path.relative_to(root).as_posix())
    if found != allowed:
        raise InvalidCapture(f"capture tree differs from canonical file set: {sorted(found ^ allowed)}")


def _parse_interfaces(text: str) -> dict[str, dict[str, str]]:
    interfaces: dict[str, dict[str, str]] = {}
    for number, line in enumerate(text.splitlines(), 1):
        declaration = re.fullmatch(r"interface=([A-Za-z0-9_.-]+)", line)
        if declaration:
            name = declaration.group(1)
            if name in interfaces or len(interfaces) >= 32:
                raise InvalidCapture(f"duplicate/excess interface declaration: {name}")
            interfaces[name] = {}
            continue
        attribute = re.fullmatch(r"([A-Za-z0-9_.-]+)\.([A-Za-z/]+)=(.*)", line)
        if not attribute:
            raise InvalidCapture(f"malformed interface line {number}")
        name, key, value = attribute.groups()
        if name not in interfaces or key not in INTERFACE_ATTRIBUTES or key in interfaces[name] or len(value.encode()) > 4_096:
            raise InvalidCapture(f"invalid/conflicting interface record at line {number}")
        if key == "type" and not value.strip().isdigit():
            raise InvalidCapture(f"invalid interface type at line {number}")
        interfaces[name][key] = value.strip()
    return interfaces


def _parse_devices(text: str) -> set[str]:
    paths: set[str] = set()
    for number, line in enumerate(text.splitlines(), 1):
        fields = line.split("|")
        if len(fields) != 9:
            raise InvalidCapture(f"malformed device line {number}")
        path, file_type, mode, uid, gid, major, minor, link, sys_link = fields
        if path not in DEVICE_PATHS or path in paths or not file_type or not re.fullmatch(r"[0-7]{3,4}", mode):
            raise InvalidCapture(f"invalid/duplicate device record at line {number}")
        if not uid.isdigit() or not gid.isdigit() or ((major == "-") != (minor == "-")):
            raise InvalidCapture(f"invalid device metadata at line {number}")
        if major != "-" and (not major.isdigit() or not minor.isdigit()):
            raise InvalidCapture(f"invalid device numbers at line {number}")
        if len(link.encode()) > 4_096 or len(sys_link.encode()) > 4_096:
            raise InvalidCapture(f"oversized device link at line {number}")
        paths.add(path)
    return paths


def _parse_owners(text: str, owner_kinds: dict[int, set[str]]) -> set[str]:
    owned_paths: set[str] = set()
    records: set[tuple[int, int, int, str]] = set()
    owner_pids: set[int] = set()
    starts: dict[int, int] = {}
    descriptors: dict[tuple[int, int], tuple[int, str]] = {}
    for number, line in enumerate(text.splitlines(), 1):
        fields = line.split("|")
        if len(fields) != 4:
            raise InvalidCapture(f"malformed owner line {number}")
        pid_text, start_text, fd_text, target = fields
        if not pid_text.isdigit() or not start_text.isdigit() or len(start_text)>20 or not fd_text.isdigit() or target not in DEVICE_PATHS:
            raise InvalidCapture(f"invalid owner record at line {number}")
        pid, start, fd = int(pid_text), int(start_text), int(fd_text)
        record = (pid, start, fd, target)
        if not 1 <= pid <= 4_096 or not 0 <= fd <= 127 or record in records:
            raise InvalidCapture(f"duplicate/out-of-bound owner record at line {number}")
        records.add(record)
        if pid in starts and starts[pid] != start:
            raise InvalidCapture("conflicting PID start times")
        if (pid, fd) in descriptors:
            raise InvalidCapture("conflicting PID/FD identity")
        starts[pid] = start
        descriptors[pid, fd] = (start, target)
        owner_pids.add(pid)
        owned_paths.add(target)
    if len(owner_pids) > 16 or owner_pids != set(owner_kinds):
        raise InvalidCapture("owner records and dynamic inventory groups disagree")
    return owned_paths


def analyze(root: Path) -> dict[str, object]:
    root = _capture_root(root)
    for relative in FIXED_EVIDENCE | {"checksums.sha256"}:
        _safe_regular(root, relative, FIXED_LIMITS[relative])

    inventory_outputs, owner_kinds = _parse_inventory(root)
    expected_checksums = FIXED_EVIDENCE | (inventory_outputs - {
        "network/proc-net-dev.txt",
        "files/libappframework.so.1.0.0",
        "files/libappmcucommunication.so.1.0.0",
    })
    checksum_count = _verify_checksums(root, expected_checksums)
    _reject_unexpected_files(root, expected_checksums)

    status = _parse_exact_kv(
        _read_text(root, "STATUS.txt", FIXED_LIMITS["STATUS.txt"]),
        {"schema", "scope", "status", "mandatory_failures", "optional_findings"},
        "status",
    )
    if status != {
        "schema": "2",
        "scope": "w176-stage4a-can-mcu-topology",
        "status": "COMPLETE",
        "mandatory_failures": "0",
        "optional_findings": status["optional_findings"],
    } or not status["optional_findings"].isdigit():
        raise InvalidCapture("transaction status is not a clean schema-2 COMPLETE")
    if _read_text(root, "COMPLETE", FIXED_LIMITS["COMPLETE"]) != "complete=1\n":
        raise InvalidCapture("invalid COMPLETE marker")
    if _safe_regular(root, "ERRORS.txt", FIXED_LIMITS["ERRORS.txt"]).stat().st_size != 0:
        raise InvalidCapture("ERRORS.txt is not empty")

    capabilities_expected = {
        "schema", "device_streams.opened", "can_frames.received", "can_frames.transmitted",
        "mcu_commands.sent", "logging.capture", "pid.scan.max", "processes.present.max",
        "fd.number.max", "fd_links.total.max", "owners.max", "maps.per_process.bytes.max",
        "maps.total.bytes.max", "interfaces.max", "devices.max", "symlink.bytes.max",
        "libappframework.bytes.max", "libappmcucommunication.bytes.max",
        "libraries.total.bytes.max", "output.final_capture.kib.max", "output.write_ceiling",
        "all_writers.individually_bounded", "application.boundary",
        "process_pid_above_scan_max", "fd_number_above_max",
    }
    capabilities = _parse_exact_kv(
        _read_text(root, "CAPABILITIES.txt", FIXED_LIMITS["CAPABILITIES.txt"]),
        capabilities_expected,
        "capabilities",
    )
    fixed_capabilities = {
        "schema": "3", "device_streams.opened": "0", "can_frames.received": "0",
        "can_frames.transmitted": "0", "mcu_commands.sent": "0", "logging.capture": "DEFERRED",
        "pid.scan.max": "4096", "processes.present.max": "256", "fd.number.max": "127",
        "fd_links.total.max": "4096", "owners.max": "16", "maps.per_process.bytes.max": "65536",
        "maps.total.bytes.max": "524288", "interfaces.max": "32", "devices.max": "18",
        "symlink.bytes.max": "4096", "libappframework.bytes.max": "393216",
        "libappmcucommunication.bytes.max": "327680", "libraries.total.bytes.max": "720896",
        "output.final_capture.kib.max": "2048", "output.write_ceiling": "NOT_CLAIMED",
        "all_writers.individually_bounded": "1", "application.boundary": "effective-mount-exact-squashfs,ro",
        "process_pid_above_scan_max": "NOT_INSPECTED", "fd_number_above_max": "NOT_INSPECTED",
    }
    if capabilities != fixed_capabilities:
        raise InvalidCapture("capabilities do not match the reviewed hard bounds")

    summary = _parse_exact_kv(
        _read_text(root, "SUMMARY.txt", FIXED_LIMITS["SUMMARY.txt"]),
        {"schema", "scope", "interfaces", "device_candidates", "processes_inspected", "fd_links_inspected", "matched_owners", "library_bytes"},
        "summary",
    )
    if summary["schema"] != "2" or summary["scope"] != "w176-stage4a-can-mcu-topology" or any(
        not summary[key].isdigit() for key in set(summary) - {"schema", "scope"}
    ):
        raise InvalidCapture("invalid summary values")

    interfaces = _parse_interfaces(_read_text(root, "network/interfaces.txt", FIXED_LIMITS["network/interfaces.txt"]))
    devices = _parse_devices(_read_text(root, "devices/device-nodes.txt", FIXED_LIMITS["devices/device-nodes.txt"]))
    owned_paths = _parse_owners(_read_text(root, "processes/owners.txt", FIXED_LIMITS["processes/owners.txt"]), owner_kinds)
    counts = {key: int(value) for key, value in summary.items() if key not in {"schema", "scope"}}
    ceilings = {"interfaces": 32, "device_candidates": 18, "processes_inspected": 256,
                "fd_links_inspected": 4096, "matched_owners": 16, "library_bytes": 720896}
    if any(counts[key] > ceiling for key, ceiling in ceilings.items()):
        raise InvalidCapture("summary exceeds reviewed bounds")
    library_bytes = sum(_safe_regular(root, name, limit).stat().st_size for name, limit in LIBRARY_LIMITS.items())
    maps_bytes = sum(_safe_regular(root, f"processes/{pid}-maps.txt", 65536).stat().st_size for pid in owner_kinds)
    if maps_bytes > 524288:
        raise InvalidCapture("aggregate maps exceeds reviewed bound")
    optional_lines = _read_text(root, "OPTIONAL.txt", 65536).splitlines()
    if any(not re.fullmatch(rf"optional\.{index}=.{{1,256}}", line) for index, line in enumerate(optional_lines, 1)):
        raise InvalidCapture("invalid OPTIONAL records")
    if int(status["optional_findings"]) != len(optional_lines):
        raise InvalidCapture("OPTIONAL count conflicts with status")
    if counts["interfaces"] != len(interfaces) or counts["device_candidates"] != len(devices) or counts["matched_owners"] != len(owner_kinds) or counts["library_bytes"] != library_bytes:
        raise InvalidCapture("summary counts conflict with evidence")
    owner_records = len(_read_text(root, "processes/owners.txt", 131072).splitlines())
    if counts["processes_inspected"] < len(owner_kinds) or counts["fd_links_inspected"] < owner_records:
        raise InvalidCapture("scan counts smaller than retained ownership evidence")
    # A copied capture need not preserve FAT allocation units. Logical byte
    # count is an independent lower-bound acceptance check, not du equivalence.
    if sum(_safe_regular(root, name, FIXED_LIMITS[name] if name in FIXED_LIMITS else _owner_limit(name)).stat().st_size
           for name in expected_checksums | {"checksums.sha256"}) > 2048 * 1024:
        raise InvalidCapture("logical final capture exceeds 2048 KiB")

    raw_interfaces = sorted(name for name, attributes in interfaces.items() if attributes.get("type") == "280")
    library_hits: dict[str, list[str]] = {}
    for relative, limit in LIBRARY_LIMITS.items():
        data = _read_bytes(root, relative, limit)
        library_hits[relative] = [value.decode("ascii") for value in INTERESTING_STRINGS if value in data]

    proprietary_paths = sorted(devices & {"/dev/canbox_protocol_dev", "/dev/hc_mcu_dev", "/dev/ttyS1"})
    translation_inference = bool(owned_paths & set(proprietary_paths)) or (bool(proprietary_paths) and any(library_hits.values()))
    if raw_interfaces:
        classification = "CASE A"
        description = "CONFIRMED Linux CAN-type interface; vehicle connection and traffic remain UNKNOWN"
    else:
        classification = "CASE D"
        description = "UNKNOWN architecture; metadata may support an MCU translation-path INFERENCE"

    return {
        "schema": 2,
        "capture_validation": "PASS",
        "integrity_model": "CONSISTENCY_ONLY_NOT_AUTHENTICATION",
        "verified_checksums": checksum_count,
        "classification": classification,
        "description": description,
        "evidence": {
            "linux_can_type_interfaces": {"state": "CONFIRMED" if raw_interfaces else "NOT_OBSERVED", "interfaces": raw_interfaces, "meaning": "ARPHRD_CAN/type 280 only"},
            "physical_mercedes_can_connectivity": "UNKNOWN",
            "can_traffic_presence": "UNKNOWN",
            "can_bitrate": "UNKNOWN",
            "vehicle_message_semantics": "UNKNOWN",
            "mcu_translation_path": "INFERENCE" if translation_inference else "UNKNOWN",
            "candidate_proprietary_paths": proprietary_paths,
            "production_owned_candidate_paths": sorted(owned_paths),
            "library_string_hits": library_hits,
            "library_string_meaning": "CONFIRMED strings in returned installed-library copies; live topology remains INFERENCE/UNKNOWN",
        },
        "case_policy": {
            "CASE_A": "requires checksum-verified interface type 280",
            "CASE_B": "not established by this metadata-only capture",
            "CASE_C": "requires both CASE A and independently confirmed translated semantics; not established here",
            "CASE_D": "used when no Linux CAN-type interface is confirmed",
        },
        "limits": {
            "device_stream_content": "NOT_COLLECTED",
            "can_frames": "NOT_COLLECTED",
            "mcu_commands": "NOT_SENT",
            "pid_above_4096": "NOT_INSPECTED",
            "fd_number_above_127": "NOT_INSPECTED",
            "fd_readlink_identity": "race-reduced but not immutable kernel open-object identity",
            "installed_target_conclusion": "requires provenance showing this capture came from the installed W176",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.capture)
    except (InvalidCapture, OSError, UnicodeError) as exc:
        parser.exit(2, f"invalid Stage-4A capture: {exc}\n")
    output = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
