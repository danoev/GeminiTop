#!/usr/bin/env python3

import argparse
import os
import struct
import sys
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_WIDTH = 560
MAX_HEIGHT = 260


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def apply_filter(filter_type: int, row: bytearray, prev: bytes, bpp: int) -> bytearray:
    out = bytearray(len(row))
    if filter_type == 0:
        return row
    if filter_type == 1:
        for i, value in enumerate(row):
            left = out[i - bpp] if i >= bpp else 0
            out[i] = (value + left) & 0xFF
        return out
    if filter_type == 2:
        for i, value in enumerate(row):
            up = prev[i] if prev else 0
            out[i] = (value + up) & 0xFF
        return out
    if filter_type == 3:
        for i, value in enumerate(row):
            left = out[i - bpp] if i >= bpp else 0
            up = prev[i] if prev else 0
            out[i] = (value + ((left + up) // 2)) & 0xFF
        return out
    if filter_type == 4:
        for i, value in enumerate(row):
            left = out[i - bpp] if i >= bpp else 0
            up = prev[i] if prev else 0
            up_left = prev[i - bpp] if prev and i >= bpp else 0
            out[i] = (value + paeth(left, up, up_left)) & 0xFF
        return out
    raise ValueError(f"Unsupported PNG filter type: {filter_type}")


def decode_png(path: str):
    with open(path, "rb") as handle:
        data = handle.read()

    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Not a PNG file")

    pos = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = interlace = None
    palette = b""
    transparency = b""
    idat = bytearray()

    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError("Truncated PNG chunk header")
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        chunk_data = data[pos + 8:pos + 8 + length]
        pos += 12 + length

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
            if compression != 0 or filter_method != 0:
                raise ValueError("Unsupported PNG compression or filter method")
        elif chunk_type == b"PLTE":
            palette = chunk_data
        elif chunk_type == b"tRNS":
            transparency = chunk_data
        elif chunk_type == b"IDAT":
            idat.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width is None or height is None:
        raise ValueError("Missing IHDR chunk")
    if interlace != 0:
        raise ValueError("Interlaced PNGs are not supported")
    if bit_depth != 8:
        raise ValueError("Only 8-bit PNGs are supported")
    if color_type not in (0, 2, 3, 4, 6):
        raise ValueError(f"Unsupported PNG color type: {color_type}")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ValueError("Unexpected decompressed PNG data size")

    rgba = bytearray(width * height * 4)
    prev = b""
    src_pos = 0

    for y in range(height):
        filter_type = raw[src_pos]
        row = bytearray(raw[src_pos + 1:src_pos + 1 + stride])
        src_pos += stride + 1
        recon = apply_filter(filter_type, row, prev, channels if channels > 1 else 1)
        prev = bytes(recon)

        for x in range(width):
            dst = (y * width + x) * 4
            if color_type == 6:
                base = x * 4
                rgba[dst:dst + 4] = recon[base:base + 4]
            elif color_type == 2:
                base = x * 3
                rgba[dst:dst + 3] = recon[base:base + 3]
                rgba[dst + 3] = 255
            elif color_type == 4:
                base = x * 2
                gray = recon[base]
                alpha = recon[base + 1]
                rgba[dst:dst + 4] = bytes((gray, gray, gray, alpha))
            elif color_type == 0:
                gray = recon[x]
                rgba[dst:dst + 4] = bytes((gray, gray, gray, 255))
            elif color_type == 3:
                index = recon[x]
                pal = index * 3
                if pal + 2 >= len(palette):
                    raise ValueError("Palette index out of range")
                alpha = transparency[index] if index < len(transparency) else 255
                rgba[dst:dst + 4] = bytes((palette[pal], palette[pal + 1], palette[pal + 2], alpha))

    return width, height, rgba


def resize_rgba(width: int, height: int, rgba: bytes, max_width: int, max_height: int):
    if width <= max_width and height <= max_height:
        return width, height, rgba

    scale = min(max_width / float(width), max_height / float(height))
    new_width = max(1, int(round(width * scale)))
    new_height = max(1, int(round(height * scale)))
    out = bytearray(new_width * new_height * 4)

    for y in range(new_height):
        src_y = min(height - 1, int(y * height / new_height))
        for x in range(new_width):
            src_x = min(width - 1, int(x * width / new_width))
            src = (src_y * width + src_x) * 4
            dst = (y * new_width + x) * 4
            out[dst:dst + 4] = rgba[src:src + 4]

    return new_width, new_height, out


def write_asset(output_c: str, output_h: str, width: int, height: int, rgba: bytes):
    with open(output_h, "w", encoding="ascii") as handle:
        handle.write("#ifndef DVDLOGO_LOGO_ASSET_H\n")
        handle.write("#define DVDLOGO_LOGO_ASSET_H\n\n")
        handle.write("#include <stdint.h>\n\n")
        handle.write("extern const unsigned int dvd_logo_width;\n")
        handle.write("extern const unsigned int dvd_logo_height;\n")
        handle.write("extern const unsigned int dvd_logo_rgba_len;\n")
        handle.write("extern const uint8_t dvd_logo_rgba[];\n\n")
        handle.write("#endif\n")

    with open(output_c, "w", encoding="ascii") as handle:
        handle.write('#include "logo_asset.h"\n\n')
        handle.write(f"const unsigned int dvd_logo_width = {width};\n")
        handle.write(f"const unsigned int dvd_logo_height = {height};\n")
        handle.write(f"const unsigned int dvd_logo_rgba_len = {len(rgba)};\n")
        handle.write("const uint8_t dvd_logo_rgba[] = {\n")
        if rgba:
            for i in range(0, len(rgba), 12):
                chunk = rgba[i:i + 12]
                values = ", ".join(f"0x{byte:02X}" for byte in chunk)
                suffix = "," if i + len(chunk) < len(rgba) else ""
                handle.write(f"    {values}{suffix}\n")
        else:
            handle.write("    0x00\n")
        handle.write("};\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="")
    parser.add_argument("--output-c", required=True)
    parser.add_argument("--output-h", required=True)
    args = parser.parse_args()

    width = 0
    height = 0
    rgba = b""

    if args.input:
        if not os.path.exists(args.input):
            raise SystemExit(f"Input PNG not found: {args.input}")
        width, height, rgba = decode_png(args.input)
        width, height, rgba = resize_rgba(width, height, rgba, MAX_WIDTH, MAX_HEIGHT)
        print(f"Embedded PNG asset: {args.input} ({width}x{height})")
    else:
        print("No logo.png found; generating fallback-only build.")

    write_asset(args.output_c, args.output_h, width, height, rgba)


if __name__ == "__main__":
    main()
