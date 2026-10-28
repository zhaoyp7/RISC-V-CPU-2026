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
  input  logic lookahead_valid,
  input  logic [`CPU_PRF_IDX_W-1:0] lookahead_tag,

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

  output logic [`CPU_DISPATCH_W-1:0] memory_uop,
  output logic [31:0] memory_seq,
  output logic memory_addr_only,

  // status
  output logic [7:0]                         count,
  output logic [7:0]                         free_count
);
`ifndef IQ_TEST_ALU_ONLY
`define IQ_TEST_ALU_ONLY 0
`endif
`ifndef IQ_TEST_LOOKAHEAD
`define IQ_TEST_LOOKAHEAD 0
`endif
`ifndef IQ_TEST_LOAD_HINT
`define IQ_TEST_LOAD_HINT 0
`endif
`ifndef IQ_TEST_CONTROL_HINT
`define IQ_TEST_CONTROL_HINT 0
`endif
`ifndef IQ_TEST_RETIRE_PREFILL
`define IQ_TEST_RETIRE_PREFILL 0
`endif
`ifndef IQ_TEST_SPECIAL_PRIORITY
`define IQ_TEST_SPECIAL_PRIORITY 0
`endif
`ifndef IQ_TEST_REUSE_ISSUED
`define IQ_TEST_REUSE_ISSUED 0
`endif
`ifndef IQ_TEST_ALU0_HINT
`define IQ_TEST_ALU0_HINT 0
`endif
`ifndef IQ_TEST_MEMORY_HINT
`define IQ_TEST_MEMORY_HINT 0
`endif
  logic unused_registered_alu_ready;
  issue_queue #(.IW(`IQ_TEST_IW), .LANE1_ALU_ONLY(`IQ_TEST_ALU_ONLY),
                .LANE1_LOOKAHEAD(`IQ_TEST_LOOKAHEAD),
                .LANE0_CONTROL_LOOKAHEAD(`IQ_TEST_CONTROL_HINT),
                .LANE0_SPECIAL_PRIORITY(`IQ_TEST_SPECIAL_PRIORITY),
                .REUSE_ISSUED_SLOTS(`IQ_TEST_REUSE_ISSUED),
                .LANE0_ALU_LOOKAHEAD(`IQ_TEST_ALU0_HINT),
`ifdef IQ_TEST_MEMORY_HINT
                .LANE0_MEMORY_LOOKAHEAD(`IQ_TEST_MEMORY_HINT),
`endif
                .RETIRE_STORE_PREFILL(`IQ_TEST_RETIRE_PREFILL)) dut (
    .lookahead_valid(`IQ_TEST_LOAD_HINT ? 1'b0 : lookahead_valid),
    .lookahead_tag(lookahead_tag),
    .registered_alu_ready(unused_registered_alu_ready),
    .lookahead_load_valid(`IQ_TEST_LOAD_HINT ? lookahead_valid : 1'b0),
    .lookahead_load_tag(lookahead_tag), .*);
endmodule
