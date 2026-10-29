// Candidate-only input monitors; injected outside the production filelist.
`ifdef LOCAL_READ_CACHE_STATS
module perf_read_cache_stats (
  input logic clk, reset, load_issue, load_miss, dc_hit, r_illegal, ld_fwd,
  input logic request_valid, request_ready, md_resp_keep,
  input logic read_fill, drain_allocate, write_cache
);
  longint cycles, executions, hits, misses, forwarded, illegal;
  longint read_fills, store_fills, fill_port_conflicts, response_no_fill, request_stall;
  always_ff @(posedge clk) begin
    if(reset)begin
      cycles<=0;executions<=0;hits<=0;misses<=0;forwarded<=0;illegal<=0;
      read_fills<=0;store_fills<=0;fill_port_conflicts<=0;response_no_fill<=0;request_stall<=0;
    end else begin
      cycles<=cycles+1;
      if(load_issue)begin
        executions<=executions+1;
        if(r_illegal)illegal<=illegal+1;
        else if(ld_fwd)forwarded<=forwarded+1;
        else if(dc_hit)hits<=hits+1;
        else misses<=misses+1;
      end
      if(load_miss != (request_valid && request_ready))$fatal(1,"cache miss handshake mismatch");
      if(write_cache && !drain_allocate)read_fills<=read_fills+1;
      if(drain_allocate)store_fills<=store_fills+1;
      if(read_fill && drain_allocate)fill_port_conflicts<=fill_port_conflicts+1;
      if(md_resp_keep && !read_fill)response_no_fill<=response_no_fill+1;
      if(request_valid && !request_ready)request_stall<=request_stall+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] READ_CACHE cycles=%0d executions=%0d hits=%0d misses=%0d forwarded=%0d illegal=%0d read_fills=%0d store_fills=%0d fill_port_conflicts=%0d response_no_fill=%0d request_stall=%0d",cycles,executions,hits,misses,forwarded,illegal,read_fills,store_fills,fill_port_conflicts,response_no_fill,request_stall);
endmodule
bind lsu perf_read_cache_stats perf_read_cache_monitor (
  .clk(clk),.reset(reset),.load_issue(load_issue),.load_miss(load_miss),.dc_hit(dc_hit),
  .r_illegal(r_illegal),.ld_fwd(ld_fwd),.request_valid(ld_req_valid),.request_ready(ld_req_ready),
  .md_resp_keep(md_resp_keep),.read_fill(gen_read_cache.read_fill),
  .drain_allocate(gen_read_cache.drain_allocate),.write_cache(gen_read_cache.write_cache)
);
`endif
