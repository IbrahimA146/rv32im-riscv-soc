// -----------------------------------------------------------------------------
// soc_top.sv - RV32IM microcontroller SoC
//
// Memory map
//   0x0000_0000  RAM      64 KiB  code + data + stack
//   0x0200_0000  CLINT            msip / mtimecmp / mtime
//   0x1000_0000  UART             8N1, FIFOs, IRQ -> MEIP
//   0x2000_0000  GPIO             32 bits
//   0x3000_0000  SYSCON           0x0 EXIT (write: halt with exit code)
//
// Unmapped addresses return a bus error -> precise access-fault exception.
// -----------------------------------------------------------------------------
module soc_top #(
  parameter int          RAM_WORDS    = 16384,
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
  logic        irq_soft, irq_timer, irq_uart;

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
    .irq_ext_i    (irq_uart)
  );

  // ---------------------------------------------------------------------------
  // Address decode
  // ---------------------------------------------------------------------------
  localparam logic [31:0] RAM_BYTES = RAM_WORDS * 4;

  logic sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys;

  assign sel_ram   = (dbus_addr <  RAM_BYTES);
  assign sel_clint = (dbus_addr[31:16] == 16'h0200);
  assign sel_uart  = (dbus_addr[31:12] == 20'h10000);
  assign sel_gpio  = (dbus_addr[31:12] == 20'h20000);
  assign sel_sys   = (dbus_addr[31:12] == 20'h30000);

  assign dbus_err  = !(sel_ram || sel_clint || sel_uart || sel_gpio || sel_sys);
  assign ibus_err  = (ibus_addr >= RAM_BYTES);

  // ---------------------------------------------------------------------------
  // Slaves
  // ---------------------------------------------------------------------------
  logic [31:0] ram_rdata, clint_rdata, uart_rdata, gpio_rdata;

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
  end

endmodule
