from __future__ import annotations

import hashlib
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "inspect_firmware.py"
SPEC = importlib.util.spec_from_file_location("inspect_firmware", MODULE_PATH)
assert SPEC and SPEC.loader
INSPECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECT)


def uimage(payload: bytes, declared_size: int | None = None) -> bytes:
    size = len(payload) if declared_size is None else declared_size
    name = b"test".ljust(32, b"\0")
    data_crc = zlib.crc32(payload) & 0xFFFFFFFF
    header = bytearray(
        struct.pack(">7I4B32s", 0x27051956, 0, 1, size, 0, 0, data_crc, 5, 2, 6, 0, name)
    )
    struct.pack_into(">I", header, 4, zlib.crc32(header) & 0xFFFFFFFF)
    return bytes(header) + payload


def squashfs_superblock(**overrides: int) -> bytes:
    values = {
        "magic": 0x73717368,
        "inode_count": 4,
        "mkfs_time": 0,
        "block_size": 32768,
        "fragments": 1,
        "compression": 3,
        "block_log": 15,
        "flags": 0,
        "id_count": 1,
        "major": 4,
        "minor": 0,
        "root_inode": 0,
        "bytes_used": 512,
        "id_table": 500,
        "xattr_table": (1 << 64) - 1,
        "inode_table": 96,
        "directory_table": 200,
        "fragment_table": 400,
        "lookup_table": (1 << 64) - 1,
    }
    values.update(overrides)
    packed = struct.pack("<5I6H8Q", *values.values())
    return packed.ljust(values["bytes_used"], b"\0")


def component_container(corrupt_first: bool = False) -> bytes:
    blob = bytearray(0x800)
    blob[:6] = b"GEMINI"
    struct.pack_into("<I", blob, 0xD8, 0x400)
    struct.pack_into("<I", blob, 0xDC, 0x400)
    for index, (name, relative, data) in enumerate(
        ((b"rootfs.", 0x200, b"A" * 16), (b"spapp.", 0x240, b"B" * 16))
    ):
        absolute = 0x400 + relative
        blob[absolute : absolute + len(data)] = data
        record = 0x100 + index * 0x80
        blob[record : record + len(name)] = name
        digest = hashlib.md5(data).hexdigest().encode("ascii")
        blob[record + 0x20 : record + 0x40] = digest
        struct.pack_into("<IIII", blob, record + 0x40, 0, relative, len(data), 0)
    if corrupt_first:
        blob[0x400 + 0x200] = ord("Z")
    return bytes(blob)


class FirmwareInspectionTests(unittest.TestCase):
    def inspect_bytes(self, value: bytes):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.bin"
            path.write_bytes(value)
            return INSPECT.inspect_binary(path, "input.bin")

    def test_valid_uimage_is_inventory_metadata(self):
        report = self.inspect_bytes(b"prefix" + uimage(b"payload"))
        self.assertEqual(len(report["embedded_images"]), 1)
        self.assertEqual(report["embedded_images"][0]["offset"], 6)
        self.assertTrue(report["embedded_images"][0]["header_crc_ok"])

    def test_truncated_uimage_is_rejected_by_bounds_check(self):
        report = self.inspect_bytes(uimage(b"short", declared_size=4096))
        self.assertEqual(report["embedded_images"], [])
        self.assertIn("bounds", report["rejected_uimage_candidates"][0]["error"])

    def test_squashfs_out_of_bounds_is_rejected(self):
        superblock = struct.pack(
            "<5I6H8Q",
            0x73717368,
            1,
            0,
            131072,
            0,
            4,
            17,
            0,
            1,
            4,
            0,
            0,
            999999,
            0,
            0,
            0,
            0,
            0,
            0,
        )
        report = self.inspect_bytes(superblock)
        self.assertEqual(report["filesystems"], [])
        self.assertFalse(report["rejected_squashfs_candidates"][0]["bounds_ok"])

    def test_squashfs_structural_fields_are_validated(self):
        valid = self.inspect_bytes(squashfs_superblock())
        self.assertEqual(len(valid["filesystems"]), 1)
        self.assertTrue(valid["filesystems"][0]["tables_ok"])

        bad_log = self.inspect_bytes(squashfs_superblock(block_log=14))
        self.assertEqual(bad_log["filesystems"], [])
        bad_table = self.inspect_bytes(squashfs_superblock(id_table=600))
        self.assertEqual(bad_table["filesystems"], [])
        bad_compression = self.inspect_bytes(squashfs_superblock(compression=99))
        self.assertEqual(bad_compression["filesystems"], [])

    def test_component_table_is_discovered_and_hash_checked(self):
        report = self.inspect_bytes(component_container())
        tables = report["container"]["component_tables"]
        self.assertEqual(len(tables), 1)
        self.assertTrue(tables[0]["valid"])
        self.assertTrue(all(item["md5_ok"] for item in tables[0]["components"]))

    def test_component_table_with_bad_md5_is_rejected(self):
        report = self.inspect_bytes(component_container(corrupt_first=True))
        self.assertEqual(report["container"]["component_tables"], [])
        rejected = report["container"]["rejected_component_tables"]
        self.assertEqual(len(rejected), 1)
        self.assertFalse(rejected[0]["valid"])
        self.assertIn("MD5", rejected[0]["error"])

    def test_zip_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("../escape.bin", b"not firmware")
            with self.assertRaises(INSPECT.InspectionError):
                INSPECT.inspect_input(path)

    def test_empty_binary_is_handled_as_malformed_content(self):
        report = self.inspect_bytes(b"")
        self.assertEqual(report["embedded_images"], [])
        self.assertEqual(report["filesystems"], [])

    def test_output_aliases_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "firmware.bin"
            source.write_bytes(b"firmware")
            with self.assertRaises(INSPECT.InspectionError):
                INSPECT.validate_output_path(source, source)

            symlink = root / "report.json"
            symlink.symlink_to(source)
            with self.assertRaises(INSPECT.InspectionError):
                INSPECT.validate_output_path(source, symlink)

            hardlink = root / "hardlink.json"
            os.link(source, hardlink)
            with self.assertRaises(INSPECT.InspectionError):
                INSPECT.validate_output_path(source, hardlink)

            for output in (source, symlink, hardlink):
                with self.subTest(output=output.name):
                    result = subprocess.run(
                        [sys.executable, str(MODULE_PATH), str(source), "--output", str(output)],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("aliases", result.stderr)
                    self.assertEqual(source.read_bytes(), b"firmware")

    def test_subprocess_timeout_and_output_limits(self):
        timed = INSPECT._run_limited(
            [sys.executable, "-c", "import time; time.sleep(10)"], 1, 1024, 1024
        )
        self.assertIn("timed out", timed["failure"])

        oversized = INSPECT._run_limited(
            [sys.executable, "-c", "import sys; sys.stdout.write('x' * 10000)"],
            5,
            128,
            128,
        )
        self.assertIn("output limit", oversized["failure"])
        self.assertLessEqual(len(oversized["stdout"]), 128)

        lingering_pipe = INSPECT._run_limited(
            ["/bin/sh", "-c", "/bin/sleep 10 &"], 5, 128, 128
        )
        self.assertIn("pipe lifetime", lingering_pipe["failure"])


if __name__ == "__main__":
    unittest.main()
