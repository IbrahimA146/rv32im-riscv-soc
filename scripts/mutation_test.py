#!/usr/bin/env python3
"""
mutation_test.py - measure how good the verification suite is at finding bugs

Each mutant is a small, realistic RTL bug (a missing forwarding path, a wrong
signedness, a flush that is not applied, ...). The mutant is compiled from a
private copy of the RTL and the directed + random test programs are run against
it. A mutant is "killed" when at least one test fails, either via its
self-check or via divergence from the ISS golden model.

    python scripts/mutation_test.py            # all mutants
    python scripts/mutation_test.py -k fwd     # subset
"""
import argparse
import shutil
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_tests as rt  # noqa: E402

CORE = "rtl/core/rv32_core.sv"

# (id, description, file, original, mutated)
MUTANTS = [
    ("fwd-mem-rs1", "no MEM->EX forwarding for rs1", CORE,
     "if (mem_valid && mem_ctrl.reg_we && mem_rd == ex_rs1)      fwd_a = mem_fwd_value;",
     "if (1'b0)      fwd_a = mem_fwd_value;"),
    ("fwd-wb-rs2", "no WB->EX forwarding for rs2", CORE,
     "else if (wb_valid && wb_reg_we && wb_rd == ex_rs2)         fwd_b = wb_value;",
     "else if (1'b0)         fwd_b = wb_value;"),
    ("fwd-priority", "WB forwarding takes priority over MEM", CORE,
     "if (mem_valid && mem_ctrl.reg_we && mem_rd == ex_rs1)      fwd_a = mem_fwd_value;\n"
     "      else if (wb_valid && wb_reg_we && wb_rd == ex_rs1)         fwd_a = wb_value;",
     "if (wb_valid && wb_reg_we && wb_rd == ex_rs1)      fwd_a = wb_value;\n"
     "      else if (mem_valid && mem_ctrl.reg_we && mem_rd == ex_rs1)         fwd_a = mem_fwd_value;"),
    ("no-load-use", "load-use hazard never stalls", CORE,
     "assign load_use = ex_valid && ex_ctrl.mem_re",
     "assign load_use = 1'b0 && ex_ctrl.mem_re"),
    ("load-use-rs2", "load-use check ignores rs2", CORE,
     "(id_ctrl.uses_rs2 && id_rs2 == ex_rd)",
     "1'b0"),
    ("regfile-bypass", "register file has no write-through", "rtl/core/rv32_regfile.sv",
     "(we_i && waddr_i == raddr1_i)        ? wdata_i : regs[raddr1_i]",
     "1'b0 ? wdata_i : regs[raddr1_i]"),
    ("mispredict-target", "mispredict ignores a wrong target", CORE,
     "(ex_actual_taken && ex_bp_target != ex_actual_target)",
     "1'b0"),
    ("no-flush-id", "mispredict does not squash the ID stage", CORE,
     "    end else if (redirect_mem || mispredict) begin\n      ex_valid <= 1'b0;",
     "    end else if (redirect_mem) begin\n      ex_valid <= 1'b0;"),
    ("bge-unsigned", "BGE compares unsigned", CORE,
     "3'b101:  br_cond = ($signed(fwd_a) >= $signed(fwd_b));",
     "3'b101:  br_cond = (fwd_a >= fwd_b);"),
    ("jalr-bit0", "JALR does not clear bit 0", CORE,
     "assign jalr_target = (fwd_a + ex_imm) & ~32'd1;",
     "assign jalr_target = (fwd_a + ex_imm);"),
    ("sra-logical", "SRA shifts logically", "rtl/core/rv32_alu.sv",
     "ALU_SRA:  y_o = $unsigned($signed(a_i) >>> shamt);",
     "ALU_SRA:  y_o = a_i >> shamt;"),
    ("slt-unsigned", "SLT compares unsigned", "rtl/core/rv32_alu.sv",
     "ALU_SLT:  y_o = {31'b0, $signed(a_i) < $signed(b_i)};",
     "ALU_SLT:  y_o = {31'b0, a_i < b_i};"),
    ("mulhsu-signed", "MULHSU treats rs2 as signed", "rtl/core/rv32_mul.sv",
     "assign b_signed = (funct3_i == 3'b001);",
     "assign b_signed = (funct3_i == 3'b001) || (funct3_i == 3'b010);"),
    ("rem-sign", "REM takes the sign of the quotient", "rtl/core/rv32_div.sv",
     "neg_rem_q  <= a_neg;",
     "neg_rem_q  <= a_neg ^ b_neg;"),
    ("div-by-zero", "divide-by-zero not special-cased", "rtl/core/rv32_div.sv",
     "if (div_by_zero) begin",
     "if (1'b0) begin"),
    ("div-no-bubble", "EX stall does not bubble MEM", CORE,
     "end else if (redirect_mem || ex_stall) begin\n      mem_valid <= 1'b0;",
     "end else if (redirect_mem) begin\n      mem_valid <= 1'b0;"),
    ("lbu-signed", "LBU sign-extends", CORE,
     "3'b100:  load_value = {24'b0, rdata_shifted[7:0]};",
     "3'b100:  load_value = {{24{rdata_shifted[7]}}, rdata_shifted[7:0]};"),
    ("sh-strobe", "SH ignores the byte offset", CORE,
     "(mem_size == 2'd1) ? (4'b0011 << mem_ofs)",
     "(mem_size == 2'd1) ? (4'b0011)"),
    ("mret-no-flush", "MRET does not flush the pipeline", CORE,
     "assign redirect_mem    = trap_take || mret_take;",
     "assign redirect_mem    = trap_take || (mret_take && 1'b0);"),
    ("epc-plus4", "mepc points past the trapping instruction", CORE,
     ".trap_pc_i     (mem_pc),",
     ".trap_pc_i     (mem_pc + 32'd4),"),
    ("csr-write-beats-trap", "CSR write wins over a coincident trap", "rtl/core/rv32_csr.sv",
     "      if (trap_i) begin",
     "      if (trap_i && !(access_i && write_i && !illegal_o)) begin"),
    ("csrrs-x0-writes", "CSRRS with rs1=x0 still writes", CORE,
     "assign csr_write  = (mem_ctrl.funct3[1:0] == 2'b01) || (mem_insn[19:15] != 5'd0);",
     "assign csr_write  = 1'b1;"),
    ("irq-ignore-mie", "interrupts ignore mstatus.MIE", "rtl/core/rv32_csr.sv",
     "assign irq_pending_o = mstatus_mie_q && (irq_active != 32'b0);",
     "assign irq_pending_o = (irq_active != 32'b0);"),
    ("mtvec-vectored", "vectored mode ignores the cause offset", "rtl/core/rv32_csr.sv",
     "? mtvec_base + {25'b0, trap_code_i, 2'b00}",
     "? mtvec_base"),
    ("illegal-csr", "unknown CSRs do not trap", "rtl/core/rv32_csr.sv",
     "assign illegal_o = access_i && (!known ||",
     "assign illegal_o = access_i && (1'b0 ||"),
    ("minstret-traps", "minstret counts trapped instructions", CORE,
     ".instret_i     (mem_valid && !trap_take),",
     ".instret_i     (mem_valid),"),
]


def build_mutant(mid, path, orig, mutated, root):
    """Copy RTL + testbench, apply one mutation, compile. Returns vvp path."""
    for sub in ("rtl", "sim"):
        shutil.copytree(rt.ROOT / sub, root / sub, dirs_exist_ok=True)
    target = root / path
    text = target.read_text()
    if text.count(orig) != 1:
        raise RuntimeError(f"mutant {mid}: pattern found {text.count(orig)} times in {path}")
    target.write_text(text.replace(orig, mutated))
    srcs = [root / p.relative_to(rt.ROOT) for p in rt.RTL_SOURCES]
    vvp = root / "tb_soc.vvp"
    r = rt.run(["iverilog", "-g2012", "-o", vvp, "-s", "tb_soc", *srcs])
    if r.returncode != 0:
        raise RuntimeError(f"mutant {mid} does not compile:\n{r.stderr}")
    return vvp


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-k", "--filter", default="")
    ap.add_argument("-n", "--num-random", type=int, default=8)
    ap.add_argument("-j", "--jobs", type=int, default=8)
    args = ap.parse_args()

    t0 = time.time()
    print("building test programs ...")
    rt.compile_rtl()
    rt.run([sys.executable, rt.ROOT / "tests/isa/gen_isa_tests.py"])
    programs = []                                   # (name, hex, cosim)
    for src in sorted((rt.ROOT / "tests/isa").glob("*.S")) + sorted((rt.ROOT / "tests/isa/generated").glob("*.S")):
        programs.append((f"isa/{src.stem}", rt.build_asm(src, rt.BUILD / "isa"), src.stem not in rt.NO_COSIM))
    rdir = rt.BUILD / "random"
    rdir.mkdir(parents=True, exist_ok=True)
    for seed in range(1, args.num_random + 1):
        src = rdir / f"seed{seed}.S"
        rt.run([sys.executable, rt.ROOT / "tests/random/gen_random.py", "--seed", seed, "-o", src])
        programs.append((f"random/seed{seed}", rt.build_asm(src, rdir), True))
    # cheap, fast-failing programs first
    programs.sort(key=lambda p: p[1].stat().st_size)

    mutants = [m for m in MUTANTS if args.filter in m[0]]
    results = []
    with ThreadPoolExecutor(args.jobs) as pool:
        for mid, desc, path, orig, mutated in mutants:
            root = rt.BUILD / "mutants" / mid
            shutil.rmtree(root, ignore_errors=True)
            vvp = build_mutant(mid, path, orig, mutated, root)

            def job(prog, vvp=vvp, root=root):
                name, hex_, cosim = prog
                local = root / hex_.name                # traces must not collide
                shutil.copy(hex_, local)
                return rt.run_program(name, local, vvp, cosim, timeout=250_000)

            killer = None
            # run in parallel batches, stop at the first failing batch
            for i in range(0, len(programs), args.jobs):
                for res in pool.map(job, programs[i:i + args.jobs]):
                    if not res.ok and killer is None:
                        killer = res
                if killer:
                    break
            status = "KILLED" if killer else "SURVIVED"
            by = f"by {killer.name}: {killer.detail.splitlines()[0]}" if killer else ""
            print(f"  {mid:<20} {status:<9} {desc:<45} {by}")
            results.append((mid, killer is not None))

    killed = sum(k for _, k in results)
    print(f"\nmutation score: {killed}/{len(results)} mutants killed "
          f"({100 * killed // max(len(results), 1)}%) in {time.time() - t0:.0f}s")
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
