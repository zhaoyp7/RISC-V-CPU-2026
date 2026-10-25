// Passive trace of baseline memory demand; never part of the production RTL.
`ifdef LOCAL_DATA_ACCESS_TRACE
module perf_data_access_trace #(parameter MD=8, MW=3) (
  input logic clk, reset, load_request, load_response, response_keep,
  input logic [31:0] request_addr, request_seq,
  input logic [MD*32-1:0] response_sequences,
  input logic [MW-1:0] response_head,
  input logic store_issue, store_drain,
  input logic [31:0] store_addr, drain_addr, drain_data, response_data,
  input logic [3:0] drain_mask
);
  longint cycles;
  always_ff @(posedge clk) begin
    if(reset)cycles<=0;
    else begin
      // The analyzer groups events by cycle; invalidations precede lookups,
      // while fills become visible only to the next cycle's lookup.
      if(store_issue)$fdisplay(32'h80000002,"[DTRACE] cycle=%0d kind=S addr=%08x",cycles,store_addr);
      if(store_drain)$fdisplay(32'h80000002,"[DTRACE] cycle=%0d kind=D addr=%08x mask=%0d data=%08x",cycles,drain_addr,drain_mask,drain_data);
      if(load_request)$fdisplay(32'h80000002,"[DTRACE] cycle=%0d kind=L seq=%0d addr=%08x",cycles,request_seq,request_addr);
      if(load_response)$fdisplay(32'h80000002,"[DTRACE] cycle=%0d kind=R seq=%0d keep=%0d data=%08x",cycles,response_sequences[response_head*32+:32],response_keep,response_data);
      cycles<=cycles+1;
    end
  end
endmodule
bind lsu perf_data_access_trace #(.MD(LDQ_DEPTH),.MW(MDW)) perf_data_access_trace_monitor (
  .clk(clk),.reset(reset),.load_request(ld_req_valid && ld_req_ready),
  .load_response(md_resp_fire),.response_keep(md_resp_keep),
  .request_addr(ld_req_addr),.request_seq(r_seq),.response_sequences(md_seq),.response_head(md_head),
  .store_issue(st_inv_valid),.store_drain(drain_fire),.store_addr(st_inv_addr),.drain_addr(drain_addr),
  .drain_data(drain_wdata),.drain_mask(drain_wstrb),.response_data(ld_resp_rdata)
);
`endif
