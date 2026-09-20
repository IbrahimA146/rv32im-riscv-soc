// -----------------------------------------------------------------------------
// rv32_decoder.sv - RV32IM + Zicsr instruction decoder (purely combinational)
// -----------------------------------------------------------------------------
module rv32_decoder
  import rv32_pkg::*;
(
  input  logic [31:0] insn_i,
  output ctrl_t       ctrl_o,
  output logic [31:0] imm_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rd, rs1;

  assign opcode = insn_i[6:0];
  assign funct3 = insn_i[14:12];
  assign funct7 = insn_i[31:25];
  assign rd     = insn_i[11:7];
  assign rs1    = insn_i[19:15];

  // Immediate formats
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  assign imm_i = {{20{insn_i[31]}}, insn_i[31:20]};
  assign imm_s = {{20{insn_i[31]}}, insn_i[31:25], insn_i[11:7]};
  assign imm_b = {{19{insn_i[31]}}, insn_i[31], insn_i[7], insn_i[30:25], insn_i[11:8], 1'b0};
  assign imm_u = {insn_i[31:12], 12'b0};
  assign imm_j = {{11{insn_i[31]}}, insn_i[31], insn_i[19:12], insn_i[20], insn_i[30:21], 1'b0};

  always_comb begin
    ctrl_o           = '0;
    ctrl_o.funct3    = funct3;
    ctrl_o.alu_op    = ALU_ADD;
    ctrl_o.sel_a     = SEL_A_RS1;
    ctrl_o.wb_sel    = WB_ALU;
    imm_o            = 32'b0;

    case (opcode)
      OPC_LUI: begin
        ctrl_o.reg_we    = 1'b1;
        ctrl_o.sel_a     = SEL_A_ZERO;
        ctrl_o.sel_b_imm = 1'b1;
        imm_o            = imm_u;
      end

      OPC_AUIPC: begin
        ctrl_o.reg_we    = 1'b1;
        ctrl_o.sel_a     = SEL_A_PC;
        ctrl_o.sel_b_imm = 1'b1;
        imm_o            = imm_u;
      end

      OPC_JAL: begin
        ctrl_o.reg_we = 1'b1;
        ctrl_o.is_jal = 1'b1;
        imm_o         = imm_j;
      end

      OPC_JALR: begin
        ctrl_o.reg_we   = 1'b1;
        ctrl_o.is_jalr  = 1'b1;
        ctrl_o.uses_rs1 = 1'b1;
        ctrl_o.illegal  = (funct3 != 3'b000);
        imm_o           = imm_i;
      end

      OPC_BRANCH: begin
        ctrl_o.is_branch = 1'b1;
        ctrl_o.uses_rs1  = 1'b1;
        ctrl_o.uses_rs2  = 1'b1;
        ctrl_o.illegal   = (funct3 == 3'b010) || (funct3 == 3'b011);
        imm_o            = imm_b;
      end

      OPC_LOAD: begin
        ctrl_o.reg_we    = 1'b1;
        ctrl_o.mem_re    = 1'b1;
        ctrl_o.uses_rs1  = 1'b1;
        ctrl_o.sel_b_imm = 1'b1;
        ctrl_o.wb_sel    = WB_MEM;
        // valid: lb lh lw lbu lhu
        ctrl_o.illegal   = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
        imm_o            = imm_i;
      end

      OPC_STORE: begin
        ctrl_o.mem_we    = 1'b1;
        ctrl_o.uses_rs1  = 1'b1;
        ctrl_o.uses_rs2  = 1'b1;
        ctrl_o.sel_b_imm = 1'b1;
        ctrl_o.illegal   = (funct3[2] == 1'b1) || (funct3 == 3'b011);
        imm_o            = imm_s;
      end

      OPC_OP_IMM: begin
        ctrl_o.reg_we    = 1'b1;
        ctrl_o.uses_rs1  = 1'b1;
        ctrl_o.sel_b_imm = 1'b1;
        imm_o            = imm_i;
        case (funct3)
          3'b000: ctrl_o.alu_op = ALU_ADD;
          3'b010: ctrl_o.alu_op = ALU_SLT;
          3'b011: ctrl_o.alu_op = ALU_SLTU;
          3'b100: ctrl_o.alu_op = ALU_XOR;
          3'b110: ctrl_o.alu_op = ALU_OR;
          3'b111: ctrl_o.alu_op = ALU_AND;
          3'b001: begin
            ctrl_o.alu_op  = ALU_SLL;
            ctrl_o.illegal = (funct7 != 7'b0000000);
          end
          3'b101: begin
            ctrl_o.alu_op  = funct7[5] ? ALU_SRA : ALU_SRL;
            ctrl_o.illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
          end
        endcase
      end

      OPC_OP: begin
        ctrl_o.reg_we   = 1'b1;
        ctrl_o.uses_rs1 = 1'b1;
        ctrl_o.uses_rs2 = 1'b1;
        if (funct7 == 7'b0000001) begin
          ctrl_o.is_mul = ~funct3[2];
          ctrl_o.is_div =  funct3[2];
        end else if (funct7 == 7'b0000000) begin
          case (funct3)
            3'b000: ctrl_o.alu_op = ALU_ADD;
            3'b001: ctrl_o.alu_op = ALU_SLL;
            3'b010: ctrl_o.alu_op = ALU_SLT;
            3'b011: ctrl_o.alu_op = ALU_SLTU;
            3'b100: ctrl_o.alu_op = ALU_XOR;
            3'b101: ctrl_o.alu_op = ALU_SRL;
            3'b110: ctrl_o.alu_op = ALU_OR;
            3'b111: ctrl_o.alu_op = ALU_AND;
          endcase
        end else if (funct7 == 7'b0100000 && funct3 == 3'b000) begin
          ctrl_o.alu_op = ALU_SUB;
        end else if (funct7 == 7'b0100000 && funct3 == 3'b101) begin
          ctrl_o.alu_op = ALU_SRA;
        end else begin
          ctrl_o.illegal = 1'b1;
        end
      end

      OPC_MISCMEM: begin
        // FENCE / FENCE.I: no-ops on this core (no caches, fused memory)
        ctrl_o.illegal = (funct3 != 3'b000) && (funct3 != 3'b001);
      end

      OPC_SYSTEM: begin
        if (funct3 == 3'b000) begin
          case (insn_i[31:7])
            25'h0000000:                ctrl_o.is_ecall  = 1'b1;  // ecall
            25'h0002000:                ctrl_o.is_ebreak = 1'b1;  // ebreak
            {12'h302, 13'h0}:           ctrl_o.is_mret   = 1'b1;  // mret
            {12'h105, 13'h0}:           ;                         // wfi -> nop
            default:                    ctrl_o.illegal   = 1'b1;
          endcase
        end else if (funct3 == 3'b100) begin
          ctrl_o.illegal = 1'b1;
        end else begin
          ctrl_o.is_csr   = 1'b1;
          ctrl_o.reg_we   = 1'b1;
          ctrl_o.wb_sel   = WB_CSR;
          ctrl_o.csr_imm  = funct3[2];
          ctrl_o.uses_rs1 = ~funct3[2];
          imm_o           = {27'b0, rs1};  // zimm
        end
      end

      default: ctrl_o.illegal = 1'b1;
    endcase

    // An illegal instruction must have no architectural side effects.
    if (ctrl_o.illegal) begin
      ctrl_o.reg_we    = 1'b0;
      ctrl_o.mem_re    = 1'b0;
      ctrl_o.mem_we    = 1'b0;
      ctrl_o.is_branch = 1'b0;
      ctrl_o.is_jal    = 1'b0;
      ctrl_o.is_jalr   = 1'b0;
      ctrl_o.is_mul    = 1'b0;
      ctrl_o.is_div    = 1'b0;
      ctrl_o.is_csr    = 1'b0;
    end

    // Writes to x0 are discarded; clearing reg_we avoids needless forwarding.
    if (rd == 5'd0) ctrl_o.reg_we = 1'b0;
  end

endmodule
