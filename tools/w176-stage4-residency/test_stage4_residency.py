from __future__ import annotations

import hashlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PAYLOAD = ROOT / "payload"
EXPECTED_HASH = "57fa924988d500224b3eb3ae74fb0408d8c8dd83cb7a702df560307be4307bd6"


class ResidencyStaticTests(unittest.TestCase):
    def test_exact_binary_hash_and_size(self) -> None:
        binary = PAYLOAD / "geminitop-proofd"
        self.assertFalse(binary.is_symlink())
        data = binary.read_bytes()
        self.assertEqual(len(data), 5556)
        self.assertEqual(hashlib.sha256(data).hexdigest(), EXPECTED_HASH)

    def test_no_live_arming_marker_is_committed(self) -> None:
        for name in (
            "ARM_STAGE4B_INSTALL",
            "ARM_STAGE4B_VERIFY_AFTER_REMOVAL",
            "ARM_STAGE4B_UNINSTALL",
        ):
            self.assertFalse((PAYLOAD / name).exists())
            self.assertTrue((PAYLOAD / f"{name}.example").is_file())

    def test_daemon_source_has_only_volatile_status_paths(self) -> None:
        text = (ROOT / "geminitop-proofd.c").read_text()
        self.assertIn('"/tmp/geminitop-proofd.status"', text)
        for token in (
            "/dev/", "/media/", "/proc/", "/sys/", "socket(", "connect(",
            "listen(", "ioctl(", "canbox", "hc_mcu", "Launcher",
        ):
            self.assertNotIn(token, text)

    def test_persistent_path_is_dedicated_and_non_shadowing(self) -> None:
        common = (PAYLOAD / "common.sh").read_text()
        self.assertIn("INSTALL_PARENT=$NVM_ROOT/geminitop", common)
        self.assertIn("INSTALL_DIR=$INSTALL_PARENT/w176", common)
        self.assertNotIn("$NVM_ROOT/bin", common)
        self.assertNotIn("$NVM_ROOT/lib", common)

    def test_installer_executes_destination_from_tmp(self) -> None:
        text = (PAYLOAD / "install.sh").read_text()
        self.assertIn('(cd /tmp && exec "$DEST_BINARY"', text)
        self.assertIn('PROCESS_EXE_ONE" = "$DEST_BINARY', text)
        self.assertIn('validate_process_detached_from_usb "$PROCESS_PID"', text)
        self.assertNotIn('exec "$SOURCE_BINARY"', text)

    def test_uninstall_has_no_recursive_or_wildcard_remove(self) -> None:
        text = (PAYLOAD / "uninstall.sh").read_text()
        self.assertNotRegex(text, r"\brm\s+-(?:[^\n ]*r|[^\n ]*R)")
        for line in text.splitlines():
            if re.search(r"\brm\b", line):
                self.assertNotRegex(line, r"\brm\b[^\n]*(?:\*|\?)")
        self.assertIn('rm -f "$DEST_MANIFEST"', text)
        self.assertIn('rm -f "$DEST_BINARY"', text)

    def test_no_boot_or_stock_mutation_commands(self) -> None:
        scripts = "\n".join(
            (PAYLOAD / name).read_text()
            for name in ("common.sh", "install.sh", "verify_after_removal.sh", "uninstall.sh")
        )
        for token in (
            "flash_erase", "nandwrite", "fw_setenv", "devmem", "/dev/mtd",
            "LD_LIBRARY_PATH=", "PATH=$NVM", "killall", "reboot", "insmod",
            "modprobe", "candump", "cansniffer", "ip link", "nc -l", "telnetd",
        ):
            self.assertNotIn(token, scripts)

    def test_uninstall_requires_hash_manifest_identity_and_term(self) -> None:
        text = (PAYLOAD / "uninstall.sh").read_text()
        for required in (
            'validate_hash "$DEST_BINARY"',
            'validate_manifest "$DEST_MANIFEST"',
            'read_process_identity "$CANDIDATE_PID"',
            'kill -TERM "$MATCHED_PID"',
            'rmdir "$INSTALL_DIR"',
        ):
            self.assertIn(required, text)
        self.assertNotIn("kill -KILL", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
