// Test-only wrapper selecting decoupled store source capture.
module store_capture_backend_top #(parameter integer W=`CPU_ISSUE_WIDTH) (
  input  logic clk,
  input  logic reset,

  // core_ooo 冻结接口
  input  logic [`CPU_DISPATCH_BUS_W-1:0] dispatch,
  input  logic [`CPU_COMMIT_BUS_W-1:0]   commit,
  input  logic [`CPU_SQUASH_W-1:0]       squash,
  output logic [`CPU_CDB_BUS_W-1:0]      cdb,
  output logic [`CPU_COMPLETE_BUS_W-1:0] complete,
  output logic [`CPU_BR_UPDATE_W-1:0]    br_update,
  output logic                           backend_ready,

  // pipelined load interface (to mem_subsystem)
  output logic        ld_req_valid,
  output logic [31:0] ld_req_addr,
  input  logic        ld_req_ready,
  input  logic        ld_resp_valid,
  input  logic [31:0] ld_resp_rdata,

  // store invalidation for the read-only D-Cache
  output logic        st_inv_valid,
  output logic [31:0] st_inv_addr,

  // pipelined store interface (to mem_subsystem)
  output logic        st_req_valid,
  output logic [31:0] st_req_addr,
  output logic [31:0] st_req_wdata,
  output logic [3:0]  st_req_wstrb,
  input  logic        st_req_ready,
  input  logic        st_resp_valid
);
 backend_ooo #(.W(W), .STORE_DATA_CAPTURE(1), .ORDERED_STORE_COMMIT(1)) dut(.*);
endmodule
