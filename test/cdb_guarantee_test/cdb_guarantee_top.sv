module cdb_guarantee_top #(parameter integer W=2,R=`CPU_CDB_NUM) (
  input  logic clk,
  input  logic reset,

  input  logic [W+1:0]                   src_valid,
  input  logic [(W+2)*`CPU_PRF_IDX_W-1:0] src_tag,
  input  logic [(W+2)*32-1:0]            src_value,
  input  logic [W+1:0]                   src_exception,
  output logic [W+1:0]                   src_ready,

  output logic [W+1:0] hint_ready_mask,
  output logic [R*`CPU_CDB_W-1:0]        cdb_out
);
 cdb #(.W(W),.R(R),.PRIORITY_ALU0(`GUARANTEE_TEST_PRIORITY),.HINT_OPTIONAL_SOURCE(2)) dut(.*);
endmodule
