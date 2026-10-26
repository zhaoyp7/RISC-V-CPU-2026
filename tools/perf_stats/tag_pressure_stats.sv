// Input-only probe for physical-tag admission pressure; not in the filelist.
`ifdef LOCAL_TAG_PRESSURE_STATS
module perf_tag_pressure #(parameter CW=7, parameter NW=2)(
  input logic clk, reset, recover_valid, out_ready, in_ready,
  input logic [CW-1:0] free_count,
  input logic [NW-1:0] n_valid
);
  longint cycles, accepted, tag_wait, zero_stall, one_stall, free_one;
  always_ff @(posedge clk)begin
    if(reset)begin
      cycles<=0;accepted<=0;tag_wait<=0;zero_stall<=0;one_stall<=0;free_one<=0;
    end else begin
      cycles<=cycles+1;
      if(in_ready && n_valid!=0)accepted<=accepted+1;
      if(free_count==1)free_one<=free_one+1;
      if(!recover_valid && out_ready && n_valid!=0 && !in_ready)begin
        tag_wait<=tag_wait+1;
        if(free_count==0)zero_stall<=zero_stall+1;
        else if(free_count==1 && n_valid>1)one_stall<=one_stall+1;
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] TAG_PRESSURE cycles=%0d accepted=%0d tag_wait=%0d zero_stall=%0d one_stall=%0d free_one=%0d",cycles,accepted,tag_wait,zero_stall,one_stall,free_one);
endmodule
bind rename perf_tag_pressure #(.CW(FCW),.NW($clog2(W+1))) perf_tag_pressure_monitor(
  .clk(clk),.reset(reset),.recover_valid(recover_valid),.out_ready(out_ready),
  .in_ready(in_ready),.free_count(free_count),.n_valid(n_valid)
);
`endif
