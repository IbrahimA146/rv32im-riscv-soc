// -----------------------------------------------------------------------------
// soc_uart.sv - 8N1 UART with 16-entry TX/RX FIFOs and interrupt output
//
// Register map (offsets):
//   0x00 TXDATA  W  [7:0] byte to transmit (dropped if TX FIFO full)
//   0x04 RXDATA  R  [31] 1 = FIFO empty, [7:0] received byte (read pops)
//   0x08 STATUS  R  [0] tx_full [1] tx_idle (FIFO empty and shifter idle)
//                   [2] rx_valid [3] rx_overrun (write 1 to clear)
//   0x0C CTRL    RW [0] rx interrupt enable, [1] tx-idle interrupt enable
//   0x10 BAUDDIV RW clock cycles per bit
// -----------------------------------------------------------------------------
module soc_uart #(
  parameter logic [31:0] DIV_RESET = 32'd434   // 50 MHz / 115200
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        sel_i,
  input  logic [7:0]  addr_i,
  input  logic        re_i,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,

  output logic        tx_o,
  input  logic        rx_i,
  output logic        irq_o
);

  localparam logic [7:0] REG_TXDATA  = 8'h00;
  localparam logic [7:0] REG_RXDATA  = 8'h04;
  localparam logic [7:0] REG_STATUS  = 8'h08;
  localparam logic [7:0] REG_CTRL    = 8'h0C;
  localparam logic [7:0] REG_BAUDDIV = 8'h10;

  logic [31:0] div_q;
  logic [1:0]  ctrl_q;
  logic        overrun_q;

  // ---- FIFOs ----------------------------------------------------------------
  logic       tx_push, tx_pop, tx_empty, tx_full;
  logic [7:0] tx_head;
  logic       rx_push, rx_pop, rx_empty, rx_full;
  logic [7:0] rx_head, rx_byte;

  assign tx_push = sel_i && we_i && addr_i == REG_TXDATA;
  assign rx_pop  = sel_i && re_i && addr_i == REG_RXDATA;

  soc_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_txfifo (
    .clk_i, .rst_ni, .push_i(tx_push), .data_i(wdata_i[7:0]), .pop_i(tx_pop),
    .data_o(tx_head), .empty_o(tx_empty), .full_o(tx_full)
  );

  soc_fifo #(.WIDTH(8), .DEPTH_LOG2(4)) u_rxfifo (
    .clk_i, .rst_ni, .push_i(rx_push), .data_i(rx_byte), .pop_i(rx_pop),
    .data_o(rx_head), .empty_o(rx_empty), .full_o(rx_full)
  );

  // ---- Bus interface --------------------------------------------------------
  always_comb begin
    case (addr_i)
      REG_RXDATA:  rdata_o = {rx_empty, 23'b0, rx_empty ? 8'h00 : rx_head};
      REG_STATUS:  rdata_o = {28'b0, overrun_q, ~rx_empty, tx_idle, tx_full};
      REG_CTRL:    rdata_o = {30'b0, ctrl_q};
      REG_BAUDDIV: rdata_o = div_q;
      default:     rdata_o = 32'b0;
    endcase
  end

  // ---- Transmitter ----------------------------------------------------------
  logic [9:0]  tx_shift_q;
  logic [3:0]  tx_bits_q;
  logic [31:0] tx_cnt_q;

  assign tx_pop = (tx_bits_q == 4'd0) && !tx_empty;
  assign tx_o   = tx_shift_q[0];

  logic tx_idle;
  assign tx_idle = tx_empty && (tx_bits_q == 4'd0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tx_shift_q <= 10'h3FF;
      tx_bits_q  <= 4'd0;
      tx_cnt_q   <= 32'd0;
    end else if (tx_bits_q == 4'd0) begin
      if (!tx_empty) begin
        tx_shift_q <= {1'b1, tx_head, 1'b0};   // stop, data (LSB first), start
        tx_bits_q  <= 4'd10;
        tx_cnt_q   <= div_q - 32'd1;
      end
    end else if (tx_cnt_q == 32'd0) begin
      tx_shift_q <= {1'b1, tx_shift_q[9:1]};
      tx_bits_q  <= tx_bits_q - 4'd1;
      tx_cnt_q   <= div_q - 32'd1;
    end else begin
      tx_cnt_q   <= tx_cnt_q - 32'd1;
    end
  end

  // ---- Receiver -------------------------------------------------------------
  logic [1:0]  rx_sync_q;
  logic        rx_busy_q;
  logic [3:0]  rx_bits_q;
  logic [31:0] rx_cnt_q;
  logic [7:0]  rx_shift_q;
  logic        rx_s;

  assign rx_s    = rx_sync_q[1];
  assign rx_byte = rx_shift_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_sync_q  <= 2'b11;
      rx_busy_q  <= 1'b0;
      rx_bits_q  <= 4'd0;
      rx_cnt_q   <= 32'd0;
      rx_shift_q <= 8'd0;
      rx_push    <= 1'b0;
    end else begin
      rx_sync_q <= {rx_sync_q[0], rx_i};
      rx_push   <= 1'b0;
      if (!rx_busy_q) begin
        if (!rx_s) begin                        // start bit edge
          rx_busy_q <= 1'b1;
          rx_bits_q <= 4'd0;
          rx_cnt_q  <= (div_q >> 1) - 32'd1;    // sample in the bit centre
        end
      end else if (rx_cnt_q != 32'd0) begin
        rx_cnt_q <= rx_cnt_q - 32'd1;
      end else begin
        rx_cnt_q <= div_q - 32'd1;
        if (rx_bits_q == 4'd0) begin            // centre of start bit
          if (rx_s) rx_busy_q <= 1'b0;          // glitch -> abort
          else      rx_bits_q <= 4'd1;
        end else if (rx_bits_q <= 4'd8) begin   // data bits
          rx_shift_q <= {rx_s, rx_shift_q[7:1]};
          rx_bits_q  <= rx_bits_q + 4'd1;
        end else begin                          // stop bit
          rx_busy_q <= 1'b0;
          rx_push   <= rx_s;                    // drop frames with bad stop bit
        end
      end
    end
  end

  // ---- Control registers ----------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_q     <= DIV_RESET;
      ctrl_q    <= 2'b00;
      overrun_q <= 1'b0;
    end else begin
      if (rx_push && rx_full) overrun_q <= 1'b1;
      if (sel_i && we_i) begin
        case (addr_i)
          REG_STATUS:  if (wdata_i[3]) overrun_q <= 1'b0;
          REG_CTRL:    ctrl_q <= wdata_i[1:0];
          REG_BAUDDIV: div_q  <= (wdata_i < 32'd2) ? 32'd2 : wdata_i;
          default: ;
        endcase
      end
    end
  end

  assign irq_o = (ctrl_q[0] && !rx_empty) || (ctrl_q[1] && tx_idle);

endmodule
