#!/usr/bin/env python3
"""
ppm2png.py - convert the testbench's framebuffer dumps to PNG

The testbench writes binary PPM (P6) because that is trivial to emit from
Verilog. This turns them into PNGs using only the standard library.

    python scripts/ppm2png.py frame0001.ppm [more.ppm ...]
    python scripts/ppm2png.py --dir build/frames
"""
import argparse
import struct
import sys
import zlib
from pathlib import Path


def read_ppm(path: Path):
    data = path.read_bytes()
    fields, pos = [], 0
    while len(fields) < 4:                       # magic, width, height, maxval
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":            # comment line
            while pos < len(data) and data[pos] != 0x0A:
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    if fields[0] != b"P6":
        raise ValueError(f"{path}: not a binary PPM")
    w, h, maxval = (int(f) for f in fields[1:])
    if maxval != 255:
        raise ValueError(f"{path}: unsupported maxval {maxval}")
    pixels = data[pos + 1:]
    if len(pixels) < w * h * 3:
        raise ValueError(f"{path}: truncated ({len(pixels)} of {w * h * 3} bytes)")
    return w, h, pixels[:w * h * 3]


def write_png(path: Path, w: int, h: int, rgb: bytes):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def convert(ppm: Path) -> Path:
    w, h, rgb = read_ppm(ppm)
    png = ppm.with_suffix(".png")
    write_png(png, w, h, rgb)
    return png


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--dir", type=Path, help="convert every .ppm in this directory")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    files = list(args.files)
    if args.dir:
        files += sorted(args.dir.glob("*.ppm"))
    if not files:
        print("nothing to convert")
        return 1
    for ppm in files:
        png = convert(ppm)
        if not args.quiet:
            print(f"{ppm.name} -> {png.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
