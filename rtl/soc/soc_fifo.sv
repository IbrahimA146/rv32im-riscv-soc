// -----------------------------------------------------------------------------
// soc_fifo.sv - synchronous first-word-fall-through FIFO
// -----------------------------------------------------------------------------
module soc_fifo #(
  parameter int WIDTH      = 8,
  parameter int DEPTH_LOG2 = 4
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             push_i,
  input  logic [WIDTH-1:0] data_i,
  input  logic             pop_i,
  output logic [WIDTH-1:0] data_o,
  output logic             empty_o,
  output logic             full_o
);

  localparam int DEPTH = 1 << DEPTH_LOG2;

  logic [WIDTH-1:0]    buf_q [DEPTH];
  logic [DEPTH_LOG2:0] count_q;
  logic [DEPTH_LOG2-1:0] rd_q, wr_q;

  assign empty_o = (count_q == 0);
  assign full_o  = (count_q == DEPTH[DEPTH_LOG2:0]);
  assign data_o  = buf_q[rd_q];

  logic do_push, do_pop;
  assign do_push = push_i && !full_o;
  assign do_pop  = pop_i  && !empty_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_q <= '0;
      rd_q    <= '0;
      wr_q    <= '0;
    end else begin
      if (do_push) begin
        buf_q[wr_q] <= data_i;
        wr_q        <= wr_q + 1'b1;
      end
      if (do_pop) rd_q <= rd_q + 1'b1;
      case ({do_push, do_pop})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: ;
      endcase
    end
  end

endmodule
