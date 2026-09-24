from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SOURCE_DIR = Path(__file__).resolve().parent


class ProbeFixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.usb = self.root / "usb"
        self.bin = self.root / "bin"
        self.proc = self.root / "proc"
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        self.internal = self.root / "internal"
        for path in (
            self.usb,
            self.bin,
            self.proc / "bus/input",
            self.sys / "block/sda",
            self.sys / "class/graphics/fb0",
            self.dev,
            self.internal / "dev/input",
            self.internal / "application/bin",
            self.internal / "usr/local/bin",
        ):
            path.mkdir(parents=True, exist_ok=True)
        for name in ("gemn_auto.sh", "stage1_probe.sh", "mount_guard.sh"):
            shutil.copy2(SOURCE_DIR / name, self.usb / name)
        self._install_commands()
        self._write_target_data()
        self.set_mounts(("sda1", self.usb, "vfat"))
        self.env = {
            **os.environ,
            "W176_PROBE_TEST_MODE": "1",
            "W176_TEST_PATH": str(self.bin),
            "W176_TEST_MOUNTS_FILE": str(self.proc / "mounts"),
            "W176_TEST_SYS_BLOCK_ROOT": str(self.sys / "block"),
            "W176_TEST_DEV_ROOT": str(self.dev),
            "W176_TEST_PROC_ROOT": str(self.proc),
            "W176_TEST_SYS_ROOT": str(self.sys),
            "W176_TEST_INTERNAL_ROOT": str(self.internal),
            "W176_TEST_TIMEOUT_SECONDS": "1",
        }

    def cleanup(self) -> None:
        try:
            self.usb.chmod(0o755)
        except OSError:
            pass
        self.temp.cleanup()

    def _install_commands(self) -> None:
        for name in ("awk", "cat", "cp", "dirname", "ls", "mkdir", "mv", "pwd", "sed", "uname", "wc"):
            source = shutil.which(name)
            if not source:
                raise unittest.SkipTest(f"host command unavailable: {name}")
            (self.bin / name).symlink_to(source)
        self.write_command("ps", "#!/bin/sh\nprintf '%s\\n' 'PID COMMAND' '1 init'\n")
        self.write_command(
            "timeout",
            f"""#!{sys.executable}
import subprocess
import sys

seconds = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:])
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    process.kill()
    process.wait()
    raise SystemExit(124)
""",
        )
        self.write_command(
            "sha256sum",
            f"""#!{sys.executable}
import hashlib
import sys

for name in sys.argv[1:]:
    with open(name, "rb") as stream:
        digest = hashlib.sha256(stream.read()).hexdigest()
    print(f"{{digest}}  {{name}}")
""",
        )

    def write_command(self, name: str, content: str) -> None:
        path = self.bin / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_text(content)
        path.chmod(0o755)

    def _write_target_data(self) -> None:
        (self.dev / "sda1").write_text("")
        (self.sys / "block/sda/removable").write_text("1\n")
        (self.proc / "cpuinfo").write_text("Hardware\t: GEMINI\n")
        (self.proc / "mtd").write_text('mtd12: 00800000 00020000 "nvm"\n')
        (self.proc / "cmdline").write_text("console=ttyS0\n")
        (self.proc / "bus/input/devices").write_text('N: Name="fts_ts"\nH: Handlers=event3\n\n')
        for name, value in (
            ("virtual_size", "1920,1440\n"),
            ("bits_per_pixel", "32\n"),
            ("stride", "7680\n"),
            ("name", "fb0\n"),
        ):
            (self.sys / "class/graphics/fb0" / name).write_text(value)

    def set_mounts(self, *mounts: tuple[str, Path, str]) -> None:
        lines = []
        for device, mount, filesystem in mounts:
            disk = device.rstrip("0123456789")
            (self.dev / device).touch()
            removable = self.sys / "block" / disk / "removable"
            removable.parent.mkdir(parents=True, exist_ok=True)
            removable.write_text("1\n")
            lines.append(f"/dev/{device} {mount.resolve()} {filesystem} rw 0 0")
        (self.proc / "mounts").write_text("\n".join(lines) + ("\n" if lines else ""))

    def run_entry(self, timeout: int = 10) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", str(self.usb / "gemn_auto.sh")],
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def run_stage(self, root: Path, timeout: int = 10) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", str(self.usb / "stage1_probe.sh"), str(root)],
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def outputs(self) -> list[Path]:
        return sorted(path for path in self.usb.glob("stage1-probe*") if path.is_dir())


class Stage1ProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ProbeFixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def assert_no_complete(self) -> None:
        self.assertFalse(any((path / "COMPLETE").exists() for path in self.fixture.outputs()))

    def test_absent_usb_is_rejected(self):
        self.fixture.set_mounts()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)
        self.assert_no_complete()

    def test_multiple_usb_mounts_are_rejected(self):
        other = self.fixture.root / "other-usb"
        other.mkdir()
        self.fixture.set_mounts(("sda1", self.fixture.usb, "vfat"), ("sdb1", other, "vfat"))
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)
        self.assert_no_complete()

    def test_wrong_filesystem_is_rejected(self):
        self.fixture.set_mounts(("sda1", self.fixture.usb, "ext4"))
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not approved", result.stderr)
        self.assert_no_complete()

    def test_non_removable_device_is_rejected(self):
        self.fixture.set_mounts(("sda1", self.fixture.usb, "vfat"))
        (self.fixture.sys / "block/sda/removable").write_text("0\n")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)
        self.assert_no_complete()

    def test_malformed_mount_table_is_rejected(self):
        (self.fixture.proc / "mounts").write_text("not a valid mount record\n")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)
        self.assert_no_complete()

    def test_arbitrary_internal_output_path_is_rejected(self):
        result = self.fixture.run_stage(self.fixture.internal)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the exact removable mount point", result.stderr)
        self.assert_no_complete()

    def test_read_only_output_is_rejected(self):
        self.fixture.usb.chmod(0o555)
        result = self.fixture.run_entry()
        self.fixture.usb.chmod(0o755)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_full_output_filesystem_is_rejected(self):
        self.fixture.write_command("mkdir", "#!/bin/sh\nexit 1\n")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot create output directory", result.stderr)
        self.assert_no_complete()

    def test_existing_output_directories_are_not_reused(self):
        (self.fixture.usb / "stage1-probe").mkdir()
        (self.fixture.usb / "stage1-probe-1").mkdir()
        result = self.fixture.run_entry()
        output = self.fixture.usb / "stage1-probe-2"
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / "STATUS.txt").read_text().splitlines()[1], "status=COMPLETE")
        self.assertTrue((output / "COMPLETE").is_file())

    def test_output_directory_enumeration_is_bounded(self):
        for index in range(100):
            name = "stage1-probe" if index == 0 else f"stage1-probe-{index}"
            (self.fixture.usb / name).mkdir()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output directory limit reached", result.stderr)
        self.assertEqual(len(self.fixture.outputs()), 100)

    def test_missing_command_records_incomplete(self):
        (self.fixture.bin / "ps").unlink()
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("missing_command:ps", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_special_and_symlink_appinfo_are_skipped(self):
        appinfo_dir = self.fixture.internal / "application/etc"
        appinfo_dir.mkdir(parents=True)
        target = self.fixture.internal / "real-appinfo.rc"
        target.write_text("GEMINI\n")
        (appinfo_dir / "appinfo.rc").symlink_to(target)
        handler_target = self.fixture.internal / "real-usb-handler"
        handler_target.write_text("handler\n")
        (self.fixture.internal / "application/bin/specialusb").symlink_to(handler_target)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / "appinfo.rc").exists())
        self.assertIn("non_regular_or_symlink", (output / "OPTIONAL.txt").read_text())
        self.assertEqual((output / "usb-handlers.sha256").read_text(), "")
        self.assertTrue((output / "COMPLETE").exists())

        (appinfo_dir / "appinfo.rc").unlink()
        os.mkfifo(appinfo_dir / "appinfo.rc")
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / "appinfo.rc").exists())
        self.assertIn("non_regular_or_symlink", (output / "OPTIONAL.txt").read_text())
        self.assertTrue((output / "COMPLETE").exists())

    def test_regular_appinfo_and_handler_are_collected(self):
        appinfo_dir = self.fixture.internal / "application/etc"
        appinfo_dir.mkdir(parents=True)
        (appinfo_dir / "appinfo.rc").write_text("GEMINI\n")
        handler = self.fixture.internal / "application/bin/usb-handler"
        handler.write_text("handler\n")
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / "appinfo.rc").read_text(), "GEMINI\n")
        self.assertIn(str(handler), (output / "usb-handler-candidates.txt").read_text())
        self.assertIn(str(handler), (output / "usb-handlers.sha256").read_text())
        self.assertTrue((output / "COMPLETE").exists())

    def test_hanging_optional_operation_times_out(self):
        self.fixture.write_command("fbset", "#!/bin/sh\n/bin/sleep 30\n")
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 6)
        self.assertIn("fbset=SKIPPED:failed_or_timed_out", (output / "OPTIONAL.txt").read_text())
        self.assertTrue((output / "COMPLETE").exists())

    def test_hanging_handler_enumeration_times_out(self):
        real_ls = shutil.which("ls")
        assert real_ls is not None
        hanging_directory = self.fixture.internal / "usr/local/bin"
        self.fixture.write_command(
            "ls",
            "#!/bin/sh\n"
            f"if [ \"$#\" -eq 2 ] && [ \"$1\" = -1 ] && [ \"$2\" = {shlex.quote(str(hanging_directory))} ]; then\n"
            "    /bin/sleep 30\n"
            "    exit 1\n"
            "fi\n"
            f"exec {shlex.quote(real_ls)} \"$@\"\n",
        )
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 6)
        self.assertIn(
            f"usb_handlers:{hanging_directory}=SKIPPED:enumeration_failed_or_timed_out",
            (output / "OPTIONAL.txt").read_text(),
        )
        self.assertTrue((output / "COMPLETE").exists())

    def test_hanging_handler_hash_times_out(self):
        (self.fixture.internal / "application/bin/usb-handler").write_text("handler\n")
        self.fixture.write_command("sha256sum", "#!/bin/sh\n/bin/sleep 30\n")
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 6)
        self.assertIn("hash_failed_or_timed_out", (output / "OPTIONAL.txt").read_text())
        self.assertEqual((output / "usb-handlers.sha256").read_text(), "")
        self.assertTrue((output / "COMPLETE").exists())

    def test_hanging_appinfo_copy_times_out(self):
        appinfo_dir = self.fixture.internal / "application/etc"
        appinfo_dir.mkdir(parents=True)
        (appinfo_dir / "appinfo.rc").write_text("GEMINI\n")
        self.fixture.write_command("cp", "#!/bin/sh\nexec /bin/sleep 30\n")
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 6)
        self.assertIn("copy_failed_or_timed_out", (output / "OPTIONAL.txt").read_text())
        self.assertFalse((output / "appinfo.rc").exists())
        self.assertTrue((output / "COMPLETE").exists())

    def test_hanging_mandatory_collection_is_incomplete(self):
        real_cat = shutil.which("cat")
        assert real_cat is not None
        hanging_file = self.fixture.proc / "mtd"
        self.fixture.write_command(
            "cat",
            "#!/bin/sh\n"
            f"if [ \"$#\" -eq 1 ] && [ \"$1\" = {shlex.quote(str(hanging_file))} ]; then\n"
            "    /bin/sleep 30\n"
            "    exit 1\n"
            "fi\n"
            f"exec {shlex.quote(real_cat)} \"$@\"\n",
        )
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 6)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("mtd:collection_failed_or_timed_out", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_optional_manifest_write_failure_is_incomplete(self):
        optional_file = self.fixture.usb / "stage1-probe/OPTIONAL.txt"
        self.fixture.write_command(
            "ps",
            "#!/bin/sh\n"
            f"/bin/chmod 0444 {shlex.quote(str(optional_file))}\n"
            "printf '%s\\n' 'PID COMMAND' '1 init'\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        optional_file.chmod(0o644)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("cannot_write_optional_manifest", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_mandatory_failure_never_creates_complete_marker(self):
        (self.fixture.proc / "mtd").unlink()
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("mtd:collection_failed_or_timed_out", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())


if __name__ == "__main__":
    unittest.main()
