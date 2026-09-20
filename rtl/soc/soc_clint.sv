// -----------------------------------------------------------------------------
// soc_clint.sv - core-local interruptor (SiFive-compatible register layout)
//
//   0x0000 msip       [0] software interrupt pending
//   0x4000 mtimecmp   low
//   0x4004 mtimecmp   high
//   0xBFF8 mtime      low
//   0xBFFC mtime      high
//
// mtime advances once every TICK_DIV clock cycles.
// -----------------------------------------------------------------------------
module soc_clint #(
  parameter int TICK_DIV = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        sel_i,
  input  logic [15:0] addr_i,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,

  output logic        irq_timer_o,
  output logic        irq_soft_o
);

  logic        msip_q;
  logic [63:0] mtime_q, mtimecmp_q;
  logic [31:0] prescale_q;

  always_comb begin
    case (addr_i)
      16'h0000: rdata_o = {31'b0, msip_q};
      16'h4000: rdata_o = mtimecmp_q[31:0];
      16'h4004: rdata_o = mtimecmp_q[63:32];
      16'hBFF8: rdata_o = mtime_q[31:0];
      16'hBFFC: rdata_o = mtime_q[63:32];
      default:  rdata_o = 32'b0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      msip_q     <= 1'b0;
      mtime_q    <= 64'b0;
      mtimecmp_q <= {64{1'b1}};
      prescale_q <= 32'b0;
    end else begin
      if (prescale_q == TICK_DIV - 1) begin
        prescale_q <= 32'b0;
        mtime_q    <= mtime_q + 64'd1;
      end else begin
        prescale_q <= prescale_q + 32'd1;
      end

      if (sel_i && we_i) begin
        case (addr_i)
          16'h0000: msip_q             <= wdata_i[0];
          16'h4000: mtimecmp_q[31:0]   <= wdata_i;
          16'h4004: mtimecmp_q[63:32]  <= wdata_i;
          16'hBFF8: mtime_q[31:0]      <= wdata_i;
          16'hBFFC: mtime_q[63:32]     <= wdata_i;
          default: ;
        endcase
      end
    end
  end

  assign irq_timer_o = (mtime_q >= mtimecmp_q);
  assign irq_soft_o  = msip_q;

endmodule
