// -----------------------------------------------------------------------------
// rv32_mul.sv - single-cycle 33x33 signed multiplier covering MUL/MULH/MULHSU/MULHU
//
// Both operands are extended to 33 bits (sign- or zero-extended per funct3) so a
// single signed multiplier serves all four variants. On FPGA this maps onto DSP
// blocks; the upper half is only required for the MULH* variants.
// -----------------------------------------------------------------------------
module rv32_mul (
  input  logic [2:0]  funct3_i,   // 000 mul, 001 mulh, 010 mulhsu, 011 mulhu
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] y_o
);

  logic               a_signed, b_signed;
  logic signed [32:0] a_ext, b_ext;
  logic signed [65:0] prod;

  assign a_signed = (funct3_i == 3'b001) || (funct3_i == 3'b010);
  assign b_signed = (funct3_i == 3'b001);

  assign a_ext = {a_signed & a_i[31], a_i};
  assign b_ext = {b_signed & b_i[31], b_i};

  // Both operands are signed 33-bit, so the 66-bit context sign-extends them.
  // (Wrapping this in $unsigned() would make the product self-determined
  // and silently truncate it to 33 bits.)
  assign prod = a_ext * b_ext;

  assign y_o = (funct3_i == 3'b000) ? prod[31:0] : prod[63:32];

endmodule
