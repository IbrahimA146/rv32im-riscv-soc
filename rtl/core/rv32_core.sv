// -----------------------------------------------------------------------------
// rv32_core.sv - 5-stage pipelined RV32IM_Zicsr processor
//
//   IF  -> ID  -> EX  -> MEM -> WB
//
//   * Full EX-stage forwarding from MEM and WB, write-through register file
//   * Load-use hazard detection (1-cycle stall)
//   * BTB + 2-bit bimodal branch prediction in IF, resolution in EX
//   * Single-cycle multiplier, iterative divider (stalls EX while busy)
//   * Precise exceptions and interrupts taken in MEM
//   * Separate instruction and data buses (Harvard access, shared memory map)
//
// Pipeline control summary
//   redirect_mem : trap or MRET in MEM   -> flush IF/ID, ID/EX, EX/MEM, new PC
//   mispredict   : wrong prediction in EX -> flush IF/ID, ID/EX, new PC
//   ex_stall     : divider busy           -> hold PC, IF/ID, ID/EX; bubble to MEM
//   load_use     : ID needs a load result -> hold PC, IF/ID; bubble to EX
// -----------------------------------------------------------------------------
module rv32_core
  import rv32_pkg::*;
#(
  parameter logic [31:0] RESET_PC     = 32'h0000_0000,
  parameter int          BTB_IDX_BITS = 6
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction bus (combinational read)
  output logic [31:0] ibus_addr_o,
  input  logic [31:0] ibus_rdata_i,
  input  logic        ibus_err_i,

  // Data bus (combinational read, synchronous write)
  output logic [31:0] dbus_addr_o,     // word-aligned
  output logic        dbus_re_o,
  output logic        dbus_we_o,
  output logic [3:0]  dbus_wstrb_o,
  output logic [31:0] dbus_wdata_o,
  input  logic [31:0] dbus_rdata_i,
  input  logic        dbus_err_i,      // must depend on the address only

  // Interrupts (level sensitive)
  input  logic        irq_soft_i,
  input  logic        irq_timer_i,
  input  logic        irq_ext_i
);

  // ===========================================================================
  // Global pipeline control (driven further down)
  // ===========================================================================
  // The events that cost the pipeline cycles are counted by the hardware
  // performance counters in rv32_csr (mhpmcounter3-6), which is both how a real
  // CPU reports them and far cheaper to read than exposing combinational
  // signals to the simulator - doing that cost 4x simulation speed.
  logic        redirect_mem;    // trap or mret in MEM
  logic [31:0] redirect_mem_pc;
  logic        trap_take;
  logic        mispredict;
  logic [31:0] mispredict_pc;
  logic        ex_stall;
  logic        load_use;

  // ===========================================================================
  // IF - fetch
  // ===========================================================================
  logic [31:0] pc_q;
  logic        bp_taken;
  logic [31:0] bp_target;

  // BPU training signals from EX
  logic        bpu_upd_valid;
  logic        ex_actual_taken;
  logic [31:0] ex_actual_target;

  assign ibus_addr_o = pc_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                   pc_q <= RESET_PC;
    else if (redirect_mem)         pc_q <= redirect_mem_pc;
    else if (mispredict)           pc_q <= mispredict_pc;
    else if (ex_stall || load_use) pc_q <= pc_q;
    else                           pc_q <= bp_taken ? bp_target : pc_q + 32'd4;
  end

  // IF/ID register
  logic        id_valid;
  logic [31:0] id_pc, id_insn, id_bp_target;
  logic        id_bp_taken, id_ifault;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_valid     <= 1'b0;
      id_pc        <= 32'b0;
      id_insn      <= NOP;
      id_bp_taken  <= 1'b0;
      id_bp_target <= 32'b0;
      id_ifault    <= 1'b0;
    end else if (redirect_mem || mispredict) begin
      id_valid <= 1'b0;
    end else if (!(ex_stall || load_use)) begin
      id_valid     <= 1'b1;
      id_pc        <= pc_q;
      id_insn      <= ibus_err_i ? NOP : ibus_rdata_i;
      id_bp_taken  <= bp_taken;
      id_bp_target <= bp_target;
      id_ifault    <= ibus_err_i;
    end
  end

  // ===========================================================================
  // ID - decode
  // ===========================================================================
  ctrl_t       id_ctrl;
  logic [31:0] id_imm;
  logic [4:0]  id_rs1, id_rs2, id_rd;
  logic [31:0] id_rv1, id_rv2;

  assign id_rs1 = id_insn[19:15];
  assign id_rs2 = id_insn[24:20];
  assign id_rd  = id_insn[11:7];

  rv32_decoder u_decoder (
    .insn_i (id_insn),
    .ctrl_o (id_ctrl),
    .imm_o  (id_imm)
  );

  // WB write port (driven in WB section)
  logic        wb_valid  /*verilator public_flat_rd*/;
  logic        wb_reg_we /*verilator public_flat_rd*/;
  logic [4:0]  wb_rd     /*verilator public_flat_rd*/;
  logic [31:0] wb_value  /*verilator public_flat_rd*/;

  rv32_regfile u_regfile (
    .clk_i    (clk_i),
    .we_i     (wb_valid && wb_reg_we),
    .waddr_i  (wb_rd),
    .wdata_i  (wb_value),
    .raddr1_i (id_rs1),
    .raddr2_i (id_rs2),
    .rdata1_o (id_rv1),
    .rdata2_o (id_rv2)
  );

  // Exceptions detectable in ID (priority: fetch fault > illegal > ecall/ebreak)
  logic        id_exc;
  logic [4:0]  id_cause;
  logic [31:0] id_tval;

  always_comb begin
    id_exc   = 1'b1;
    id_cause = EXC_ILLEGAL_INSN;
    id_tval  = 32'b0;
    if (id_ifault) begin
      id_cause = EXC_INSN_ACCESS;
      id_tval  = id_pc;
    end else if (id_ctrl.illegal) begin
      id_cause = EXC_ILLEGAL_INSN;
      id_tval  = id_insn;
    end else if (id_ctrl.is_ecall) begin
      id_cause = EXC_ECALL_M;
    end else if (id_ctrl.is_ebreak) begin
      id_cause = EXC_BREAKPOINT;
      id_tval  = id_pc;
    end else begin
      id_exc   = 1'b0;
    end
  end

  // ID/EX register
  logic        ex_valid;
  ctrl_t       ex_ctrl;
  logic [31:0] ex_pc, ex_insn, ex_imm, ex_rv1, ex_rv2, ex_bp_target;
  logic [4:0]  ex_rs1, ex_rs2, ex_rd;
  logic        ex_bp_taken;
  logic        ex_exc;
  logic [4:0]  ex_cause;
  logic [31:0] ex_tval;

  // Load-use: the instruction in EX is a load whose result ID needs now.
  assign load_use = ex_valid && ex_ctrl.mem_re && (ex_rd != 5'd0) && id_valid &&
                    ((id_ctrl.uses_rs1 && id_rs1 == ex_rd) ||
                     (id_ctrl.uses_rs2 && id_rs2 == ex_rd));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_valid     <= 1'b0;
      ex_ctrl      <= '0;
      ex_pc        <= 32'b0;
      ex_insn      <= NOP;
      ex_imm       <= 32'b0;
      ex_rv1       <= 32'b0;
      ex_rv2       <= 32'b0;
      ex_rs1       <= 5'b0;
      ex_rs2       <= 5'b0;
      ex_rd        <= 5'b0;
      ex_bp_taken  <= 1'b0;
      ex_bp_target <= 32'b0;
      ex_exc       <= 1'b0;
      ex_cause     <= 5'b0;
      ex_tval      <= 32'b0;
    end else if (redirect_mem || mispredict) begin
      ex_valid <= 1'b0;
    end else if (ex_stall) begin
      ex_valid <= ex_valid;           // hold
    end else if (load_use) begin
      ex_valid <= 1'b0;               // bubble
    end else begin
      ex_valid     <= id_valid;
      ex_ctrl      <= id_ctrl;
      ex_pc        <= id_pc;
      ex_insn      <= id_insn;
      ex_imm       <= id_imm;
      ex_rv1       <= id_rv1;
      ex_rv2       <= id_rv2;
      ex_rs1       <= id_ctrl.uses_rs1 ? id_rs1 : 5'd0;
      ex_rs2       <= id_ctrl.uses_rs2 ? id_rs2 : 5'd0;
      ex_rd        <= id_rd;
      ex_bp_taken  <= id_bp_taken;
      ex_bp_target <= id_bp_target;
      ex_exc       <= id_exc;
      ex_cause     <= id_cause;
      ex_tval      <= id_tval;
    end
  end

  // ===========================================================================
  // EX - execute
  // ===========================================================================
  // MEM/WB state used for forwarding (driven below)
  logic        mem_valid;
  ctrl_t       mem_ctrl;
  logic [4:0]  mem_rd;
  logic [31:0] mem_fwd_value;

  logic [31:0] fwd_a, fwd_b;

  always_comb begin
    fwd_a = ex_rv1;
    if (ex_rs1 != 5'd0) begin
      if (mem_valid && mem_ctrl.reg_we && mem_rd == ex_rs1)      fwd_a = mem_fwd_value;
      else if (wb_valid && wb_reg_we && wb_rd == ex_rs1)         fwd_a = wb_value;
    end
    fwd_b = ex_rv2;
    if (ex_rs2 != 5'd0) begin
      if (mem_valid && mem_ctrl.reg_we && mem_rd == ex_rs2)      fwd_b = mem_fwd_value;
      else if (wb_valid && wb_reg_we && wb_rd == ex_rs2)         fwd_b = wb_value;
    end
  end

  // ALU
  logic [31:0] alu_a, alu_b, alu_y;
  assign alu_a = (ex_ctrl.sel_a == SEL_A_PC)   ? ex_pc :
                 (ex_ctrl.sel_a == SEL_A_ZERO) ? 32'b0 : fwd_a;
  assign alu_b = ex_ctrl.sel_b_imm ? ex_imm : fwd_b;

  rv32_alu u_alu (
    .op_i (ex_ctrl.alu_op),
    .a_i  (alu_a),
    .b_i  (alu_b),
    .y_o  (alu_y)
  );

  // M extension
  logic [31:0] mul_y, div_y;
  logic        div_done;

  rv32_mul u_mul (
    .funct3_i (ex_ctrl.funct3),
    .a_i      (fwd_a),
    .b_i      (fwd_b),
    .y_o      (mul_y)
  );

  rv32_div u_div (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .start_i  (ex_valid && ex_ctrl.is_div && !ex_exc),
    .abort_i  (redirect_mem),
    .funct3_i (ex_ctrl.funct3),
    .a_i      (fwd_a),
    .b_i      (fwd_b),
    .done_o   (div_done),
    .result_o (div_y)
  );

  assign ex_stall = ex_valid && ex_ctrl.is_div && !ex_exc && !div_done && !redirect_mem;

  // Branch resolution
  logic        br_cond;
  logic [31:0] br_target, jalr_target, pc_plus4;

  always_comb begin
    case (ex_ctrl.funct3)
      3'b000:  br_cond = (fwd_a == fwd_b);
      3'b001:  br_cond = (fwd_a != fwd_b);
      3'b100:  br_cond = ($signed(fwd_a) <  $signed(fwd_b));
      3'b101:  br_cond = ($signed(fwd_a) >= $signed(fwd_b));
      3'b110:  br_cond = (fwd_a <  fwd_b);
      3'b111:  br_cond = (fwd_a >= fwd_b);
      default: br_cond = 1'b0;
    endcase
  end

  assign pc_plus4    = ex_pc + 32'd4;
  assign br_target   = ex_pc + ex_imm;
  assign jalr_target = (fwd_a + ex_imm) & ~32'd1;

  logic ex_is_cf;
  assign ex_is_cf         = ex_ctrl.is_branch || ex_ctrl.is_jal || ex_ctrl.is_jalr;
  assign ex_actual_taken  = ex_ctrl.is_jal || ex_ctrl.is_jalr || (ex_ctrl.is_branch && br_cond);
  assign ex_actual_target = ex_ctrl.is_jalr ? jalr_target : br_target;

  // A taken jump to a non word-aligned target raises a misaligned exception.
  logic ex_misaligned;
  assign ex_misaligned = ex_valid && !ex_exc && ex_actual_taken && (ex_actual_target[1:0] != 2'b00);

  logic ex_resolve;   // EX holds a real, non-faulting instruction leaving this cycle
  assign ex_resolve = ex_valid && !ex_exc && !ex_misaligned && !redirect_mem && !ex_stall;

  assign mispredict    = ex_resolve &&
                         ((ex_bp_taken != ex_actual_taken) ||
                          (ex_actual_taken && ex_bp_target != ex_actual_target));
  assign mispredict_pc = ex_actual_taken ? ex_actual_target : pc_plus4;

  assign bpu_upd_valid = ex_resolve && ex_is_cf;

  rv32_bpu #(.IDX_BITS(BTB_IDX_BITS)) u_bpu (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .pc_i          (pc_q),
    .pred_taken_o  (bp_taken),
    .pred_target_o (bp_target),
    .upd_valid_i   (bpu_upd_valid),
    .upd_pc_i      (ex_pc),
    .upd_taken_i   (ex_actual_taken),
    .upd_uncond_i  (ex_ctrl.is_jal || ex_ctrl.is_jalr),
    .upd_target_i  (ex_actual_target)
  );

  logic [31:0] ex_result;
  assign ex_result = (ex_ctrl.is_jal || ex_ctrl.is_jalr) ? pc_plus4 :
                     ex_ctrl.is_mul                      ? mul_y    :
                     ex_ctrl.is_div                      ? div_y    : alu_y;

  // EX/MEM register
  logic [31:0] mem_pc, mem_insn, mem_result, mem_wdata, mem_csr_operand;
  logic        mem_exc;
  logic [4:0]  mem_cause;
  logic [31:0] mem_tval;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_valid       <= 1'b0;
      mem_ctrl        <= '0;
      mem_pc          <= 32'b0;
      mem_insn        <= NOP;
      mem_rd          <= 5'b0;
      mem_result      <= 32'b0;
      mem_wdata       <= 32'b0;
      mem_csr_operand <= 32'b0;
      mem_exc         <= 1'b0;
      mem_cause       <= 5'b0;
      mem_tval        <= 32'b0;
    end else if (redirect_mem || ex_stall) begin
      mem_valid <= 1'b0;
    end else begin
      mem_valid       <= ex_valid;
      mem_ctrl        <= ex_ctrl;
      mem_pc          <= ex_pc;
      mem_insn        <= ex_insn;
      mem_rd          <= ex_rd;
      mem_result      <= ex_result;
      mem_wdata       <= fwd_b;
      mem_csr_operand <= ex_ctrl.csr_imm ? ex_imm : fwd_a;
      mem_exc         <= ex_exc || ex_misaligned;
      mem_cause       <= ex_exc ? ex_cause : EXC_INSN_MISALIGNED;
      mem_tval        <= ex_exc ? ex_tval  : ex_actual_target;
    end
  end

  // ===========================================================================
  // MEM - memory access, CSRs, trap decision
  // ===========================================================================
  logic [1:0]  mem_ofs;
  logic [1:0]  mem_size;
  logic        mem_misaligned;

  assign mem_ofs        = mem_result[1:0];
  assign mem_size       = mem_ctrl.funct3[1:0];
  assign mem_misaligned = (mem_size == 2'd2 && mem_ofs != 2'd0) ||
                          (mem_size == 2'd1 && mem_ofs[0]);

  logic irq_pending;
  logic [4:0] irq_code;
  logic irq_take;
  // A completed divide in MEM is never pre-empted. Otherwise an interrupt that
  // becomes pending during the ~34-cycle division (common with fast timers)
  // would flush it at MEM on every attempt and the program would livelock.
  // The interrupt is instead taken on the following instruction.
  assign irq_take = mem_valid && irq_pending && !mem_ctrl.is_div;

  // Bus strobes may only depend on state that cannot itself depend on the bus
  // response, otherwise dbus_err -> trap -> re/we would form a combinational loop.
  logic mem_bus_ok;
  assign mem_bus_ok = mem_valid && !mem_exc && !irq_take && !mem_misaligned;

  assign dbus_addr_o  = {mem_result[31:2], 2'b00};
  assign dbus_re_o    = mem_bus_ok && mem_ctrl.mem_re;
  assign dbus_we_o    = mem_bus_ok && mem_ctrl.mem_we && !dbus_err_i;
  assign dbus_wdata_o = mem_wdata << {mem_ofs, 3'b000};
  assign dbus_wstrb_o = (mem_size == 2'd0) ? (4'b0001 << mem_ofs) :
                        (mem_size == 2'd1) ? (4'b0011 << mem_ofs) : 4'b1111;

  // Load data extraction
  logic [31:0] rdata_shifted, load_value;
  assign rdata_shifted = dbus_rdata_i >> {mem_ofs, 3'b000};
  always_comb begin
    case (mem_ctrl.funct3)
      3'b000:  load_value = {{24{rdata_shifted[7]}},  rdata_shifted[7:0]};
      3'b001:  load_value = {{16{rdata_shifted[15]}}, rdata_shifted[15:0]};
      3'b100:  load_value = {24'b0, rdata_shifted[7:0]};
      3'b101:  load_value = {16'b0, rdata_shifted[15:0]};
      default: load_value = dbus_rdata_i;
    endcase
  end

  // CSR block
  logic        csr_access, csr_write, csr_illegal;
  logic [31:0] csr_rdata, trap_vector, mepc;
  logic        mret_take;

  assign csr_access = mem_valid && mem_ctrl.is_csr && !mem_exc;
  // CSRRS/CSRRC with rs1=x0 (or zimm=0) are read-only accesses
  assign csr_write  = (mem_ctrl.funct3[1:0] == 2'b01) || (mem_insn[19:15] != 5'd0);

  // Exception in MEM with priority: earlier stage > misaligned > access fault > CSR
  logic        exc_take;
  logic [4:0]  exc_cause;
  logic [31:0] exc_tval;

  always_comb begin
    exc_take  = mem_valid;
    exc_cause = mem_cause;
    exc_tval  = mem_tval;
    if (mem_exc) begin
      // keep
    end else if (mem_ctrl.mem_re && mem_misaligned) begin
      exc_cause = EXC_LOAD_MISALIGNED;   exc_tval = mem_result;
    end else if (mem_ctrl.mem_we && mem_misaligned) begin
      exc_cause = EXC_STORE_MISALIGNED;  exc_tval = mem_result;
    end else if (mem_ctrl.mem_re && dbus_err_i) begin
      exc_cause = EXC_LOAD_ACCESS;       exc_tval = mem_result;
    end else if (mem_ctrl.mem_we && dbus_err_i) begin
      exc_cause = EXC_STORE_ACCESS;      exc_tval = mem_result;
    end else if (csr_illegal) begin
      exc_cause = EXC_ILLEGAL_INSN;      exc_tval = mem_insn;
    end else begin
      exc_take  = 1'b0;
    end
  end

  assign trap_take       = irq_take || exc_take;
  assign mret_take       = mem_valid && mem_ctrl.is_mret && !trap_take;
  assign redirect_mem    = trap_take || mret_take;
  assign redirect_mem_pc = trap_take ? trap_vector : mepc;

  rv32_csr u_csr (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .addr_i        (mem_insn[31:20]),
    .funct3_i      (mem_ctrl.funct3),
    .access_i      (csr_access),
    .write_i       (csr_write),
    .operand_i     (mem_csr_operand),
    .commit_i      (!trap_take),
    .rdata_o       (csr_rdata),
    .illegal_o     (csr_illegal),
    .trap_i        (trap_take),
    .trap_is_irq_i (irq_take),
    .trap_code_i   (irq_take ? irq_code : exc_cause),
    .trap_pc_i     (mem_pc),
    .trap_tval_i   (irq_take ? 32'b0 : exc_tval),
    .mret_i        (mret_take),
    .trap_vector_o (trap_vector),
    .mepc_o        (mepc),
    .irq_soft_i    (irq_soft_i),
    .irq_timer_i   (irq_timer_i),
    .irq_ext_i     (irq_ext_i),
    .irq_pending_o (irq_pending),
    .irq_code_o    (irq_code),
    .instret_i     (mem_valid && !trap_take),
    .branch_i      (bpu_upd_valid),
    .mispredict_i  (mispredict && ex_is_cf),
    .stall_load_i  (load_use),
    .stall_div_i   (ex_stall)
  );

  assign mem_fwd_value = (mem_ctrl.wb_sel == WB_CSR) ? csr_rdata : mem_result;

  // MEM/WB register (plus commit-trace fields used by the testbench)
  // Exposed to the simulation harness so it can emit the commit trace.
  logic [31:0] wb_pc /*verilator public_flat_rd*/, wb_insn /*verilator public_flat_rd*/;
  logic        wb_mem_we /*verilator public_flat_rd*/;
  logic [31:0] wb_mem_addr /*verilator public_flat_rd*/, wb_mem_wdata /*verilator public_flat_rd*/;
  logic [1:0]  wb_mem_size /*verilator public_flat_rd*/;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wb_valid     <= 1'b0;
      wb_reg_we    <= 1'b0;
      wb_rd        <= 5'b0;
      wb_value     <= 32'b0;
      wb_pc        <= 32'b0;
      wb_insn      <= NOP;
      wb_mem_we    <= 1'b0;
      wb_mem_addr  <= 32'b0;
      wb_mem_wdata <= 32'b0;
      wb_mem_size  <= 2'b0;
    end else begin
      wb_valid     <= mem_valid && !trap_take;
      wb_reg_we    <= mem_ctrl.reg_we;
      wb_rd        <= mem_rd;
      wb_value     <= (mem_ctrl.wb_sel == WB_MEM) ? load_value :
                      (mem_ctrl.wb_sel == WB_CSR) ? csr_rdata  : mem_result;
      wb_pc        <= mem_pc;
      wb_insn      <= mem_insn;
      wb_mem_we    <= mem_ctrl.mem_we;
      wb_mem_addr  <= mem_result;
      wb_mem_wdata <= mem_wdata;
      wb_mem_size  <= mem_size;
    end
  end

  // ===========================================================================
  // WB - write back happens through the regfile write port above
  // ===========================================================================

endmodule
