// -----------------------------------------------------------------------------
// rv32_div.sv - iterative restoring divider for DIV/DIVU/REM/REMU
//
// * 32 iterations for the general case, so the critical path is one 33-bit
//   subtractor instead of a 32-level combinational array.
// * Divide-by-zero and signed overflow (INT_MIN / -1) are resolved in a single
//   cycle with the results mandated by the RISC-V spec (no traps).
// * `abort_i` cancels an in-flight division when the pipeline is flushed.
//
// Handshake: hold `start_i` high; `done_o` pulses for exactly one cycle with
// `result_o` valid, after which the divider returns to IDLE.
// -----------------------------------------------------------------------------
module rv32_div (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  logic        abort_i,
  input  logic [2:0]  funct3_i,  // 100 div, 101 divu, 110 rem, 111 remu
  input  logic [31:0] a_i,       // dividend
  input  logic [31:0] b_i,       // divisor
  output logic        done_o,
  output logic [31:0] result_o
);

  typedef enum logic [1:0] {S_IDLE, S_BUSY, S_DONE} state_e;

  state_e      state_q;
  logic [5:0]  count_q;
  logic [31:0] quo_q, rem_q, dvsr_q, result_q;
  logic        want_rem_q, neg_quo_q, neg_rem_q;

  // Operand analysis for the start cycle
  logic        is_signed, want_rem, a_neg, b_neg;
  logic [31:0] a_abs, b_abs;

  assign is_signed = ~funct3_i[0];
  assign want_rem  =  funct3_i[1];
  assign a_neg     = is_signed & a_i[31];
  assign b_neg     = is_signed & b_i[31];
  assign a_abs     = a_neg ? (~a_i + 32'd1) : a_i;
  assign b_abs     = b_neg ? (~b_i + 32'd1) : b_i;

  logic div_by_zero, overflow;
  assign div_by_zero = (b_i == 32'd0);
  assign overflow    = is_signed && (a_i == 32'h8000_0000) && (b_i == 32'hFFFF_FFFF);

  // One restoring step
  logic [32:0] rem_shift;
  logic [33:0] trial;
  assign rem_shift = {rem_q, quo_q[31]};
  assign trial     = {1'b0, rem_shift} - {2'b0, dvsr_q};

  // Quotient/remainder as they will be after the final iteration
  logic [31:0] last_rem, last_quo;
  assign last_rem = trial[33] ? rem_shift[31:0] : trial[31:0];
  assign last_quo = {quo_q[30:0], ~trial[33]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= S_IDLE;
      count_q    <= '0;
      quo_q      <= '0;
      rem_q      <= '0;
      dvsr_q     <= '0;
      result_q   <= '0;
      want_rem_q <= 1'b0;
      neg_quo_q  <= 1'b0;
      neg_rem_q  <= 1'b0;
    end else if (abort_i) begin
      state_q <= S_IDLE;
    end else begin
      case (state_q)
        S_IDLE: if (start_i) begin
          if (div_by_zero) begin
            result_q <= want_rem ? a_i : 32'hFFFF_FFFF;
            state_q  <= S_DONE;
          end else if (overflow) begin
            result_q <= want_rem ? 32'd0 : a_i;
            state_q  <= S_DONE;
          end else begin
            quo_q      <= a_abs;
            rem_q      <= 32'd0;
            dvsr_q     <= b_abs;
            count_q    <= 6'd32;
            want_rem_q <= want_rem;
            neg_quo_q  <= a_neg ^ b_neg;
            neg_rem_q  <= a_neg;
            state_q    <= S_BUSY;
          end
        end

        S_BUSY: begin
          if (!trial[33]) begin
            rem_q <= trial[31:0];
            quo_q <= {quo_q[30:0], 1'b1};
          end else begin
            rem_q <= rem_shift[31:0];
            quo_q <= {quo_q[30:0], 1'b0};
          end
          count_q <= count_q - 6'd1;
          if (count_q == 6'd1) state_q <= S_DONE;
        end

        S_DONE: state_q <= S_IDLE;

        default: state_q <= S_IDLE;
      endcase

      // Sign fix-up happens once, on the transition into DONE.
      if (state_q == S_BUSY && count_q == 6'd1) begin
        if (want_rem_q) result_q <= neg_rem_q ? (~last_rem + 32'd1) : last_rem;
        else            result_q <= neg_quo_q ? (~last_quo + 32'd1) : last_quo;
      end
    end
  end

  assign done_o   = (state_q == S_DONE);
  assign result_o = result_q;

endmodule
