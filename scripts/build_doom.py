#!/usr/bin/env python3
"""
build_doom.py - build DOOM for the SoC and run it on the RTL

    python scripts/build_doom.py --frames 1      # title screen
    python scripts/build_doom.py --frames 200 --video

Needs external/doomgeneric (source) and a WAD; scripts/fetch_doom.py gets both.
DOOM is compiled in CMAP256 mode at 320x200 so its 8-bit output and palette map
straight onto soc_video.sv.
"""
import argparse
import os
import shutil
import subprocess
import struct
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
DG = ROOT / "external/doomgeneric/doomgeneric"
sys.path.insert(0, str(ROOT / "scripts"))
import build_vsim  # noqa: E402
import run_tests as rt  # noqa: E402

RAM_MB = 24
SIM_TICKS_PER_MS = 6_700      # measured simulation rate, ~6.7 M cycles/s
# Playing needs frames more than it needs pixels: a smaller viewport and low
# detail cost 1.8x fewer cycles per frame (1.33 M -> 0.74 M measured), which is
# the difference between a slideshow and something you can actually control.
PLAY_SCREEN_SIZE = 7
PLAY_LOW_DETAIL = 1
WAD_ADDR = 0x01000000
WAD_MAGIC = 0x57414442

# doomgeneric's own file list, minus the platform front-ends (we supply ours)
DOOM_SRC = """dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main
d_mode d_net f_finale f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale
i_system i_timer memio m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc
m_random p_ceilng p_doors p_enemy p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr
p_saveg p_setup p_sight p_spec p_switch p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane
r_segs r_sky r_things sha1 sounds statdump st_lib st_stuff s_sound tables v_video wi_stuff
w_checksum w_file w_main w_wad z_zone w_file_stdc i_input i_video doomgeneric""".split()

CFLAGS = [
    "-march=rv32im_zicsr", "-mabi=ilp32", "-Os", "-g",
    "-ffreestanding", "-fno-tree-loop-distribute-patterns",
    "-ffunction-sections", "-fdata-sections",
    "-DCMAP256", "-DDOOMGENERIC_RESX=320", "-DDOOMGENERIC_RESY=200",
    "-DNORMALUNIX", "-DFEATURE_SOUND=0",
    "-Wno-implicit-function-declaration", "-Wno-int-conversion",
]


def compile_one(src: Path, obj: Path, includes) -> tuple:
    obj.parent.mkdir(parents=True, exist_ok=True)
    cmd = [rt.PREFIX + "gcc", *CFLAGS, *[f"-I{i}" for i in includes], "-c", str(src), "-o", str(obj)]
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    return obj, r


def doom_linker_script(out: Path) -> Path:
    """The stock script describes the 64 KiB test machine; DOOM needs the big one."""
    text = (ROOT / "fw/common/link.ld").read_text()
    text = text.replace("LENGTH = 64K", f"LENGTH = {RAM_MB}M")
    script = out / "link.ld"
    script.write_text(text)
    return script


def build_firmware(jobs: int) -> Path:
    out = BUILD / "fw/doom"
    out.mkdir(parents=True, exist_ok=True)
    includes = [DG, ROOT / "fw/common"]
    sources = [DG / f"{n}.c" for n in DOOM_SRC]
    sources += sorted((ROOT / "fw/common").glob("*.[cS]"))
    sources += sorted((ROOT / "fw/apps/doom").glob("*.[cS]"))

    from concurrent.futures import ThreadPoolExecutor
    objs, errors = [], []
    with ThreadPoolExecutor(jobs) as pool:
        futures = [pool.submit(compile_one, s, out / "obj" / (s.stem + ".o"), includes)
                   for s in sources]
        for f in futures:
            obj, r = f.result()
            if r.returncode != 0:
                errors.append(r.stdout + r.stderr)
            else:
                objs.append(obj)
    if errors:
        sys.stderr.write("\n".join(errors[:5]))
        raise SystemExit(f"{len(errors)} source file(s) failed to compile")

    elf = out / "doom.elf"
    link = [rt.PREFIX + "gcc", "-march=rv32im_zicsr", "-mabi=ilp32", "-nostartfiles",
            "-specs=nano.specs",
            *[a for d in rt.rv32_lib_dirs() for a in ("-L", str(d))],
            "-Wl,--gc-sections", "-Wl,--no-warn-rwx-segments",
            f"-Wl,-Map={out / 'doom.map'}",
            "-T", str(doom_linker_script(out)),
            *[str(o) for o in objs],
            # nano.specs rewrites -lm to -lm_nano, which this toolchain does not
            # ship, so link the real libm by path
            *[str(d / "libm.a") for d in rt.rv32_lib_dirs() if (d / "libm.a").is_file()],
            "-o", str(elf)]
    r = subprocess.run([str(c) for c in link], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("link failed")
    subprocess.run([rt.PREFIX + "size", str(elf)])
    return rt.elf_to_hex(elf)


def find_wad() -> Path:
    for p in sorted((ROOT / "external").glob("*.wad")) + sorted((ROOT / "external").glob("*.WAD")):
        return p
    raise SystemExit("no WAD in external/ - run: python scripts/fetch_doom.py")


ARGS_LEN = 120
CFG_LEN = 256


def wad_blob(wad: Path, doom_args: str, ticks_per_ms: int, blocks: int, detail: int,
             fixed_step: int = 0) -> Path:
    """Header (magic, size, clock rate, view settings, command line) then the WAD."""
    data = wad.read_bytes()
    args = doom_args.encode()[:ARGS_LEN - 1]
    args = args + bytes(ARGS_LEN - len(args))
    blob = BUILD / "fw/doom/wad.bin"
    blob.write_bytes(struct.pack("<IIIBBBB", WAD_MAGIC, len(data), ticks_per_ms,
                                 blocks, detail, fixed_step, 0) + args + data)
    return blob


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", type=int, default=1, help="stop after N presented frames")
    ap.add_argument("--timeout", type=int, default=4_000_000_000)
    ap.add_argument("--keys", default="", help="scancodes to inject, comma separated")
    ap.add_argument("--doom-args", default="", help="extra DOOM options, e.g. -timedemo demo1")
    ap.add_argument("--video", action="store_true", help="encode the frames with ffmpeg")
    ap.add_argument("--fps", type=int, default=35, help="playback frame rate for the video")
    ap.add_argument("--play", action="store_true",
                    help="open a window and play it live (needs SDL2)")
    ap.add_argument("--scale", type=int, default=2, help="window zoom for --play")
    ap.add_argument("--screen-size", type=int, default=0,
                    help="DOOM viewport size 3-11 (smaller renders fewer pixels, so it runs faster)")
    ap.add_argument("--low-detail", action="store_true",
                    help="DOOM's low detail mode: half horizontal resolution, roughly twice the speed")
    ap.add_argument("--ticks-per-ms", type=int, default=0,
                    help="cycles the game counts as a millisecond "
                         "(default: 50000 when capturing, the measured simulation rate when playing)")
    ap.add_argument("--build-only", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    if not DG.is_dir():
        raise SystemExit("external/doomgeneric missing - run: python scripts/fetch_doom.py")

    print("building DOOM for rv32im ...")
    hex_ = build_firmware(args.jobs)
    wad = find_wad()
    # when playing, time should pass at wall-clock speed, not at the speed a
    # real 50 MHz chip would run; when capturing frames, 50 MHz is correct
    ticks = args.ticks_per_ms or (SIM_TICKS_PER_MS if args.play else 50_000)

    # doomgeneric compiles out DOOM's config-file reader, so the view settings
    # travel in the header and the firmware applies them through R_SetViewSize
    blocks = args.screen_size or (PLAY_SCREEN_SIZE if args.play else 0)
    detail = int(args.low_detail) or (PLAY_LOW_DETAIL if args.play else 0)
    blob = wad_blob(wad, args.doom_args, ticks, blocks, detail, int(args.play))
    print(f"WAD: {wad.name} ({wad.stat().st_size / 1e6:.1f} MB)")

    name = "doom-play" if args.play else "doom"
    sim = build_vsim.build(name, RAM_MB * 1024 * 1024 // 4, 320, 200, 8, args.jobs,
                           sdl=args.play, fast=args.play)
    if args.build_only:
        return 0

    frames_dir = BUILD / "frames/doom"
    if frames_dir.exists():
        shutil.rmtree(frames_dir)
    frames_dir.mkdir(parents=True)

    cmd = [str(sim), f"--hex={hex_}", f"--wad={blob}", f"--wad-addr={WAD_ADDR}",
           f"--timeout={args.timeout}"]
    if args.play:
        cmd += ["--play", f"--scale={args.scale}"]
    else:
        cmd += [f"--frames={frames_dir}/f_", f"--max-frames={args.frames}"]
    if args.keys:
        cmd.append(f"--keys={args.keys}")
    print(" ".join(cmd))
    t0 = time.time()
    rc = subprocess.run(cmd, cwd=ROOT).returncode
    wall = time.time() - t0

    pngs = sorted(frames_dir.glob("*.ppm"))
    if pngs:
        subprocess.run([sys.executable, str(ROOT / "scripts/ppm2png.py"), "-q", *map(str, pngs)])
    print(f"\n{len(pngs)} frame(s) in {wall:.1f}s -> {frames_dir}")

    if args.video and pngs:
        mp4 = BUILD / "doom.mp4"
        ff = shutil.which("ffmpeg") or r"C:\ffmpeg\bin\ffmpeg.exe"
        subprocess.run([ff, "-y", "-framerate", str(args.fps), "-i", str(frames_dir / "f_%04d.png"),
                        "-vf", "scale=640:400:flags=neighbor", "-pix_fmt", "yuv420p", str(mp4)],
                       capture_output=True)
        print(f"video -> {mp4}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
