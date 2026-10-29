// Test-only wrapper; production source retains its generic default.
module frontend_banked_top #(parameter integer W=`CPU_ISSUE_WIDTH) (
  input  logic        clk,
  input  logic        reset,

  input  logic        backend_ready,
  input  logic [W-1:0] decode_capacity,

  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,

  input  logic        br_update_valid,
  input  logic [31:0] br_update_pc,
  input  logic        br_update_taken,
  input  logic [31:0] br_update_target,
  input  logic        br_update_is_jalr,
  input  logic        br_update_uncond,
  input  logic [`CPU_PRF_IDX_W-1:0] br_update_tag,

  output logic [W-1:0]                 dec_valid,
  output logic [W*`CPU_DECODE_W-1:0]   dec_uop,
  output logic [W-1:0]                 dec_pred_taken,
  output logic [W*32-1:0]              dec_pred_target,
  input  logic                         rename_ready,

  output logic [31:0]                 pc_out,

  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata,

  output logic        refill_valid1,
  output logic [31:0] refill_addr1,
  input  logic        refill_resp_valid1,
  input  logic [31:0] refill_rdata1
);
  frontend_ooo #(.W(`CPU_ISSUE_WIDTH), .WORD_BANKING(1)) dut (.*);
endmodule
