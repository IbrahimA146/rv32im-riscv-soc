#!/usr/bin/env python3
"""
run_tests.py - build and run the verification suites

    python scripts/run_tests.py                 # everything
    python scripts/run_tests.py isa             # directed ISA tests (+ co-simulation)
    python scripts/run_tests.py random -n 50    # 50 constrained-random programs
    python scripts/run_tests.py fw -v           # firmware demo, show UART console
    python scripts/run_tests.py isa -k div      # filter by name

Every ISA and random test is run twice: on the RTL (Icarus Verilog) and on the
Python ISS. The two commit traces must match instruction-for-instruction.
"""
import argparse
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


# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
def compile_rtl() -> Path:
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
    out = BUILD / "fw" / app
    out.mkdir(parents=True, exist_ok=True)
    srcs = sorted((ROOT / "fw/common").glob("*.[cS]")) + sorted((ROOT / "fw/apps" / app).glob("*.[cS]"))
    elf = out / f"{app}.elf"
    check([PREFIX + "gcc", *ARCH, "-O2", "-g", "-Wall", "-Wextra", "-ffreestanding", "-nostdlib",
           "-nostartfiles", "-fno-builtin", "-fno-tree-loop-distribute-patterns", "-ffunction-sections", "-fdata-sections",
           "-Wl,--gc-sections", "-Wl,--no-warn-rwx-segments", f"-Wl,-Map={out / (app + '.map')}",
           "-I", ROOT / "fw/common", "-T", ROOT / "fw/common/link.ld", *srcs, "-o", elf],
          f"build firmware {app}")
    size = run([PREFIX + "size", elf]).stdout
    (out / "size.txt").write_text(size)
    return elf_to_hex(elf)


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
@dataclass
class Result:
    name: str
    ok: bool = False
    detail: str = ""
    cycles: int = 0
    insns: int = 0
    bpred: str = ""
    seconds: float = 0.0
    console: str = field(default="", repr=False)


def run_rtl(vvp: Path, hex_: Path, trace: Path = None, uart_in: str = None, timeout=3_000_000):
    args = ["vvp", "-n", vvp, f"+hex={hex_}", f"+timeout={timeout}"]
    if trace:
        args.append(f"+trace={trace}")
    if uart_in:
        args.append(f"+uart_in={uart_in}")
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


def run_program(name: str, hex_: Path, vvp: Path, do_cosim: bool, uart_in=None,
                timeout=3_000_000) -> Result:
    res = Result(name)
    t0 = time.time()
    rtl_trace = hex_.with_suffix(".rtl.trace") if do_cosim else None
    out = run_rtl(vvp, hex_, rtl_trace, uart_in, timeout)
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
def suite_isa(vvp, pool, filt):
    subprocess.run([sys.executable, ROOT / "tests/isa/gen_isa_tests.py"], capture_output=True)
    srcs = sorted((ROOT / "tests/isa").glob("*.S")) + sorted((ROOT / "tests/isa/generated").glob("*.S"))
    srcs = [s for s in srcs if not filt or filt in s.stem]

    def job(src):
        try:
            hex_ = build_asm(src, BUILD / "isa")
        except RuntimeError as e:
            return Result(f"isa/{src.stem}", False, str(e))
        return run_program(f"isa/{src.stem}", hex_, vvp, src.stem not in NO_COSIM)

    return list(pool.map(job, srcs))


def suite_random(vvp, pool, n, seed0, filt):
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
        return run_program(name, hex_, vvp, True)

    seeds = [s for s in range(seed0, seed0 + n) if not filt or filt in str(s)]
    return list(pool.map(job, seeds))


def suite_fw(vvp, verbose):
    try:
        hex_ = build_firmware("demo")
    except RuntimeError as e:
        return [Result("fw/demo", False, str(e))]
    res = run_program("fw/demo", hex_, vvp, False, uart_in=DEMO_UART_INPUT)
    if verbose:
        print(res.console)
    return [res]


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("suites", nargs="*", metavar="SUITE", help="isa, random, fw (default: all)")
    ap.add_argument("-n", "--num-random", type=int, default=25)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-k", "--filter", default="")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("-v", "--verbose", action="store_true", help="print firmware UART console")
    args = ap.parse_args()
    args.suites = args.suites or ["isa", "random", "fw"]
    for s in args.suites:
        if s not in ("isa", "random", "fw"):
            ap.error(f"unknown suite '{s}'")

    t0 = time.time()
    vvp = compile_rtl()
    results = []
    with ThreadPoolExecutor(args.jobs) as pool:
        if "isa" in args.suites:
            results += suite_isa(vvp, pool, args.filter)
        if "random" in args.suites:
            results += suite_random(vvp, pool, args.num_random, args.seed, args.filter)
    if "fw" in args.suites:
        results += suite_fw(vvp, args.verbose)

    w = max((len(r.name) for r in results), default=10)
    print(f"\n{'TEST':<{w}}  {'RESULT':<6}  {'INSNS':>8}  {'CPI':>5}  {'BPRED':>6}  DETAIL")
    print("-" * (w + 60))
    for r in results:
        cpi = f"{r.cycles / r.insns:.2f}" if r.insns else "-"
        status = "PASS" if r.ok else "FAIL"
        detail = r.detail if r.ok else r.detail.replace("\n", "\n" + " " * (w + 2))
        print(f"{r.name:<{w}}  {status:<6}  {r.insns:>8}  {cpi:>5}  {r.bpred:>6}  {detail}")
    passed = sum(r.ok for r in results)
    total_insns = sum(r.insns for r in results)
    print("-" * (w + 60))
    print(f"{passed}/{len(results)} passed, {total_insns:,} instructions verified "
          f"in {time.time() - t0:.1f}s")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
