#!/usr/bin/env python3
"""Reproduce round-2 findings using the frozen rejected code and temp fixtures."""
from __future__ import annotations

import hashlib
import os
import signal
import subprocess
import sys
import tempfile
import types
from pathlib import Path

FROZEN = "11376fc13f61cf0f05a3bfd45ab287e5f42982d0"
REPO = Path(__file__).resolve().parents[2]
PREFIX = "tools/w176-stage4-topology/"


def frozen_file(relative: str) -> str:
    return subprocess.check_output(["git", "show", f"{FROZEN}:{PREFIX}{relative}"], cwd=REPO, text=True)


def refresh(root: Path, relative: str) -> None:
    manifest = root / "checksums.sha256"
    digest = hashlib.sha256((root / relative).read_bytes()).hexdigest()
    lines = [f"{digest}  {relative}" if line.endswith(f"  {relative}") else line for line in manifest.read_text().splitlines()]
    manifest.write_text("\n".join(lines) + "\n")


def main() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as scratch:
        payload = Path(scratch) / "payload"
        payload.mkdir()
        for name in ("gemn_auto.sh", "mount_guard.sh", "stage4_topology.sh"):
            (payload / name).write_text(frozen_file("payload/" + name))
        analyzer = types.ModuleType("frozen_analyzer")
        exec(compile(frozen_file("analyze_topology.py"), "frozen_analyzer", "exec"), analyzer.__dict__)
        sys.modules["analyze_topology"] = analyzer
        fixture_module = types.ModuleType("frozen_fixture")
        fixture_module.__file__ = str(REPO / PREFIX / "test_stage4_topology.py")
        exec(compile(frozen_file("test_stage4_topology.py"), "frozen_fixture", "exec"), fixture_module.__dict__)
        fixture_module.PAYLOAD = payload
        Fixture = fixture_module.Fixture
        reproduced = 0

        def result(label: str, condition: bool) -> None:
            nonlocal reproduced
            print(f"{label}: {'REPRODUCED' if condition else 'NOT REPRODUCED'}", flush=True)
            if not condition:
                raise AssertionError(label)
            reproduced += 1

        for label, behavior in (("1_STATUS_hash_nonzero_empty", "raise SystemExit(7)"),
                                ("2_STATUS_hash_nonzero_valid", "print(f'{digest}  {name}'); raise SystemExit(7)"),
                                ("3_STATUS_hash_malformed", "print('z'*64+'  '+name)")):
            f = Fixture()
            try:
                f.command("sha256sum", "import hashlib,sys\nname=sys.argv[1]; digest=hashlib.sha256(open(name,'rb').read()).hexdigest()\n"
                          + "if name=='STATUS.txt':\n " + behavior + "\nelse: print(f'{digest}  {name}')\n")
                run = f.run()
                result(label, run.returncode == 0 and (f.output() / "COMPLETE").exists())
            finally:
                f.cleanup()

        f = Fixture()
        try:
            with (f.proc / "mounts").open("a") as mounts:
                mounts.write(f"tmpfs {f.target / 'application/lib'} tmpfs rw 0 0\n")
            result("4_nested_writable_mount_accepted", f.run().returncode == 0)
        finally:
            f.cleanup()

        f = Fixture()
        writer = None
        process = None
        try:
            with (f.proc / "mounts").open("a") as mounts:
                mounts.write(f"tmpfs {f.target / 'application/lib'} tmpfs rw 0 0\n")
            fifo = f.root / "swap-fifo"
            sentinel = f.root / "OPENED"
            os.mkfifo(fifo)
            writer = subprocess.Popen([sys.executable, "-c", "import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY); open(sys.argv[2],'w').write('OPENED'); os.write(fd,b'x'); os.close(fd)", str(fifo), str(sentinel)], start_new_session=True)
            f.replace('        exec 3< "$SOURCE" || exit 25',
                      f'        if [ "$SOURCE" = "{f.target}/application/lib/libappframework.so.1.0.0" ]; then rm -f "$SOURCE"; mv "{fifo}" "$SOURCE"; fi\n        exec 3< "$SOURCE" || exit 25')
            process = subprocess.Popen(["/bin/sh", "gemn_auto.sh"], cwd=f.usb, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            result("5_nested_mount_swap_opens_FIFO", sentinel.exists())
        finally:
            for child in (process, writer):
                if child is not None and child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            f.cleanup()

        f = Fixture()
        try:
            original = f.proc / "mounts"
            actual = f.proc / "self-mounts"
            original.rename(actual)
            original.symlink_to(actual)
            result("6_proc_mounts_symlink_rejected", f.run().returncode != 0)
        finally:
            f.cleanup()

        f = Fixture()
        try:
            device = f.sys / "devices/virtual/net/can0"
            device.parent.mkdir(parents=True)
            (f.sys / "class/net/can0").rename(device)
            (f.sys / "class/net/can0").symlink_to("../../devices/virtual/net/can0")
            run = f.run()
            result("7_sysfs_class_link_loses_type280", run.returncode == 0 and analyzer.analyze(f.output())["classification"] == "CASE D")
        finally:
            f.cleanup()

        for label, edit in (("8_impossible_process_count", lambda r: (r / "SUMMARY.txt").write_text((r / "SUMMARY.txt").read_text().replace("processes_inspected=1", "processes_inspected=999999"))),
                            ("9_OPTIONAL_count_mismatch", lambda r: (r / "OPTIONAL.txt").write_text("optional.1=unexpected\n")),
                            ("12_conflicting_owner_start", lambda r: (r / "processes/owners.txt").write_text((r / "processes/owners.txt").read_text() + "101|99999|7|/dev/hc_mcu_dev\n"))):
            f = Fixture()
            try:
                assert f.run().returncode == 0
                root = f.output()
                edit(root)
                for relative in ("SUMMARY.txt", "OPTIONAL.txt", "processes/owners.txt"):
                    refresh(root, relative)
                result(label, analyzer.analyze(root)["capture_validation"] == "PASS")
            finally:
                f.cleanup()

        for label, count, maps_size in (("10_seventeen_owner_groups", 17, 32), ("11_aggregate_maps_exceeded", 16, 65536)):
            f = Fixture()
            try:
                assert f.run().returncode == 0
                root = f.output()
                inventory = root / "capture-inventory.txt"
                rows = [line for line in inventory.read_text().splitlines() if not line.startswith("owner_")]
                checksums = root / "checksums.sha256"
                hash_rows = [line for line in checksums.read_text().splitlines() if not line.split("  ")[1].startswith("processes/101-")]
                owners = []
                for pid in range(101, 101 + count):
                    owners.append(f"{pid}|{10000+pid}|7|/dev/hc_mcu_dev")
                    for kind, suffix, data in (("comm", "comm.txt", b"owner\n"), ("cmdline", "cmdline.bin", b"owner\0"), ("exe", "exe.txt", b"/application/bin/Launcher\n"), ("maps", "maps.txt", b"x" * maps_size)):
                        relative = f"processes/{pid}-{suffix}"
                        (root / relative).write_bytes(data)
                        rows.append(f"owner_{kind}_{pid}|OWNER|OK|/proc/{pid}/{kind}|{len(data)}|{relative}")
                        hash_rows.append(f"{hashlib.sha256(data).hexdigest()}  {relative}")
                inventory.write_text("\n".join(rows) + "\n")
                checksums.write_text("\n".join(hash_rows) + "\n")
                (root / "processes/owners.txt").write_text("\n".join(owners) + "\n")
                summary = root / "SUMMARY.txt"
                summary.write_text(summary.read_text().replace("matched_owners=1", f"matched_owners={count}"))
                for relative in ("capture-inventory.txt", "processes/owners.txt", "SUMMARY.txt"):
                    refresh(root, relative)
                result(label, analyzer.analyze(root)["capture_validation"] == "PASS")
            finally:
                f.cleanup()

        f = Fixture()
        try:
            f.replace("MAX_TOTAL_OUTPUT_KIB=2048", "MAX_TOTAL_OUTPUT_KIB=1")
            run = f.run()
            result("13_output_limit_is_post_collection", run.returncode != 0 and (f.output() / "files/libappframework.so.1.0.0").exists())
        finally:
            f.cleanup()
        print(f"frozen={FROZEN}\nreproduced={reproduced}")


if __name__ == "__main__":
    main()
