// -----------------------------------------------------------------------------
// soc_video.sv - framebuffer with an indexed colour palette
//
// A classic VGA-style display controller: the CPU writes 8-bit colour indices
// into pixel memory, and a 256-entry palette turns each index into 24-bit RGB.
// Indexed colour costs a quarter of the memory and bandwidth of a 32-bit
// framebuffer, which is what DOOM (and VGA mode 13h) was built around.
//
// Three address windows, decoded by the interconnect:
//   PIX  WIDTH*HEIGHT bytes, one colour index per pixel, row-major
//   PAL  256 words, 0x00RRGGBB (reset: grayscale ramp)
//   CTL  0x00 PRESENT  W  frame is complete -> pulse frame_strobe_o
//        0x04 FRAME    R  frames presented so far
//        0x08 MODE     R  {height[15:0], width[15:0]}
//
// Pixel memory accepts byte, half and word writes so firmware can plot single
// pixels or blit whole words.
// -----------------------------------------------------------------------------
module soc_video #(
  parameter int WIDTH  = 320,
  parameter int HEIGHT = 200
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        sel_pix_i,
  input  logic        sel_pal_i,
  input  logic        sel_ctl_i,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [3:0]  wstrb_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,

  output logic        frame_strobe_o,
  output logic [31:0] frame_count_o
);

  localparam int PIX_BYTES = WIDTH * HEIGHT;
  // Round up to a power of two so every address in the window is backed by
  // storage (no undefined reads above the last visible pixel).
  localparam int PIX_AW    = $clog2((PIX_BYTES + 3) / 4);
  localparam int PIX_WORDS = 1 << PIX_AW;

  logic [31:0] pix [PIX_WORDS];
  logic [23:0] pal [256];

  localparam logic [15:0] W16 = WIDTH[15:0];
  localparam logic [15:0] H16 = HEIGHT[15:0];

  logic [PIX_AW-1:0] pix_idx;
  logic [7:0]        pal_idx;

  assign pix_idx = addr_i[PIX_AW+1:2];
  assign pal_idx = addr_i[9:2];

  integer i;
  initial begin
    for (i = 0; i < PIX_WORDS; i = i + 1) pix[i] = 32'b0;
  end

  // ---- pixel memory ---------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (sel_pix_i && we_i) begin
      if (wstrb_i[0]) pix[pix_idx][7:0]   <= wdata_i[7:0];
      if (wstrb_i[1]) pix[pix_idx][15:8]  <= wdata_i[15:8];
      if (wstrb_i[2]) pix[pix_idx][23:16] <= wdata_i[23:16];
      if (wstrb_i[3]) pix[pix_idx][31:24] <= wdata_i[31:24];
    end
  end

  // ---- palette and control --------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // grayscale ramp: index i -> 0xiiiiii
      for (i = 0; i < 256; i = i + 1) pal[i] <= 24'(i) * 24'h01_01_01;
      frame_count_o  <= 32'b0;
      frame_strobe_o <= 1'b0;
    end else begin
      frame_strobe_o <= 1'b0;
      if (sel_pal_i && we_i) pal[pal_idx] <= wdata_i[23:0];
      if (sel_ctl_i && we_i && addr_i[11:0] == 12'h000) begin
        frame_strobe_o <= 1'b1;
        frame_count_o  <= frame_count_o + 32'd1;
      end
    end
  end

  // ---- read mux -------------------------------------------------------------
  always_comb begin
    rdata_o = 32'b0;
    if (sel_pix_i) begin
      rdata_o = pix[pix_idx];
    end else if (sel_pal_i) begin
      rdata_o = {8'b0, pal[pal_idx]};
    end else if (sel_ctl_i) begin
      case (addr_i[11:0])
        12'h004: rdata_o = frame_count_o;
        12'h008: rdata_o = {H16, W16};
        default: rdata_o = 32'b0;
      endcase
    end
  end

endmodule
