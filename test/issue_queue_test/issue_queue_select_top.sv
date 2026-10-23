// Test-only parameter wrapper; not part of the core filelist.
module issue_queue_select_top (
  input  logic clk,
  input  logic reset,

  // dispatch
  input  logic [`CPU_ISSUE_WIDTH-1:0]                       in_valid,
  input  logic [`CPU_ISSUE_WIDTH-1:0]                       in_alloc_mask,
  input  logic [`CPU_ISSUE_WIDTH*`CPU_DISPATCH_W-1:0]       in_uop,
  output logic                               in_ready,

  // CDB wake (R lanes)
  input  logic [`CPU_CDB_NUM-1:0]            wake_valid,
  input  logic [`CPU_CDB_NUM*`CPU_PRF_IDX_W-1:0] wake_tag,

  // dispatch sequence: lane i is seq_base + i
  input  logic [31:0]                        seq_base,

  // squash: keep seq == squash_seq, drop seq > squash_seq
  input  logic                               squash_valid,
  input  logic [31:0]                        squash_seq,

  // issue
  output logic [`IQ_TEST_IW-1:0]                      out_valid,
  output logic [`IQ_TEST_IW-1:0]                      out_addr_only,
  output logic [`IQ_TEST_IW*`CPU_DISPATCH_W-1:0]      out_uop,
  output logic [`IQ_TEST_IW*32-1:0]                   out_seq,
  input  logic [`IQ_TEST_IW-1:0]                      out_ready,

  // status
  output logic [7:0]                         count,
  output logic [7:0]                         free_count
);
  issue_queue #(.IW(`IQ_TEST_IW)) dut (.*);
endmodule
