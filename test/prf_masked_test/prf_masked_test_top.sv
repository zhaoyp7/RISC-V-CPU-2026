module prf_masked_test_top (
 input logic clk,reset,
 input logic [2*`CPU_ISSUE_WIDTH*`CPU_PRF_IDX_W-1:0] raddr,
 input logic [2*`CPU_ISSUE_WIDTH*`CPU_PRF_SIZE-1:0] rselect,
 output logic [2*`CPU_ISSUE_WIDTH*32-1:0] rdata,
 input logic [`CPU_CDB_NUM-1:0] we,
 input logic [`CPU_CDB_NUM*`CPU_PRF_IDX_W-1:0] waddr,
 input logic [`CPU_CDB_NUM*32-1:0] wdata
);
 prf #(.W(`CPU_ISSUE_WIDTH),.R(`CPU_CDB_NUM),
       .PREDECODED_READS({(2*`CPU_ISSUE_WIDTH){1'b1}})) dut(.*);
endmodule
