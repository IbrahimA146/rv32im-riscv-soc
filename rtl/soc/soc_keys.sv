// -----------------------------------------------------------------------------
// soc_keys.sv - keyboard event queue
//
// Takes already-decoded key events (a real board would put a PS/2 or USB
// decoder in front of this) and queues them for the CPU, raising an interrupt
// while the queue is not empty.
//
//   0x00 DATA    R  [31] 1 = queue empty, [8] 1 = pressed / 0 = released,
//                   [7:0] key code. Reading pops the event.
//   0x04 STATUS  R  [0] event available, [1] queue full, [2] events dropped (W1C)
//   0x08 CTRL    RW [0] interrupt enable
// -----------------------------------------------------------------------------
module soc_keys (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        sel_i,
  input  logic [31:0] addr_i,
  input  logic        re_i,
  input  logic        we_i,
  input  logic [31:0] wdata_i,
  output logic [31:0] rdata_o,

  // event input: one pulse per key transition
  input  logic        key_valid_i,
  input  logic [8:0]  key_event_i,   // {pressed, code[7:0]}

  output logic        irq_o
);

  logic       ctrl_irq_en_q, dropped_q;
  logic       empty, full, pop;
  logic [8:0] head;

  assign pop = sel_i && re_i && (addr_i[11:0] == 12'h000);

  soc_fifo #(.WIDTH(9), .DEPTH_LOG2(4)) u_fifo (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .push_i  (key_valid_i),
    .data_i  (key_event_i),
    .pop_i   (pop),
    .data_o  (head),
    .empty_o (empty),
    .full_o  (full)
  );

  always_comb begin
    case (addr_i[11:0])
      12'h000: rdata_o = {empty, 22'b0, empty ? 9'b0 : head};
      12'h004: rdata_o = {29'b0, dropped_q, full, ~empty};
      12'h008: rdata_o = {31'b0, ctrl_irq_en_q};
      default: rdata_o = 32'b0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ctrl_irq_en_q <= 1'b0;
      dropped_q     <= 1'b0;
    end else begin
      if (key_valid_i && full) dropped_q <= 1'b1;
      if (sel_i && we_i) begin
        case (addr_i[11:0])
          12'h004: if (wdata_i[2]) dropped_q <= 1'b0;
          12'h008: ctrl_irq_en_q <= wdata_i[0];
          default: ;
        endcase
      end
    end
  end

  assign irq_o = ctrl_irq_en_q && !empty;

endmodule
