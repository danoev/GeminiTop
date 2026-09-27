"""Permanent round-2 regressions. All targets are disposable host fixtures."""
from __future__ import annotations

import hashlib
import os
import signal
import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path

from analyze_topology import InvalidCapture, analyze
import test_stage4_topology as existing
from test_stage4_topology import Fixture, rewrite_checksum


class Round2Tests(unittest.TestCase):
    setUp = existing.Stage4ATests.setUp
    tearDown = existing.Stage4ATests.tearDown
    assert_incomplete = existing.Stage4ATests.assert_incomplete
    assert_library_special_rejected = existing.Stage4ATests.assert_library_special_rejected

    def test_late_transaction_failure_matrix(self):
        operations = [
            'status_write COMPLETE',
            'hash_committed STATUS.txt',
            "printf 'complete=1\\n' > \"$COMPLETE_TEMP\"",
            'COMPLETE_SIZE=$(stat -c \'%s\' "$COMPLETE_TEMP")',
            '[ "$COMPLETE_SIZE" = 11 ]',
            'COMPLETE_CONTENT=$(dd if="$COMPLETE_TEMP" bs=12 count=1 2>/dev/null)',
            '[ "$COMPLETE_CONTENT" = \'complete=1\' ]',
            'strict_sha256 "$COMPLETE_TEMP" COMPLETE',
            'rm -f "$CHECKSUM_PATHS" .sha256-output.tmp .sha256-digest.tmp 2>/dev/null',
            'commit_file "$CHECKSUM_WORK" checksums.sha256',
            'is_regular_nonsymlink "$REQUIRED"',
            '[ ! -s ERRORS.txt ]',
            'du -sk . > .du-output.tmp 2>/dev/null',
            'IFS= read -r OUTPUT_KIB < .du-value.tmp',
            '[ "$OUTPUT_KIB" -le "$MAX_TOTAL_OUTPUT_KIB" ]',
            'rm -f .du-output.tmp .du-value.tmp',
            'is_regular_nonsymlink "$COMPLETE_TEMP"',
            '[ ! -e COMPLETE ] && [ ! -L COMPLETE ]',
            'mv "$COMPLETE_TEMP" COMPLETE',
        ]
        text = (self.fixture.usb / "stage4_topology.sh").read_text()
        tail = text[text.index("final_transaction()"):]
        operations += [line.strip().split(" || finish_incomplete")[0]
                       for line in tail.splitlines() if line.strip().startswith("awk ")]
        for operation in operations:
            with self.subTest(operation=operation):
                fixture = Fixture()
                try:
                    fixture.replace(operation + " || finish_incomplete",
                                    "false || finish_incomplete")
                    result = fixture.run()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()

    def test_status_hash_failure_variants(self):
        bodies = [
            "raise SystemExit(1)",
            "print(hashlib.sha256(data).hexdigest()+'  '+name); raise SystemExit(1)",
            "print('z'*64+'  '+name)",
            "print('a'*63+'  '+name)",
            "print('a'*64+'  '+name+' extra')",
        ]
        for body in bodies:
            with self.subTest(body=body):
                fixture = Fixture()
                try:
                    fixture.command("sha256sum", "import hashlib,sys\nname=sys.argv[1]\ndata=open(name,'rb').read()\n"
                                    "if name=='STATUS.txt':\n " + body +
                                    "\nelse: print(hashlib.sha256(data).hexdigest()+'  '+name)\n")
                    self.assertNotEqual(fixture.run().returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()

    def nested_mount(self, fs="tmpfs", options="rw"):
        with (self.fixture.proc / "self/mounts").open("a") as stream:
            stream.write(f"nested {(self.fixture.target / 'application/lib').resolve()} {fs} {options} 0 0\n")

    def test_nested_writable_mount_rejected(self):
        self.nested_mount()
        self.assert_incomplete(self.fixture.run())
        self.assertFalse((self.fixture.output() / "files/libappframework.so.1.0.0").exists())

    def test_nested_readonly_ext4_mount_rejected(self):
        self.nested_mount("ext4", "ro")
        self.assert_incomplete(self.fixture.run())

    def test_ambiguous_escaped_duplicate_and_truncated_mount_tables_rejected(self):
        for extra in ["DUPLICATE",
                      "nested /escaped\\040mount tmpfs rw 0 0\n",
                      "nested /too-large tmpfs rw 0 0\n"*5000]:
            with self.subTest(extra=extra[:80]):
                fixture = Fixture()
                try:
                    if extra == "DUPLICATE":
                        extra = (fixture.proc / "self/mounts").read_text().splitlines()[1]+"\n"
                    with (fixture.proc / "self/mounts").open("a") as stream:
                        stream.write(extra)
                    self.assertNotEqual(fixture.run().returncode, 0)
                    self.assertFalse((fixture.output() / "COMPLETE").exists())
                finally:
                    fixture.cleanup()

    def test_final_failure_count_gate_blocks_complete(self):
        self.fixture.replace('    [ "$FAILURES" -eq 0 ] || finish_incomplete\n'
                             '    # Exact hashed temp is renamed LAST.',
                             '    record_failure injected_late_failure\n'
                             '    [ "$FAILURES" -eq 0 ] || finish_incomplete\n'
                             '    # Exact hashed temp is renamed LAST.')
        self.assert_incomplete(self.fixture.run())

    def test_unrelated_and_component_boundary_mounts_allowed(self):
        with (self.fixture.proc / "self/mounts").open("a") as stream:
            for suffix in ("elsewhere", "application/lib2"):
                stream.write(f"nested {self.fixture.target.resolve() / suffix} tmpfs rw 0 0\n")
        self.assertEqual(self.fixture.run().returncode, 0)
        self.assertEqual(analyze(self.fixture.output())["classification"], "CASE A")

    def test_different_source_device_rejected(self):
        path = self.fixture.bin / "stat"
        text = path.read_text()
        text = text.replace("print(fmt)", "print('99999999' if fmt==str(value.st_dev) and path.endswith('libappframework.so.1.0.0') else fmt)")
        path.write_text(text)
        self.assert_incomplete(self.fixture.run())

    def test_mount_change_before_child_revalidation_rejected(self):
        app = (self.fixture.target / "application/lib").resolve()
        mounts = self.fixture.proc / "self/mounts"
        self.fixture.replace("        CANONICAL=$(/bin/sh",
                             f"        printf 'nested {app} tmpfs rw 0 0\\n' >> '{mounts}'\n        CANONICAL=$(/bin/sh")
        self.assert_incomplete(self.fixture.run())

    def test_rejected_mutable_mount_cannot_reach_swap_or_fifo_open(self):
        self.nested_mount()
        # Attempted swap hook must be unreachable after effective-mount rejection.
        sentinel = self.fixture.root / "swap-reached"
        fifo = self.fixture.root / "swap-fifo"
        os.mkfifo(fifo)
        opened = self.fixture.root / "fifo-opened"
        self.fixture.replace('        exec 3< "$SOURCE" || exit 25',
                             f"        printf reached > '{sentinel}'\n"
                             f"        rm -f \"$SOURCE\"; mv '{fifo}' \"$SOURCE\"\n"
                             '        exec 3< "$SOURCE" || exit 25')
        writer = subprocess.Popen([sys.executable, "-c",
            "import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY); open(sys.argv[2],'w').write('opened')",
            str(fifo), str(opened)], start_new_session=True)
        try:
            self.assert_incomplete(self.fixture.run())
            time.sleep(.05)
            self.assertFalse(sentinel.exists())
            self.assertFalse(opened.exists())
            self.assertIsNone(writer.poll())
        finally:
            if writer.poll() is None:
                os.killpg(writer.pid, signal.SIGKILL)
            writer.wait()

    def test_normal_proc_symlink_and_sysfs_class_links(self):
        self.assertTrue((self.fixture.proc / "mounts").is_symlink())
        self.assertTrue((self.fixture.sys / "class/net/can0").is_symlink())
        self.assertEqual(self.fixture.run().returncode, 0)
        self.assertIn("can0.type=280", (self.fixture.output() / "network/interfaces.txt").read_text())
        self.assertEqual(analyze(self.fixture.output())["classification"], "CASE A")

    def test_out_of_root_sysfs_link_fails_closed(self):
        link = self.fixture.sys / "class/net/can0"
        link.unlink()
        link.symlink_to(self.fixture.target / "application")
        self.assert_incomplete(self.fixture.run())

    def test_missing_sysfs_attribute_is_optional(self):
        (self.fixture.sys / "devices/virtual/net/can0/address").unlink()
        self.assertEqual(self.fixture.run().returncode, 0)
        self.assertIn("interface_attribute_absent:can0:address",
                      (self.fixture.output() / "OPTIONAL.txt").read_text())
        analyze(self.fixture.output())

    def test_socket_library_rejected(self):
        library = self.fixture.target / "application/lib/libappframework.so.1.0.0"
        library.unlink()
        with socket.socket(socket.AF_UNIX) as stream:
            try:
                stream.bind(str(library))
            except PermissionError as exc:
                self.skipTest(f"host sandbox prohibits socket fixture: {exc}")
            self.assert_incomplete(self.fixture.run())

    def test_impossible_checksummed_summary_fields_rejected(self):
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        path = root / "SUMMARY.txt"
        original = path.read_text()
        for key, value in [("interfaces", 1), ("interfaces", 33), ("device_candidates", 19),
                           ("device_candidates", 1), ("processes_inspected", 999999),
                           ("processes_inspected", 0), ("fd_links_inspected", 4097),
                           ("fd_links_inspected", 0), ("matched_owners", 17),
                           ("library_bytes", 720897), ("library_bytes", 1)]:
            with self.subTest(key=key, value=value):
                path.write_text("\n".join(f"{key}={value}" if line.startswith(key+"=") else line
                                          for line in original.splitlines())+"\n")
                rewrite_checksum(root, "SUMMARY.txt")
                with self.assertRaises(InvalidCapture):
                    analyze(root)
        path.write_text(original)
        rewrite_checksum(root, "SUMMARY.txt")

    def test_optional_count_and_record_shape_rejected(self):
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        for value in ["optional.1=undercounted\n", "optional.2=bad-sequence\n", "garbage\n"]:
            (root / "OPTIONAL.txt").write_text(value)
            rewrite_checksum(root, "OPTIONAL.txt")
            with self.assertRaises(InvalidCapture):
                analyze(root)

    def test_conflicting_owner_identity_rejected(self):
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        path = root / "processes/owners.txt"
        original = path.read_text()
        for record in ["101|101|999999|7|/dev/hc_mcu_dev\n",
                       "101|101|10101|7|/dev/canbox_protocol_dev\n",
                       "101|101|999999|8|/dev/hc_mcu_dev\n",
                       "101|999|10101|8|/dev/hc_mcu_dev\n"]:
            path.write_text(original+record)
            rewrite_checksum(root, "processes/owners.txt")
            with self.assertRaises(InvalidCapture):
                analyze(root)

    def synthetic_owners(self, count, maps_size):
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        inventory = root / "capture-inventory.txt"
        original = [line for line in inventory.read_text().splitlines() if not line.startswith("owner_")]
        manifest = root / "checksums.sha256"
        hashes = [line for line in manifest.read_text().splitlines()
                  if "  processes/101-" not in line and not line.endswith("  processes/leaders.txt")]
        templates = {kind: (root / f"processes/101-{kind}{suffix}").read_bytes()
                     for kind, suffix in [("comm", ".txt"), ("cmdline", ".bin"), ("exe", ".txt"), ("maps", ".txt")]}
        for path in (root / "processes").glob("101-*"):
            path.unlink()
        records = []
        leaders = []
        for pid in range(100,100+count):
            records.append(f"{pid}|{pid}|{10000+pid}|7|/dev/hc_mcu_dev")
            leaders.append(f"{pid}|{pid}|{10000+pid}")
            for kind, suffix in [("comm",".txt"), ("cmdline",".bin"), ("exe",".txt"), ("maps",".txt")]:
                data = b"x"*maps_size if kind=="maps" else templates[kind]
                relative = f"processes/{pid}-{kind}{suffix}"
                (root / relative).write_bytes(data)
                original.append(f"owner_{kind}_{pid}|OWNER|OK|/proc/{pid}/{kind}|{len(data)}|{relative}")
                hashes.append(f"{hashlib.sha256(data).hexdigest()}  {relative}")
        inventory.write_text("\n".join(original)+"\n")
        (root / "processes/owners.txt").write_text("\n".join(records)+"\n")
        leader_data = ("\n".join(leaders)+"\n").encode()
        (root / "processes/leaders.txt").write_bytes(leader_data)
        hashes.append(f"{hashlib.sha256(leader_data).hexdigest()}  processes/leaders.txt")
        summary = root / "SUMMARY.txt"
        summary.write_text("\n".join(f"{key}={value}" for key,value in
                          (line.split("=",1) for line in summary.read_text().splitlines())
                          if key not in {"matched_owners","processes_inspected","fd_links_inspected"})+
                           f"\nmatched_owners={count}\nprocesses_inspected={count}\nfd_links_inspected={count}\n")
        manifest.write_text("\n".join(hashes)+"\n")
        for name in ["capture-inventory.txt", "processes/owners.txt", "SUMMARY.txt"]:
            rewrite_checksum(root,name)
        return root

    def test_seventeen_dynamic_owner_groups_rejected(self):
        with self.assertRaises(InvalidCapture):
            analyze(self.synthetic_owners(17,32))

    def test_aggregate_maps_bound_independently_enforced(self):
        with self.assertRaisesRegex(InvalidCapture,"aggregate maps"):
            analyze(self.synthetic_owners(16,65536))

    def test_interfaces_devices_duplicate_and_conflict_rejected(self):
        self.assertEqual(self.fixture.run().returncode, 0)
        root = self.fixture.output()
        for name, extra in [("network/interfaces.txt","interface=can0\n"),
                            ("devices/device-nodes.txt",(root / "devices/device-nodes.txt").read_text().splitlines()[0]+"\n")]:
            with (root / name).open("a") as stream:
                stream.write(extra)
            rewrite_checksum(root,name)
            with self.assertRaises(InvalidCapture):
                analyze(root)

    def test_output_property_is_honest_and_append_admission_is_bounded(self):
        self.assertEqual(self.fixture.run().returncode, 0)
        caps = (self.fixture.output() / "CAPABILITIES.txt").read_text()
        self.assertIn("output.final_capture.kib.max=2048",caps)
        self.assertIn("output.write_ceiling=NOT_CLAIMED",caps)
        self.assertIn("all_writers.individually_bounded=1",caps)
        self.assertNotIn("output.kib.max=",caps)
        # The append guard must reject before writing a record over its file cap.
        fixture = Fixture()
        try:
            path = fixture.usb / "stage4_topology.sh"
            path.write_text(path.read_text().replace("append_bounded network/interfaces.txt 262144",
                                                    "append_bounded network/interfaces.txt 1"))
            self.assertNotEqual(fixture.run().returncode,0)
            self.assertEqual((fixture.output() / "network/interfaces.txt").stat().st_size,0)
        finally:
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
