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

from analyze_topology import InvalidCapture, analyze


SOURCE = Path(__file__).resolve().parent
PAYLOAD = SOURCE / "payload"


class Fixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.usb = self.root / "usb"
        self.bin = self.root / "bin"
        self.target = self.root / "target"
        self.proc = self.root / "proc"
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        for path in (
            self.usb,
            self.bin,
            self.target / "proc/net",
            self.target / "application/lib",
            self.target / "application/etc",
            self.proc,
            self.sys / "block/sda",
            self.sys / "class/net/can0",
            self.sys / "class/net/eth0",
            self.sys / "dev/char",
            self.dev,
        ):
            path.mkdir(parents=True, exist_ok=True)
        self._commands()
        self._payload()
        self._target()
        self.arm()
        self.set_mount(self.usb)

    def cleanup(self) -> None:
        self.temp.cleanup()

    def _payload(self) -> None:
        substitutions = {
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
            "stage4_topology.sh": {
                "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(self.bin))}",
                "TARGET_ROOT=/": f"TARGET_ROOT={shlex.quote(str(self.target))}",
                "PROCESS_ROOT=/proc": f"PROCESS_ROOT={shlex.quote(str(self.proc / 'process'))}",
                "FD_ROOT=/proc/self/fd": "FD_ROOT=/dev/fd",
                "SYS_NET_ROOT=/sys/class/net": f"SYS_NET_ROOT={shlex.quote(str(self.sys / 'class/net'))}",
                "SYS_DEV_CHAR_ROOT=/sys/dev/char": f"SYS_DEV_CHAR_ROOT={shlex.quote(str(self.sys / 'dev/char'))}",
                "DEV_ROOT=/dev": f"DEV_ROOT={shlex.quote(str(self.dev))}",
            },
        }
        for name, replacements in substitutions.items():
            text = (PAYLOAD / name).read_text(encoding="utf-8")
            for old, new in replacements.items():
                if text.count(old) != 1:
                    raise AssertionError(f"unexpected production occurrence: {name}: {old}")
                text = text.replace(old, new)
            path = self.usb / name
            path.write_text(text, encoding="utf-8")
            path.chmod(0o755)

    def _commands(self) -> None:
        for name in (
            "awk", "dd", "dirname", "du", "grep", "mkdir", "mv", "pwd", "readlink",
            "rm", "sed", "tr", "wc",
        ):
            executable = shutil.which(name)
            if not executable:
                raise unittest.SkipTest(f"host command unavailable: {name}")
            (self.bin / name).symlink_to(executable)
        self.command(
            "sha256sum",
            "import hashlib, sys\n"
            "for name in sys.argv[1:]:\n"
            " data = open(name, 'rb').read()\n"
            " print(f'{hashlib.sha256(data).hexdigest()}  {name}')\n",
        )
        self.command(
            "stat",
            "import os, stat, sys\n"
            "args=sys.argv[1:]\n"
            "follow=False\n"
            "if args and args[0]=='-L': follow=True; args=args[1:]\n"
            "if len(args)!=3 or args[0]!='-c': raise SystemExit(2)\n"
            "fmt,path=args[1],args[2]\n"
            "if path.startswith('/dev/fd/'):\n"
            " value=os.fstat(int(path.rsplit('/',1)[1]))\n"
            "else:\n"
            " value=os.stat(path) if follow else os.lstat(path)\n"
            "mode=value.st_mode\n"
            "kind=('regular file' if stat.S_ISREG(mode) else 'symbolic link' if stat.S_ISLNK(mode) "
            "else 'fifo' if stat.S_ISFIFO(mode) else 'directory' if stat.S_ISDIR(mode) "
            "else 'character special file' if stat.S_ISCHR(mode) else 'other')\n"
            "mapping={'%F':kind,'%a':format(stat.S_IMODE(mode),'o'),'%u':str(value.st_uid),"
            "'%g':str(value.st_gid),'%t':format(os.major(value.st_rdev),'x'),"
            "'%T':format(os.minor(value.st_rdev),'x'),'%d':str(value.st_dev),"
            "'%i':str(value.st_ino),'%f':format(mode,'x'),'%s':str(value.st_size),"
            "'%Y':str(int(value.st_mtime)),'%Z':str(int(value.st_ctime))}\n"
            "for key in sorted(mapping, key=len, reverse=True): fmt=fmt.replace(key,mapping[key])\n"
            "print(fmt)\n",
        )

    def command(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
        path.chmod(0o755)

    def _target(self) -> None:
        (self.sys / "block/sda/removable").write_text("1\n")
        (self.dev / "sda1").write_text("")
        (self.target / "proc/net/dev").write_text(
            "Inter-| Receive | Transmit\n face |bytes|packets|bytes|packets\n"
            " can0: 0 0 0 0\n eth0: 0 0 0 0\n"
        )
        for name, net_type in (("can0", "280\n"), ("eth0", "1\n")):
            interface = self.sys / "class/net" / name
            (interface / "type").write_text(net_type)
            (interface / "operstate").write_text("down\n")
            (interface / "mtu").write_text("16\n" if name == "can0" else "1500\n")
            (interface / "flags").write_text("0x0\n")
            (interface / "uevent").write_text("")
            (interface / "address").write_text("00:00:00:00:00:00\n")
        # A FIFO would block if the collector opened it. Metadata calls do not.
        os.mkfifo(self.dev / "hc_mcu_dev")
        (self.dev / "canbox_protocol_dev").write_text("")
        (self.target / "application/lib/libappframework.so.1.0.0").write_bytes(
            b"fixture HcCar notify_car_event /dev/hc_mcu_dev\x00"
        )
        (self.target / "application/lib/libappmcucommunication.so.1.0.0").write_bytes(
            b"fixture HcProtocol hc_mcu_read notify_canbox_event\x00"
        )
        (self.target / "application/etc/can.conf").write_text("fixture metadata only\n")
        self.add_owner(101, self.dev / "hc_mcu_dev")

    def add_owner(self, pid: int, target: Path, extra_fds: int = 0, maps_size: int = 32) -> None:
        root = self.proc / "process" / str(pid)
        (root / "fd").mkdir(parents=True, exist_ok=True)
        fields = ["S", "1"] + ["0"] * 17 + [str(10000 + pid)]
        (root / "stat").write_text(f"{pid} (fixture owner) " + " ".join(fields) + "\n")
        (root / "comm").write_text("fixture-owner\n")
        (root / "cmdline").write_bytes(b"fixture-owner\x00--idle\x00")
        (root / "maps").write_text("x" * maps_size)
        (root / "exe").symlink_to(self.target / "application/bin/Launcher")
        (root / "fd/7").symlink_to(target)
        for index in range(extra_fds):
            (root / "fd" / str(8 + index)).symlink_to(target)

    def set_mount(self, mount: Path) -> None:
        (self.proc / "mounts").write_text(f"/dev/sda1 {mount.resolve()} vfat rw,dirsync 0 0\n")

    def arm(self) -> None:
        (self.usb / "ARM_STAGE4_CAN_MCU_TOPOLOGY").write_text("reviewed=fixture\n")

    def replace(self, old: str, new: str) -> None:
        path = self.usb / "stage4_topology.sh"
        text = path.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"unexpected fixture replacement count: {old}")
        path.write_text(text.replace(old, new))

    def run(self, timeout: float = 8) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", "gemn_auto.sh"], cwd=self.usb, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def output(self) -> Path:
        return self.usb / "stage4-topology"


class Stage4ATests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def assert_incomplete(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture.output() / "COMPLETE").exists())

    def test_fifo_is_not_opened_and_clean_capture_classifies_hybrid(self) -> None:
        result = self.fixture.run(timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.fixture.output()
        self.assertEqual((output / "STATUS.txt").read_text().splitlines()[2], "status=COMPLETE")
        self.assertEqual((output / "ERRORS.txt").read_text(), "")
        self.assertTrue((self.fixture.usb / ".stage4a-topology.lock").is_dir())
        self.assertFalse((self.fixture.usb / "ARM_STAGE4_CAN_MCU_TOPOLOGY").exists())
        report = analyze(output)
        self.assertEqual(report["classification"], "CASE C")
        self.assertIn("/dev/hc_mcu_dev", report["evidence"]["production_owned_candidate_paths"])

    def test_symlink_candidate_is_metadata_only(self) -> None:
        self.dev_link = self.fixture.dev / "can-alias"
        self.dev_link.symlink_to(self.fixture.dev / "hc_mcu_dev")
        result = self.fixture.run(timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.fixture.output() / "devices/device-nodes.txt").read_text()
        self.assertIn(str(self.dev_link), text)
        self.assertIn("symbolic link", text)

    def test_fd_disappearance_is_bounded_and_not_promoted_to_owner(self) -> None:
        needle = 'matches_candidate "$TARGET_ONE" || continue\n        TARGET_TWO='
        self.fixture.replace(needle, 'matches_candidate "$TARGET_ONE" || continue\n        rm -f "$FD_PATH"\n        TARGET_TWO=')
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.fixture.output() / "processes/owners.txt").read_text(), "")
        self.assertIn("fd_disappeared", (self.fixture.output() / "OPTIONAL.txt").read_text())

    def test_pid_disappearance_is_bounded_and_not_promoted_to_owner(self) -> None:
        needle = 'TARGET_TWO=$(readlink "$FD_PATH" 2>/dev/null) || { record_optional "fd_disappeared:$PID:${FD_PATH##*/}"; continue; }\n        [ "$TARGET_ONE" = "$TARGET_TWO" ]'
        replacement = 'TARGET_TWO=$(readlink "$FD_PATH" 2>/dev/null) || { record_optional "fd_disappeared:$PID:${FD_PATH##*/}"; continue; }\n        rm -f "$PDIR/stat"\n        [ "$TARGET_ONE" = "$TARGET_TWO" ]'
        self.fixture.replace(needle, replacement)
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pid_disappeared", (self.fixture.output() / "OPTIONAL.txt").read_text())

    def test_process_limit_fails_closed(self) -> None:
        self.fixture.add_owner(102, self.fixture.dev / "hc_mcu_dev")
        self.fixture.replace("MAX_PROCESSES=256", "MAX_PROCESSES=1")
        self.assert_incomplete(self.fixture.run())

    def test_fd_limit_fails_closed(self) -> None:
        self.fixture.add_owner(102, self.fixture.dev / "hc_mcu_dev", extra_fds=2)
        self.fixture.replace("MAX_FDS_PER_PROCESS=128", "MAX_FDS_PER_PROCESS=1")
        self.assert_incomplete(self.fixture.run())

    def test_maps_total_limit_fails_closed(self) -> None:
        self.fixture.replace("MAX_TOTAL_MAPS=524288", "MAX_TOTAL_MAPS=1")
        self.assert_incomplete(self.fixture.run())

    def test_library_bound_fails_closed_without_complete(self) -> None:
        path = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        path.write_bytes(b"x" * 400000)
        self.assert_incomplete(self.fixture.run())

    def test_missing_library_prevents_false_complete(self) -> None:
        (self.fixture.target / "application/lib/libappframework.so.1.0.0").unlink()
        result = self.fixture.run()
        self.assert_incomplete(result)
        self.assertIn("snapshot_failed", (self.fixture.output() / "ERRORS.txt").read_text())

    def test_wrong_usb_mount_fails_before_output(self) -> None:
        other = self.fixture.root / "other"
        other.mkdir()
        self.fixture.set_mount(other)
        result = self.fixture.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.fixture.output().exists())

    def test_tampered_capture_is_rejected(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.fixture.output() / "network/interfaces.txt"
        path.write_text(path.read_text() + "tampered=1\n")
        with self.assertRaises(InvalidCapture):
            analyze(self.fixture.output())

    def test_static_device_safety_contract(self) -> None:
        text = (PAYLOAD / "stage4_topology.sh").read_text()
        forbidden = ("candump", "cansniffer", "ip link set", "strace", "gdb", "ioctl")
        for token in forbidden:
            self.assertNotIn(token, text)
        self.assertNotRegex(text, r"(?:<|dd if=)\"?\$PATHNAME")
        self.assertIn('readlink "$FD_PATH"', text)
        self.assertIn("MAX_DEVICE_CANDIDATES=64", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
