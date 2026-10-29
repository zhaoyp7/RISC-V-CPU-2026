// Test-only wrapper selecting decoupled store source capture.
`ifndef STORE_TEST_ORDERED
`define STORE_TEST_ORDERED 1
`endif
module store_capture_lsq_top #(parameter integer W=`CPU_ISSUE_WIDTH) (
  input  logic clk,
  input  logic reset,

  // dispatch allocation
  input  logic [W-1:0]                 alloc_valid,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  alloc_id,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob,
  input  logic [W-1:0]                 alloc_is_store,
  output logic                         alloc_ready,
  input  logic                         alloc_fire,

  // issue fill
  input  logic                         fill_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    fill_id,
  input  logic [31:0]                  fill_addr,
  input  logic [31:0]                  fill_wdata,
  input  logic [3:0]                   fill_wstrb,
  input  logic                         fill_is_store,

  // store address prefill (address known before data is ready)
  input  logic                         prefill_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    prefill_id,
  input  logic [31:0]                  prefill_addr,

  // Optional source capture after an address-only store leaves the IQ.
  input logic [`CPU_PRF_IDX_W-1:0] prefill_data_tag,
  input logic [3:0] prefill_wstrb,
  input logic [`CPU_CDB_BUS_W-1:0] store_cdb,

  // commit
  input  logic [W-1:0]                 commit_valid,
  input  logic [W-1:0]                 commit_is_store,
  input  logic [W-1:0]                 commit_is_load,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  commit_id,

  // dispatch sequence: lane i is seq_base + i
  input  logic [31:0]                  seq_base,

  // squash: keep seq == squash_seq, drop seq > squash_seq
  input  logic                         squash_valid,
  input  logic [31:0]                  squash_seq,

  // store drain
  output logic                         drain_valid,
  output logic [`CPU_LSQ_IDX_W-1:0]    drain_id,
  output logic [31:0]                  drain_addr,
  output logic [31:0]                  drain_wdata,
  output logic [3:0]                   drain_wstrb,
  input  logic                         drain_fire,
  input  logic                         store_resp_valid,

  // load ordering query (speculative, before fill)
  input  logic                         query_valid,
  input  logic [31:0]                  query_seq,
  input  logic [31:0]                  query_addr,
  output logic                         query_ready,
  output logic                         query_resp_valid,
  input  logic                         query_resp_ready,
  input  logic                         query_flush,
  output logic                         query_blocked,
  output logic                         query_fwd_valid,
  output logic [31:0]                  query_fwd_data,

  output logic [7:0]                   count
);
 lsq #(.W(W), .STORE_DATA_CAPTURE(1), .ORDERED_STORE_COMMIT(`STORE_TEST_ORDERED)) dut(.*);
endmodule
