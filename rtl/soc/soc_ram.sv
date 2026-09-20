// -----------------------------------------------------------------------------
// soc_ram.sv - word-addressed memory with one read-only instruction port and
// one read/write data port (maps to distributed RAM / LUTRAM on FPGA).
// -----------------------------------------------------------------------------
module soc_ram #(
  parameter int WORDS = 16384      // 64 KiB
) (
  input  logic        clk_i,

  input  logic [31:0] iaddr_i,
  output logic [31:0] irdata_o,

  input  logic [31:0] daddr_i,
  input  logic        dwe_i,
  input  logic [3:0]  dwstrb_i,
  input  logic [31:0] dwdata_i,
  output logic [31:0] drdata_o
);

  localparam int AW = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  integer i;
  initial for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'b0;

  logic [AW-1:0] iidx, didx;
  assign iidx = iaddr_i[AW+1:2];
  assign didx = daddr_i[AW+1:2];

  assign irdata_o = mem[iidx];
  assign drdata_o = mem[didx];

  always_ff @(posedge clk_i) begin
    if (dwe_i) begin
      if (dwstrb_i[0]) mem[didx][7:0]   <= dwdata_i[7:0];
      if (dwstrb_i[1]) mem[didx][15:8]  <= dwdata_i[15:8];
      if (dwstrb_i[2]) mem[didx][23:16] <= dwdata_i[23:16];
      if (dwstrb_i[3]) mem[didx][31:24] <= dwdata_i[31:24];
    end
  end

endmodule
