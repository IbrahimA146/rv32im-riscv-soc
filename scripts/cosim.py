#!/usr/bin/env python3
"""
cosim.py - compare an RTL commit trace against the ISS golden trace.

Reports the first divergence with surrounding context. '********' fields in
the reference trace are don't-cares.
"""
import sys

WILDCARD = "********"


def fields_match(rtl: str, ref: str) -> bool:
    a, b = rtl.split(), ref.split()
    if len(a) != len(b):
        return False
    return all(y == WILDCARD or x == y for x, y in zip(a, b))


def compare(rtl_path: str, ref_path: str, context: int = 5):
    rtl = [l.rstrip() for l in open(rtl_path) if l.strip()]
    ref = [l.rstrip() for l in open(ref_path) if l.strip()]
    for i, (r, g) in enumerate(zip(rtl, ref)):
        if not fields_match(r, g):
            lo = max(0, i - context)
            msg = [f"MISMATCH at commit #{i}:"]
            for j in range(lo, i):
                msg.append(f"    {j:7d}  {ref[j]}")
            msg.append(f"  > {i:7d}  ISS: {g}")
            msg.append(f"  > {i:7d}  RTL: {r}")
            return False, "\n".join(msg)
    if len(rtl) != len(ref):
        return False, f"LENGTH MISMATCH: RTL committed {len(rtl)} instructions, ISS {len(ref)}"
    return True, f"{len(ref)} commits match"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <rtl.trace> <iss.trace>")
        return 2
    ok, msg = compare(sys.argv[1], sys.argv[2])
    print(msg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
