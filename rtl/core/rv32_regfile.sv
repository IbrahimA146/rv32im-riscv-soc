// -----------------------------------------------------------------------------
// rv32_regfile.sv - 31 general purpose registers (x0 hardwired to zero)
//
// Asynchronous read with write-through bypass, so an instruction in ID sees
// the value being committed by WB in the same cycle. This removes the need for
// a third (WB->ID) forwarding path in the pipeline.
// -----------------------------------------------------------------------------
module rv32_regfile (
  input  logic        clk_i,
  input  logic        we_i,
  input  logic [4:0]  waddr_i,
  input  logic [31:0] wdata_i,
  input  logic [4:0]  raddr1_i,
  input  logic [4:0]  raddr2_i,
  output logic [31:0] rdata1_o,
  output logic [31:0] rdata2_o
);

  logic [31:0] regs [1:31];

  integer i;
  initial for (i = 1; i < 32; i = i + 1) regs[i] = 32'b0;

  always_ff @(posedge clk_i) begin
    if (we_i && waddr_i != 5'd0) regs[waddr_i] <= wdata_i;
  end

  assign rdata1_o = (raddr1_i == 5'd0)                  ? 32'b0   :
                    (we_i && waddr_i == raddr1_i)        ? wdata_i : regs[raddr1_i];
  assign rdata2_o = (raddr2_i == 5'd0)                  ? 32'b0   :
                    (we_i && waddr_i == raddr2_i)        ? wdata_i : regs[raddr2_i];

endmodule
