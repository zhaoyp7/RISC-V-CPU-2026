module recovery_count_top(input logic [`CPU_PRF_SIZE-1:0] mask,output logic [7:0] count);
rename dut(.clk(1'b0),.reset(1'b0),.recover_valid(1'b0),.recover_free_mask(mask));
assign count=8'(dut.recover_count);
endmodule
