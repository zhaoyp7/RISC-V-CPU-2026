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
  input  logic        st_resp_valid,
  output logic [31:0] early_base_events,
  output logic[31:0]future0_events,future1_events
);
`ifndef EXECUTION_HINT_TEST
`define EXECUTION_HINT_TEST 0
`endif
 backend_ooo #(.W(W), .EXECUTION_LOOKAHEAD(`EXECUTION_HINT_TEST), .MEMORY_BASE_LOOKAHEAD(1), .STORE_DATA_CAPTURE(1), .ORDERED_STORE_COMMIT(1),.DISPATCH_ALU_BYPASS(1),.DISPATCH_CONTROL_BYPASS(1)) dut(.*);
 always_ff@(posedge clk)begin
  if(reset)begin future0_events<=0;future1_events<=0;end
  else if(dut.iq_out_valid[1]&&dut.issue_ready[1])begin
   if(dut.execute_hint_valid &&
      ((!dut.u_iq.src1_ready[dut.u_iq.sel_idx[1]]&&dut.j_src1_tag==dut.a0_dest)||
       (!dut.u_iq.src2_ready[dut.u_iq.sel_idx[1]]&&dut.j_src2_tag==dut.a0_dest)))future0_events<=future0_events+1;
   if(dut.execute1_hint_valid &&
      ((!dut.u_iq.src1_ready[dut.u_iq.sel_idx[1]]&&dut.j_src1_tag==dut.p_dest)||
       (!dut.u_iq.src2_ready[dut.u_iq.sel_idx[1]]&&dut.j_src2_tag==dut.p_dest)))future1_events<=future1_events+1;
  end
 end
 always_ff@(posedge clk)begin
  if(reset)early_base_events<=0;
  else if(dut.iq_out_valid[0] && dut.issue_ready[0] && dut.i_is_mem && dut.early_memory_base &&
          !dut.u_iq.src1_ready[dut.u_iq.sel_idx[0]])early_base_events<=early_base_events+1;
 end
endmodule
