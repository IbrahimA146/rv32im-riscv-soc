#!/usr/bin/env python3
"""
profile_report.py - turn the harness's PC samples into a function-level profile

The harness samples the committed program counter while the design runs
(`--profile=<file>`). This maps those addresses onto the symbols in the ELF and
prints where the cycles actually went.

    python scripts/profile_report.py build/doom.prof build/fw/doom/doom.elf
"""
import bisect
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import run_tests as rt  # noqa: E402


def symbols(elf: Path):
    """Sorted (address, name) for every function in the image."""
    out = rt.run([rt.PREFIX + "nm", "-n", "--defined-only", str(elf)]).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1].lower() in "tw":
            syms.append((int(parts[0], 16), parts[2]))
    return syms


def main() -> int:
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <profile> <elf> [top N]")
        return 2
    prof, elf = Path(sys.argv[1]), Path(sys.argv[2])
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 25

    syms = symbols(elf)
    addrs = [a for a, _ in syms]

    totals, total = {}, 0
    for line in prof.read_text().splitlines():
        pc_s, count_s = line.split()
        pc, count = int(pc_s, 16), int(count_s)
        i = bisect.bisect_right(addrs, pc) - 1
        name = syms[i][1] if i >= 0 else "?"
        totals[name] = totals.get(name, 0) + count
        total += count

    print(f"{total} samples over {len(totals)} functions\n")
    print(f"{'share':>7}  {'samples':>8}  function")
    print("-" * 46)
    for name, count in sorted(totals.items(), key=lambda kv: -kv[1])[:top]:
        print(f"{100 * count / total:6.2f}%  {count:8}  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
