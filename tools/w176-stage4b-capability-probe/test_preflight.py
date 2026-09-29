"""Disposable Linux fixtures; no RoadTop binaries or device streams."""

import gzip
import hashlib
import array
import fcntl
import os
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time
import unittest
from pathlib import Path

from analyze import InvalidCapture, analyze

HERE = Path(__file__).resolve().parent


def synthetic_arm_libc(names, undefined=(), hidden=()):
    data = bytearray(1024)
    data[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into("<H", data, 16, 3)
    struct.pack_into("<H", data, 18, 40)
    struct.pack_into("<I", data, 20, 1)
    struct.pack_into("<I", data, 28, 52)
    struct.pack_into("<I", data, 32, 768)
    struct.pack_into("<HHH", data, 40, 52, 32, 2)
    struct.pack_into("<HH", data, 46, 40, 4)
    strings = b"\0libc.so.6\0"
    offsets = []
    for name in names:
        offsets.append(len(strings))
        strings += name.encode() + b"\0"
    data[256:256 + len(strings)] = strings
    struct.pack_into("<IIIIIIII", data, 52, 1, 0, 0, 0, 1024, 1024, 5, 4096)
    struct.pack_into("<IIIIIIII", data, 84, 2, 640, 640, 640, 48, 48, 4, 4)
    for index, (tag, value) in enumerate(((5, 256), (6, 384), (10, len(strings)),
                                          (11, 16), (14, 1), (0, 0))):
        struct.pack_into("<II", data, 640 + index * 8, tag, value)
    for index, offset in enumerate(offsets, 1):
        struct.pack_into("<I", data, 384 + index * 16, offset)
        struct.pack_into("<BBH", data, 384 + index * 16 + 12,
                         18, 2 if names[index - 1] in hidden else 0,
                         0 if names[index - 1] in undefined else 3)
    struct.pack_into("<IIIIII", data, 808, 0, 3, 0, 256, 256, len(strings))
    struct.pack_into("<IIIIII", data, 848, 0, 11, 0, 384, 384, (len(names) + 1) * 16)
    struct.pack_into("<I", data, 848 + 24, 1)
    struct.pack_into("<I", data, 848 + 36, 16)
    struct.pack_into("<IIIIII", data, 888, 0, 1, 0, 0, 512, 16)
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

    def install_real_guard_fixture(self):
        """Use actual guard code with finite synthetic device/mount metadata."""
        mount_table = self.base / "usb-mounts"
        info_table = self.base / "usb-mountinfo"
        sys_block = self.base / "usb-sys/block/sdz"
        dev_root = self.base / "usb-dev"
        sys_block.mkdir(parents=True)
        (sys_block / "removable").write_text("1\n")
        dev_root.mkdir()
        (dev_root / "sdz9").write_text("")
        mount_table.write_text(f"/dev/sdz9 {self.payload} vfat rw 0 0\n")
        dev = self.payload.stat().st_dev
        info_table.write_text(f"31 20 {os.major(dev)}:{os.minor(dev)} / "
                              f"{self.payload} rw - vfat /dev/sdz9 rw\n")
        source = (HERE / "payload/mount_guard.sh").read_text()
        source = source.replace("MOUNTS_FILE=/proc/mounts", f"MOUNTS_FILE={mount_table}")
        source = source.replace("MOUNTINFO_FILE=/proc/self/mountinfo",
                                f"MOUNTINFO_FILE={info_table}")
        source = source.replace("SYS_BLOCK_ROOT=/sys/block",
                                f"SYS_BLOCK_ROOT={sys_block.parent}")
        source = source.replace("DEV_ROOT=/dev", f"DEV_ROOT={dev_root}")
        source = source.replace("DEVICE_TEST=-b", "DEVICE_TEST=-e")
        (self.payload / "mount_guard.sh").write_text(source)
        return mount_table, info_table

    def rehash(self, root):
        entries = []
        for line in (root / "checksums.sha256").read_text().splitlines():
            name = line.split("  ", 1)[1]
            digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
            entries.append(f"{digest}  {name}\n")
        (root / "checksums.sha256").write_text("".join(entries))

    def coherent_nvm(self, root):
        path = root / "metadata/objects.txt"
        lines = path.read_text().splitlines()
        output = []
        for line in lines:
            if line.startswith("media.link|"):
                line = "media.link|/tmp/sp/media/"
            elif line.startswith("nvm|"):
                fields = line.split("|")
                fields[2] = str(os.makedev(31, 12))
                line = "|".join(fields)
            elif line.startswith("mtdblock12|"):
                line = "mtdblock12|block special file|1|2|6000|0|600|1f|c"
            elif line.startswith("class_block|"):
                line = "class_block|symbolic link|1|4|a000|30|777|0|0"
            output.append(line)
        output += ["sys_dev_block|symbolic link|1|3|a000|30|777|0|0",
                   "sys_dev_block.link|../../devices/virtual/block/mtdblock12",
                   "class_block.link|../../devices/virtual/block/mtdblock12"]
        path.write_text("\n".join(output) + "\n")
        self.rehash(root)
        return root

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
        self.assertEqual(result["NVM_MOUNT_PRESENTATION"], "CONTRADICTORY")
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

    def test_real_guard_integration_before_first_mutation(self):
        mount_table, _ = self.install_real_guard_fixture()
        with mount_table.open("a") as handle:
            handle.write(f"tmpfs {self.payload} tmpfs rw 0 0\n")
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.payload / ".stage4b-capability.lock").exists())
        self.assertTrue((self.payload / "ARM_STAGE4B_CAPABILITY_PREFLIGHT").exists())

    def test_real_guard_integration_complete(self):
        self.install_real_guard_fixture()
        self.assertEqual(analyze(self.capture())["CAPTURE"], "COMPLETE")

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

    # Independent NO-GO reproductions. These are intentionally asserted as
    # safe outcomes, so they fail against the frozen 0f65de8 implementation.
    def test_review_nvm_wrong_mountinfo_device_is_not_confirmed(self):
        self.put("proc/self/mountinfo",
                 b"31 20 99:12 / /tmp/sp/media/flash/nvm rw,noatime - yaffs2 /dev/mtdblock12 rw,noatime\n")
        self.assertNotEqual(analyze(self.capture())["NVM_MOUNT_PRESENTATION"], "CONFIRMED")

    def test_review_fully_coherent_nvm_is_confirmed(self):
        self.assertEqual(analyze(self.coherent_nvm(self.capture()))["NVM_MOUNT_PRESENTATION"],
                         "CONFIRMED")

    def test_review_nvm_contradiction_matrix(self):
        cases = (
            ("mount_major_minor", "mounts/mountinfo.txt", b"31:12", b"99:12"),
            ("mount_source", "mounts/proc-mounts.txt", b"/dev/mtdblock12", b"/dev/mtdblock11"),
            ("mtd_number", "mounts/proc-mtd.txt", b"mtd12:", b"mtd11:"),
            ("mtd_name", "mounts/proc-mtd.txt", b'"nvm"', b'"other"'),
            ("mtd_size", "mounts/proc-mtd.txt", b"00800000", b"00400000"),
            ("sysfs_dev", "metadata/mtd12-dev.txt", b"90:24", b"90:22"),
            ("sysfs_name", "metadata/mtd12-name.txt", b"nvm", b"other"),
            ("sysfs_size", "metadata/mtd12-size.txt", b"8388608", b"4194304"),
            ("sysfs_erase", "metadata/mtd12-erasesize.txt", b"131072", b"65536"),
            ("block_node_minor", "metadata/objects.txt", b"|1f|c\n", b"|1f|b\n"),
            ("media_link", "metadata/objects.txt", b"media.link|/tmp/sp/media/",
             b"media.link|/tmp/other/"),
            ("sysfs_block_link", "metadata/objects.txt",
             b"class_block.link|../../devices/virtual/block/mtdblock12",
             b"class_block.link|../../devices/virtual/block/mtdblock11"),
        )
        for label, file, old, new in cases:
            with self.subTest(label=label):
                root = self.coherent_nvm(self.capture())
                path = root / file
                path.write_bytes(path.read_bytes().replace(old, new))
                self.rehash(root)
                self.assertEqual(analyze(root)["NVM_MOUNT_PRESENTATION"], "CONTRADICTORY")
                self.setUp()

    def test_review_nvm_missing_association_is_partial(self):
        root = self.coherent_nvm(self.capture())
        path = root / "metadata/objects.txt"
        path.write_text("\n".join(row for row in path.read_text().splitlines()
                                  if not row.startswith("sys_dev_block")) + "\n")
        self.rehash(root)
        self.assertEqual(analyze(root)["NVM_MOUNT_PRESENTATION"], "PARTIAL")

    def test_review_nvm_missing_sysfs_attribute_is_partial(self):
        (self.sys / "class/mtd/mtd12/name").unlink()
        root = self.coherent_nvm(self.capture())
        self.assertEqual(analyze(root)["NVM_MOUNT_PRESENTATION"], "PARTIAL")

    def test_second_review_malformed_mtd_type_cannot_confirm(self):
        root = self.coherent_nvm(self.capture())
        (root / "metadata/mtd12-type.txt").write_text("not-a-valid-mtd-type\n")
        self.rehash(root)
        self.assertEqual(analyze(root)["NVM_MOUNT_PRESENTATION"], "CONTRADICTORY")

    def test_second_review_mtd_type_missing_or_other_family(self):
        (self.sys / "class/mtd/mtd12/type").unlink()
        self.assertEqual(analyze(self.coherent_nvm(self.capture()))["NVM_MOUNT_PRESENTATION"],
                         "PARTIAL")
        self.setUp()
        (self.sys / "class/mtd/mtd12/type").write_text("nor\n")
        self.assertEqual(analyze(self.coherent_nvm(self.capture()))["NVM_MOUNT_PRESENTATION"],
                         "PARTIAL")

    def test_second_review_collector_association_read_options(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        log = self.base / "dd.log"
        wrapper = bin_dir / "dd"
        wrapper.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{log}"\n'
                           'exec /usr/bin/dd "$@"\n')
        wrapper.chmod(0o755)
        script = self.payload / "capability_probe.sh"
        script.write_text(script.read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"PATH={bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin", 1))
        self.capture()
        calls = log.read_text().splitlines()
        for source, count in ((self.proc / "self/mounts", 65537),
                              (self.proc / "self/mountinfo", 131073),
                              (self.proc / "mtd", 16385),
                              (self.sys / "class/mtd/mtd12/type", 4097)):
            with self.subTest(source=source):
                self.assertTrue(any(f"if={source}" in call and "bs=1" in call
                                    and f"count={count}" in call for call in calls))

    def test_review_undefined_libc_import_is_not_wrapper(self):
        self.put("lib/libc-2.30.so",
                 synthetic_arm_libc(("memfd_create",), undefined=("memfd_create",)))
        self.assertNotEqual(analyze(self.capture())["TARGET_LIBC_WRAPPER_MEMFD_CREATE"],
                            "OBSERVED")

    def test_review_hidden_and_missing_libc_export(self):
        self.put("lib/libc-2.30.so",
                 synthetic_arm_libc(("memfd_create",), hidden=("memfd_create",)))
        self.assertEqual(analyze(self.capture())["TARGET_LIBC_WRAPPER_MEMFD_CREATE"],
                         "NOT_OBSERVED")
        self.setUp()
        self.put("lib/libc-2.30.so", synthetic_arm_libc(("fexecve",)))
        self.assertEqual(analyze(self.capture())["TARGET_LIBC_WRAPPER_MEMFD_CREATE"],
                         "NOT_OBSERVED")

    def test_second_review_et_rel_is_not_runtime_libc(self):
        image = bytearray(synthetic_arm_libc(("memfd_create",)))
        struct.pack_into("<H", image, 16, 1)  # ET_REL
        self.put("lib/libc-2.30.so", image)
        self.assertNotEqual(analyze(self.capture())["TARGET_LIBC_WRAPPER_MEMFD_CREATE"],
                            "OBSERVED")

    def test_second_review_shared_image_structure_matrix(self):
        wrappers = ("memfd_create", "execveat", "fexecve")
        for name in wrappers:
            with self.subTest(wrapper=name):
                self.setUp()
                self.put("lib/libc-2.30.so", synthetic_arm_libc((name,)))
                self.assertEqual(analyze(self.capture())[f"TARGET_LIBC_WRAPPER_{name.upper()}"],
                                 "OBSERVED")
                for offset, fmt, value in ((16, "<H", 1), (16, "<H", 2),
                                           (44, "<H", 0), (84, "<I", 0),
                                           (640 + 4 * 8, "<I", 999)):
                    self.setUp()
                    image = bytearray(synthetic_arm_libc((name,)))
                    struct.pack_into(fmt, image, offset, value)
                    self.put("lib/libc-2.30.so", image)
                    self.assertEqual(
                        analyze(self.capture())[f"TARGET_LIBC_WRAPPER_{name.upper()}"],
                        "UNKNOWN", (name, offset, value))

    def test_second_review_all_wrapper_export_semantics(self):
        for name in ("memfd_create", "execveat", "fexecve"):
            with self.subTest(wrapper=name):
                for label, kwargs in (("undefined", {"undefined": (name,)}),
                                      ("hidden", {"hidden": (name,)})):
                    self.setUp()
                    self.put("lib/libc-2.30.so", synthetic_arm_libc((name,), **kwargs))
                    self.assertEqual(
                        analyze(self.capture())[f"TARGET_LIBC_WRAPPER_{name.upper()}"],
                        "NOT_OBSERVED", (name, label))
                self.setUp()
                self.put("lib/libc-2.30.so", synthetic_arm_libc(()))
                self.assertEqual(analyze(self.capture())[f"TARGET_LIBC_WRAPPER_{name.upper()}"],
                                 "NOT_OBSERVED")

    def test_review_out_of_scope_libc_link_is_unknown(self):
        link = self.target / "lib/libc.so.6"
        link.unlink()
        link.symlink_to("../other/libc.so")
        self.assertEqual(analyze(self.capture())["TARGET_LIBC_WRAPPER_MEMFD_CREATE"],
                         "UNKNOWN")

    def test_review_truncated_kallsyms_fake_is_not_positive(self):
        tail = b"00000000 T SyS_memfd_create"
        pad = b"x\n" * ((524288 - len(tail)) // 2)
        pad += b"\n" * (524288 - len(pad) - len(tail))
        self.put("proc/kallsyms", pad + tail + b"_fake\n")
        root = self.capture()
        self.assertNotIn("SyS_memfd_create",
                         (root / "kernel/symbol-names.txt").read_text().splitlines())

    def test_review_kallsyms_complete_boundary_and_truncation(self):
        line = b"00000000 T SyS_memfd_create\n"
        padding = b"x\n" * ((524288 - len(line)) // 2)
        padding += b"\n" * (524288 - len(padding) - len(line))
        self.put("proc/kallsyms", padding + line)
        root = self.capture()
        self.assertIn("SyS_memfd_create",
                      (root / "kernel/symbol-names.txt").read_text().splitlines())
        self.setUp()
        self.put("proc/kallsyms", padding + line + b"x\n")
        root = self.capture()
        self.assertIn("SyS_memfd_create",
                      (root / "kernel/symbol-names.txt").read_text().splitlines())
        self.assertIn("kallsyms:truncated_prefix", (root / "OPTIONAL.txt").read_text())

    def test_review_kallsyms_final_incomplete_and_restricted(self):
        self.put("proc/kallsyms", b"00000000 T SyS_memfd_create")
        root = self.capture()
        self.assertEqual((root / "kernel/symbol-names.txt").read_text(), "")
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")
        self.setUp()
        self.put("proc/kallsyms", b"")
        root = self.capture()
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")
        self.setUp()
        path = self.proc / "kallsyms"
        path.unlink()
        path.symlink_to("/etc/passwd")
        root = self.capture()
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")

    def test_review_kallsyms_filter_output_limit_is_optional_unknown(self):
        self.put("proc/kallsyms", b"00000000 T SyS_memfd_create\n" * 5000)
        root = self.capture()
        self.assertNotIn("kernel/symbol-names.txt", (root / "INVENTORY.txt").read_text())
        self.assertFalse((root / "kernel/symbol-names.txt").exists())
        self.assertIn("kallsyms:filter_or_limit", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(analyze(root)["TARGET_MEMFD_SUPPORT"], "UNKNOWN")


class FrozenMountGuardReproduction(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="stage4b-guard-review-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.usb = self.base / "usb"
        self.usb.mkdir()
        self.table = self.base / "mounts"
        self.info = self.base / "mountinfo"
        self.sys = self.base / "sys"
        self.dev = self.base / "dev"
        (self.sys / "sda").mkdir(parents=True)
        (self.sys / "sda/removable").write_text("1\n")
        self.dev.mkdir()
        (self.dev / "sda1").write_text("")
        self.script = self.base / "mount_guard.sh"
        source = (HERE / "payload/mount_guard.sh").read_text()
        source = source.replace("MOUNTS_FILE=/proc/mounts", f"MOUNTS_FILE={self.table}")
        source = source.replace("MOUNTINFO_FILE=/proc/self/mountinfo",
                                f"MOUNTINFO_FILE={self.info}")
        source = source.replace("SYS_BLOCK_ROOT=/sys/block", f"SYS_BLOCK_ROOT={self.sys}")
        source = source.replace("DEV_ROOT=/dev", f"DEV_ROOT={self.dev}")
        source = source.replace("DEVICE_TEST=-b", "DEVICE_TEST=-e")
        self.script.write_text(source)
        self.table.write_text(f"/dev/sda1 {self.usb} vfat rw 0 0\n")
        dev = self.usb.stat().st_dev
        self.info.write_text(f"31 20 {os.major(dev)}:{os.minor(dev)} / {self.usb} rw - vfat /dev/sda1 rw\n")

    def run_guard(self):
        return subprocess.run(["/bin/sh", str(self.script), str(self.usb)],
                              cwd=self.usb, capture_output=True, text=True, timeout=5)

    def stream_short_reads(self, target, chunks):
        """Native FIFO sends one consumed short record per read call."""
        target.unlink()
        os.mkfifo(target)
        errors = []

        def writer():
            try:
                fd = os.open(target, os.O_WRONLY)
                try:
                    for chunk in chunks:
                        try:
                            os.write(fd, chunk.encode())
                        except BrokenPipeError:
                            break  # Frozen dd may stop after count short blocks.
                        deadline = time.monotonic() + 2
                        while True:
                            queued = array.array("i", [0])
                            fcntl.ioctl(fd, termios.FIONREAD, queued, True)
                            if queued[0] == 0:
                                break
                            if time.monotonic() > deadline:
                                raise TimeoutError("FIFO reader did not consume record")
                            time.sleep(0.001)
                        time.sleep(0.006)
                finally:
                    os.close(fd)
            except Exception as exc:
                errors.append(exc)

        thread = threading.Thread(target=writer, daemon=True)
        thread.start()
        result = self.run_guard()
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive(), "FIFO writer stuck")
        self.assertEqual(errors, [])
        return result

    def test_second_review_later_short_read_overmount_is_rejected(self):
        chunks = [f"/dev/sda1 {self.usb} vfat rw 0 0\n"]
        chunks += [f"tmpfs /unused{i} tmpfs rw 0 0\n" for i in range(16)]
        chunks += [f"tmpfs {self.usb} tmpfs rw 0 0\n"]
        self.assertNotEqual(self.stream_short_reads(self.table, chunks).returncode, 0)

    def test_second_review_later_short_read_mountinfo_overmount_is_rejected(self):
        chunks = [self.info.read_text()]
        chunks += [f"{40+i} 20 0:99 / /unused{i} rw - tmpfs tmpfs rw\n"
                   for i in range(32)]
        chunks += [f"99 31 0:100 / {self.usb} rw - tmpfs tmpfs rw\n"]
        self.assertNotEqual(self.stream_short_reads(self.info, chunks).returncode, 0)

    def test_second_review_complete_short_read_streams_pass(self):
        chunks = [f"/dev/sda1 {self.usb} vfat rw 0 0\n"]
        chunks += [f"tmpfs /unused{i} tmpfs rw 0 0\n" for i in range(16)]
        self.assertEqual(self.stream_short_reads(self.table, chunks).returncode, 0)
        self.setUp()
        chunks = [self.info.read_text()]
        chunks += [f"{40+i} 20 0:99 / /unused{i} rw - tmpfs tmpfs rw\n"
                   for i in range(32)]
        self.assertEqual(self.stream_short_reads(self.info, chunks).returncode, 0)

    def test_second_review_short_read_incomplete_final_record_rejected(self):
        chunks = [f"/dev/sda1 {self.usb} vfat rw 0 0\n", "tmpfs /unterminated"]
        self.assertNotEqual(self.stream_short_reads(self.table, chunks).returncode, 0)

    def test_review_stacked_mount_is_rejected(self):
        with self.table.open("a") as handle:
            handle.write(f"tmpfs {self.usb} tmpfs rw 0 0\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_valid_mount_identity_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_deeper_covering_mount_is_rejected(self):
        with self.info.open("a") as handle:
            handle.write(f"32 31 0:99 / {self.usb}/stage4b-capability rw - tmpfs tmpfs rw\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_underlying_fat_but_effective_wrong_fs_is_rejected(self):
        with self.info.open("a") as handle:
            handle.write(f"32 31 0:99 / {self.usb} rw - tmpfs tmpfs rw\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_wrong_fs_and_source_are_rejected(self):
        self.table.write_text(f"/dev/sda1 {self.usb} ext4 rw 0 0\n")
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.table.write_text(f"/dev/mtdblock12 {self.usb} vfat rw 0 0\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_contradictory_readonly_mount_view_is_rejected(self):
        self.table.write_text(f"/dev/sda1 {self.usb} vfat ro 0 0\n")
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.table.write_text(f"/dev/sda1 {self.usb} vfat rw 0 0\n")
        self.info.write_text(self.info.read_text().replace(" rw - vfat", " ro - vfat"))
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_duplicate_mount_records_are_rejected(self):
        with self.table.open("a") as handle:
            handle.write(self.table.read_text())
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_symlink_root_is_rejected(self):
        link = self.base / "usb-link"
        link.symlink_to(self.usb)
        result = subprocess.run(["/bin/sh", str(self.script), str(link)],
                                cwd=self.usb, capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_mount_views_are_rejected(self):
        self.info.write_text("broken\n")
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.info.write_text("31 20 1:2 / /foo rw - vfat /dev/sda1 rw\n")
        self.table.write_text("broken\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_exact_mount_table_limit_passes_and_plus_one_fails(self):
        lines = [f"/dev/sda1 {self.usb} vfat rw 0 0\n"]
        lines += [f"tmpfs /unused{i} tmpfs rw 0 0\n" for i in range(31)]
        table = "".join(line.rstrip("\n").ljust(2047) + "\n" for line in lines)
        self.assertEqual(len(table), 65536)
        self.table.write_text(table)
        self.assertEqual(self.run_guard().returncode, 0)
        self.table.write_text(table + "x")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_exact_mountinfo_limit_passes_and_plus_one_fails(self):
        dev = self.usb.stat().st_dev
        lines = [f"31 20 {os.major(dev)}:{os.minor(dev)} / {self.usb} rw - vfat /dev/sda1 rw\n"]
        lines += [f"{32+i} 20 0:99 / /unused{i} rw - tmpfs tmpfs rw\n"
                  for i in range(63)]
        table = "".join(line.rstrip("\n").ljust(2047) + "\n" for line in lines)
        self.assertEqual(len(table), 131072)
        self.info.write_text(table)
        self.assertEqual(self.run_guard().returncode, 0)
        self.info.write_text(table + "x")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_excessive_records_and_long_line_are_rejected(self):
        self.table.write_text(f"/dev/sda1 {self.usb} vfat rw 0 0\n" +
                              "tmpfs /unused tmpfs rw 0 0\n" * 256)
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.table.write_text(f"/dev/sda1 {self.usb} vfat rw 0 0\n" +
                              "tmpfs /unused tmpfs rw 0 0".ljust(2049) + "\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_mountinfo_excessive_records_and_long_line_are_rejected(self):
        original = self.info.read_text()
        self.info.write_text(original + "40 20 0:99 / /unused rw - tmpfs tmpfs rw\n" * 256)
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.info.write_text(original +
                             "40 20 0:99 / /unused rw - tmpfs tmpfs rw".ljust(2049) + "\n")
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_guard_producer_nonzero_after_plausible_data(self):
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "dd"
        wrapper.write_text(
            '#!/bin/sh\ncase "$*" in *mounts*) printf "/dev/sda1 '
            f'{self.usb} vfat rw 0 0\\n"; exit 7;; esac\n'
            'exec /usr/bin/dd "$@"\n')
        wrapper.chmod(0o755)
        self.script.write_text(self.script.read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin",
            f"PATH={bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin", 1))
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_review_oversized_mount_table_is_rejected(self):
        with self.table.open("a") as handle:
            handle.write("tmpfs /x tmpfs rw 0 0\n" * 10000)
        self.assertNotEqual(self.run_guard().returncode, 0)


if __name__ == "__main__":
    unittest.main()
