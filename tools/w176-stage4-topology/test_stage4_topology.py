from __future__ import annotations

import hashlib
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from analyze_topology import InvalidCapture, _safe_regular, analyze


SOURCE = Path(__file__).resolve().parent
PAYLOAD = SOURCE / "payload"


class Fixture:
    def __init__(self) -> None:
        self.temp = tempfile.TemporaryDirectory(dir="/tmp")
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
            self.proc / "process",
            self.sys / "block/sda",
            self.sys / "devices/virtual/net/can0",
            self.sys / "devices/virtual/net/eth0",
            self.sys / "class/net",
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
                "TARGET_MOUNTS_FILE=/proc/self/mounts": f"TARGET_MOUNTS_FILE={shlex.quote(str(self.proc / 'self/mounts'))}",
                "PROCESS_ROOT=/proc": f"PROCESS_ROOT={shlex.quote(str(self.proc / 'process'))}",
                "FD_ROOT=/proc/self/fd": "FD_ROOT=/dev/fd",
                "SYS_NET_ROOT=/sys/class/net": f"SYS_NET_ROOT={shlex.quote(str(self.sys / 'class/net'))}",
                "SYS_DEVICES_ROOT=/sys/devices": f"SYS_DEVICES_ROOT={shlex.quote(str(self.sys / 'devices'))}",
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
        shutil.copy2(PAYLOAD / "library_mount_guard.sh", self.usb / "library_mount_guard.sh")

    def _commands(self) -> None:
        for name in (
            "awk", "dd", "dirname", "du", "grep", "ln", "mkdir", "mv", "pwd", "readlink",
            "rm", "sed", "tr",
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
            "else 'character special file' if stat.S_ISCHR(mode) else 'block special file' if stat.S_ISBLK(mode) else 'socket' if stat.S_ISSOCK(mode) else 'other')\n"
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
        if path.exists() or path.is_symlink():
            path.unlink()
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
            interface = self.sys / "devices/virtual/net" / name
            (self.sys / "class/net" / name).symlink_to(f"../../devices/virtual/net/{name}")
            (interface / "type").write_text(net_type)
            (interface / "operstate").write_text("down\n")
            (interface / "mtu").write_text("16\n" if name == "can0" else "1500\n")
            (interface / "flags").write_text("0x0\n")
            (interface / "uevent").write_text("")
            (interface / "address").write_text("00:00:00:00:00:00\n")
        os.mkfifo(self.dev / "hc_mcu_dev")
        (self.dev / "canbox_protocol_dev").write_text("")
        (self.target / "application/lib/libappframework.so.1.0.0").write_bytes(
            b"fixture HcCar notify_car_event /dev/hc_mcu_dev\x00"
        )
        (self.target / "application/lib/libappmcucommunication.so.1.0.0").write_bytes(
            b"fixture HcProtocol hc_mcu_read notify_canbox_event\x00"
        )
        self.add_owner(101, self.dev / "hc_mcu_dev")

    def write_stat(self, pid: int, start: int) -> str:
        fields = ["S", "1"] + ["0"] * 17 + [str(start)]
        return f"{pid} (fixture owner) " + " ".join(fields) + "\n"

    def write_status(self, pid: int, tgid: int | str | None = None, state: str = "S") -> str:
        label = {"S": "sleeping", "R": "running", "Z": "zombie", "X": "dead", "x": "dead"}.get(state, "test state")
        return f"Name:\tfixture\nState:\t{state} ({label})\nTgid:\t{pid if tgid is None else tgid}\nPid:\t{pid}\n"

    def add_owner(self, pid: int, target: Path, fd: int = 7, maps_size: int = 32) -> None:
        root = self.proc / "process" / str(pid)
        (root / "fd").mkdir(parents=True, exist_ok=True)
        (root / "stat").write_text(self.write_stat(pid, 10_000 + pid))
        (root / "status").write_text(self.write_status(pid))
        (root / "comm").write_text("fixture-owner\n")
        (root / "cmdline").write_bytes(b"fixture-owner\x00--idle\x00")
        (root / "maps").write_text("x" * maps_size)
        (root / "exe").symlink_to(self.target / "application/bin/Launcher")
        (root / "fd" / str(fd)).symlink_to(target)

    def set_mount(self, mount: Path, application_fs: str = "squashfs", application_options: str = "ro") -> None:
        (self.proc / "self").mkdir(exist_ok=True)
        if not (self.proc / "mounts").is_symlink():
            (self.proc / "mounts").unlink(missing_ok=True)
            (self.proc / "mounts").symlink_to("self/mounts")
        (self.proc / "mounts").write_text(
            f"/dev/sda1 {mount.resolve()} vfat rw,dirsync 0 0\n"
            f"rom@spapp. {(self.target / 'application').resolve()} {application_fs} {application_options} 0 0\n"
        )

    def arm(self) -> None:
        (self.usb / "ARM_STAGE4_CAN_MCU_TOPOLOGY").write_text("reviewed=fixture\n")

    def replace(self, old: str, new: str) -> None:
        path = self.usb / "stage4_topology.sh"
        text = path.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"unexpected fixture replacement count: {old}")
        path.write_text(text.replace(old, new))

    def run(self, timeout: float = 12) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/sh", "gemn_auto.sh"], cwd=self.usb, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )

    def output(self) -> Path:
        return self.usb / "stage4-topology"


def rewrite_checksum(root: Path, relative: str) -> None:
    manifest = root / "checksums.sha256"
    digest = hashlib.sha256((root / relative).read_bytes()).hexdigest()
    lines = manifest.read_text().splitlines()
    replacement = f"{digest}  {relative}"
    matches = [index for index, line in enumerate(lines) if line.endswith(f"  {relative}")]
    if len(matches) != 1:
        raise AssertionError(f"expected one checksum row for {relative}")
    lines[matches[0]] = replacement
    manifest.write_text("\n".join(lines) + "\n")


class Stage4ATests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def assert_incomplete(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.fixture.output() / "COMPLETE").exists())

    def assert_library_special_rejected(self, symlink_target: Path | None = None) -> None:
        library = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        library.unlink()
        fifo = symlink_target or library
        if symlink_target is None:
            os.mkfifo(fifo)
        else:
            library.symlink_to(symlink_target)
        sentinel = self.fixture.root / "fifo-opened-sentinel"
        writer = subprocess.Popen(
            [sys.executable, "-c", "import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY); open(sys.argv[2],'w').write('OPENED'); os.close(fd)", str(fifo), str(sentinel)],
            start_new_session=True,
        )
        try:
            result = self.fixture.run(timeout=6)
            self.assert_incomplete(result)
            time.sleep(0.05)
            self.assertFalse(sentinel.exists(), "special source was opened")
            self.assertIsNone(writer.poll(), "FIFO writer unblocked, proving an open")
        finally:
            if writer.poll() is None:
                os.killpg(writer.pid, signal.SIGKILL)
                writer.wait()

    def test_clean_capture_is_canonical_and_conservative(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = analyze(self.fixture.output())
        self.assertEqual(report["classification"], "CASE A")
        self.assertEqual(report["evidence"]["mcu_translation_path"], "INFERENCE")
        self.assertEqual(report["evidence"]["physical_mercedes_can_connectivity"], "UNKNOWN")
        self.assertEqual(report["integrity_model"], "CONSISTENCY_ONLY_NOT_AUTHENTICATION")
        self.assertEqual(report["verified_checksums"], 18)

    def test_approved_library_fifo_is_rejected_before_open(self) -> None:
        self.assert_library_special_rejected()

    def test_approved_library_symlink_to_fifo_is_rejected_before_open(self) -> None:
        fifo = self.fixture.root / "external-fifo"
        os.mkfifo(fifo)
        self.assert_library_special_rejected(fifo)

    def test_approved_library_symlink_to_candidate_mcu_is_rejected_before_open(self) -> None:
        self.assert_library_special_rejected(self.fixture.dev / "hc_mcu_dev")

    def test_approved_library_directory_is_rejected(self) -> None:
        library = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        library.unlink()
        library.mkdir()
        self.assert_incomplete(self.fixture.run(timeout=6))

    def test_approved_library_character_device_is_rejected_where_supported(self) -> None:
        if not hasattr(os, "mknod"):
            self.skipTest("host has no mknod")
        library = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        library.unlink()
        try:
            os.mknod(library, stat.S_IFCHR | 0o600, os.makedev(1, 3))
        except (PermissionError, OSError) as exc:
            self.skipTest(f"character-device fixture unavailable: {exc}")
        self.assert_incomplete(self.fixture.run(timeout=6))

    def test_library_disappearance_between_preflight_checks_is_rejected(self) -> None:
        needle = '        [ ! -L "$SOURCE" ] || exit 20\n        [ "$(stat -c "%F" "$SOURCE")" = "regular file" ] || exit 21'
        replacement = '        [ ! -L "$SOURCE" ] || exit 20\n        rm -f "$SOURCE"\n        [ "$(stat -c "%F" "$SOURCE")" = "regular file" ] || exit 21'
        self.fixture.replace(needle, replacement)
        self.assert_incomplete(self.fixture.run(timeout=6))

    def test_application_mount_must_be_unique_readonly_squashfs(self) -> None:
        for filesystem, options in (("squashfs", "rw"), ("ext4", "ro")):
            with self.subTest(filesystem=filesystem, options=options):
                fixture = Fixture()
                try:
                    fixture.set_mount(fixture.usb, filesystem, options)
                    result = fixture.run(timeout=6)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()

    def test_sha256_failures_and_malformed_output_never_complete(self) -> None:
        cases = {
            "nonzero_empty": "import sys\nsys.exit(7)\n",
            "nonzero_valid": "import hashlib,sys\nfor name in sys.argv[1:]:\n data=open(name,'rb').read(); print(f'{hashlib.sha256(data).hexdigest()}  {name}')\nsys.exit(7)\n",
            "malformed": "import sys\nprint('z'*64+'  '+sys.argv[1])\n",
            "truncated": "import sys\nprint('0'*63+'  '+sys.argv[1])\n",
            "extra_path": "import hashlib,sys\nname=sys.argv[1]; data=open(name,'rb').read(); print(f'{hashlib.sha256(data).hexdigest()}  {name} unexpected')\n",
        }
        self.fixture.cleanup()
        for label, body in cases.items():
            with self.subTest(label=label):
                fixture = Fixture()
                try:
                    fixture.command("sha256sum", body)
                    result = fixture.run(timeout=6)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()
        self.fixture = Fixture()

    def test_missing_sha256sum_never_completes(self) -> None:
        (self.fixture.bin / "sha256sum").unlink()
        self.assert_incomplete(self.fixture.run(timeout=6))

    def test_unchecked_classification_evidence_is_rejected(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        path = root / "network/interfaces.txt"
        path.write_text(path.read_text().replace("can0.type=280", "can0.type=1"))
        manifest = root / "checksums.sha256"
        manifest.write_text("".join(line for line in manifest.read_text().splitlines(True) if not line.endswith("  network/interfaces.txt\n")))
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_manifest_rejects_duplicate_unexpected_absolute_and_traversal(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        original = (self.fixture.output() / "checksums.sha256").read_text()
        bad_lines = (
            original + original.splitlines()[0] + "\n",
            original + "0" * 64 + "  surprise.txt\n",
            original + "0" * 64 + "  /absolute.txt\n",
            original + "0" * 64 + "  ../escape.txt\n",
        )
        for value in bad_lines:
            with self.subTest(value=value[-90:]):
                (self.fixture.output() / "checksums.sha256").write_text(value)
                with self.assertRaises(InvalidCapture):
                    analyze(self.fixture.output())
        (self.fixture.output() / "checksums.sha256").write_text(original)

    def test_inventory_is_covered_and_dynamic_owner_group_is_complete(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        inventory = self.fixture.output() / "capture-inventory.txt"
        inventory.write_text(inventory.read_text().replace("owner_maps_101", "owner_maps_102"))
        with self.assertRaises(InvalidCapture):
            analyze(self.fixture.output())

    def test_output_name_exhaustion_fails_without_modifying_stale_results(self) -> None:
        before: dict[str, tuple[str, int]] = {}
        for number in range(100):
            name = "stage4-topology" if number == 0 else f"stage4-topology-{number}"
            directory = self.fixture.usb / name
            directory.mkdir()
            sentinel = directory / "stale-evidence"
            sentinel.write_text(f"stale-{number}\n")
            before[name] = (sentinel.read_text(), sentinel.stat().st_mtime_ns)
        result = self.fixture.run(timeout=6)
        self.assertNotEqual(result.returncode, 0)
        for name, expected in before.items():
            directory = self.fixture.usb / name
            sentinel = directory / "stale-evidence"
            self.assertEqual((sentinel.read_text(), sentinel.stat().st_mtime_ns), expected)
            self.assertEqual({path.name for path in directory.iterdir()}, {"stale-evidence"})

    def test_analyser_rejects_leaf_parent_and_nested_symlinks(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        original = (root / "network/interfaces.txt").read_bytes()
        external = self.fixture.root / "external"
        external.mkdir()
        leaf = external / "interfaces.txt"
        leaf.write_bytes(original)
        (root / "network/interfaces.txt").unlink()
        (root / "network/interfaces.txt").symlink_to(leaf)
        with self.assertRaises(InvalidCapture):
            analyze(root)
        (root / "network/interfaces.txt").unlink()
        (root / "network/interfaces.txt").write_bytes(original)
        outside_network = external / "network"
        (root / "network").rename(outside_network)
        (root / "network").symlink_to(outside_network, target_is_directory=True)
        with self.assertRaises(InvalidCapture):
            analyze(root)

    def test_safe_path_rejects_absolute_traversal_and_accepts_normal_nested(self) -> None:
        root = self.fixture.root / "safe-root"
        (root / "a/b").mkdir(parents=True)
        (root / "a/b/file").write_text("ok")
        established = root.resolve()
        self.assertEqual(_safe_regular(established, "a/b/file", 8).read_text(), "ok")
        for relative in ("/etc/passwd", "../escape", "a/../b/file", "./a/b/file"):
            with self.subTest(relative=relative), self.assertRaises(InvalidCapture):
                _safe_regular(established, relative, 8)
        outside = self.fixture.root / "outside"
        outside.mkdir()
        (outside / "file").write_text("ok")
        (root / "a/link").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(InvalidCapture):
            _safe_regular(established, "a/link/file", 8)

    def test_weak_mcu_evidence_remains_case_d_inference(self) -> None:
        (self.fixture.sys / "class/net/can0/type").write_text("1\n")
        self.assertEqual(self.fixture.run().returncode, 0)
        report = analyze(self.fixture.output())
        self.assertEqual(report["classification"], "CASE D")
        self.assertEqual(report["evidence"]["mcu_translation_path"], "INFERENCE")

    def inject_before_after_bracket(self, shell: str) -> None:
        marker = "                # Per-FD identity bracket; the whole group is still staged.\n"
        self.fixture.replace(marker, shell + "\n" + marker)

    def assert_owner_race_discarded(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)
        root = self.fixture.output()
        self.assertEqual((root / "processes/owners.txt").read_text(), "")
        self.assertFalse((root / "processes/101-cmdline.bin").exists())
        self.assertIn("owner_race_unusable", (root / "OPTIONAL.txt").read_text())
        self.assertEqual(analyze(root)["evidence"]["production_owned_candidate_paths"], [])

    def test_owner_pid_disappearance_after_capture_is_discarded(self) -> None:
        self.inject_before_after_bracket('                rm -f "$PDIR/stat"')
        self.assert_owner_race_discarded()

    def test_owner_pid_reuse_after_capture_is_discarded(self) -> None:
        replacement = self.fixture.write_stat(101, 999_999).strip().replace("'", "")
        self.inject_before_after_bracket(f"                printf '%s\\n' '{replacement}' > \"$PDIR/stat\"")
        self.assert_owner_race_discarded()

    def test_owner_fd_disappearance_after_capture_is_discarded(self) -> None:
        self.inject_before_after_bracket('                rm -f "$FD_PATH"')
        self.assert_owner_race_discarded()

    def test_owner_fd_replacement_after_capture_is_discarded(self) -> None:
        self.inject_before_after_bracket('                rm -f "$FD_PATH"; ln -s "$DEV_ROOT/canbox_protocol_dev" "$FD_PATH"')
        self.assert_owner_race_discarded()

    def test_owner_metadata_capture_failure_is_discarded(self) -> None:
        needle = '                       stage_owner_text "$PDIR/cmdline" 16384 ".owner-$PID-cmdline.tmp" &&'
        replacement = '                       rm -f "$PDIR/cmdline" &&\n' + needle
        self.fixture.replace(needle, replacement)
        self.assert_owner_race_discarded()

    def test_stable_owner_has_complete_bracketed_metadata(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        self.assertIn("101|101|10101|7|/dev/hc_mcu_dev", (root / "processes/owners.txt").read_text())
        for suffix in ("comm.txt", "cmdline.bin", "exe.txt", "maps.txt"):
            self.assertTrue((root / f"processes/101-{suffix}").is_file())

    def test_exact_device_candidates_ignore_broad_names_and_out_of_range(self) -> None:
        for name in ("hc_unrelated", "other_mcu", "can8", "ttyS8"):
            (self.fixture.dev / name).write_text("")
        (self.fixture.dev / "can7").write_text("")
        (self.fixture.dev / "ttyS7").write_text("")
        self.assertEqual(self.fixture.run().returncode, 0)
        text = (self.fixture.output() / "devices/device-nodes.txt").read_text()
        self.assertIn("/dev/can7|", text)
        self.assertIn("/dev/ttyS7|", text)
        for name in ("hc_unrelated", "other_mcu", "can8", "ttyS8"):
            self.assertNotIn(name, text)

    def test_process_and_fd_numeric_ranges_are_hard(self) -> None:
        self.fixture.add_owner(4096, self.fixture.dev / "hc_mcu_dev", fd=127)
        self.fixture.add_owner(4097, self.fixture.dev / "hc_mcu_dev", fd=7)
        owner = self.fixture.proc / "process/101/fd/128"
        owner.symlink_to(self.fixture.dev / "hc_mcu_dev")
        self.assertEqual(self.fixture.run().returncode, 0)
        text = (self.fixture.output() / "processes/owners.txt").read_text()
        self.assertIn("4096|4096|14096|127|/dev/hc_mcu_dev", text)
        self.assertNotIn("4097|", text)
        self.assertNotIn("|128|", text)

    def test_process_fd_map_and_interface_limits_fail_closed(self) -> None:
        cases = {
            "fd_total": ('MAX_TOTAL_FD_LINKS=4096', 'MAX_TOTAL_FD_LINKS=0'),
            "maps_total": ('MAX_TOTAL_MAPS=524288', 'MAX_TOTAL_MAPS=1'),
            "interfaces": ('MAX_INTERFACES=32', 'MAX_INTERFACES=1'),
        }
        self.fixture.cleanup()
        for label, (old, new) in cases.items():
            with self.subTest(label=label):
                fixture = Fixture()
                try:
                    fixture.replace(old, new)
                    result = fixture.run()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()
        self.fixture = Fixture()

    def test_present_process_count_limit_fails_closed(self) -> None:
        for pid in range(1, 258):
            if pid == 101:
                continue
            process = self.fixture.proc / "process" / str(pid)
            (process / "fd").mkdir(parents=True)
            (process / "stat").write_text(self.fixture.write_stat(pid, 20_000 + pid))
            (process / "status").write_text(self.fixture.write_status(pid))
        self.assert_incomplete(self.fixture.run(timeout=45))

    def test_readonly_library_and_map_bounds_fail_closed(self) -> None:
        path = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        path.write_bytes(b"x" * 400_000)
        self.assert_incomplete(self.fixture.run())

    def test_malformed_schemas_and_conflicting_interface_records_are_rejected(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        mutations = (
            ("network/interfaces.txt", "\ncan0.type=1\n"),
            ("devices/device-nodes.txt", "\nmalformed\n"),
            ("processes/owners.txt", "\nmalformed\n"),
            ("CAPABILITIES.txt", "\nunexpected=value\n"),
        )
        originals = {relative: (root / relative).read_bytes() for relative, _ in mutations}
        for relative, suffix in mutations:
            with self.subTest(relative=relative):
                (root / relative).write_bytes(originals[relative] + suffix.encode())
                rewrite_checksum(root, relative)
                with self.assertRaises(InvalidCapture):
                    analyze(root)
                (root / relative).write_bytes(originals[relative])
                rewrite_checksum(root, relative)

    def test_analyser_checks_size_before_read_and_rejects_extra_files(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        interfaces = root / "network/interfaces.txt"
        interfaces.write_bytes(b"x" * 262_145)
        with self.assertRaises(InvalidCapture):
            analyze(root)
        # Restore with a fresh fixture for the canonical-tree check.
        self.fixture.cleanup()
        self.fixture = Fixture()
        self.assertEqual(self.fixture.run().returncode, 0)
        (self.fixture.output() / "unchecked-extra.txt").write_text("extra")
        with self.assertRaises(InvalidCapture):
            analyze(self.fixture.output())

    def test_status_complete_and_error_false_success_paths_are_rejected(self) -> None:
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        for relative, value in (
            ("COMPLETE", "complete=0\n"),
            ("STATUS.txt", "schema=3\nscope=w176-stage4a-can-mcu-topology\nstatus=COMPLETE\nmandatory_failures=1\noptional_findings=0\n"),
            ("ERRORS.txt", "error.1=hidden\n"),
        ):
            original = (root / relative).read_bytes()
            (root / relative).write_text(value)
            rewrite_checksum(root, relative)
            with self.assertRaises(InvalidCapture):
                analyze(root)
            (root / relative).write_bytes(original)
            rewrite_checksum(root, relative)

    def test_static_safety_and_no_masked_production_pipelines(self) -> None:
        text = (PAYLOAD / "stage4_topology.sh").read_text()
        for token in ("candump", "cansniffer", "ip link set", "strace", "gdb", "ioctl"):
            self.assertNotIn(token, text)
        self.assertNotIn('"$DEV_ROOT"/*', text)
        self.assertNotIn("*mcu*", text)
        self.assertNotIn("hc*", text)
        self.assertNotRegex(text, r"sha256sum[^\n]*\|")
        for line in text.splitlines():
            if "sha256sum " in line or "dd " in line:
                self.assertNotRegex(line, r"(?<!\|)\|(?!\|)")
        self.assertIn("MAX_DEVICE_CANDIDATES=18", text)
        self.assertIn("PID_SCAN_MAX=4096", text)
        self.assertIn("FD_NUMBER_MAX=127", text)
        self.assertNotRegex(text, r'(?:<|dd if=)"?\$ACTUAL')
        snapshot = text[text.index("snapshot_library()") :]
        self.assertLess(snapshot.index("SOURCE_TYPE=$(stat"), snapshot.index("exec 3<"))
        self.assertLess(snapshot.index("effective_mount_invalid"), snapshot.index("exec 3<"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
