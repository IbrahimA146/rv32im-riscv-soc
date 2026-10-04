#!/usr/bin/env python3
"""
build_vsim.py - compile the RTL into a fast C++ simulator with Verilator

    python scripts/build_vsim.py                 # 64 KiB build used by the tests
    python scripts/build_vsim.py --ram-mb 16 --name doom

The result is build/vsim-<name>/vsim(.exe), driven by sim/verilator/main.cpp.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"

# Verilator on MSYS2 ships a Perl wrapper that needs modules which are not
# installed; verilator_bin is the real binary and takes the same arguments.
MSYS = Path(r"C:\msys64")
VERILATOR_ROOT = MSYS / "ucrt64/share/verilator"

WARN_OFF = ["-Wno-UNUSEDSIGNAL", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "-Wno-TIMESCALEMOD",
            "-Wno-UNUSEDPARAM", "-Wno-VARHIDDEN"]


def rtl_sources():
    return ([ROOT / "rtl/core/rv32_pkg.sv"]
            + sorted(p for p in (ROOT / "rtl/core").glob("*.sv") if p.name != "rv32_pkg.sv")
            + sorted((ROOT / "rtl/soc").glob("*.sv")))


def sdl_available() -> bool:
    """SDL2 is only needed for the interactive window."""
    if os.name == "nt":
        return (MSYS / "ucrt64/include/SDL2/SDL.h").is_file()
    return subprocess.run(["pkg-config", "--exists", "sdl2"], capture_output=True).returncode == 0


def build(name: str, ram_words: int, width: int, height: int, uart_div: int, jobs: int,
          sdl: bool = False, fast: bool = False, threads: int = 0) -> Path:
    outdir = BUILD / f"vsim-{name}"
    exe = outdir / ("vsim.exe" if os.name == "nt" else "vsim")
    defines = f"-DRAM_WORDS={ram_words} -DVID_WIDTH={width} -DVID_HEIGHT={height}"
    ldflags = []
    if sdl:
        if not sdl_available():
            raise SystemExit("SDL2 not found: install mingw-w64-ucrt-x86_64-SDL2")
        defines += " -DUSE_SDL"
        ldflags = ["-LDFLAGS", "-lmingw32 -lSDL2main -lSDL2" if os.name == "nt" else "-lSDL2"]
    # interactive play wants every bit of speed; -march=native is fine for a
    # local tool that is rebuilt on the machine it runs on
    cflags = "-O3 -march=native -flto" if fast else "-O2"
    cmd = [
        "verilator_bin", "--cc", "--exe", "--build", "-j", str(jobs),
        "-O3", "-CFLAGS", f"{cflags} {defines}", *ldflags,
        *(["--threads", str(threads)] if threads > 1 else []),
        "--x-assign", "fast", "--x-initial", "fast",
        "--timescale", "1ns/1ps", *WARN_OFF,
        f"-GRAM_WORDS={ram_words}", f"-GVID_WIDTH={width}", f"-GVID_HEIGHT={height}",
        f"-GUART_DIV={uart_div}",
        "--top", "soc_top", "-Mdir", str(outdir), "-o", exe.name,
        *[str(p) for p in rtl_sources()], str(ROOT / "sim/verilator/main.cpp"),
    ]

    if os.name == "nt" and MSYS.is_dir():
        # run inside the MSYS2 shell: its g++ needs a writable TMP, which the
        # Windows environment does not provide
        # paths must be POSIX and quoted: backslashes do not survive the shell
        quoted = " ".join("'" + str(c).replace("\\", "/") + "'" for c in cmd)
        script = (f"export PATH=/ucrt64/bin:$PATH VERILATOR_ROOT={VERILATOR_ROOT.as_posix()}; "
                  f"cd '{ROOT.as_posix()}' && {quoted}")
        proc = subprocess.run([str(MSYS / "usr/bin/bash"), "-lc", script],
                              capture_output=True, text=True)
    else:
        if not shutil.which("verilator_bin"):
            cmd[0] = "verilator"
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

    if proc.returncode != 0 or not exe.exists():
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit(f"verilator build failed for '{name}'")
    return exe


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="soc")
    ap.add_argument("--ram-mb", type=float, default=0.0625, help="RAM size in MiB (default 64 KiB)")
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=200)
    ap.add_argument("--uart-div", type=int, default=8)
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    words = int(args.ram_mb * 1024 * 1024 / 4)
    exe = build(args.name, words, args.width, args.height, args.uart_div, args.jobs)
    print(f"built {exe}  (RAM {words * 4 // 1024} KiB, {args.width}x{args.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
