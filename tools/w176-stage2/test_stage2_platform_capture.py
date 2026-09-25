from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE_DIR = Path(__file__).resolve().parent

COPY_PATHS = {
    "/application/bin/Launcher": "application__bin__Launcher",
    "/application/appinfo.rc": "application__appinfo.rc",
    "/init.rc": "init.rc",
    "/init.platform.rc": "init.platform.rc",
    "/init.gui.rc": "init.gui.rc",
    "/init.environ.rc": "init.environ.rc",
    "/etc/inittab": "etc__inittab",
    "/etc/init.d/rcS": "etc__init.d__rcS",
    "/etc/fstab": "etc__fstab",
    "/etc/mdev.conf": "etc__mdev.conf",
    "/etc/usb_action_8368-U": "etc__usb_action_8368-U",
    "/lib/ld-2.30.so": "lib__ld-2.30.so",
}

HASH_PATHS = {
    "/application/lib/libappframework.so.1.0.0",
    "/application/lib/libappmcucommunication.so.1.0.0",
    "/usr/local/bin/servicemanager",
    "/usr/local/bin/resourcemanager",
    "/usr/local/bin/networkmanager",
    "/usr/local/bin/device_server",
    "/usr/local/bin/pfc_server",
    "/lib/libc-2.30.so",
    "/lib/libstdc++.so.6.0.28",
    "/bin/busybox",
}


class Stage2Fixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.usb = self.root / "usb"
        self.bin = self.root / "bin"
        self.proc = self.root / "proc"
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        self.target = self.root / "target"
        for path in (self.usb, self.bin, self.proc, self.sys / "block/sda", self.dev, self.target):
            path.mkdir(parents=True, exist_ok=True)
        self._install_payload()
        self._install_commands()
        self._write_target()
        self.arm()
        self.set_mounts(("sda1", self.usb, "vfat"))

    def cleanup(self) -> None:
        self.temp.cleanup()

    def _install_payload(self) -> None:
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
            "stage2_platform_capture.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
                "PROCESS_ROOT=/proc": f"PROCESS_ROOT={shlex.quote(str(self.proc / 'process'))}",
                "TARGET_ROOT=": f"TARGET_ROOT={shlex.quote(str(self.target))}",
                "COMMAND_POLL_INTERVAL=1": "COMMAND_POLL_INTERVAL=0.01",
                "COMMAND_RUN_POLLS=5": "COMMAND_RUN_POLLS=20",
                "COMMAND_TERM_POLLS=1": "COMMAND_TERM_POLLS=3",
                "COMMAND_KILL_POLLS=1": "COMMAND_KILL_POLLS=3",
                "SELFTEST_POLL_INTERVAL=1": "SELFTEST_POLL_INTERVAL=0.01",
                "SELFTEST_RUN_POLLS=1": "SELFTEST_RUN_POLLS=1",
                "SELFTEST_TERM_POLLS=1": "SELFTEST_TERM_POLLS=3",
                "SELFTEST_KILL_POLLS=1": "SELFTEST_KILL_POLLS=3",
                "SELFTEST_NATURAL_DELAY=10": "SELFTEST_NATURAL_DELAY=1",
                "observe_owned_child() {": (
                    "observe_owned_child() {\n"
                    "    process_snapshot \"$1\" >/dev/null 2>&1 || true"
                ),
                "run_bounded() {": (
                    "run_bounded() {\n"
                    "    process_self_snapshot >/dev/null 2>&1 || true"
                ),
            },
        }
        for name, substitutions in replacements.items():
            content = (SOURCE_DIR / name).read_text()
            for original, replacement in substitutions.items():
                if content.count(original) != 1:
                    raise AssertionError(f"unexpected production occurrence: {name}: {original}")
                content = content.replace(original, replacement)
            destination = self.usb / name
            destination.write_text(content)
            destination.chmod(0o755)

    def _install_commands(self) -> None:
        for name in (
            "awk", "cat", "cp", "dirname", "mkdir", "mv", "pwd", "readlink",
            "rm", "sed", "sleep", "wc",
        ):
            source = shutil.which(name)
            if not source:
                raise unittest.SkipTest(f"host command unavailable: {name}")
            (self.bin / name).symlink_to(source)
        process_root = self.proc / "process"
        self.write_command(
            "process_self_snapshot",
            f"#!{sys.executable}\n"
            "import os\n"
            f"path = {str(process_root / 'self')!r}\n"
            "os.makedirs(path, exist_ok=True)\n"
            "with open(os.path.join(path, 'stat'), 'w') as stream:\n"
            "    stream.write(f'{os.getppid()} (fixture shell) S\\n')\n",
        )
        self.write_command(
            "process_snapshot",
            f"#!{sys.executable}\n"
            "import os, shutil, sys\n"
            f"root = {str(process_root)!r}\n"
            "pid = int(sys.argv[1])\n"
            "directory = os.path.join(root, str(pid))\n"
            "try:\n"
            "    os.kill(pid, 0)\n"
            "except ProcessLookupError:\n"
            "    shutil.rmtree(directory, ignore_errors=True)\n"
            "    raise SystemExit(0)\n"
            "except PermissionError:\n"
            "    pass\n"
            "os.makedirs(directory, exist_ok=True)\n"
            "fields = ['S', str(os.getppid())] + ['0'] * 17 + [str(pid), '0']\n"
            "with open(os.path.join(directory, 'stat'), 'w') as stream:\n"
            "    stream.write(f'{pid} (fixture command) ' + ' '.join(fields) + '\\n')\n",
        )
        self.write_command(
            "sha256sum",
            f"#!{sys.executable}\n"
            "import hashlib, sys\n"
            "for name in sys.argv[1:]:\n"
            "    with open(name, 'rb') as stream:\n"
            "        digest = hashlib.sha256(stream.read()).hexdigest()\n"
            "    print(f'{digest}  {name}')\n",
        )

    def _write_target(self) -> None:
        for source in [*COPY_PATHS, *HASH_PATHS]:
            path = self.target / source.lstrip("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((f"fixture:{source}\n").encode())
        (self.dev / "sda1").write_text("")
        (self.sys / "block/sda/removable").write_text("1\n")

    def arm(self) -> None:
        (self.usb / "ARM_STAGE2_PLATFORM_CAPTURE").write_text(
            "scope=w176-stage2-platform-v1\n"
        )

    def write_command(self, name: str, content: str) -> None:
        path = self.bin / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_text(content)
        path.chmod(0o755)

    def replace_stage(self, original: str, replacement: str) -> None:
        path = self.usb / "stage2_platform_capture.sh"
        content = path.read_text()
        if content.count(original) != 1:
            raise AssertionError(f"unexpected test literal occurrence: {original}")
        path.write_text(content.replace(original, replacement))

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
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def run_stage(self, root: Path, timeout: int = 10) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", str(self.usb / "stage2_platform_capture.sh"), str(root)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def outputs(self) -> list[Path]:
        return sorted(path for path in self.usb.glob("stage2-platform*") if path.is_dir())

    def fail_mv_to(self, destination: Path, allow: int = 0) -> None:
        real_mv = shutil.which("mv")
        assert real_mv
        counter = self.root / "mv-count"
        self.write_command(
            "mv",
            "#!/bin/sh\n"
            "LAST=\n"
            "for ARG in \"$@\"; do LAST=$ARG; done\n"
            f"if [ \"$LAST\" = {shlex.quote(str(destination.resolve()))} ]; then\n"
            "  COUNT=0\n"
            f"  [ ! -r {shlex.quote(str(counter))} ] || COUNT=$(/bin/cat {shlex.quote(str(counter))})\n"
            "  COUNT=$((COUNT + 1))\n"
            f"  printf '%s\\n' \"$COUNT\" > {shlex.quote(str(counter))}\n"
            f"  [ \"$COUNT\" -le {allow} ] || exit 1\n"
            "fi\n"
            f"exec {shlex.quote(real_mv)} \"$@\"\n",
        )


class Stage2CaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Stage2Fixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def assert_no_complete(self) -> None:
        self.assertFalse(any((path / "COMPLETE").exists() for path in self.fixture.outputs()))

    def test_success_is_transactional_and_whitelist_only(self):
        secret = self.fixture.target / "application/secret-user-data"
        secret.write_text("must-not-copy")
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.fixture.outputs()[-1]
        self.assertIn("status=COMPLETE", (output / "STATUS.txt").read_text())
        self.assertIn("mandatory_failures=0", (output / "STATUS.txt").read_text())
        self.assertEqual((output / "COMPLETE").read_text(), "complete=1\n")
        self.assertFalse((output / "COMPLETE").is_symlink())
        self.assertEqual(
            {path.name for path in (output / "files").iterdir()}, set(COPY_PATHS.values())
        )
        self.assertNotIn("secret-user-data", "\n".join(p.read_text(errors="ignore") for p in output.rglob("*") if p.is_file()))
        checksum_paths = {line.split(None, 1)[1] for line in (output / "checksums.sha256").read_text().splitlines()}
        self.assertEqual(checksum_paths, HASH_PATHS)

    def test_unarmed_payload_does_nothing(self):
        (self.fixture.usb / "ARM_STAGE2_PLATFORM_CAPTURE").unlink()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not armed", result.stderr)
        self.assertEqual(self.fixture.outputs(), [])

    def test_symlink_arm_marker_is_rejected(self):
        marker = self.fixture.usb / "ARM_STAGE2_PLATFORM_CAPTURE"
        marker.unlink()
        marker.symlink_to("ARM_STAGE2_PLATFORM_CAPTURE.example")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])

    def test_zero_and_multiple_usb_candidates_fail(self):
        self.fixture.set_mounts()
        self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        other = self.fixture.root / "other"
        other.mkdir()
        self.fixture.set_mounts(("sda1", self.fixture.usb, "vfat"), ("sdb1", other, "vfat"))
        self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])

    def test_internal_output_fallback_is_rejected(self):
        result = self.fixture.run_stage(self.fixture.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the exact removable mount point", result.stderr)
        self.assert_no_complete()

    def test_missing_mandatory_file_is_incomplete(self):
        (self.fixture.target / "etc/mdev.conf").unlink()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        output = self.fixture.outputs()[-1]
        self.assertIn("mdev:source_validation_2", (output / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_symlink_source_is_rejected(self):
        path = self.fixture.target / "etc/mdev.conf"
        path.unlink()
        path.symlink_to("fstab")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_deliberate_symlink_metadata_is_recorded_without_following(self):
        (self.fixture.target / "media").symlink_to("/tmp/sp/media")
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        links = (self.fixture.outputs()[-1] / "symlinks.txt").read_text()
        self.assertIn("media_link|/media|/tmp/sp/media", links)

    def test_directory_source_is_rejected(self):
        path = self.fixture.target / "etc/mdev.conf"
        path.unlink()
        path.mkdir()
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_oversized_source_is_rejected(self):
        (self.fixture.target / "application/bin/Launcher").write_bytes(b"x" * 262145)
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("launcher:source_validation_6", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_hash_operation_is_bounded(self):
        self.fixture.write_command("sha256sum", "#!/bin/sh\nexec /bin/sleep 30\n")
        result = self.fixture.run_entry(timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hash_failed_or_timed_out", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_hash_output_must_name_the_exact_source(self):
        self.fixture.write_command(
            "sha256sum",
            "#!/bin/sh\n"
            "printf '%064d  %s\\n' 0 /unexpected/path\n",
        )
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hash_output_invalid", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_copy_operation_is_bounded(self):
        self.fixture.write_command("cp", "#!/bin/sh\nexec /bin/sleep 30\n")
        result = self.fixture.run_entry(timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy_failed_or_timed_out", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_fifo_replacement_race_is_bounded(self):
        real_wc = shutil.which("wc")
        assert real_wc
        launcher = self.fixture.target / "application/bin/Launcher"
        self.fixture.write_command(
            "wc",
            "#!/bin/sh\n"
            f"if [ \"$#\" -eq 2 ] && [ \"$2\" = {shlex.quote(str(launcher))} ]; then\n"
            f"  /bin/rm -f {shlex.quote(str(launcher))}\n"
            f"  /usr/bin/mkfifo {shlex.quote(str(launcher))}\n"
            "fi\n"
            f"exec {shlex.quote(real_wc)} \"$@\"\n",
        )
        result = self.fixture.run_entry(timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("launcher:source_validation_4", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_partial_usb_copy_is_not_committed(self):
        self.fixture.write_command(
            "cp",
            "#!/bin/sh\n"
            "printf partial > \"$2\"\n"
            "exit 1\n",
        )
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        output = self.fixture.outputs()[-1]
        self.assert_no_complete()
        self.assertFalse((output / "files/application__bin__Launcher").exists())

    def test_manifest_commit_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage2-platform/capture-inventory.txt"
        self.fixture.fail_mv_to(destination)
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_final_status_failure_has_no_complete(self):
        destination = self.fixture.usb / "stage2-platform/STATUS.txt"
        self.fixture.fail_mv_to(destination, allow=1)
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_total_capture_size_limit_fails_closed(self):
        self.fixture.replace_stage("MAX_TOTAL_CAPTURE_BYTES=1048576", "MAX_TOTAL_CAPTURE_BYTES=100")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capture_total_limit_exceeded", (self.fixture.outputs()[-1] / "ERRORS.txt").read_text())
        self.assert_no_complete()

    def test_unexpected_target_layout_fails_safely(self):
        shutil.rmtree(self.fixture.target / "application")
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_existing_output_is_not_reused(self):
        (self.fixture.usb / "stage2-platform").mkdir()
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.fixture.usb / "stage2-platform-1/COMPLETE").is_file())

    def test_production_source_has_no_broad_or_sensitive_access(self):
        stage = (SOURCE_DIR / "stage2_platform_capture.sh").read_text()
        for forbidden in ("/dev/mtd", "/dev/mem", "/media/flash/nvm", "find ", "cp -r", "cp -R"):
            self.assertNotIn(forbidden, stage)
        for path in [*COPY_PATHS, *HASH_PATHS]:
            self.assertEqual(stage.count(f" {path} "), 1)
        self.assertNotIn("W176_STAGE2_TEST", stage)
        self.assertNotIn("timeout -k", stage)
        self.assertEqual(stage.count('"$@" &'), 1)


if __name__ == "__main__":
    unittest.main()
