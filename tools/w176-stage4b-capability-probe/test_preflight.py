"""Disposable Linux fixtures; no RoadTop binaries or device streams."""

import gzip
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from analyze import InvalidCapture, analyze

HERE = Path(__file__).resolve().parent


def synthetic_arm_libc(names):
    data = bytearray(1024)
    data[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into("<H", data, 16, 3)
    struct.pack_into("<H", data, 18, 40)
    struct.pack_into("<I", data, 32, 768)
    struct.pack_into("<HH", data, 46, 40, 3)
    strings = b"\0"
    offsets = []
    for name in names:
        offsets.append(len(strings))
        strings += name.encode() + b"\0"
    data[256:256 + len(strings)] = strings
    for index, offset in enumerate(offsets, 1):
        struct.pack_into("<I", data, 384 + index * 16, offset)
    struct.pack_into("<IIIIII", data, 808, 0, 3, 0, 0, 256, len(strings))
    struct.pack_into("<IIIIII", data, 848, 0, 11, 0, 0, 384, (len(names) + 1) * 16)
    struct.pack_into("<I", data, 848 + 24, 1)
    struct.pack_into("<I", data, 848 + 36, 16)
    return bytes(data)


class PreflightFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stage4b-capability-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.payload = self.base / "usb"
        shutil.copytree(HERE / "payload", self.payload)
        (self.payload / "mount_guard.sh").write_text(
            '#!/bin/sh\ncd -P "$1" && pwd -P\n', encoding="ascii")
        script = self.payload / "capability_probe.sh"
        source = script.read_text()
        self.target = self.base / "target"
        self.proc = self.target / "proc"
        self.sys = self.target / "sys"
        self.dev = self.target / "dev"
        source = source.replace("ROOT=\n", f"ROOT={self.target}\n", 1)
        source = source.replace("PROC=/proc\n", f"PROC={self.proc}\n", 1)
        source = source.replace("SYS=/sys\n", f"SYS={self.sys}\n", 1)
        source = source.replace("DEV=/dev\n", f"DEV={self.dev}\n", 1)
        script.write_text(source)
        self.put("proc/version", b"Linux version 4.9.217 (fixture)\n")
        self.put("proc/sys/kernel/osrelease", b"4.9.217\n")
        self.put("proc/filesystems", b"nodev\ttmpfs\nnodev\tproc\n")
        self.put("proc/self/mounts",
                 (f"rootfs {self.target} squashfs ro 0 0\n"
                  f"/dev/mtdblock12 /tmp/sp/media/flash/nvm yaffs2 rw,noatime 0 0\n").encode())
        self.put("proc/self/mountinfo",
                 b"31 20 31:12 / /tmp/sp/media/flash/nvm rw,noatime - yaffs2 /dev/mtdblock12 rw,noatime\n")
        self.put("proc/mtd", b'mtd12: 00800000 00020000 "nvm"\n')
        self.put("proc/config.gz", gzip.compress(b"CONFIG_TMPFS=y\nCONFIG_PROC_FS=y\n"))
        self.put("proc/kallsyms", b"00000000 T SyS_memfd_create\n"
                 b"00000000 T shmem_add_seals\n00000000 T shmem_get_seals\n"
                 b"00000000 T SyS_execveat\n")
        for name, value in (("name", b"nvm\n"), ("type", b"nand\n"),
                            ("size", b"8388608\n"), ("erasesize", b"131072\n"),
                            ("dev", b"90:24\n")):
            self.put(f"sys/class/mtd/mtd12/{name}", value)
        self.put("lib/libc-2.30.so", synthetic_arm_libc(("memfd_create", "fexecve")))
        self.put("lib/ld-2.30.so", b"fixture loader")
        self.target.joinpath("tmp/sp/media/flash/nvm").mkdir(parents=True)
        self.target.joinpath("media").symlink_to("tmp/sp/media")
        self.target.joinpath("lib/libc.so.6").symlink_to("libc-2.30.so")
        self.target.joinpath("lib/ld-linux-armhf.so.3").symlink_to("ld-2.30.so")
        (self.payload / "ARM_STAGE4B_CAPABILITY_PREFLIGHT").write_text("arm\n")

    def put(self, relative, data):
        path = self.target / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def run_probe(self):
        return subprocess.run(["/bin/sh", str(self.payload / "capability_probe.sh"),
                               str(self.payload)], capture_output=True, text=True,
                              timeout=20)

    def capture(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.payload / "stage4b-capability"

    def rehash(self, root):
        entries = []
        for line in (root / "checksums.sha256").read_text().splitlines():
            name = line.split("  ", 1)[1]
            digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
            entries.append(f"{digest}  {name}\n")
        (root / "checksums.sha256").write_text("".join(entries))

    def test_complete_metadata_never_proves_execution(self):
        root = self.capture()
        result = analyze(root)
        self.assertEqual(result["CAPTURE"], "COMPLETE")
        self.assertEqual(result["TARGET_MEMFD_SUPPORT"], "SUPPORTED_BY_METADATA")
        self.assertEqual(result["TARGET_SEALING_SUPPORT"], "SUPPORTED_BY_METADATA")
        self.assertEqual(result["TARGET_EXECVEAT_SUPPORT"], "SUPPORTED_BY_METADATA")
        self.assertEqual(result["TARGET_LIBC_WRAPPER_MEMFD_CREATE"], "OBSERVED",
                         (root / "OPTIONAL.txt").read_text())
        self.assertEqual(result["TARGET_LIBC_WRAPPER_EXECVEAT"], "NOT_OBSERVED")
        self.assertEqual(result["NVM_MOUNT_PRESENTATION"], "CONFIRMED")
        self.assertEqual(result["SEALED_RUNTIME_EXECUTION"], "NOT_TESTED")
        self.assertEqual(result["EXECUTION_HIGH"], "OPEN")
        self.assertFalse((self.payload / "ARM_STAGE4B_CAPABILITY_PREFLIGHT").exists())
        self.assertTrue((self.payload / ".stage4b-capability.lock").is_dir())
        self.assertNotIn("00000000", (self.payload / "stage4b-capability/kernel/symbol-names.txt").read_text())

    def test_missing_optional_config_is_complete_unknown(self):
        (self.proc / "config.gz").unlink()
        root = self.capture()
        result = analyze(root)
        self.assertEqual(result["TARGET_MEMFD_SUPPORT"], "UNKNOWN")
        self.assertEqual(result["SEALED_RUNTIME_EXECUTION"], "NOT_TESTED")

    def test_conflicting_config_sources_cannot_support_feature(self):
        self.put("boot/config-4.9.217", b"# CONFIG_TMPFS is not set\nCONFIG_PROC_FS=y\n")
        result = analyze(self.capture())
        self.assertEqual(result["TARGET_MEMFD_SUPPORT"], "UNKNOWN")
        self.assertEqual(result["TARGET_SEALING_SUPPORT"], "UNKNOWN")

    def test_unreadable_config_symlink_never_followed(self):
        source = self.proc / "config.gz"
        source.unlink()
        source.symlink_to("/etc/passwd")
        root = self.capture()
        self.assertNotIn("kernel/proc-config.gz", (root / "INVENTORY.txt").read_text())
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")

    def test_oversized_optional_and_mandatory(self):
        (self.proc / "config.gz").write_bytes(b"x" * 262145)
        self.assertEqual(analyze(self.capture())["TARGET_MEMFD_SUPPORT"], "UNKNOWN")
        # Fresh second fixture is used because the lock must be retained.
        self.setUp()
        (self.proc / "version").write_bytes(b"x" * 8193)
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        root = self.payload / "stage4b-capability"
        self.assertFalse((root / "COMPLETE").exists())
        self.assertIn("status=INCOMPLETE", (root / "STATUS.txt").read_text())

    def test_false_complete(self):
        root = self.capture()
        (root / "STATUS.txt").write_text((root / "STATUS.txt").read_text().replace(
            "status=COMPLETE", "status=INCOMPLETE"))
        self.rehash(root)
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_checksum_inventory_and_symlink(self):
        root = self.capture()
        (root / "kernel/uname.txt").write_text("changed\n")
        with self.assertRaises(InvalidCapture):
            analyze(root)
        self.rehash(root)
        (root / "INVENTORY.txt").write_text((root / "INVENTORY.txt").read_text()
                                            + "kernel/uname.txt\n")
        self.rehash(root)
        with self.assertRaises(InvalidCapture):
            analyze(root)
        (root / "kernel/uname.txt").unlink()
        (root / "kernel/uname.txt").symlink_to("/etc/passwd")
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_malformed_duplicate_status(self):
        root = self.capture()
        with (root / "STATUS.txt").open("a") as handle:
            handle.write("status=COMPLETE\n")
        self.rehash(root)
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_guard_failure_precedes_lock(self):
        (self.payload / "mount_guard.sh").write_text("#!/bin/sh\nexit 9\n")
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.payload / ".stage4b-capability.lock").exists())
        self.assertTrue((self.payload / "ARM_STAGE4B_CAPABILITY_PREFLIGHT").exists())

    def test_nonzero_uname_with_plausible_output_fails(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "uname"
        wrapper.write_text("#!/bin/sh\nprintf 'Linux fixture armv7l\\n'\nexit 7\n")
        wrapper.chmod(0o755)
        script = self.payload / "capability_probe.sh"
        source = script.read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"PATH={bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin", 1)
        script.write_text(source)
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        root = self.payload / "stage4b-capability"
        self.assertFalse((root / "COMPLETE").exists())

    def test_nonzero_dd_with_plausible_output_fails(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "dd"
        wrapper.write_text(
            '#!/bin/sh\n'
            'case "$*" in *proc/version*)\n'
            '  for arg do case "$arg" in of=*) output=${arg#of=};; esac; done\n'
            '  printf "Linux version 4.9.217\\n" > "$output"\n'
            '  exit 7;;\n'
            'esac\n'
            'exec /usr/bin/dd "$@"\n')
        wrapper.chmod(0o755)
        script = self.payload / "capability_probe.sh"
        script.write_text(script.read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"PATH={bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin", 1))
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.payload / "stage4b-capability/COMPLETE").exists())

    def test_optional_config_read_failure_is_unknown(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "dd"
        wrapper.write_text(
            '#!/bin/sh\n'
            'case "$*" in *proc/config.gz*) exit 7;; esac\n'
            'exec /usr/bin/dd "$@"\n')
        wrapper.chmod(0o755)
        script = self.payload / "capability_probe.sh"
        script.write_text(script.read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"PATH={bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin", 1))
        root = self.capture()
        self.assertIn("proc_config:producer_failed", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")

    def test_root_mount_guard_rejects_nested_rw_and_special_source(self):
        guard = self.payload / "root_mount_guard.sh"
        source = self.target / "lib/libc-2.30.so"
        table = self.proc / "self/mounts"
        args = ["/bin/sh", str(guard), str(source), str(self.target), str(table)]
        self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
        original = table.read_text()
        table.write_text(original + f"tmpfs {self.target}/lib tmpfs rw 0 0\n")
        self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
        table.write_text(original.replace("squashfs ro", "squashfs rw"))
        self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
        table.write_text(original)
        source.unlink()
        os.mkfifo(source)
        self.assertNotEqual(subprocess.run(args, capture_output=True, timeout=2).returncode, 0)

    def test_malformed_optional_and_unparseable_libc(self):
        (self.target / "lib/libc-2.30.so").write_bytes(b"not an ELF")
        root = self.capture()
        self.assertEqual(analyze(root)["TARGET_LIBC_WRAPPER_MEMFD_CREATE"], "UNKNOWN")
        with (root / "OPTIONAL.txt").open("a") as stream:
            stream.write("optional.1=duplicate\n")
        self.rehash(root)
        with self.assertRaises(InvalidCapture):
            analyze(root)


if __name__ == "__main__":
    unittest.main()
