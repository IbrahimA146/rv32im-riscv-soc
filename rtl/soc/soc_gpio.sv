// -----------------------------------------------------------------------------
// soc_gpio.sv - 32-bit GPIO
//
//   0x00 OUT   RW output latch
//   0x04 IN    R  synchronised pin state
//   0x08 OE    RW output enable (1 = drive)
// -----------------------------------------------------------------------------
module soc_gpio (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        sel_i,
  input  logic [7:0]  addr_i,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,

  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe_o
);

  logic [31:0] out_q, oe_q, sync1_q, sync2_q;

  always_comb begin
    case (addr_i)
      8'h00:   rdata_o = out_q;
      8'h04:   rdata_o = sync2_q;
      8'h08:   rdata_o = oe_q;
      default: rdata_o = 32'b0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_q   <= 32'b0;
      oe_q    <= 32'b0;
      sync1_q <= 32'b0;
      sync2_q <= 32'b0;
    end else begin
      sync1_q <= gpio_i;
      sync2_q <= sync1_q;
      if (sel_i && we_i) begin
        case (addr_i)
          8'h00: out_q <= wdata_i;
          8'h08: oe_q  <= wdata_i;
          default: ;
        endcase
      end
    end
  end

  assign gpio_o    = out_q;
  assign gpio_oe_o = oe_q;

endmodule
