#!/usr/bin/env python3
"""Run the frozen GO candidate only against disposable synthetic proc fixtures."""
from __future__ import annotations

import shutil
import shlex
import subprocess
from pathlib import Path

from test_stage4_topology import Fixture


FROZEN = "17557e6481d68799712779ca605b87e2da866e47"
REPO = Path(__file__).resolve().parents[2]
SOURCE = "tools/w176-stage4-topology/payload/stage4_topology.sh"


def main() -> None:
    fixture = Fixture()
    try:
        frozen = subprocess.check_output(["git", "show", f"{FROZEN}:{SOURCE}"], cwd=REPO, text=True)
        substitutions = {
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin": f"PATH={shlex.quote(str(fixture.bin))}",
            "TARGET_ROOT=/": f"TARGET_ROOT={shlex.quote(str(fixture.target))}",
            "TARGET_MOUNTS_FILE=/proc/self/mounts": f"TARGET_MOUNTS_FILE={shlex.quote(str(fixture.proc / 'self/mounts'))}",
            "PROCESS_ROOT=/proc": f"PROCESS_ROOT={shlex.quote(str(fixture.proc / 'process'))}",
            "FD_ROOT=/proc/self/fd": "FD_ROOT=/dev/fd",
            "SYS_NET_ROOT=/sys/class/net": f"SYS_NET_ROOT={shlex.quote(str(fixture.sys / 'class/net'))}",
            "SYS_DEVICES_ROOT=/sys/devices": f"SYS_DEVICES_ROOT={shlex.quote(str(fixture.sys / 'devices'))}",
            "SYS_DEV_CHAR_ROOT=/sys/dev/char": f"SYS_DEV_CHAR_ROOT={shlex.quote(str(fixture.sys / 'dev/char'))}",
            "DEV_ROOT=/dev": f"DEV_ROOT={shlex.quote(str(fixture.dev))}",
        }
        for old, new in substitutions.items():
            if frozen.count(old) != 1:
                raise AssertionError(f"frozen production path changed unexpectedly: {old}")
            frozen = frozen.replace(old, new)
        (fixture.usb / "stage4_topology.sh").write_text(frozen)
        shutil.rmtree(fixture.proc / "process/101")
        for ident in range(700, 721):
            fixture.add_owner(ident, fixture.dev / "hc_mcu_dev")
            (fixture.proc / "process" / str(ident) / "status").write_text(
                f"Name:\t{'Launcher' if ident == 700 else 'QThread'}\n"
                f"Tgid:\t700\nPid:\t{ident}\n"
            )
        result = fixture.run(timeout=30)
        output = fixture.output()
        errors = (output / "ERRORS.txt").read_text()
        owners = (output / "processes/owners.txt").read_text()
        summary = (output / "SUMMARY.txt").read_text()
        if result.returncode == 0 or "owner_limit" not in errors or (output / "COMPLETE").exists():
            raise AssertionError(f"frozen candidate did not reproduce fail-closed owner_limit: rc={result.returncode} errors={errors!r} stderr={result.stderr!r} summary={summary!r}")
        if "701|" not in owners or "matched_owners=17" not in summary:
            raise AssertionError("frozen candidate did not duplicate non-leader TIDs")
        print(f"frozen_candidate={FROZEN}")
        print("single_TGID=700; numeric_identities=21")
        print("old_model=owner_limit; matched_owners=17; nonleader_701_retained=YES")
        print("valid_COMPLETE=NO; result=REPRODUCED")
    finally:
        fixture.cleanup()


if __name__ == "__main__":
    main()
