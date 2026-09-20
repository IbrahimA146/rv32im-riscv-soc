// -----------------------------------------------------------------------------
// rv32_csr.sv - machine-mode CSRs, trap entry/exit and performance counters
//
// All CSR side effects are applied from the MEM stage, together with the
// precise-trap decision, so a flushed instruction can never corrupt CSR state.
// -----------------------------------------------------------------------------
module rv32_csr
  import rv32_pkg::*;
#(
  parameter logic [31:0] HART_ID = 32'd0
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- CSR instruction access (MEM stage) -----------------------------------
  input  logic [11:0] addr_i,
  input  logic [2:0]  funct3_i,       // 01 rw, 10 rs, 11 rc (bit 2 = immediate form)
  input  logic        access_i,       // a valid CSR instruction is in MEM
  input  logic        write_i,        // instruction intends to write
  input  logic [31:0] operand_i,      // rs1 value or zimm
  input  logic        commit_i,       // no trap this cycle -> apply the write
  output logic [31:0] rdata_o,
  output logic        illegal_o,

  // ---- Traps ----------------------------------------------------------------
  input  logic        trap_i,
  input  logic        trap_is_irq_i,
  input  logic [4:0]  trap_code_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,
  output logic [31:0] trap_vector_o,
  output logic [31:0] mepc_o,

  // ---- Interrupts -----------------------------------------------------------
  input  logic        irq_soft_i,
  input  logic        irq_timer_i,
  input  logic        irq_ext_i,
  output logic        irq_pending_o,
  output logic [4:0]  irq_code_o,

  // ---- Counter events -------------------------------------------------------
  input  logic        instret_i,
  input  logic        branch_i,
  input  logic        mispredict_i
);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic        mstatus_mie_q, mstatus_mpie_q;
  logic        mie_msie_q, mie_mtie_q, mie_meie_q;
  logic [31:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
  logic [63:0] mcycle_q, minstret_q;
  logic [31:0] hpm3_q, hpm4_q;

  localparam logic [31:0] MISA = 32'h4000_1100;  // RV32 + I + M

  logic [31:0] mstatus, mie, mip;
  assign mstatus = {19'b0, 2'b11, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};
  assign mie     = {20'b0, mie_meie_q, 3'b0, mie_mtie_q, 3'b0, mie_msie_q, 3'b0};
  assign mip     = {20'b0, irq_ext_i,  3'b0, irq_timer_i, 3'b0, irq_soft_i, 3'b0};

  // ---------------------------------------------------------------------------
  // Read mux / legality
  // ---------------------------------------------------------------------------
  logic known;
  always_comb begin
    known   = 1'b1;
    rdata_o = 32'b0;
    case (addr_i)
      CSR_MSTATUS:   rdata_o = mstatus;
      CSR_MISA:      rdata_o = MISA;
      CSR_MIE:       rdata_o = mie;
      CSR_MTVEC:     rdata_o = mtvec_q;
      CSR_MSCRATCH:  rdata_o = mscratch_q;
      CSR_MEPC:      rdata_o = mepc_q;
      CSR_MCAUSE:    rdata_o = mcause_q;
      CSR_MTVAL:     rdata_o = mtval_q;
      CSR_MIP:       rdata_o = mip;
      CSR_MCYCLE:    rdata_o = mcycle_q[31:0];
      CSR_MCYCLEH:   rdata_o = mcycle_q[63:32];
      CSR_MINSTRET:  rdata_o = minstret_q[31:0];
      CSR_MINSTRETH: rdata_o = minstret_q[63:32];
      CSR_MHPMCNT3:  rdata_o = hpm3_q;
      CSR_MHPMCNT4:  rdata_o = hpm4_q;
      CSR_MVENDORID: rdata_o = 32'b0;
      CSR_MARCHID:   rdata_o = 32'b0;
      CSR_MIMPLID:   rdata_o = 32'h0001_0000;
      CSR_MHARTID:   rdata_o = HART_ID;
      default:       known   = 1'b0;
    endcase
  end

  // CSRs 0xC00-0xFFF are read-only by address encoding.
  assign illegal_o = access_i && (!known || (write_i && addr_i[11:10] == 2'b11));

  // Value to be written for RW / RS / RC
  logic [31:0] wval;
  always_comb begin
    case (funct3_i[1:0])
      2'b01:   wval = operand_i;
      2'b10:   wval = rdata_o |  operand_i;
      2'b11:   wval = rdata_o & ~operand_i;
      default: wval = rdata_o;
    endcase
  end

  logic do_write;
  assign do_write = access_i && write_i && commit_i && !illegal_o;

  // ---------------------------------------------------------------------------
  // Interrupt arbitration: MEI > MSI > MTI (priority order from the spec)
  // ---------------------------------------------------------------------------
  logic [31:0] irq_active;
  assign irq_active = mip & mie;

  always_comb begin
    irq_code_o = IRQ_M_TIMER;
    if      (irq_active[11]) irq_code_o = IRQ_M_EXT;
    else if (irq_active[3])  irq_code_o = IRQ_M_SOFT;
    else if (irq_active[7])  irq_code_o = IRQ_M_TIMER;
  end

  assign irq_pending_o = mstatus_mie_q && (irq_active != 32'b0);

  // Direct mode, or vectored mode (base + 4*cause) for interrupts
  logic [31:0] mtvec_base;
  assign mtvec_base    = {mtvec_q[31:2], 2'b00};
  assign trap_vector_o = (mtvec_q[0] && trap_is_irq_i) ? mtvec_base + {25'b0, trap_code_i, 2'b00}
                                                       : mtvec_base;
  assign mepc_o = mepc_q;

  // ---------------------------------------------------------------------------
  // Sequential update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_msie_q     <= 1'b0;
      mie_mtie_q     <= 1'b0;
      mie_meie_q     <= 1'b0;
      mtvec_q        <= 32'b0;
      mscratch_q     <= 32'b0;
      mepc_q         <= 32'b0;
      mcause_q       <= 32'b0;
      mtval_q        <= 32'b0;
      mcycle_q       <= 64'b0;
      minstret_q     <= 64'b0;
      hpm3_q         <= 32'b0;
      hpm4_q         <= 32'b0;
    end else begin
      // Free-running counters (a CSR write in the same cycle takes priority)
      mcycle_q <= mcycle_q + 64'd1;
      if (instret_i)    minstret_q <= minstret_q + 64'd1;
      if (branch_i)     hpm3_q     <= hpm3_q + 32'd1;
      if (mispredict_i) hpm4_q     <= hpm4_q + 32'd1;

      if (trap_i) begin
        mepc_q         <= trap_pc_i;
        mcause_q       <= {trap_is_irq_i, 26'b0, trap_code_i};
        mtval_q        <= trap_tval_i;
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
      end else if (mret_i) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end else if (do_write) begin
        case (addr_i)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= wval[3];
            mstatus_mpie_q <= wval[7];
          end
          CSR_MIE: begin
            mie_msie_q <= wval[3];
            mie_mtie_q <= wval[7];
            mie_meie_q <= wval[11];
          end
          CSR_MTVEC:     mtvec_q    <= {wval[31:2], 1'b0, wval[0]};
          CSR_MSCRATCH:  mscratch_q <= wval;
          CSR_MEPC:      mepc_q     <= {wval[31:2], 2'b00};
          CSR_MCAUSE:    mcause_q   <= wval;
          CSR_MTVAL:     mtval_q    <= wval;
          CSR_MCYCLE:    mcycle_q   <= {mcycle_q[63:32], wval};
          CSR_MCYCLEH:   mcycle_q   <= {wval, mcycle_q[31:0]};
          CSR_MINSTRET:  minstret_q <= {minstret_q[63:32], wval};
          CSR_MINSTRETH: minstret_q <= {wval, minstret_q[31:0]};
          CSR_MHPMCNT3:  hpm3_q     <= wval;
          CSR_MHPMCNT4:  hpm4_q     <= wval;
          default: ;
        endcase
      end
    end
  end

endmodule
