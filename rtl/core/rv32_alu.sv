// -----------------------------------------------------------------------------
// rv32_alu.sv - arithmetic/logic unit
// -----------------------------------------------------------------------------
module rv32_alu
  import rv32_pkg::*;
(
  input  logic [3:0]  op_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] y_o
);

  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  always_comb begin
    case (op_i)
      ALU_ADD:  y_o = a_i + b_i;
      ALU_SUB:  y_o = a_i - b_i;
      ALU_SLL:  y_o = a_i << shamt;
      ALU_SLT:  y_o = {31'b0, $signed(a_i) < $signed(b_i)};
      ALU_SLTU: y_o = {31'b0, a_i < b_i};
      ALU_XOR:  y_o = a_i ^ b_i;
      ALU_SRL:  y_o = a_i >> shamt;
      ALU_SRA:  y_o = $unsigned($signed(a_i) >>> shamt);
      ALU_OR:   y_o = a_i | b_i;
      ALU_AND:  y_o = a_i & b_i;
      default:  y_o = 32'b0;
    endcase
  end

endmodule
