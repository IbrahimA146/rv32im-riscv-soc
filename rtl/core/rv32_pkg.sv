// -----------------------------------------------------------------------------
// rv32_pkg.sv - shared constants and types for the RV32IM pipeline
// -----------------------------------------------------------------------------
package rv32_pkg;

  // ---------------------------------------------------------------------------
  // Base opcodes (insn[6:0])
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPC_LUI     = 7'b0110111;
  localparam logic [6:0] OPC_AUIPC   = 7'b0010111;
  localparam logic [6:0] OPC_JAL     = 7'b1101111;
  localparam logic [6:0] OPC_JALR    = 7'b1100111;
  localparam logic [6:0] OPC_BRANCH  = 7'b1100011;
  localparam logic [6:0] OPC_LOAD    = 7'b0000011;
  localparam logic [6:0] OPC_STORE   = 7'b0100011;
  localparam logic [6:0] OPC_OP_IMM  = 7'b0010011;
  localparam logic [6:0] OPC_OP      = 7'b0110011;
  localparam logic [6:0] OPC_MISCMEM = 7'b0001111;
  localparam logic [6:0] OPC_SYSTEM  = 7'b1110011;

  localparam logic [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0

  // ---------------------------------------------------------------------------
  // ALU operations
  // ---------------------------------------------------------------------------
  localparam logic [3:0] ALU_ADD  = 4'd0;
  localparam logic [3:0] ALU_SUB  = 4'd1;
  localparam logic [3:0] ALU_SLL  = 4'd2;
  localparam logic [3:0] ALU_SLT  = 4'd3;
  localparam logic [3:0] ALU_SLTU = 4'd4;
  localparam logic [3:0] ALU_XOR  = 4'd5;
  localparam logic [3:0] ALU_SRL  = 4'd6;
  localparam logic [3:0] ALU_SRA  = 4'd7;
  localparam logic [3:0] ALU_OR   = 4'd8;
  localparam logic [3:0] ALU_AND  = 4'd9;

  // Operand A select
  localparam logic [1:0] SEL_A_RS1  = 2'd0;
  localparam logic [1:0] SEL_A_PC   = 2'd1;
  localparam logic [1:0] SEL_A_ZERO = 2'd2;

  // Write-back select
  localparam logic [1:0] WB_ALU = 2'd0;   // ALU / M-extension / pc+4 (pre-muxed in EX)
  localparam logic [1:0] WB_MEM = 2'd1;   // load data
  localparam logic [1:0] WB_CSR = 2'd2;   // CSR read value

  // ---------------------------------------------------------------------------
  // Decoded control word, carried down the pipeline
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        reg_we;
    logic        mem_re;
    logic        mem_we;
    logic [2:0]  funct3;
    logic [3:0]  alu_op;
    logic [1:0]  sel_a;
    logic        sel_b_imm;
    logic [1:0]  wb_sel;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_mul;      // MUL/MULH/MULHSU/MULHU  (single-cycle)
    logic        is_div;      // DIV/DIVU/REM/REMU      (iterative, stalls EX)
    logic        is_csr;
    logic        csr_imm;     // CSRRxI: operand is zimm instead of rs1
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        illegal;
    logic        uses_rs1;
    logic        uses_rs2;
  } ctrl_t;

  // ---------------------------------------------------------------------------
  // Exception causes (mcause, interrupt bit clear)
  // ---------------------------------------------------------------------------
  localparam logic [4:0] EXC_INSN_MISALIGNED  = 5'd0;
  localparam logic [4:0] EXC_INSN_ACCESS      = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL_INSN     = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT       = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGNED  = 5'd4;
  localparam logic [4:0] EXC_LOAD_ACCESS      = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGNED = 5'd6;
  localparam logic [4:0] EXC_STORE_ACCESS     = 5'd7;
  localparam logic [4:0] EXC_ECALL_M          = 5'd11;

  // Interrupt codes (mcause with interrupt bit set)
  localparam logic [4:0] IRQ_M_SOFT  = 5'd3;
  localparam logic [4:0] IRQ_M_TIMER = 5'd7;
  localparam logic [4:0] IRQ_M_EXT   = 5'd11;

  // ---------------------------------------------------------------------------
  // CSR addresses
  // ---------------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MISA      = 12'h301;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
  localparam logic [11:0] CSR_MHPMCNT3  = 12'hB03;  // resolved branches/jumps
  localparam logic [11:0] CSR_MHPMCNT4  = 12'hB04;  // branch mispredictions
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MIMPLID   = 12'hF13;
  localparam logic [11:0] CSR_MHARTID   = 12'hF14;

endpackage
