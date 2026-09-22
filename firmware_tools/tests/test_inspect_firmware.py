from __future__ import annotations

import hashlib
import importlib.util
import struct
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

    def test_component_table_is_discovered_and_hash_checked(self):
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
        report = self.inspect_bytes(bytes(blob))
        tables = report["container"]["component_tables"]
        self.assertEqual(len(tables), 1)
        self.assertTrue(all(item["md5_ok"] for item in tables[0]["components"]))

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


if __name__ == "__main__":
    unittest.main()
