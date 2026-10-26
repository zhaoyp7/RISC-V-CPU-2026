// Candidate-specific passive probe, injected only by an experiment wrapper.
`ifdef LOCAL_RESPONSE_BYPASS_STATS
module perf_response_bypass #(parameter CW=4, parameter BYPASS_ENABLED=1) (
  input logic clk, reset, md_resp_fire, md_resp_keep,
  input logic response_bypass_valid, response_bypass_fire,
  input logic [CW-1:0] rq_count,
  input logic load_result_valid, load_result_ready, rq_pop
);
  longint cycles, responses, kept, direct, buffered, busy_fifo, busy_cdb;
  longint writebacks, queued_writebacks, discarded_queue;
  longint forced_queue;
  always_ff @(posedge clk) begin
    if(reset)begin
      cycles<=0;responses<=0;kept<=0;direct<=0;buffered<=0;busy_fifo<=0;busy_cdb<=0;
      writebacks<=0;queued_writebacks<=0;discarded_queue<=0;
      forced_queue<=0;
    end else begin
      cycles<=cycles+1;
      if(md_resp_fire)responses<=responses+1;
      if(md_resp_keep)begin
        kept<=kept+1;
        if(response_bypass_fire)direct<=direct+1;
        else begin
          buffered<=buffered+1;
          if(rq_count!=0)busy_fifo<=busy_fifo+1;
          else if(!load_result_ready)busy_cdb<=busy_cdb+1;
          else if(!BYPASS_ENABLED)forced_queue<=forced_queue+1;
          else $fatal(1,"buffered load response has no blocking reason");
        end
      end
      if(response_bypass_fire && (!response_bypass_valid || !load_result_valid || !load_result_ready))
        $fatal(1,"direct load writeback missing external handshake");
      if(load_result_valid && load_result_ready)begin
        writebacks<=writebacks+1;
        if(!response_bypass_fire)queued_writebacks<=queued_writebacks+1;
      end
      if(rq_pop && !load_result_valid)discarded_queue<=discarded_queue+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LOAD_BYPASS cycles=%0d responses=%0d kept=%0d direct=%0d buffered=%0d busy_fifo=%0d busy_cdb=%0d forced_queue=%0d writebacks=%0d queued_writebacks=%0d discarded_queue=%0d",cycles,responses,kept,direct,buffered,busy_fifo,busy_cdb,forced_queue,writebacks,queued_writebacks,discarded_queue);
endmodule
bind lsu perf_response_bypass #(.CW(MDW+1),.BYPASS_ENABLED(1)) perf_response_bypass_monitor (
  .clk(clk),.reset(reset),.md_resp_fire(md_resp_fire),.md_resp_keep(md_resp_keep),
  .response_bypass_valid(response_bypass_valid),.response_bypass_fire(response_bypass_fire),
  .rq_count(rq_count),.load_result_valid(load_result_valid),.load_result_ready(load_result_ready),.rq_pop(rq_pop)
);
`endif
