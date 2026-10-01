#!/usr/bin/env python3
"""
rv32_iss.py - golden reference instruction-set simulator for RV32IM_Zicsr (M-mode)

Used for differential verification: it runs the same memory image as the RTL
and emits a commit trace in the identical format, which scripts/cosim.py
compares line by line.

Trace format (one line per committed instruction):
    <pc> <insn>                    no architectural write
    <pc> <insn> x<rd> <value>      register write
    <pc> <insn> mem <addr> <data>  memory write (data masked to access size)

Values that legitimately differ between models (e.g. mcycle) are written as
'********' and treated as don't-care by the comparator.

Asynchronous interrupts are not modelled; programs that rely on them are run
RTL-only.
"""
import argparse
import sys

M32 = 0xFFFFFFFF

RAM_SIZE = 0x10000
UART_BASE = 0x10000000
GPIO_BASE = 0x20000000
CLINT_BASE = 0x02000000
SYSCON_EXIT = 0x30000000
VID_PIX_BASE = 0x40000000
VID_PAL_BASE = 0x40010000
VID_CTL_BASE = 0x40020000
KEYS_BASE = 0x50000000
GPIO_IN_VALUE = 0xA5A50000     # matches tb_soc.sv
VID_WIDTH, VID_HEIGHT = 320, 200
# the RTL rounds pixel storage up to a power of two covering the whole window
VID_PIX_WORDS = 1 << ((VID_WIDTH * VID_HEIGHT + 3) // 4 - 1).bit_length()

WILDCARD = "********"


def sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v: int) -> int:
    return sext(v, 32)


class Trap(Exception):
    def __init__(self, cause: int, tval: int = 0):
        super().__init__(cause, tval)
        self.cause = cause
        self.tval = tval & M32


class Halt(Exception):
    def __init__(self, code: int):
        super().__init__(code)
        self.code = code


class RV32ISS:
    CSR_RO_COUNTERS = {0xB00, 0xB02, 0xB03, 0xB04, 0xB80, 0xB82}

    def __init__(self, image: bytes):
        self.mem = bytearray(RAM_SIZE)
        self.mem[:len(image)] = image
        self.x = [0] * 32
        self.pc = 0
        # CSRs
        self.mie_bit = 0
        self.mpie_bit = 0
        self.mie = 0
        self.mtvec = 0
        self.mscratch = 0
        self.mepc = 0
        self.mcause = 0
        self.mtval = 0
        self.gpio_out = 0
        self.gpio_oe = 0
        # video: pixel memory covers the whole 64 KiB window, like the RTL
        self.vram = bytearray(VID_PIX_WORDS * 4)
        self.palette = [i * 0x010101 for i in range(256)]   # grayscale on reset
        self.frame_count = 0
        self.keys_ctrl = 0
        self.uart_out = []
        self.steps = 0

    # ---------------------------------------------------------------- memory
    def _check(self, addr: int, size: int, cause_misalign: int, cause_fault: int):
        if (size == 4 and addr & 3) or (size == 2 and addr & 1):
            raise Trap(cause_misalign, addr)
        w = addr & ~3
        mapped = (w < RAM_SIZE
                  or (w >> 16) in (0x0200, 0x4000, 0x4001, 0x4002)
                  or (w >> 12) in (0x10000, 0x20000, 0x30000, 0x50000))
        if not mapped:
            raise Trap(cause_fault, addr)

    def _mmio_read_word(self, w: int):
        """Returns (value, deterministic)."""
        if (w >> 16) == 0x0200:
            return 0, False
        if (w >> 12) == 0x10000:
            off = w & 0xFF
            if off == 0x04:
                return 0x80000000, True
            if off == 0x08:
                return 0x2, True           # TX FIFO empty, nothing received
            return 0, False
        if (w >> 12) == 0x20000:
            off = w & 0xFF
            return {0x00: self.gpio_out, 0x04: GPIO_IN_VALUE, 0x08: self.gpio_oe}.get(off, 0), True
        if (w >> 16) == 0x4000:                            # framebuffer pixels
            i = (w - VID_PIX_BASE) & (VID_PIX_WORDS * 4 - 1)
            return int.from_bytes(self.vram[i:i + 4], "little"), True
        if (w >> 16) == 0x4001:                            # palette
            return self.palette[(w >> 2) & 0xFF], True
        if (w >> 16) == 0x4002:                            # video control
            off = w & 0xFFF
            if off == 0x04:
                return self.frame_count, True
            if off == 0x08:
                return (VID_HEIGHT << 16) | VID_WIDTH, True
            return 0, True
        if (w >> 12) == 0x50000:                           # keys
            off = w & 0xFFF
            if off == 0x000:
                return 0x80000000, True                    # queue always empty here
            if off == 0x004:
                return 0, True
            if off == 0x008:
                return self.keys_ctrl, True
            return 0, True
        return 0, True

    def load(self, addr: int, size: int):
        self._check(addr, size, 4, 5)
        w, ofs = addr & ~3, addr & 3
        if w < RAM_SIZE:
            word = int.from_bytes(self.mem[w:w + 4], "little")
            det = True
        else:
            word, det = self._mmio_read_word(w)
        return (word >> (8 * ofs)) & ((1 << (8 * size)) - 1), det

    def store(self, addr: int, size: int, value: int):
        self._check(addr, size, 6, 7)
        value &= (1 << (8 * size)) - 1
        if addr < RAM_SIZE:
            self.mem[addr:addr + size] = value.to_bytes(size, "little")
            return
        w = addr & ~3
        if w == SYSCON_EXIT:
            raise Halt(value)
        if (w >> 16) == 0x4000:                            # framebuffer pixels
            i = (addr - VID_PIX_BASE) & (VID_PIX_WORDS * 4 - 1)
            self.vram[i:i + size] = value.to_bytes(size, "little")
            return
        if (w >> 16) == 0x4001:                            # palette
            self.palette[(w >> 2) & 0xFF] = value & 0xFFFFFF
            return
        if (w >> 16) == 0x4002:                            # video control
            if (w & 0xFFF) == 0x000:
                self.frame_count += 1
            return
        if (w >> 12) == 0x50000:                           # keys
            if (w & 0xFFF) == 0x008:
                self.keys_ctrl = value & 1
            return
        if w == UART_BASE and addr == w:
            self.uart_out.append(value & 0xFF)
        elif (w >> 12) == 0x20000:
            if w & 0xFF == 0x00:
                self.gpio_out = value
            elif w & 0xFF == 0x08:
                self.gpio_oe = value

    # ------------------------------------------------------------------ CSRs
    def csr_read(self, addr: int):
        """Returns (value, deterministic) or raises illegal."""
        if addr == 0x300:
            return (0x1800 | (self.mpie_bit << 7) | (self.mie_bit << 3)), True
        simple = {
            0x301: 0x40001100, 0x304: self.mie, 0x305: self.mtvec, 0x340: self.mscratch,
            0x341: self.mepc, 0x342: self.mcause, 0x343: self.mtval, 0x344: 0,
            0xF11: 0, 0xF12: 0, 0xF13: 0x00010000, 0xF14: 0,
        }
        if addr in simple:
            return simple[addr], True
        if addr in self.CSR_RO_COUNTERS:
            return 0, False
        return None, True

    def csr_write(self, addr: int, v: int):
        v &= M32
        if addr == 0x300:
            self.mie_bit, self.mpie_bit = (v >> 3) & 1, (v >> 7) & 1
        elif addr == 0x304:
            self.mie = v & 0x888
        elif addr == 0x305:
            self.mtvec = v & ~2 & M32
        elif addr == 0x340:
            self.mscratch = v
        elif addr == 0x341:
            self.mepc = v & ~3 & M32
        elif addr == 0x342:
            self.mcause = v
        elif addr == 0x343:
            self.mtval = v

    # ------------------------------------------------------------------ step
    def step(self):
        """Execute one instruction. Returns a trace line or None (trapped)."""
        pc = self.pc
        try:
            if pc >= RAM_SIZE:
                raise Trap(1, pc)
            insn = int.from_bytes(self.mem[pc:pc + 4], "little")
            line = self._execute(pc, insn)
            self.steps += 1
            return line
        except Trap as t:
            self.mepc = pc
            self.mcause = t.cause
            self.mtval = t.tval
            self.mpie_bit = self.mie_bit
            self.mie_bit = 0
            self.pc = self.mtvec & ~3
            return None

    def _execute(self, pc: int, insn: int):
        x = self.x
        opc = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        f7 = insn >> 25
        a, b = x[rs1], x[rs2]
        imm_i = sext(insn >> 20, 12)
        next_pc = (pc + 4) & M32
        rdval = None
        memw = None
        det = True

        def illegal():
            raise Trap(2, insn)

        def jump(target):
            target &= M32
            if target & 3:
                raise Trap(0, target)
            return target

        if opc == 0x37:                                     # LUI
            rdval = insn & 0xFFFFF000
        elif opc == 0x17:                                   # AUIPC
            rdval = (pc + (insn & 0xFFFFF000)) & M32
        elif opc == 0x6F:                                   # JAL
            off = sext(((insn >> 31) << 20) | (((insn >> 12) & 0xFF) << 12) |
                       (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)
            next_pc = jump(pc + off)
            rdval = (pc + 4) & M32
        elif opc == 0x67:                                   # JALR
            if f3 != 0:
                illegal()
            next_pc = jump((a + imm_i) & ~1)
            rdval = (pc + 4) & M32
        elif opc == 0x63:                                   # BRANCH
            off = sext(((insn >> 31) << 12) | (((insn >> 7) & 1) << 11) |
                       (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
            conds = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                     6: a < b, 7: a >= b}
            if f3 not in conds:
                illegal()
            if conds[f3]:
                next_pc = jump(pc + off)
        elif opc == 0x03:                                   # LOAD
            sizes = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}
            if f3 not in sizes:
                illegal()
            v, det = self.load((a + imm_i) & M32, sizes[f3])
            if f3 in (0, 1):
                v = sext(v, 8 * sizes[f3]) & M32
            rdval = v
        elif opc == 0x23:                                   # STORE
            sizes = {0: 1, 1: 2, 2: 4}
            if f3 not in sizes:
                illegal()
            addr = (a + sext((f7 << 5) | ((insn >> 7) & 0x1F), 12)) & M32
            self.store(addr, sizes[f3], b)
            memw = (addr, b & ((1 << (8 * sizes[f3])) - 1))
        elif opc == 0x13:                                   # OP-IMM
            sh = imm_i & 0x1F
            if f3 == 0:
                rdval = (a + imm_i) & M32
            elif f3 == 2:
                rdval = int(s32(a) < imm_i)
            elif f3 == 3:
                rdval = int(a < (imm_i & M32))
            elif f3 == 4:
                rdval = (a ^ imm_i) & M32
            elif f3 == 6:
                rdval = (a | imm_i) & M32
            elif f3 == 7:
                rdval = (a & imm_i) & M32
            elif f3 == 1:
                if f7 != 0:
                    illegal()
                rdval = (a << sh) & M32
            else:
                if f7 == 0:
                    rdval = a >> sh
                elif f7 == 0x20:
                    rdval = (s32(a) >> sh) & M32
                else:
                    illegal()
        elif opc == 0x33:                                   # OP
            if f7 == 1:
                rdval = self._muldiv(f3, a, b)
            elif f7 == 0:
                rdval = {0: a + b, 1: a << (b & 31), 2: int(s32(a) < s32(b)), 3: int(a < b),
                         4: a ^ b, 5: a >> (b & 31), 6: a | b, 7: a & b}[f3] & M32
            elif f7 == 0x20 and f3 == 0:
                rdval = (a - b) & M32
            elif f7 == 0x20 and f3 == 5:
                rdval = (s32(a) >> (b & 31)) & M32
            else:
                illegal()
        elif opc == 0x0F:                                   # MISC-MEM
            if f3 not in (0, 1):
                illegal()
        elif opc == 0x73:                                   # SYSTEM
            if f3 == 0:
                top = insn >> 7
                if top == 0:
                    raise Trap(11, 0)
                if top == 0x2000:
                    raise Trap(3, pc)
                if top == (0x302 << 13):
                    self.mie_bit, self.mpie_bit = self.mpie_bit, 1
                    next_pc = self.mepc
                elif top == (0x105 << 13):
                    pass                                    # WFI
                else:
                    illegal()
            elif f3 == 4:
                illegal()
            else:
                csr = insn >> 20
                old, det = self.csr_read(csr)
                write = (f3 & 3) == 1 or rs1 != 0
                if old is None or (write and (csr >> 10) == 3):
                    illegal()
                operand = rs1 if f3 & 4 else a
                if write:
                    new = {1: operand, 2: old | operand, 3: old & ~operand}[f3 & 3]
                    self.csr_write(csr, new)
                rdval = old
        else:
            illegal()

        # ---- commit
        self.pc = next_pc
        if memw is not None:
            return f"{pc:08x} {insn:08x} mem {memw[0]:08x} {memw[1]:08x}"
        if rdval is not None and rd != 0:
            x[rd] = rdval & M32
            return f"{pc:08x} {insn:08x} x{rd} {rdval & M32:08x}" if det else \
                   f"{pc:08x} {insn:08x} x{rd} {WILDCARD}"
        return f"{pc:08x} {insn:08x}"

    @staticmethod
    def _muldiv(f3: int, a: int, b: int) -> int:
        sa, sb = s32(a), s32(b)
        if f3 == 0:
            return (a * b) & M32
        if f3 == 1:
            return ((sa * sb) >> 32) & M32
        if f3 == 2:
            return ((sa * b) >> 32) & M32
        if f3 == 3:
            return ((a * b) >> 32) & M32
        if f3 in (4, 6):                                    # DIV / REM (signed)
            if b == 0:
                return M32 if f3 == 4 else a
            if a == 0x80000000 and b == M32:
                return a if f3 == 4 else 0
            q = abs(sa) // abs(sb)
            if (sa < 0) != (sb < 0):
                q = -q
            return (q if f3 == 4 else sa - q * sb) & M32
        if b == 0:                                          # DIVU / REMU
            return M32 if f3 == 5 else a
        return (a // b) if f3 == 5 else (a % b)


def load_hex(path: str) -> bytes:
    out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out += int(line, 16).to_bytes(4, "little")
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hex")
    ap.add_argument("--trace", help="write commit trace to this file")
    ap.add_argument("--max-steps", type=int, default=5_000_000)
    args = ap.parse_args()

    iss = RV32ISS(load_hex(args.hex))
    tf = open(args.trace, "w") if args.trace else None
    code = None
    try:
        while iss.steps < args.max_steps:
            try:
                line = iss.step()
            except Halt as h:
                # the exit store itself is a committed instruction
                if tf:
                    pc = iss.pc
                    insn = int.from_bytes(iss.mem[pc:pc + 4], "little")
                    tf.write(f"{pc:08x} {insn:08x} mem {SYSCON_EXIT:08x} {h.code & M32:08x}\n")
                code = h.code
                break
            if tf and line:
                tf.write(line + "\n")
    finally:
        if tf:
            tf.close()

    sys.stdout.write(bytes(iss.uart_out).decode(errors="replace"))
    if code is None:
        print(f"\nISS: step limit reached (pc={iss.pc:08x})")
        return 2
    print(f"\nISS: exit code {code} after {iss.steps + 1} instructions")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
