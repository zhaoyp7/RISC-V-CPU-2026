// Simulation-only observations of cache requests, replay-free merge and credits.
`ifdef LOCAL_STATS
module perf_line_cache (
 input wire clk,reset,accept,hit_read,arriving_word,lookup_hit,match_valid,allocate,
 input wire req_valid,req_ready,bank_available,row_busy,free_valid,
 input wire resp_valid,send_fire,return_valid,store_fire,st_hit,store_write,
 input wire [1:0] m_valid,
 input wire [3:0] q_count,flight_count,
 input wire [7:0] q_done,
 input wire [2:0] q_head
);
 longint cycles,requests,hits,arriving,merged,misses,responses,external_reads,returns;
 longint stall_queue,stall_bank,stall_set,stall_mshr,stall_other;
 longint head_wait,reorder_hold,queue_sum,one_fill,two_fills,store_hits,store_misses,store_updates;
 always_ff @(posedge clk)begin
  if(reset)begin
   cycles<=0;requests<=0;hits<=0;arriving<=0;merged<=0;misses<=0;responses<=0;
   external_reads<=0;returns<=0;stall_queue<=0;stall_bank<=0;stall_set<=0;
   stall_mshr<=0;stall_other<=0;head_wait<=0;reorder_hold<=0;queue_sum<=0;
   one_fill<=0;two_fills<=0;store_hits<=0;store_misses<=0;store_updates<=0;
  end else begin
   cycles<=cycles+1;queue_sum<=queue_sum+q_count;
   requests<=requests+accept;hits<=hits+hit_read;arriving<=arriving+(accept&&arriving_word);
   merged<=merged+(accept&&!lookup_hit&&!arriving_word&&match_valid);
   misses<=misses+allocate;responses<=responses+resp_valid;
   external_reads<=external_reads+send_fire;returns<=returns+return_valid;
   if(req_valid&&!req_ready)begin
    if(q_count==8)stall_queue<=stall_queue+1;
    else if(lookup_hit&&!bank_available)stall_bank<=stall_bank+1;
    else if(!lookup_hit&&!match_valid&&row_busy)stall_set<=stall_set+1;
    else if(!lookup_hit&&!match_valid&&!free_valid)stall_mshr<=stall_mshr+1;
    else stall_other<=stall_other+1;
   end
   if(q_count!=0&&!resp_valid)head_wait<=head_wait+1;
   if(q_count!=0&&!resp_valid&&(|q_done))reorder_hold<=reorder_hold+1;
   if(m_valid==1||m_valid==2)one_fill<=one_fill+1;
   if(m_valid==3)two_fills<=two_fills+1;
   store_hits<=store_hits+(store_fire&&st_hit);store_misses<=store_misses+(store_fire&&!st_hit);
   store_updates<=store_updates+store_write;
  end
 end
 final $fdisplay(32'h80000002,"[STATS] LINE_CACHE cycles=%0d requests=%0d hits=%0d arriving=%0d merged=%0d misses=%0d responses=%0d external_reads=%0d returns=%0d stall_queue=%0d stall_bank=%0d stall_set=%0d stall_mshr=%0d stall_other=%0d head_wait=%0d reorder_hold=%0d queue_sum=%0d one_fill=%0d two_fills=%0d store_hits=%0d store_misses=%0d store_updates=%0d",cycles,requests,hits,arriving,merged,misses,responses,external_reads,returns,stall_queue,stall_bank,stall_set,stall_mshr,stall_other,head_wait,reorder_hold,queue_sum,one_fill,two_fills,store_hits,store_misses,store_updates);
endmodule
bind load_line_cache perf_line_cache cache_monitor (
 .clk(clk),.reset(reset),.accept(accept),.hit_read(hit_read),.arriving_word(arriving_word),
 .lookup_hit(lookup_hit),.match_valid(match_valid),.allocate(allocate),
 .req_valid(req_valid),.req_ready(req_ready),.bank_available(bank_available),
 .row_busy(row_busy),.free_valid(free_valid),.resp_valid(resp_valid),.send_fire(send_fire),
 .return_valid(return_valid),.store_fire(store_fire),.st_hit(st_hit),.store_write(store_write),
 .m_valid(m_valid),.q_count(q_count),.flight_count(flight_count),.q_done(q_done),.q_head(q_head)
);
`endif
