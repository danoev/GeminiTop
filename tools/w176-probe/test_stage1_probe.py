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
        self._install_test_payload()
        self._install_commands()
        self._write_target_data()
        self.set_mounts(("sda1", self.usb, "vfat"))
        self.env = {**os.environ}

    def cleanup(self) -> None:
        try:
            self.usb.chmod(0o755)
        except OSError:
            pass
        self.temp.cleanup()

    def _install_test_payload(self) -> None:
        replacements = {
            "gemn_auto.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
            },
            "mount_guard.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
                "MOUNTS_FILE=/proc/mounts": f"MOUNTS_FILE={shlex.quote(str(self.proc / 'mounts'))}",
                "SYS_BLOCK_ROOT=/sys/block": f"SYS_BLOCK_ROOT={shlex.quote(str(self.sys / 'block'))}",
                "DEV_ROOT=/dev": f"DEV_ROOT={shlex.quote(str(self.dev))}",
                "DEVICE_TEST=-b": "DEVICE_TEST=-e",
            },
            "stage1_probe.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
                "PROC_ROOT=/proc": f"PROC_ROOT={shlex.quote(str(self.proc))}",
                "SYS_ROOT=/sys": f"SYS_ROOT={shlex.quote(str(self.sys))}",
                "INTERNAL_ROOT=": f"INTERNAL_ROOT={shlex.quote(str(self.internal))}",
                "COMMAND_TIMEOUT=5": "COMMAND_TIMEOUT=1",
                "COMMAND_KILL_GRACE=1": "COMMAND_KILL_GRACE=0.2",
            },
        }
        for name, substitutions in replacements.items():
            source = SOURCE_DIR / name
            content = source.read_text()
            for original, replacement in substitutions.items():
                if content.count(original) != 1:
                    raise AssertionError(f"unexpected production constant occurrence: {name}: {original}")
                content = content.replace(original, replacement)
            destination = self.usb / name
            destination.write_text(content)
            destination.chmod(source.stat().st_mode & 0o777)

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
import os
import signal
import subprocess
import sys

if len(sys.argv) < 5 or sys.argv[1] != "-k":
    raise SystemExit(125)
kill_grace = float(sys.argv[2])
seconds = float(sys.argv[3])
process = subprocess.Popen(sys.argv[4:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=kill_grace)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
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

    def fail_mv_to(self, destination: Path, allow_matches: int = 0) -> None:
        real_mv = shutil.which("mv")
        if not real_mv:
            raise unittest.SkipTest("host command unavailable: mv")
        destination = destination.resolve()
        counter = self.root / "mv-match-count"
        self.write_command(
            "mv",
            "#!/bin/sh\n"
            "LAST=\n"
            "for ARG in \"$@\"; do LAST=$ARG; done\n"
            f"if [ \"$LAST\" = {shlex.quote(str(destination))} ]; then\n"
            "    COUNT=0\n"
            f"    [ ! -r {shlex.quote(str(counter))} ] || COUNT=$(/bin/cat {shlex.quote(str(counter))})\n"
            "    COUNT=$((COUNT + 1))\n"
            f"    printf '%s\\n' \"$COUNT\" > {shlex.quote(str(counter))}\n"
            f"    [ \"$COUNT\" -le {allow_matches} ] || exit 1\n"
            "fi\n"
            f"exec {shlex.quote(real_mv)} \"$@\"\n",
        )

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

    def test_deployable_scripts_have_no_runtime_test_mode(self):
        for name in ("gemn_auto.sh", "mount_guard.sh", "stage1_probe.sh"):
            content = (SOURCE_DIR / name).read_text()
            self.assertNotIn("W176_PROBE_TEST_MODE", content)
            self.assertNotIn("W176_TEST_", content)
        guard = (SOURCE_DIR / "mount_guard.sh").read_text()
        self.assertIn("MOUNTS_FILE=/proc/mounts", guard)
        self.assertIn("SYS_BLOCK_ROOT=/sys/block", guard)
        self.assertIn("DEV_ROOT=/dev", guard)
        self.assertIn("DEVICE_TEST=-b", guard)

    def test_inherited_test_mode_does_not_redirect_deployable_guard(self):
        environment = {
            **os.environ,
            "W176_PROBE_TEST_MODE": "1",
            "W176_TEST_PATH": str(self.fixture.bin),
            "W176_TEST_MOUNTS_FILE": str(self.fixture.proc / "mounts"),
            "W176_TEST_SYS_BLOCK_ROOT": str(self.fixture.sys / "block"),
            "W176_TEST_DEV_ROOT": str(self.fixture.dev),
        }
        result = subprocess.run(
            ["/bin/sh", str(SOURCE_DIR / "mount_guard.sh"), str(self.fixture.usb)],
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.stdout.strip(), str(self.fixture.usb.resolve()))

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

    def test_unexpected_device_name_is_rejected(self):
        self.fixture.set_mounts(("nvme0n1", self.fixture.usb, "vfat"))
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)
        self.assert_no_complete()

    def test_regular_file_cannot_substitute_for_block_device(self):
        guard = self.fixture.usb / "mount_guard.sh"
        content = guard.read_text()
        self.assertEqual(content.count("DEVICE_TEST=-e"), 1)
        guard.write_text(content.replace("DEVICE_TEST=-e", "DEVICE_TEST=-b"))
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 0", result.stderr)
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

    def test_missing_mount_metadata_is_rejected(self):
        (self.fixture.proc / "mounts").unlink()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mount table is unavailable", result.stderr)
        self.assert_no_complete()

    def test_arbitrary_internal_output_path_is_rejected(self):
        result = self.fixture.run_stage(self.fixture.internal)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the exact removable mount point", result.stderr)
        self.assert_no_complete()

    def test_direct_invocation_from_usb_subdirectory_is_rejected(self):
        subdirectory = self.fixture.usb / "payload"
        subdirectory.mkdir()
        result = self.fixture.run_stage(subdirectory)
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
        self.assertFalse((output / "COMPLETE").is_symlink())

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

    def test_missing_hard_timeout_fails_closed(self):
        (self.fixture.bin / "timeout").unlink()
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("missing_hard_timeout:TERM_then_KILL", (output / "ERRORS.txt").read_text())
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

    def test_term_ignoring_child_is_killed(self):
        pid_file = self.fixture.root / "term-ignoring.pid"
        self.fixture.write_command(
            "fbset",
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$$\" > {shlex.quote(str(pid_file))}\n"
            "trap '' TERM\n"
            "while :; do :; done\n",
        )
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 4)
        self.assertIn("fbset=SKIPPED:failed_or_timed_out", (output / "OPTIONAL.txt").read_text())
        pid = int(pid_file.read_text().strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertTrue((output / "COMPLETE").is_file())
        self.assertFalse((output / "COMPLETE").is_symlink())

    def test_fifo_replacement_open_is_inside_timeout(self):
        appinfo_dir = self.fixture.internal / "application/etc"
        appinfo_dir.mkdir(parents=True)
        candidate = appinfo_dir / "appinfo.rc"
        candidate.write_text("GEMINI\n")
        real_wc = shutil.which("wc")
        if not real_wc:
            self.skipTest("host command unavailable: wc")
        self.fixture.write_command(
            "wc",
            "#!/bin/sh\n"
            f"if [ \"$#\" -eq 2 ] && [ \"$1\" = -c ] && [ \"$2\" = {shlex.quote(str(candidate))} ]; then\n"
            f"    /bin/rm -f {shlex.quote(str(candidate))}\n"
            f"    /usr/bin/mkfifo {shlex.quote(str(candidate))}\n"
            "fi\n"
            f"exec {shlex.quote(real_wc)} \"$@\"\n",
        )
        started = time.monotonic()
        result = self.fixture.run_entry(timeout=8)
        elapsed = time.monotonic() - started
        output = self.fixture.outputs()[-1]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 4)
        self.assertIn("size_check_failed", (output / "OPTIONAL.txt").read_text())
        self.assertFalse((output / "appinfo.rc").exists())
        self.assertTrue((output / "COMPLETE").is_file())

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
        optional_work = self.fixture.usb / "stage1-probe/.OPTIONAL.txt.work"
        self.fixture.write_command(
            "ps",
            "#!/bin/sh\n"
            f"/bin/chmod 0444 {shlex.quote(str(optional_work))}\n"
            "printf '%s\\n' 'PID COMMAND' '1 init'\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        optional_file = output / "OPTIONAL.txt"
        if optional_file.exists():
            optional_file.chmod(0o644)
        elif optional_work.exists():
            optional_work.chmod(0o644)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("cannot_write_optional_manifest", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_error_manifest_append_failure_is_incomplete(self):
        error_work = self.fixture.usb / "stage1-probe/.ERRORS.txt.work"
        self.fixture.write_command(
            "uname",
            "#!/bin/sh\n"
            f"/bin/chmod 0444 {shlex.quote(str(error_work))}\n"
            "printf '%s\\n' 'Linux test 1.0'\n",
        )
        (self.fixture.proc / "mtd").unlink()
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        committed_error = output / "ERRORS.txt"
        if committed_error.exists():
            committed_error.chmod(0o644)
        elif error_work.exists():
            error_work.chmod(0o644)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_summary_finalization_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage1-probe/stage1-summary.txt"
        self.fixture.fail_mv_to(destination)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("summary:cannot_write_output", (output / "ERRORS.txt").read_text())
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_summary_write_failure_has_no_complete(self):
        summary_temp = self.fixture.usb / "stage1-probe/.stage1-summary.txt.tmp"
        self.fixture.write_command(
            "ps",
            "#!/bin/sh\n"
            f"/bin/mkdir {shlex.quote(str(summary_temp))}\n"
            "printf '%s\\n' 'PID COMMAND' '1 init'\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("summary:cannot_write_output", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_readme_finalization_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage1-probe/README.txt"
        self.fixture.fail_mv_to(destination)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("readme:cannot_write_output", (output / "ERRORS.txt").read_text())
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_readme_write_failure_has_no_complete(self):
        readme_temp = self.fixture.usb / "stage1-probe/.README.txt.tmp"
        self.fixture.write_command(
            "ps",
            "#!/bin/sh\n"
            f"/bin/mkdir {shlex.quote(str(readme_temp))}\n"
            "printf '%s\\n' 'PID COMMAND' '1 init'\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("readme:cannot_write_output", (output / "ERRORS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_mandatory_output_finalization_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage1-probe/mtd.txt"
        self.fixture.fail_mv_to(destination)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mtd:cannot_commit_output", (output / "ERRORS.txt").read_text())
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_final_complete_status_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage1-probe/STATUS.txt"
        self.fixture.fail_mv_to(destination, allow_matches=1)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_initial_status_write_failure_has_no_complete(self):
        real_mkdir = shutil.which("mkdir")
        if not real_mkdir:
            self.skipTest("host command unavailable: mkdir")
        self.fixture.write_command(
            "mkdir",
            "#!/bin/sh\n"
            f"{shlex.quote(real_mkdir)} \"$@\" || exit 1\n"
            "LAST=\n"
            "for ARG in \"$@\"; do LAST=$ARG; done\n"
            'case "$LAST" in *stage1-probe) /bin/mkdir "$LAST/.STATUS.txt.tmp" ;; esac\n',
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((output / "COMPLETE").exists())

    def test_complete_rename_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage1-probe/COMPLETE"
        self.fixture.fail_mv_to(destination)
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_complete_temp_write_failure_has_no_complete(self):
        complete_temp = self.fixture.usb / "stage1-probe/.COMPLETE.tmp"
        self.fixture.write_command(
            "ps",
            "#!/bin/sh\n"
            f"/bin/mkdir {shlex.quote(str(complete_temp))}\n"
            "printf '%s\\n' 'PID COMMAND' '1 init'\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())

    def test_symlink_complete_is_rejected_and_quarantined(self):
        destination = (self.fixture.usb / "stage1-probe/COMPLETE").resolve()
        real_mv = shutil.which("mv")
        if not real_mv:
            self.skipTest("host command unavailable: mv")
        self.fixture.write_command(
            "mv",
            "#!/bin/sh\n"
            "LAST=\n"
            "for ARG in \"$@\"; do LAST=$ARG; done\n"
            f"if [ \"$LAST\" = {shlex.quote(str(destination))} ]; then\n"
            "    /bin/ln -s \"$1\" \"$LAST\"\n"
            "    exit 0\n"
            "fi\n"
            f"exec {shlex.quote(real_mv)} \"$@\"\n",
        )
        result = self.fixture.run_entry()
        output = self.fixture.outputs()[-1]
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status=INCOMPLETE", (output / "STATUS.txt").read_text())
        self.assertFalse((output / "COMPLETE").exists())
        self.assertTrue((output / ".COMPLETE.invalid").is_symlink())

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
