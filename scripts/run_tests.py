#!/usr/bin/env python3
"""
run_tests.py - build and run the verification suites

    python scripts/run_tests.py                 # everything
    python scripts/run_tests.py isa             # directed ISA tests (+ co-simulation)
    python scripts/run_tests.py random -n 50    # 50 constrained-random programs
    python scripts/run_tests.py fw -v           # firmware apps, show UART console
    python scripts/run_tests.py isa -k div      # filter by name

Every ISA and random test is run twice: on the RTL and on the Python ISS, and
the two commit traces must match instruction-for-instruction.

The RTL runs under either simulator: Verilator (default, several hundred times
faster) or Icarus Verilog. --sim=both runs every test under both, which also
checks that the two simulators agree with each other.
"""
import argparse
import functools
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
sys.path.insert(0, str(ROOT / "scripts"))
import cosim  # noqa: E402
import build_vsim  # noqa: E402

# MSYS2 on Windows installs the toolchain here; harmless elsewhere.
for extra in (r"C:\msys64\ucrt64\bin", r"C:\msys64\usr\bin"):
    if os.path.isdir(extra) and extra not in os.environ["PATH"]:
        os.environ["PATH"] += os.pathsep + extra

RTL_SOURCES = (
    [ROOT / "rtl/core/rv32_pkg.sv"]
    + sorted(p for p in (ROOT / "rtl/core").glob("*.sv") if p.name != "rv32_pkg.sv")
    + sorted((ROOT / "rtl/soc").glob("*.sv"))
    + [ROOT / "sim/tb_soc.sv"]
)

# Tests that depend on asynchronous interrupts / timers: RTL self-check only.
NO_COSIM = {"irq"}

DEMO_UART_INPUT = "help,ping,stats,led,exit"

# firmware apps run by the "fw" suite: name -> harness options
FW_APPS = {
    "demo":    {"uart_in": DEMO_UART_INPUT},
    "testpat": {"frames": "build/frames/testpat_", "keys": "30,31"},
    "libctest": {},
}
FRAME_DIR = BUILD / "frames"


def find_prefix() -> str:
    for p in ("riscv64-unknown-elf-", "riscv32-unknown-elf-", "riscv-none-elf-"):
        if shutil.which(p + "gcc"):
            return p
    sys.exit("error: no RISC-V GCC found (riscv64-unknown-elf-gcc)")


PREFIX = find_prefix()
ARCH = ["-march=rv32im_zicsr", "-mabi=ilp32"]


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)


def check(cmd, what):
    r = run(cmd)
    if r.returncode != 0:
        raise RuntimeError(f"{what} failed:\n{r.stdout}{r.stderr}")
    return r


@functools.lru_cache(maxsize=1)
def rv32_lib_dirs():
    """Directories holding the rv32im/ilp32 newlib and libgcc.

    CSR instructions need -march=rv32im_zicsr, but that arch string matches no
    multilib name, so GCC would otherwise link the 64-bit libraries. Asking the
    plain rv32im driver where its libraries live and putting those directories
    first on the link line fixes it.
    """
    dirs = []
    for query in ("-print-file-name=libc.a", "-print-libgcc-file-name"):
        path = Path(run([PREFIX + "gcc", "-march=rv32im", "-mabi=ilp32", query]).stdout.strip())
        if path.is_file():
            dirs.append(path.parent)
    return tuple(dirs)


# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
def compile_sim(sim: str) -> Path:
    """Build the chosen RTL simulator and return its executable."""
    if sim == "verilator":
        return build_vsim.build("soc", 16384, 320, 200, 8, os.cpu_count() or 4)
    vvp = BUILD / "sim" / "tb_soc.vvp"
    vvp.parent.mkdir(parents=True, exist_ok=True)
    newest = max(p.stat().st_mtime for p in RTL_SOURCES)
    if not vvp.exists() or vvp.stat().st_mtime < newest:
        r = run(["iverilog", "-g2012", "-o", vvp, "-s", "tb_soc", *RTL_SOURCES])
        errors = [l for l in (r.stdout + r.stderr).splitlines()
                  if l and "constant selects in always_*" not in l]
        if r.returncode != 0:
            raise RuntimeError("iverilog failed:\n" + "\n".join(errors))
    return vvp


def elf_to_hex(elf: Path) -> Path:
    bin_ = elf.with_suffix(".bin")
    hex_ = elf.with_suffix(".hex")
    check([PREFIX + "objcopy", "-O", "binary", elf, bin_], "objcopy")
    lst = run([PREFIX + "objdump", "-d", "-M", "no-aliases", elf])
    elf.with_suffix(".lst").write_text(lst.stdout)
    check([sys.executable, ROOT / "scripts/bin2hex.py", bin_, hex_], "bin2hex")
    return hex_


def build_asm(src: Path, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / (src.stem + ".elf")
    check([PREFIX + "gcc", *ARCH, "-nostdlib", "-nostartfiles", "-Wl,--no-warn-rwx-segments",
           "-I", ROOT / "fw/common", "-I", ROOT / "tests/isa",
           "-T", ROOT / "fw/common/link.ld", src, "-o", elf], f"assemble {src.name}")
    return elf_to_hex(elf)


def build_firmware(app: str) -> Path:
    if not rv32_lib_dirs():
        raise ToolchainMissing(
            "no rv32im C library in this toolchain: firmware needs newlib "
            "(the ISA, random and mutation suites do not)")
    out = BUILD / "fw" / app
    out.mkdir(parents=True, exist_ok=True)
    srcs = sorted((ROOT / "fw/common").glob("*.[cS]")) + sorted((ROOT / "fw/apps" / app).glob("*.[cS]"))
    elf = out / f"{app}.elf"
    check([PREFIX + "gcc", *ARCH, "-O2", "-g", "-Wall", "-Wextra", "-ffreestanding",
           "-nostartfiles", "-fno-tree-loop-distribute-patterns", "-specs=nano.specs",
           "-ffunction-sections", "-fdata-sections",
           *[a for d in rv32_lib_dirs() for a in ("-L", str(d))],
           "-Wl,--gc-sections", "-Wl,--no-warn-rwx-segments", f"-Wl,-Map={out / (app + '.map')}",
           "-I", ROOT / "fw/common", "-T", ROOT / "fw/common/link.ld", *srcs, "-o", elf],
          f"build firmware {app}")
    size = run([PREFIX + "size", elf]).stdout
    (out / "size.txt").write_text(size)
    return elf_to_hex(elf)


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
class ToolchainMissing(RuntimeError):
    """The toolchain cannot build this target (e.g. no rv32 C library)."""


@dataclass
class Result:
    name: str
    ok: bool = False
    skipped: bool = False
    detail: str = ""
    cycles: int = 0
    insns: int = 0
    bpred: str = ""
    seconds: float = 0.0
    console: str = field(default="", repr=False)


def run_rtl(sim_exe: Path, hex_: Path, trace: Path = None, timeout=3_000_000, opts=None):
    """Run one image on the RTL. opts keys: uart_in, frames, keys."""
    opts = opts or {}
    if sim_exe.suffix == ".vvp":
        args = ["vvp", "-n", sim_exe, f"+hex={hex_}", f"+timeout={timeout}"]
        if trace:
            args.append(f"+trace={trace}")
        args += [f"+{k}={v}" for k, v in opts.items()]
    else:
        args = [sim_exe, f"--hex={hex_}", f"--timeout={timeout}", "--quiet"]
        if trace:
            args.append(f"--trace={trace}")
        args += [f"--{k.replace('_', '-')}={v}" for k, v in opts.items()]
    r = run(args, cwd=ROOT)
    out = "\n".join(l for l in r.stdout.splitlines() if "$readmemh" not in l and "$finish" not in l)
    return out


def parse_stats(out: str, res: Result):
    m = re.search(r"cycles\s+:\s+(\d+)", out)
    res.cycles = int(m.group(1)) if m else 0
    m = re.search(r"instructions\s+:\s+(\d+)", out)
    res.insns = int(m.group(1)) if m else 0
    m = re.search(r"branch pred\.\s+:\s+\S+ correct \(([\d.]+%)\)", out)
    res.bpred = m.group(1) if m else ""


def run_program(name: str, hex_: Path, sim_exe: Path, do_cosim: bool, uart_in=None,
                timeout=3_000_000, opts=None) -> Result:
    res = Result(name)
    t0 = time.time()
    opts = dict(opts or {})
    if uart_in:
        opts["uart_in"] = uart_in
    rtl_trace = hex_.with_suffix(".rtl.trace") if do_cosim else None
    out = run_rtl(sim_exe, hex_, rtl_trace, timeout, opts)
    res.console = out
    parse_stats(out, res)
    if "*** PASS ***" not in out:
        m = re.search(r"\*\*\* (FAIL.*|TIMEOUT.*) \*\*\*", out)
        res.detail = m.group(1) if m else "simulation did not finish"
    elif do_cosim:
        iss_trace = hex_.with_suffix(".iss.trace")
        run([sys.executable, ROOT / "scripts/rv32_iss.py", hex_, "--trace", iss_trace])
        ok, msg = cosim.compare(str(rtl_trace), str(iss_trace))
        res.ok, res.detail = ok, ("cosim: " + msg if ok else msg)
    else:
        res.ok, res.detail = True, "self-check (no cosim)"
    res.seconds = time.time() - t0
    return res


# ---------------------------------------------------------------------------
# Suites
# ---------------------------------------------------------------------------
def suite_isa(sim_exe, pool, filt):
    subprocess.run([sys.executable, ROOT / "tests/isa/gen_isa_tests.py"], capture_output=True)
    srcs = sorted((ROOT / "tests/isa").glob("*.S")) + sorted((ROOT / "tests/isa/generated").glob("*.S"))
    srcs = [s for s in srcs if not filt or filt in s.stem]

    def job(src):
        try:
            hex_ = build_asm(src, BUILD / "isa")
        except RuntimeError as e:
            return Result(f"isa/{src.stem}", False, str(e))
        return run_program(f"isa/{src.stem}", hex_, sim_exe, src.stem not in NO_COSIM)

    return list(pool.map(job, srcs))


def suite_random(sim_exe, pool, n, seed0, filt):
    out = BUILD / "random"
    out.mkdir(parents=True, exist_ok=True)

    def job(seed):
        name = f"random/seed{seed}"
        src = out / f"seed{seed}.S"
        subprocess.run([sys.executable, ROOT / "tests/random/gen_random.py", "--seed", str(seed),
                        "-o", str(src)], check=True)
        try:
            hex_ = build_asm(src, out)
        except RuntimeError as e:
            return Result(name, False, str(e))
        return run_program(name, hex_, sim_exe, True)

    seeds = [s for s in range(seed0, seed0 + n) if not filt or filt in str(s)]
    return list(pool.map(job, seeds))


def suite_fw(sim_exe, verbose, filt=""):
    results = []
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    for app, opts in FW_APPS.items():
        if filt and filt not in app:
            continue
        try:
            hex_ = build_firmware(app)
        except ToolchainMissing as e:
            results.append(Result(f"fw/{app}", ok=True, skipped=True, detail=f"skipped: {e}"))
            continue
        except RuntimeError as e:
            results.append(Result(f"fw/{app}", False, str(e)))
            continue
        res = run_program(f"fw/{app}", hex_, sim_exe, False, opts=opts)
        if verbose:
            print(res.console)
        # turn any captured frames into PNGs and say where they went
        frames = sorted(FRAME_DIR.glob(f"{app}_*.ppm"))
        if frames:
            run([sys.executable, ROOT / "scripts/ppm2png.py", "-q", *frames])
            res.detail = f"{len(frames)} frame(s) -> {FRAME_DIR / (app + '_*.png')}"
        results.append(res)
    return results


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suites", nargs="*", metavar="SUITE", help="isa, random, fw (default: all)")
    ap.add_argument("-n", "--num-random", type=int, default=25)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-k", "--filter", default="")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("-v", "--verbose", action="store_true", help="print firmware UART console")
    ap.add_argument("--sim", default="verilator", choices=["verilator", "icarus", "both"],
                    help="which RTL simulator to run the tests on (default: verilator)")
    args = ap.parse_args()
    args.suites = args.suites or ["isa", "random", "fw"]
    for s in args.suites:
        if s not in ("isa", "random", "fw"):
            ap.error(f"unknown suite '{s}'")

    t0 = time.time()
    results = []
    for sim in (["verilator", "icarus"] if args.sim == "both" else [args.sim]):
        sim_exe = compile_sim(sim)
        tag = f"[{sim[:3]}] " if args.sim == "both" else ""
        sim_results = []
        with ThreadPoolExecutor(args.jobs) as pool:
            if "isa" in args.suites:
                sim_results += suite_isa(sim_exe, pool, args.filter)
            if "random" in args.suites:
                sim_results += suite_random(sim_exe, pool, args.num_random, args.seed, args.filter)
        if "fw" in args.suites:
            sim_results += suite_fw(sim_exe, args.verbose, args.filter)
        for r in sim_results:
            r.name = tag + r.name
        results += sim_results

    w = max((len(r.name) for r in results), default=10)
    print(f"\n{'TEST':<{w}}  {'RESULT':<6}  {'INSNS':>8}  {'CPI':>5}  {'BPRED':>6}  DETAIL")
    print("-" * (w + 60))
    for r in results:
        cpi = f"{r.cycles / r.insns:.2f}" if r.insns else "-"
        status = "SKIP" if r.skipped else "PASS" if r.ok else "FAIL"
        detail = r.detail if r.ok else r.detail.replace("\n", "\n" + " " * (w + 2))
        print(f"{r.name:<{w}}  {status:<6}  {r.insns:>8}  {cpi:>5}  {r.bpred:>6}  {detail}")
    skipped = sum(r.skipped for r in results)
    passed = sum(r.ok and not r.skipped for r in results)
    total = len(results) - skipped
    total_insns = sum(r.insns for r in results)
    print("-" * (w + 60))
    print(f"{passed}/{total} passed"
          + (f", {skipped} skipped" if skipped else "")
          + f", {total_insns:,} instructions verified in {time.time() - t0:.1f}s")
    # skipped tests are not failures: a toolchain without an rv32 C library can
    # still run everything that does not need one
    return 0 if all(r.ok for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
