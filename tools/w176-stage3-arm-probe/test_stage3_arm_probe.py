from __future__ import annotations

import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE_DIR = Path(__file__).resolve().parent
PAYLOAD_DIR = SOURCE_DIR / "payload"
EXPECTED_STDOUT = (
    "schema=1\n"
    "probe=w176-arm-loadability\n"
    "started=1\n"
    "result=PASS\n"
)


class Stage3Fixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.usb = self.root / "usb"
        self.bin = self.root / "bin"
        self.proc = self.root / "proc"
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        for path in (self.usb, self.bin, self.proc, self.sys / "block/sda", self.dev):
            path.mkdir(parents=True, exist_ok=True)
        self._install_payload()
        self._install_commands()
        self.set_stub(f"#!/bin/sh\nprintf '%s' {shlex.quote(EXPECTED_STDOUT)}\n")
        self.arm()
        self.set_mounts(("sda1", self.usb, "vfat", "1"))

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
            "stage3_arm_probe.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
                "PROCESS_ROOT=/proc": f"PROCESS_ROOT={shlex.quote(str(self.proc / 'process'))}",
                "FD_ROOT=/proc/self/fd": "FD_ROOT=/dev/fd",
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
        for name in ("gemn_auto.sh", "mount_guard.sh", "stage3_arm_probe.sh"):
            content = (PAYLOAD_DIR / name).read_text()
            for original, replacement in replacements[name].items():
                if content.count(original) != 1:
                    raise AssertionError(f"unexpected production occurrence: {name}: {original}")
                content = content.replace(original, replacement)
            destination = self.usb / name
            destination.write_text(content)
            destination.chmod(0o755)
        shutil.copy2(
            PAYLOAD_DIR / "ARM_STAGE3_ARM_EXECUTION_PROBE.example",
            self.usb / "ARM_STAGE3_ARM_EXECUTION_PROBE.example",
        )

    def _install_commands(self) -> None:
        for name in (
            "awk", "chmod", "cmp", "cp", "dd", "dirname", "mkdir", "mv",
            "pwd", "rm", "sed", "sleep"
        ):
            source = shutil.which(name)
            if not source:
                raise unittest.SkipTest(f"host command unavailable: {name}")
            (self.bin / name).symlink_to(source)
        self.write_command(
            "stat",
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "args = sys.argv[1:]\n"
            "if len(args) != 4 or args[0] != '-L' or args[1] != '-c':\n"
            "    raise SystemExit(2)\n"
            "fmt, path = args[2], args[3]\n"
            "if path.startswith('/dev/fd/'):\n"
            "    value = os.fstat(int(path.rsplit('/', 1)[1]))\n"
            "else:\n"
            "    value = os.stat(path)\n"
            "mapping = {\n"
            "    '%d': str(value.st_dev), '%i': str(value.st_ino),\n"
            "    '%f': format(value.st_mode, 'x'), '%s': str(value.st_size),\n"
            "    '%Y': str(int(value.st_mtime)), '%Z': str(int(value.st_ctime)),\n"
            "}\n"
            "for key, replacement in mapping.items():\n"
            "    fmt = fmt.replace(key, replacement)\n"
            "print(fmt)\n",
        )
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

    def write_command(self, name: str, content: str) -> None:
        path = self.bin / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_text(content)
        path.chmod(0o755)

    def arm(self) -> None:
        (self.usb / "ARM_STAGE3_ARM_EXECUTION_PROBE").write_text("armed\n")

    def set_stub(self, content: str) -> None:
        binary = self.usb / "arm_probe"
        if binary.exists() or binary.is_symlink():
            binary.unlink()
        binary.write_text(content)
        binary.chmod(0o755)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        size = binary.stat().st_size
        stage = self.usb / "stage3_arm_probe.sh"
        text = stage.read_text()
        text = self._replace_assignment(text, "EXPECTED_BINARY_SHA256", digest)
        text = self._replace_assignment(text, "EXPECTED_BINARY_SIZE", str(size))
        stage.write_text(text)

    @staticmethod
    def _replace_assignment(content: str, key: str, value: str) -> str:
        lines = content.splitlines(keepends=True)
        matches = [index for index, line in enumerate(lines) if line.startswith(f"{key}=")]
        if len(matches) != 1:
            raise AssertionError(key)
        lines[matches[0]] = f"{key}={value}\n"
        return "".join(lines)

    def replace_stage(self, original: str, replacement: str) -> None:
        stage = self.usb / "stage3_arm_probe.sh"
        content = stage.read_text()
        if content.count(original) != 1:
            raise AssertionError(original)
        stage.write_text(content.replace(original, replacement))

    def set_mounts(self, *mounts: tuple[str, Path, str, str]) -> None:
        lines = []
        for device, mount, filesystem, removable_value in mounts:
            disk = device.rstrip("0123456789")
            (self.dev / device).touch()
            removable = self.sys / "block" / disk / "removable"
            removable.parent.mkdir(parents=True, exist_ok=True)
            removable.write_text(removable_value + "\n")
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
            ["/bin/sh", str(self.usb / "stage3_arm_probe.sh"), str(root)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def outputs(self) -> list[Path]:
        return sorted(path for path in self.usb.glob("stage3-arm-probe*") if path.is_dir())

    def fail_mv_to(self, destination: Path, allow: int = 0) -> None:
        real_mv = shutil.which("mv")
        assert real_mv
        counter = self.root / "mv-count"
        self.write_command(
            "mv",
            f"#!{sys.executable}\n"
            "import os, pathlib, sys\n"
            f"destination = {str(destination.resolve())!r}\n"
            f"counter = pathlib.Path({str(counter)!r})\n"
            "last = os.path.abspath(sys.argv[-1])\n"
            "if last == destination:\n"
            "    count = int(counter.read_text()) if counter.exists() else 0\n"
            "    count += 1\n"
            "    counter.write_text(str(count))\n"
            f"    if count > {allow}: raise SystemExit(1)\n"
            f"os.execv({real_mv!r}, [{real_mv!r}, *sys.argv[1:]])\n",
        )

    def install_process_override(self, trigger: Path, mode: str) -> None:
        real = self.bin / "process_snapshot.real"
        (self.bin / "process_snapshot").rename(real)
        process_root = self.proc / "process"
        if mode == "unknown":
            writer = "stream.write('malformed\\n')"
        elif mode == "replaced":
            writer = (
                "fields = ['S', '999999'] + ['0'] * 17 + ['1', '0']\n"
                "        stream.write(f'{pid} (replaced) ' + ' '.join(fields) + '\\n')"
            )
        else:
            raise AssertionError(mode)
        self.write_command(
            "process_snapshot",
            f"#!{sys.executable}\n"
            "import os, pathlib, sys\n"
            f"trigger = pathlib.Path({str(trigger)!r})\n"
            f"real = {str(real)!r}\n"
            f"root = {str(process_root)!r}\n"
            "pid = int(sys.argv[1])\n"
            "if not trigger.exists(): os.execv(real, [real, *sys.argv[1:]])\n"
            "directory = os.path.join(root, str(pid))\n"
            "os.makedirs(directory, exist_ok=True)\n"
            "with open(os.path.join(directory, 'stat'), 'w') as stream:\n"
            f"        {writer}\n",
        )


class Stage3Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Stage3Fixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def assert_no_complete(self) -> None:
        self.assertFalse(any((path / "COMPLETE").exists() for path in self.fixture.outputs()))

    def test_success_is_strict_and_transactional(self):
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.fixture.outputs()[-1]
        self.assertEqual((output / "probe.stdout.txt").read_text(), EXPECTED_STDOUT)
        self.assertEqual((output / "probe.stderr.txt").read_text(), "")
        self.assertIn("probe.exit_status=0", (output / "execution.txt").read_text())
        self.assertIn("status=COMPLETE", (output / "STATUS.txt").read_text())
        self.assertEqual((output / "COMPLETE").read_text(), "complete=1\n")

    def test_unarmed_and_symlink_markers_are_rejected(self):
        marker = self.fixture.usb / "ARM_STAGE3_ARM_EXECUTION_PROBE"
        marker.unlink()
        self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])
        marker.symlink_to("ARM_STAGE3_ARM_EXECUTION_PROBE.example")
        self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])

    def test_wrong_nonremovable_zero_and_multiple_mounts_fail(self):
        cases = [
            (("sda1", self.fixture.usb, "ext4", "1"),),
            (("sda1", self.fixture.usb, "vfat", "0"),),
            (),
        ]
        for mounts in cases:
            with self.subTest(mounts=mounts):
                self.fixture.set_mounts(*mounts)
                self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        other = self.fixture.root / "other"
        other.mkdir()
        self.fixture.set_mounts(
            ("sda1", self.fixture.usb, "vfat", "1"),
            ("sdb1", other, "vfat", "1"),
        )
        self.assertNotEqual(self.fixture.run_entry().returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])

    def test_direct_stage_cannot_fall_back_to_internal_path(self):
        internal = self.fixture.root / "internal"
        internal.mkdir()
        result = self.fixture.run_stage(internal)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.outputs(), [])

    def test_mount_path_replacement_keeps_output_on_anchor(self):
        anchored = self.fixture.root / "anchored-usb"
        real_mkdir = shutil.which("mkdir")
        assert real_mkdir
        self.fixture.write_command(
            "mkdir",
            f"#!{sys.executable}\n"
            "import os, pathlib, sys\n"
            f"usb = pathlib.Path({str(self.fixture.usb)!r})\n"
            f"anchored = pathlib.Path({str(anchored)!r})\n"
            "if sys.argv[1:] == ['stage3-arm-probe'] and not anchored.exists():\n"
            "    usb.rename(anchored)\n"
            "    usb.mkdir()\n"
            "    (usb / 'SENTINEL').write_text('internal')\n"
            f"os.execv({real_mkdir!r}, [{real_mkdir!r}, *sys.argv[1:]])\n",
        )
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((anchored / "stage3-arm-probe/COMPLETE").is_file())
        self.assertFalse((self.fixture.usb / "stage3-arm-probe").exists())

    def test_binary_absent_symlink_oversize_hash_and_mutation_fail(self):
        binary = self.fixture.usb / "arm_probe"
        operations = (
            "absent", "symlink", "oversize", "wrong-hash", "same-size-mutation"
        )
        for operation in operations:
            with self.subTest(operation=operation):
                self.fixture.cleanup()
                self.fixture = Stage3Fixture()
                binary = self.fixture.usb / "arm_probe"
                if operation == "absent":
                    binary.unlink()
                elif operation == "symlink":
                    binary.unlink()
                    binary.symlink_to("ARM_STAGE3_ARM_EXECUTION_PROBE.example")
                elif operation == "oversize":
                    binary.write_bytes(b"x" * 65537)
                elif operation == "wrong-hash":
                    binary.write_bytes(b"wrong")
                else:
                    data = bytearray(binary.read_bytes())
                    data[-1] ^= 1
                    binary.write_bytes(data)
                self.assertNotEqual(self.fixture.run_entry().returncode, 0)
                self.assert_no_complete()

    def test_nonzero_stderr_malformed_missing_pass_and_exec_failure_fail(self):
        stubs = (
            "#!/bin/sh\nexit 7\n",
            f"#!/bin/sh\nprintf '%s' {shlex.quote(EXPECTED_STDOUT)}\nprintf error >&2\n",
            "#!/bin/sh\nprintf 'schema=1\\nresult=MALFORMED\\n'\n",
            "#!/bin/sh\nprintf 'schema=1\\nstarted=1\\n'\n",
            "not an executable format\n",
        )
        for stub in stubs:
            with self.subTest(stub=stub[:20]):
                self.fixture.cleanup()
                self.fixture = Stage3Fixture()
                self.fixture.set_stub(stub)
                self.assertNotEqual(self.fixture.run_entry().returncode, 0)
                self.assert_no_complete()

    def test_timeout_term_and_kill_cases_are_incomplete(self):
        stubs = (
            "#!/bin/sh\nsleep 2\n",
            "#!/bin/sh\ntrap '' TERM\nsleep 2\n",
        )
        for stub in stubs:
            with self.subTest(stub=stub):
                self.fixture.cleanup()
                self.fixture = Stage3Fixture()
                self.fixture.set_stub(stub)
                self.assertNotEqual(self.fixture.run_entry(timeout=8).returncode, 0)
                self.assert_no_complete()

    def test_unknown_and_replaced_child_states_are_fatal(self):
        for mode in ("unknown", "replaced"):
            with self.subTest(mode=mode):
                self.fixture.cleanup()
                self.fixture = Stage3Fixture()
                trigger = self.fixture.root / "trigger"
                self.fixture.set_stub(
                    f"#!/bin/sh\n: > {shlex.quote(str(trigger))}\nsleep 2\n"
                )
                self.fixture.install_process_override(trigger, mode)
                self.assertNotEqual(self.fixture.run_entry(timeout=8).returncode, 0)
                output = self.fixture.outputs()[-1]
                self.assertIn("runner_fatal", (output / "ERRORS.txt").read_text())
                self.assert_no_complete()

    def test_binary_path_replacement_after_hash_is_rejected(self):
        binary = self.fixture.usb / "arm_probe"
        real_hash = self.fixture.bin / "sha256sum.real"
        (self.fixture.bin / "sha256sum").rename(real_hash)
        self.fixture.write_command(
            "sha256sum",
            "#!/bin/sh\n"
            f"{shlex.quote(str(real_hash))} \"$@\"\n"
            "status=$?\n"
            f"if [ ! -e {shlex.quote(str(self.fixture.root / 'changed'))} ]; then\n"
            f"  : > {shlex.quote(str(self.fixture.root / 'changed'))}\n"
            f"  mv {shlex.quote(str(binary))} {shlex.quote(str(binary) + '.old')}\n"
            f"  cp {shlex.quote(str(binary) + '.old')} {shlex.quote(str(binary))}\n"
            "fi\n"
            "exit \"$status\"\n",
        )
        result = self.fixture.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_complete()

    def test_output_and_complete_commit_failures_have_no_false_success(self):
        for filename in ("execution.txt", "COMPLETE"):
            with self.subTest(destination=filename):
                self.fixture.cleanup()
                self.fixture = Stage3Fixture()
                destination = self.fixture.usb / "stage3-arm-probe" / filename
                self.fixture.fail_mv_to(destination)
                self.assertNotEqual(self.fixture.run_entry().returncode, 0)
                self.assert_no_complete()

    def test_existing_output_is_not_reused(self):
        (self.fixture.usb / "stage3-arm-probe").mkdir()
        result = self.fixture.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.fixture.usb / "stage3-arm-probe-1/COMPLETE").is_file())

    def test_production_source_and_payload_policy(self):
        source = (SOURCE_DIR / "probe.c").read_text()
        stage = (PAYLOAD_DIR / "stage3_arm_probe.sh").read_text()
        forbidden_apis = (
            "system(", "popen(", "fork(", "exec", "socket(", "connect(",
            "mount(", "reboot(", "ptrace(", "kill(", "ioctl(", "open(",
            "fopen(", "unlink(", "rename(", "setuid(", "pthread_create(",
        )
        for forbidden in forbidden_apis:
            self.assertNotIn(forbidden, source)
        for forbidden_path in (
            "/dev/mtd", "/dev/mem", "/media/flash", "/dev/input", "/dev/fb",
        ):
            self.assertNotIn(forbidden_path, source)
            self.assertNotIn(forbidden_path, stage)
        self.assertLessEqual(len(source.splitlines()), 100)
        self.assertFalse((PAYLOAD_DIR / "ARM_STAGE3_ARM_EXECUTION_PROBE").exists())
        self.assertEqual(stage.count('"$@" &'), 1)


if __name__ == "__main__":
    unittest.main()
