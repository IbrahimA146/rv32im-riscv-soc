// -----------------------------------------------------------------------------
// rv32_bpu.sv - branch prediction unit: direct-mapped BTB + 2-bit bimodal counters
//
// Lookup (IF, combinational):  pc -> {taken, target}
//   * BTB hit on an unconditional jump (JAL/JALR)  -> predict taken
//   * BTB hit on a conditional branch               -> counter MSB decides
//   * miss                                           -> predict pc+4
//
// Update (EX, registered): every resolved branch/jump trains the table.
// Entries are only allocated for control-flow instructions that were actually
// taken, so never-taken branches do not evict useful entries.
// -----------------------------------------------------------------------------
module rv32_bpu #(
  parameter int IDX_BITS = 6          // 2^IDX_BITS entries
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Prediction
  input  logic [31:0] pc_i,
  output logic        pred_taken_o,
  output logic [31:0] pred_target_o,

  // Training
  input  logic        upd_valid_i,
  input  logic [31:0] upd_pc_i,
  input  logic        upd_taken_i,
  input  logic        upd_uncond_i,
  input  logic [31:0] upd_target_i
);

  localparam int N        = 1 << IDX_BITS;
  localparam int TAG_BITS = 30 - IDX_BITS;

  logic                valid_q  [N];
  logic                uncond_q [N];
  logic [1:0]          ctr_q    [N];
  logic [TAG_BITS-1:0] tag_q    [N];
  logic [31:0]         target_q [N];

  // ---- lookup ---------------------------------------------------------------
  logic [IDX_BITS-1:0] idx;
  logic [TAG_BITS-1:0] tag;
  logic                hit;

  assign idx = pc_i[IDX_BITS+1:2];
  assign tag = pc_i[31:IDX_BITS+2];
  assign hit = valid_q[idx] && (tag_q[idx] == tag);

  assign pred_taken_o  = hit && (uncond_q[idx] || ctr_q[idx][1]);
  assign pred_target_o = target_q[idx];

  // ---- update ---------------------------------------------------------------
  logic [IDX_BITS-1:0] uidx;
  logic [TAG_BITS-1:0] utag;
  logic                uhit;
  logic [1:0]          uctr;

  assign uidx = upd_pc_i[IDX_BITS+1:2];
  assign utag = upd_pc_i[31:IDX_BITS+2];
  assign uhit = valid_q[uidx] && (tag_q[uidx] == utag);
  assign uctr = ctr_q[uidx];

  integer i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (i = 0; i < N; i = i + 1) begin
        valid_q[i]  <= 1'b0;
        uncond_q[i] <= 1'b0;
        ctr_q[i]    <= 2'b01;
        tag_q[i]    <= '0;
        target_q[i] <= '0;
      end
    end else if (upd_valid_i) begin
      if (upd_taken_i) begin
        valid_q[uidx]  <= 1'b1;
        uncond_q[uidx] <= upd_uncond_i;
        tag_q[uidx]    <= utag;
        target_q[uidx] <= upd_target_i;
        // New entries start weakly-taken; existing ones saturate upwards.
        ctr_q[uidx]    <= !uhit          ? 2'b10 :
                          (uctr == 2'b11) ? 2'b11 : uctr + 2'b01;
      end else if (uhit) begin
        ctr_q[uidx]    <= (uctr == 2'b00) ? 2'b00 : uctr - 2'b01;
      end
    end
  end

endmodule
