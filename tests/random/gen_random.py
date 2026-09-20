#!/usr/bin/env python3
"""
gen_random.py - constrained-random RV32IM program generator

Produces programs that terminate by construction yet stress the micro-
architecture: dense register dependencies (forwarding), load-after-store and
load-then-use sequences (load-use stalls), divides followed by dependent
instructions (EX stall + forwarding), bounded loops with data-dependent
branches (predictor training/mispredicts), JAL/JALR with arbitrary link
registers, and edge-case operand values.

Reserved registers:
    x31  data-region base (never written)
    x30  scratch for JALR targets
    x29  loop counter
"""
import argparse
import random

DATA_BASE = 0xC000
FREE = list(range(1, 29))

INTERESTING = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFFFFE, 0x80000001,
               0x0000FFFF, 0xFFFF0000, 0x55555555, 0xAAAAAAAA, 31, 32, 0x800, 0xFFFFF7FF]

RR_OPS = ["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu",
          "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
IMM_OPS = ["addi", "andi", "ori", "xori", "slti", "sltiu"]
SHIFT_IMM_OPS = ["slli", "srli", "srai"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


class Gen:
    def __init__(self, rng: random.Random):
        self.r = rng
        self.lines = []
        self.label = 0
        self.recent = []        # recently written registers -> dependency chains

    def emit(self, s: str):
        self.lines.append("    " + s)

    def new_label(self) -> str:
        self.label += 1
        return f"L{self.label}"

    def rd(self, exclude=()):
        choices = [r for r in FREE if r not in exclude]
        reg = self.r.choice(choices)
        self.recent = ([reg] + self.recent)[:4]
        return reg

    def rs(self, exclude=()):
        pool = [r for r in self.recent if r not in exclude]
        if pool and self.r.random() < 0.6:
            return self.r.choice(pool)
        return self.r.choice([r for r in [0] + FREE if r not in exclude])

    def value(self) -> int:
        if self.r.random() < 0.5:
            return self.r.choice(INTERESTING)
        return self.r.getrandbits(32)

    # ------------------------------------------------------------------ blocks
    def blk_li(self, ex=()):
        self.emit(f"li x{self.rd(ex)}, 0x{self.value():08x}")

    def blk_rr(self, ex=()):
        op = self.r.choice(RR_OPS)
        a, b = self.rs(ex), self.rs(ex)
        self.emit(f"{op} x{self.rd(ex)}, x{a}, x{b}")

    def blk_imm(self, ex=()):
        a = self.rs(ex)
        if self.r.random() < 0.3:
            op = self.r.choice(SHIFT_IMM_OPS)
            self.emit(f"{op} x{self.rd(ex)}, x{a}, {self.r.randrange(32)}")
        else:
            op = self.r.choice(IMM_OPS)
            imm = self.r.choice([0, 1, -1, 2047, -2048, self.r.randrange(-2048, 2048)])
            self.emit(f"{op} x{self.rd(ex)}, x{a}, {imm}")

    def blk_lui_auipc(self, ex=()):
        op = self.r.choice(["lui", "auipc"])
        self.emit(f"{op} x{self.rd(ex)}, 0x{self.r.getrandbits(20):05x}")

    def blk_mem(self, ex=()):
        size, sop, lops = self.r.choice([(1, "sb", ["lb", "lbu"]), (2, "sh", ["lh", "lhu"]),
                                         (4, "sw", ["lw"])])
        off = self.r.randrange(-512, 512) & ~(size - 1)
        src = self.rs(ex)
        self.emit(f"{sop} x{src}, {off}(x31)")
        if self.r.random() < 0.8:
            dst = self.rd(ex)
            self.emit(f"{self.r.choice(lops)} x{dst}, {off}(x31)")
            if self.r.random() < 0.5:     # immediately consume -> load-use stall
                self.emit(f"add x{self.rd(ex)}, x{dst}, x{self.rs(ex)}")

    def blk_div_chain(self, ex=()):
        d = self.rd(ex)
        self.emit(f"{self.r.choice(['div', 'divu', 'rem', 'remu'])} x{d}, x{self.rs(ex)}, x{self.rs(ex)}")
        self.emit(f"{self.r.choice(['add', 'xor', 'mul'])} x{self.rd(ex)}, x{d}, x{d}")

    def blk_branch(self, ex=()):
        skip = self.new_label()
        self.emit(f"{self.r.choice(BRANCHES)} x{self.rs(ex)}, x{self.rs(ex)}, {skip}")
        for _ in range(self.r.randrange(0, 3)):
            self.r.choice([self.blk_rr, self.blk_imm, self.blk_li])(ex)
        self.lines.append(f"{skip}:")

    def blk_jal(self, ex=()):
        skip = self.new_label()
        link = self.r.choice([0, 1] + FREE)
        if link not in ex:
            self.emit(f"jal x{link}, {skip}")
            self.emit(f"li x{self.rd(ex)}, 0xBAD")         # must never commit
            self.lines.append(f"{skip}:")

    def blk_jalr(self, ex=()):
        link = self.r.choice([0] + [r for r in FREE if r not in ex])
        self.emit("auipc x30, 0")
        self.emit(f"jalr x{link}, 12(x30)")
        self.emit(f"lui x{self.rd(ex)}, 0xBAD")            # skipped (auipc+12)

    def blk_loop(self):
        top = self.new_label()
        self.emit(f"li x29, {self.r.randrange(2, 12)}")
        self.lines.append(f"{top}:")
        for _ in range(self.r.randrange(1, 5)):
            self.r.choice([self.blk_rr, self.blk_imm, self.blk_mem, self.blk_branch])((29,))
        self.emit("addi x29, x29, -1")
        self.emit(f"bnez x29, {top}")

    def program(self, n_blocks: int) -> str:
        head = [
            "/* AUTO-GENERATED by tests/random/gen_random.py */",
            '#include "soc.h"',
            '    .section .text.start, "ax"',
            "    .globl _start",
            "_start:",
            "    la t0, trap",
            "    csrw mtvec, t0",
            f"    li x31, 0x{DATA_BASE:x}",
        ]
        for r in FREE:
            self.emit(f"li x{r}, 0x{self.value():08x}")
        weights = [(self.blk_rr, 25), (self.blk_imm, 15), (self.blk_li, 5), (self.blk_lui_auipc, 4),
                   (self.blk_mem, 15), (self.blk_div_chain, 5), (self.blk_branch, 12),
                   (self.blk_jal, 4), (self.blk_jalr, 4), (self.blk_loop, 6)]
        blocks, wts = zip(*weights)
        for _ in range(n_blocks):
            self.r.choices(blocks, wts)[0]()
        tail = [
            "    li t0, SYSCON_EXIT",
            "    sw zero, 0(t0)",
            "1:  j 1b",
            "    .align 2",
            "trap:",
            "    li t0, SYSCON_EXIT",
            "    li t1, 0xDEAD",
            "    sw t1, 0(t0)",
            "2:  j 2b",
        ]
        return "\n".join(head + self.lines + tail) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--blocks", type=int, default=400)
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()
    g = Gen(random.Random(args.seed))
    with open(args.out, "w") as f:
        f.write(g.program(args.blocks))


if __name__ == "__main__":
    main()
