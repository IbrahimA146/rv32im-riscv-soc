// -----------------------------------------------------------------------------
// tb_soc.sv - system-level testbench
//
// Plusargs
//   +hex=<file>        memory image (one 32-bit little-endian word per line)
//   +trace=<file>      write commit trace (pc, insn, rd write, memory write)
//   +uart_in=<a,b,c>   commands typed into the UART, one per "> " prompt
//   +timeout=<cycles>  abort after N cycles (default 20M)
//   +vcd               dump waves to build/wave.vcd
//   +quiet             do not echo UART output
//
// The UART line is decoded bit-by-bit from the serial pin exactly as a real
// USB-UART bridge would, so firmware output proves the full TX path works.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_soc;

  localparam int UART_DIV = 8;            // fast baud for simulation
  localparam logic [31:0] EXIT_ADDR = 32'h3000_0000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #10 clk = ~clk;                  // 50 MHz

  logic        uart_tx, uart_rx;
  logic [31:0] gpio_out, gpio_oe;
  logic        halt;
  logic [31:0] exit_code;

  soc_top #(
    .UART_DIV  (UART_DIV),
    .TIMER_DIV (1)
  ) dut (
    .clk_i       (clk),
    .rst_ni      (rst_n),
    .uart_tx_o   (uart_tx),
    .uart_rx_i   (uart_rx),
    .gpio_i      (32'hA5A5_0000),
    .gpio_o      (gpio_out),
    .gpio_oe_o   (gpio_oe),
    .halt_o      (halt),
    .exit_code_o (exit_code)
  );

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------
  reg [8*256-1:0] hexfile, tracefile;
  reg [8*512-1:0] uart_in;
  integer         timeout, trace_fd, cycles;
  bit             quiet, tracing;

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("ERROR: +hex=<file> required");
      $finish;
    end
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 20_000_000;
    if (!$value$plusargs("uart_in=%s", uart_in)) uart_in = '0;
    quiet   = $test$plusargs("quiet");
    tracing = $value$plusargs("trace=%s", tracefile);
    if (tracing) trace_fd = $fopen(tracefile, "w");
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/wave.vcd");
      $dumpvars(0, tb_soc);
    end

    $readmemh(hexfile, dut.u_ram.mem);

    uart_rx = 1'b1;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // UART receiver model (decodes the DUT's TX pin)
  // ---------------------------------------------------------------------------
  reg [7:0] prev_char;
  integer   prompt_count = 0;
  event     prompt_seen;

  initial begin : uart_monitor
    reg [7:0] c;
    integer   b;
    prev_char = 8'h00;
    forever begin
      @(negedge uart_tx);
      repeat (UART_DIV / 2) @(posedge clk);          // centre of start bit
      for (b = 0; b < 8; b = b + 1) begin
        repeat (UART_DIV) @(posedge clk);
        c[b] = uart_tx;
      end
      repeat (UART_DIV) @(posedge clk);              // stop bit
      if (!quiet && c != 8'h0D) $write("%c", c);
      if (prev_char == ">" && c == " ") -> prompt_seen;
      prev_char = c;
    end
  end

  // ---------------------------------------------------------------------------
  // UART transmitter model: types one comma-separated command per prompt
  // ---------------------------------------------------------------------------
  task automatic uart_send(input [7:0] c);
    integer b;
    uart_rx = 1'b0;
    repeat (UART_DIV) @(posedge clk);
    for (b = 0; b < 8; b = b + 1) begin
      uart_rx = c[b];
      repeat (UART_DIV) @(posedge clk);
    end
    uart_rx = 1'b1;
    repeat (2 * UART_DIV) @(posedge clk);
  endtask

  initial begin : uart_driver
    integer pos;
    reg [7:0] ch;
    pos = 511;
    while (pos >= 0 && uart_in[pos*8 +: 8] == 8'h00) pos = pos - 1;
    while (pos >= 0) begin
      @(prompt_seen);
      repeat (50 * UART_DIV) @(posedge clk);
      ch = uart_in[pos*8 +: 8];
      while (pos >= 0 && ch != ",") begin
        uart_send(ch);
        pos = pos - 1;
        if (pos >= 0) ch = uart_in[pos*8 +: 8];
      end
      uart_send(8'h0D);
      pos = pos - 1;                                 // skip the comma
    end
  end

  // ---------------------------------------------------------------------------
  // Commit monitor: trace, exit detection, statistics
  // ---------------------------------------------------------------------------
  function automatic [31:0] size_mask(input [1:0] sz);
    size_mask = (sz == 2'd0) ? 32'h0000_00FF : (sz == 2'd1) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
  endfunction

  integer instret = 0;

  initial cycles = 0;
  always @(posedge clk) if (rst_n) begin
    cycles = cycles + 1;

    if (dut.u_core.wb_valid) begin
      instret = instret + 1;
      if (tracing) begin
        if (dut.u_core.wb_mem_we)
          $fdisplay(trace_fd, "%08x %08x mem %08x %08x", dut.u_core.wb_pc, dut.u_core.wb_insn,
                    dut.u_core.wb_mem_addr,
                    dut.u_core.wb_mem_wdata & size_mask(dut.u_core.wb_mem_size));
        else if (dut.u_core.wb_reg_we)
          $fdisplay(trace_fd, "%08x %08x x%0d %08x", dut.u_core.wb_pc, dut.u_core.wb_insn,
                    dut.u_core.wb_rd, dut.u_core.wb_value);
        else
          $fdisplay(trace_fd, "%08x %08x", dut.u_core.wb_pc, dut.u_core.wb_insn);
      end
    end

    // Finish once the exit store has been committed (and traced)
    if (dut.u_core.wb_valid && dut.u_core.wb_mem_we && dut.u_core.wb_mem_addr == EXIT_ADDR)
      finish_sim(dut.u_core.wb_mem_wdata);

    if (cycles >= timeout) begin
      $display("\n*** TIMEOUT after %0d cycles (pc=%08x) ***", cycles, dut.u_core.pc_q);
      if (tracing) $fclose(trace_fd);
      $finish;
    end
  end

  task automatic finish_sim(input [31:0] code);
    integer branches, mispredicts;
    branches    = dut.u_core.u_csr.hpm3_q;
    mispredicts = dut.u_core.u_csr.hpm4_q;
    if (tracing) $fclose(trace_fd);
    $display("");
    $display("---------------------------------------------------------------");
    $display(" cycles        : %0d", cycles);
    $display(" instructions  : %0d", instret);
    $display(" CPI           : %0d.%03d", cycles / instret, ((cycles % instret) * 1000) / instret);
    if (branches > 0)
      $display(" branch pred.  : %0d/%0d correct (%0d.%01d%%)", branches - mispredicts, branches,
               ((branches - mispredicts) * 100) / branches,
               (((branches - mispredicts) * 1000) / branches) % 10);
    $display("---------------------------------------------------------------");
    if (code == 0) $display("*** PASS ***");
    else           $display("*** FAIL (exit code %0d) ***", code);
    $finish;
  endtask

endmodule
