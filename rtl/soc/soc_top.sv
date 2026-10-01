// -----------------------------------------------------------------------------
// soc_top.sv - RV32IM microcontroller SoC
//
// Memory map
//   0x0000_0000  RAM      64 KiB  code + data + stack
//   0x0200_0000  CLINT            msip / mtimecmp / mtime
//   0x1000_0000  UART             8N1, FIFOs, IRQ -> MEIP
//   0x2000_0000  GPIO             32 bits
//   0x3000_0000  SYSCON           0x0 EXIT (write: halt with exit code)
//   0x4000_0000  VIDEO pixels     WIDTH*HEIGHT bytes, 8-bit colour index
//   0x4001_0000  VIDEO palette    256 x 0x00RRGGBB
//   0x4002_0000  VIDEO control    PRESENT / FRAME / MODE
//   0x5000_0000  KEYS             event queue, IRQ -> MEIP
//
// Unmapped addresses return a bus error -> precise access-fault exception.
// -----------------------------------------------------------------------------
module soc_top #(
  parameter int          RAM_WORDS    = 16384,     // 64 KiB; DOOM builds raise this
  parameter int          VID_WIDTH    = 320,
  parameter int          VID_HEIGHT   = 200,
  parameter logic [31:0] UART_DIV     = 32'd434,
  parameter int          TIMER_DIV    = 1,
  parameter int          BTB_IDX_BITS = 6
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  output logic        uart_tx_o,
  input  logic        uart_rx_i,

  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe_o,

  // decoded key events (a board would decode PS/2 or USB in front of this)
  input  logic        key_valid_i,
  input  logic [8:0]  key_event_i,

  // pulses when firmware presents a finished frame
  output logic        frame_strobe_o,
  output logic [31:0] frame_count_o,

  output logic        halt_o,
  output logic [31:0] exit_code_o
);

  // ---------------------------------------------------------------------------
  // CPU
  // ---------------------------------------------------------------------------
  logic [31:0] ibus_addr, ibus_rdata;
  logic        ibus_err;
  logic [31:0] dbus_addr, dbus_wdata, dbus_rdata;
  logic        dbus_re, dbus_we, dbus_err;
  logic [3:0]  dbus_wstrb;
  logic        irq_soft, irq_timer, irq_uart, irq_keys;

  rv32_core #(
    .RESET_PC     (32'h0000_0000),
    .BTB_IDX_BITS (BTB_IDX_BITS)
  ) u_core (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .ibus_addr_o  (ibus_addr),
    .ibus_rdata_i (ibus_rdata),
    .ibus_err_i   (ibus_err),
    .dbus_addr_o  (dbus_addr),
    .dbus_re_o    (dbus_re),
    .dbus_we_o    (dbus_we),
    .dbus_wstrb_o (dbus_wstrb),
    .dbus_wdata_o (dbus_wdata),
    .dbus_rdata_i (dbus_rdata),
    .dbus_err_i   (dbus_err),
    .irq_soft_i   (irq_soft),
    .irq_timer_i  (irq_timer),
    .irq_ext_i    (irq_uart | irq_keys)
  );

  // ---------------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------------
  localparam logic [31:0] RAM_BYTES = RAM_WORDS * 4;

  logic sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys;
  logic sel_vpix, sel_vpal, sel_vctl, sel_keys;

  assign sel_ram   = (dbus_addr <  RAM_BYTES);
  assign sel_clint = (dbus_addr[31:16] == 16'h0200);
  assign sel_uart  = (dbus_addr[31:12] == 20'h10000);
  assign sel_gpio  = (dbus_addr[31:12] == 20'h20000);
  assign sel_sys   = (dbus_addr[31:12] == 20'h30000);
  assign sel_vpix  = (dbus_addr[31:16] == 16'h4000);
  assign sel_vpal  = (dbus_addr[31:16] == 16'h4001);
  assign sel_vctl  = (dbus_addr[31:16] == 16'h4002);
  assign sel_keys  = (dbus_addr[31:12] == 20'h50000);

  assign dbus_err  = !(sel_ram || sel_clint || sel_uart || sel_gpio || sel_sys ||
                       sel_vpix || sel_vpal || sel_vctl || sel_keys);
  assign ibus_err  = (ibus_addr >= RAM_BYTES);

  // ---------------------------------------------------------------------------
  // Slaves
  // ---------------------------------------------------------------------------
  logic [31:0] ram_rdata, clint_rdata, uart_rdata, gpio_rdata, vid_rdata, keys_rdata;

  soc_ram #(.WORDS(RAM_WORDS)) u_ram (
    .clk_i    (clk_i),
    .iaddr_i  (ibus_addr),
    .irdata_o (ibus_rdata),
    .daddr_i  (dbus_addr),
    .dwe_i    (dbus_we && sel_ram),
    .dwstrb_i (dbus_wstrb),
    .dwdata_i (dbus_wdata),
    .drdata_o (ram_rdata)
  );

  soc_clint #(.TICK_DIV(TIMER_DIV)) u_clint (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .sel_i       (sel_clint),
    .addr_i      (dbus_addr[15:0]),
    .we_i        (dbus_we),
    .wdata_i     (dbus_wdata),
    .rdata_o     (clint_rdata),
    .irq_timer_o (irq_timer),
    .irq_soft_o  (irq_soft)
  );

  soc_uart #(.DIV_RESET(UART_DIV)) u_uart (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .sel_i   (sel_uart),
    .addr_i  (dbus_addr[7:0]),
    .re_i    (dbus_re),
    .we_i    (dbus_we),
    .wdata_i (dbus_wdata),
    .rdata_o (uart_rdata),
    .tx_o    (uart_tx_o),
    .rx_i    (uart_rx_i),
    .irq_o   (irq_uart)
  );

  soc_gpio u_gpio (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .sel_i     (sel_gpio),
    .addr_i    (dbus_addr[7:0]),
    .we_i      (dbus_we),
    .wdata_i   (dbus_wdata),
    .rdata_o   (gpio_rdata),
    .gpio_i    (gpio_i),
    .gpio_o    (gpio_o),
    .gpio_oe_o (gpio_oe_o)
  );

  soc_video #(
    .WIDTH  (VID_WIDTH),
    .HEIGHT (VID_HEIGHT)
  ) u_video (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .sel_pix_i      (sel_vpix),
    .sel_pal_i      (sel_vpal),
    .sel_ctl_i      (sel_vctl),
    .addr_i         (dbus_addr),
    .we_i           (dbus_we),
    .wstrb_i        (dbus_wstrb),
    .wdata_i        (dbus_wdata),
    .rdata_o        (vid_rdata),
    .frame_strobe_o (frame_strobe_o),
    .frame_count_o  (frame_count_o)
  );

  soc_keys u_keys (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .sel_i       (sel_keys),
    .addr_i      (dbus_addr),
    .re_i        (dbus_re),
    .we_i        (dbus_we),
    .wdata_i     (dbus_wdata),
    .rdata_o     (keys_rdata),
    .key_valid_i (key_valid_i),
    .key_event_i (key_event_i),
    .irq_o       (irq_keys)
  );

  // SYSCON: simulation / board control
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      halt_o      <= 1'b0;
      exit_code_o <= 32'b0;
    end else if (sel_sys && dbus_we && dbus_addr[11:0] == 12'h000) begin
      halt_o      <= 1'b1;
      exit_code_o <= dbus_wdata;
    end
  end

  // Read mux
  always_comb begin
    dbus_rdata = 32'b0;
    if      (sel_ram)   dbus_rdata = ram_rdata;
    else if (sel_clint) dbus_rdata = clint_rdata;
    else if (sel_uart)  dbus_rdata = uart_rdata;
    else if (sel_gpio)  dbus_rdata = gpio_rdata;
    else if (sel_keys)  dbus_rdata = keys_rdata;
    else if (sel_vpix || sel_vpal || sel_vctl) dbus_rdata = vid_rdata;
  end

endmodule
