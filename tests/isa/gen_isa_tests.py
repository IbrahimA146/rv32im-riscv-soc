#!/usr/bin/env python3
"""
Generate directed, self-checking assembly tests for the RV32IM data-path
instructions. Expected values are computed here with plain Python integer
arithmetic (independent of the ISS in scripts/rv32_iss.py), and every opcode is
exercised with edge-case operands plus forwarding/bypass variants.

Output: tests/isa/generated/<op>.S
"""
from pathlib import Path

M32 = 0xFFFFFFFF
OUT = Path(__file__).resolve().parent / "generated"


def s32(x: int) -> int:
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def u32(x: int) -> int:
    return x & M32


def trunc_div(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


# ---------------------------------------------------------------------------
# Reference semantics for each operation (a, b are unsigned 32-bit patterns)
# ---------------------------------------------------------------------------
def _div(a, b):
    if b == 0:
        return M32
    if a == 0x80000000 and b == M32:
        return a
    return u32(trunc_div(s32(a), s32(b)))


def _rem(a, b):
    if b == 0:
        return a
    if a == 0x80000000 and b == M32:
        return 0
    return u32(s32(a) - trunc_div(s32(a), s32(b)) * s32(b))


OPS = {
    "add":    lambda a, b: u32(a + b),
    "sub":    lambda a, b: u32(a - b),
    "and":    lambda a, b: a & b,
    "or":     lambda a, b: a | b,
    "xor":    lambda a, b: a ^ b,
    "sll":    lambda a, b: u32(a << (b & 31)),
    "srl":    lambda a, b: a >> (b & 31),
    "sra":    lambda a, b: u32(s32(a) >> (b & 31)),
    "slt":    lambda a, b: int(s32(a) < s32(b)),
    "sltu":   lambda a, b: int(a < b),
    "mul":    lambda a, b: u32(a * b),
    "mulh":   lambda a, b: u32((s32(a) * s32(b)) >> 32),
    "mulhsu": lambda a, b: u32((s32(a) * b) >> 32),
    "mulhu":  lambda a, b: u32((a * b) >> 32),
    "div":    _div,
    "divu":   lambda a, b: M32 if b == 0 else a // b,
    "rem":    _rem,
    "remu":   lambda a, b: a if b == 0 else a % b,
}

IMM_OPS = {"addi": "add", "andi": "and", "ori": "or", "xori": "xor",
           "slti": "slt", "sltiu": "sltu", "slli": "sll", "srli": "srl", "srai": "sra"}

EDGE = [0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x00000007, 0x0000000F,
        0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0x0000FFFF,
        0x00007FFF, 0xFFFF8000, 0x12345678, 0x87654321, 0xDEADBEEF, 0x55555555,
        0xAAAAAAAA, 0x01234567, 0xFFFFF800, 0x000007FF, 0xFFFFFFEC, 0x00000006]

SHIFT_AMTS = [0, 1, 7, 14, 20, 31]
IMM12 = [0, 1, -1, 2047, -2048, 0x555, -0x556, 3, 0x7F0, -20]


def hx(v: int) -> str:
    return f"0x{u32(v):08x}"


def gen_rr(op: str) -> str:
    fn = OPS[op]
    lines, n = [], 1
    is_shift = op in ("sll", "srl", "sra")
    pairs = []
    for a in EDGE:
        for b in (SHIFT_AMTS if is_shift else EDGE[::3]):
            pairs.append((a, b))
    if op in ("div", "divu", "rem", "remu"):
        pairs += [(20, 6), (u32(-20), 6), (20, u32(-6)), (u32(-20), u32(-6)),
                  (0x80000000, 1), (0x80000000, M32), (0x80000000, 0), (1, 0), (0, 0)]
    for a, b in pairs:
        lines.append(f"  TEST_RR_OP({n}, {op}, {hx(fn(a, b))}, {hx(a)}, {hx(b)})"); n += 1

    a, b = 0x0000000D, 0x0000000B if not is_shift else 3
    lines.append(f"  TEST_RR_SRC1_EQ_DEST({n}, {op}, {hx(fn(a, b))}, {hx(a)}, {hx(b)})"); n += 1
    lines.append(f"  TEST_RR_SRC12_EQ_DEST({n}, {op}, {hx(fn(a, a))}, {hx(a)})"); n += 1
    lines.append(f"  TEST_RR_ZERODEST({n}, {op}, {hx(a)}, {hx(b)})"); n += 1
    for nops in range(3):
        lines.append(f"  TEST_RR_DEST_BYPASS({n}, {nops}, {op}, {hx(fn(a, b))}, {hx(a)}, {hx(b)})"); n += 1
    for n1 in range(3):
        for n2 in range(3 - n1):
            lines.append(f"  TEST_RR_SRC_BYPASS({n}, {n1}, {n2}, {op}, {hx(fn(a, b))}, {hx(a)}, {hx(b)})"); n += 1
    return "\n".join(lines)


def gen_imm(op: str) -> str:
    fn = OPS[IMM_OPS[op]]
    lines, n = [], 1
    is_shift = op in ("slli", "srli", "srai")
    for a in EDGE:
        for imm in (SHIFT_AMTS if is_shift else IMM12):
            lines.append(f"  TEST_IMM_OP({n}, {op}, {hx(fn(a, u32(imm)))}, {hx(a)}, {imm})"); n += 1
    a, imm = 0x00FF00FF, (5 if is_shift else 0x70F)
    lines.append(f"  TEST_IMM_SRC1_EQ_DEST({n}, {op}, {hx(fn(a, u32(imm)))}, {hx(a)}, {imm})"); n += 1
    for nops in range(3):
        lines.append(f"  TEST_IMM_DEST_BYPASS({n}, {nops}, {op}, {hx(fn(a, u32(imm)))}, {hx(a)}, {imm})"); n += 1
    return "\n".join(lines)


def gen_branches() -> str:
    conds = {
        "beq":  lambda a, b: a == b,
        "bne":  lambda a, b: a != b,
        "blt":  lambda a, b: s32(a) < s32(b),
        "bge":  lambda a, b: s32(a) >= s32(b),
        "bltu": lambda a, b: a < b,
        "bgeu": lambda a, b: a >= b,
    }
    vals = [0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFE, 2]
    lines, n = [], 1
    for br, fn in conds.items():
        for a in vals:
            for b in vals:
                macro = "TEST_BR2_TAKEN" if fn(a, b) else "TEST_BR2_NOTTAKEN"
                lines.append(f"  {macro}({n}, {br}, {hx(a)}, {hx(b)})"); n += 1
    return "\n".join(lines)


HEADER = """/* AUTO-GENERATED by tests/isa/gen_isa_tests.py - do not edit */
#include "test_macros.h"

RVTEST_CODE_BEGIN
"""
FOOTER = """
  TEST_PASSFAIL
RVTEST_CODE_END
"""


def main() -> None:
    OUT.mkdir(exist_ok=True)
    groups = {op: gen_rr(op) for op in OPS}
    groups.update({op: gen_imm(op) for op in IMM_OPS})
    groups["branch"] = gen_branches()
    for name, body in groups.items():
        (OUT / f"{name}.S").write_text(HEADER + body + FOOTER)
    print(f"generated {len(groups)} tests in {OUT}")


if __name__ == "__main__":
    main()
