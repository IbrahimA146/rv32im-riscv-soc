#!/usr/bin/env python3
"""Convert a flat binary image into a $readmemh file of 32-bit little-endian words."""
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <in.bin> <out.hex>")
        return 1
    data = open(sys.argv[1], "rb").read()
    data += b"\0" * (-len(data) % 4)
    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
