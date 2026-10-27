// Test-only wrapper; production source retains its generic default.
module icache_banked_top (
  input  logic        clk,
  input  logic        reset,
  input  logic        flush,          // 重定向/冲刷，单拍有效，最高优先级
  input  logic        discard,        // 只清年轻项，不压制当前 resp

  // 前端取指请求
  input  logic        fetch_valid,
  input  logic [31:0] fetch_pc,
  output logic        fetch_ready,

  // 前端取指响应
  output logic        fetch_resp_valid,
  output logic [31:0] fetch_resp_pc,
  output logic [31:0] fetch_inst,
  input  logic        fetch_resp_ready,

  // 回填请求（占用 mem_subsystem 的 if_refill 客户口）
  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata
);
  icache_pipe #(.INDEX_BITS(`ICACHE_BANK_TEST_BITS), .BANKED_WORD(1)) dut (.*);
endmodule
