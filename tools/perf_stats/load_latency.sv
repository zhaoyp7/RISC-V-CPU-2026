// Passive simulation probes; excluded from the official production filelist.
`ifdef LOCAL_STATS
module perf_load_latency #(
  parameter LP=16, MD=8, LW=4, PW=6, MW=3
) (
  input logic clk, reset, load_enqueue, load_issue, r_illegal, ld_fwd,
  input logic [LW-1:0] issue_id, r_id,
  input logic [31:0] issue_seq, r_seq,
  input logic ld_req_valid, ld_req_ready, md_resp_fire, md_resp_keep,
  input logic [MW-1:0] md_head, md_tail, rq_head, rq_tail,
  input logic [MD*32-1:0] md_seq,
  input logic rq_push, rq_pop, result_valid, result_ready
);
  longint cycles, enqueues, executions, requests, responses, kept_responses;
  longint lp_sum, lp_max, memory_sum, memory_max, kept_memory_sum;
  longint result_sum, result_max, writebacks, discarded_results;
  longint result_one, result_two, result_many, forwarded, illegal;
  longint lp_tick[LP], md_tick[MD], rq_tick[MD];
  logic [31:0] lp_sequence[LP], md_sequence[MD];
  bit lp_seen[LP], md_seen[MD], rq_seen[MD];
  longint age;
  integer i;
  // Blocking assignments are confined to private observer state. Responses
  // are sampled before new requests so simultaneous FIFO pop/push is precise.
  always @(posedge clk) begin
    if (reset) begin
      cycles=0;enqueues=0;executions=0;requests=0;responses=0;kept_responses=0;
      lp_sum=0;lp_max=0;memory_sum=0;memory_max=0;kept_memory_sum=0;
      result_sum=0;result_max=0;writebacks=0;discarded_results=0;
      result_one=0;result_two=0;result_many=0;forwarded=0;illegal=0;
      for(i=0;i<LP;i=i+1) begin lp_seen[i]=0;lp_tick[i]=0;lp_sequence[i]=0;end
      for(i=0;i<MD;i=i+1) begin
        md_seen[i]=0;md_tick[i]=0;md_sequence[i]=0;rq_seen[i]=0;rq_tick[i]=0;
      end
    end else begin
      if (md_resp_fire) begin
        if(!md_seen[md_head] || md_sequence[md_head]!=md_seq[md_head*32+:32])
          $fatal(1,"load latency response identity mismatch");
        age=cycles-md_tick[md_head];responses=responses+1;memory_sum=memory_sum+age;
        if(age>memory_max)memory_max=age;
        if(md_resp_keep)begin kept_responses=kept_responses+1;kept_memory_sum=kept_memory_sum+age;end
        md_seen[md_head]=0;
      end
      if(rq_pop)begin
        if(!rq_seen[rq_head])$fatal(1,"load latency result slot has no timestamp");
        age=cycles-rq_tick[rq_head];rq_seen[rq_head]=0;
        if(result_valid && result_ready)begin
          writebacks=writebacks+1;result_sum=result_sum+age;
          if(age>result_max)result_max=age;
          if(age==1)result_one=result_one+1;
          else if(age==2)result_two=result_two+1;
          else result_many=result_many+1;
        end else discarded_results=discarded_results+1;
      end
      if(rq_push)begin
        if(rq_seen[rq_tail])$fatal(1,"load latency result timestamp overwritten");
        rq_seen[rq_tail]=1;rq_tick[rq_tail]=cycles;
      end
      if(load_issue)begin
        if(!lp_seen[r_id] || lp_sequence[r_id]!=r_seq)
          $fatal(1,"load latency execution identity mismatch");
        age=cycles-lp_tick[r_id];lp_sum=lp_sum+age;executions=executions+1;
        if(age>lp_max)lp_max=age;
        lp_seen[r_id]=0;
        if(r_illegal)illegal=illegal+1;
        else if(ld_fwd)forwarded=forwarded+1;
      end
      if((ld_req_valid && ld_req_ready)!=(load_issue && !r_illegal && !ld_fwd))
        $fatal(1,"load request handshake inconsistent");
      if(ld_req_valid && ld_req_ready)begin
        if(md_seen[md_tail])$fatal(1,"load latency request timestamp overwritten");
        md_seen[md_tail]=1;md_tick[md_tail]=cycles;md_sequence[md_tail]=r_seq;requests=requests+1;
      end
      if(load_enqueue)begin
        lp_seen[issue_id]=1;lp_tick[issue_id]=cycles;lp_sequence[issue_id]=issue_seq;enqueues=enqueues+1;
      end
      cycles=cycles+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LOAD_LAT cycles=%0d enqueues=%0d executions=%0d requests=%0d responses=%0d kept_responses=%0d lp_sum=%0d lp_max=%0d memory_sum=%0d memory_max=%0d kept_memory_sum=%0d writebacks=%0d discarded_results=%0d result_sum=%0d result_max=%0d result_one=%0d result_two=%0d result_many=%0d forwarded=%0d illegal=%0d",cycles,enqueues,executions,requests,responses,kept_responses,lp_sum,lp_max,memory_sum,memory_max,kept_memory_sum,writebacks,discarded_results,result_sum,result_max,result_one,result_two,result_many,forwarded,illegal);
endmodule

bind lsu perf_load_latency #(.LP(LP_DEPTH),.MD(LDQ_DEPTH),.LW(LW),.PW(PW),.MW(MDW)) perf_load_latency_monitor (
  .clk(clk),.reset(reset),.load_enqueue(load_enqueue),.load_issue(load_issue),
  .r_illegal(r_illegal),.ld_fwd(ld_fwd),.issue_id(issue_lsq),.r_id(r_id),
  .issue_seq(issue_seq),.r_seq(r_seq),.ld_req_valid(ld_req_valid),.ld_req_ready(ld_req_ready),
  .md_resp_fire(md_resp_fire),.md_resp_keep(md_resp_keep),.md_head(md_head),.md_tail(md_tail),
  .rq_head(rq_head),.rq_tail(rq_tail),.md_seq(md_seq),.rq_push(rq_push),.rq_pop(rq_pop),
  .result_valid(load_result_valid),.result_ready(load_result_ready)
);

module perf_load_use #(
  parameter D=8, PW=6, DW=`CPU_DISPATCH_W, R=2
) (
  input logic clk, reset, squash_valid, load_fire,
  input logic [31:0] squash_seq,
  input logic [PW-1:0] load_tag,
  input logic [D-1:0] valid, src1_ready, src2_ready, lane1_eligible,
  input logic [D*PW-1:0] src1_tag, src2_tag,
  input logic [D*32-1:0] seq,
  input logic [R-1:0] wake_valid,
  input logic [R*PW-1:0] wake_tag,
  input logic [1:0] issue_valid, issue_ready,
  input logic [2*32-1:0] issue_seq
);
  longint cycles, opportunities, issued, canceled, vanished, latency_sum, latency_max;
  longint same_cycle, next_cycle, two_cycles, later, lane1_candidates, lane1_issued;
  longint started[D];logic [31:0] identity[D];bit tracked[D], tracked_lane1[D];
  bit h1,h2,load_hit;longint age;integer i,r,l;
  always @(posedge clk) begin
    if(reset)begin
      cycles=0;opportunities=0;issued=0;canceled=0;vanished=0;latency_sum=0;latency_max=0;
      same_cycle=0;next_cycle=0;two_cycles=0;later=0;lane1_candidates=0;lane1_issued=0;
      for(i=0;i<D;i=i+1)begin tracked[i]=0;started[i]=0;identity[i]=0;tracked_lane1[i]=0;end
    end else begin
      for(i=0;i<D;i=i+1)begin
        if(tracked[i] && (!valid[i] || seq[i*32+:32]!=identity[i]))begin
          vanished=vanished+1;tracked[i]=0;
        end
        if(tracked[i] && squash_valid && identity[i]>squash_seq)begin
          canceled=canceled+1;tracked[i]=0;
        end
        h1=src1_ready[i];h2=src2_ready[i];
        for(r=0;r<R;r=r+1)begin
          h1=h1||(wake_valid[r]&&wake_tag[r*PW+:PW]==src1_tag[i*PW+:PW]);
          h2=h2||(wake_valid[r]&&wake_tag[r*PW+:PW]==src2_tag[i*PW+:PW]);
        end
        load_hit=(!src1_ready[i] && src1_tag[i*PW+:PW]==load_tag) ||
                 (!src2_ready[i] && src2_tag[i*PW+:PW]==load_tag);
        if(load_fire && valid[i] && load_hit && h1 && h2 &&
           !(squash_valid && seq[i*32+:32]>squash_seq))begin
          if(tracked[i])$fatal(1,"load consumer measured twice");
          tracked[i]=1;started[i]=cycles;identity[i]=seq[i*32+:32];tracked_lane1[i]=lane1_eligible[i];
          opportunities=opportunities+1;
          if(lane1_eligible[i])lane1_candidates=lane1_candidates+1;
        end
        for(l=0;l<2;l=l+1)begin
          if(tracked[i] && issue_valid[l] && issue_ready[l] && issue_seq[l*32+:32]==identity[i])begin
            age=cycles-started[i];latency_sum=latency_sum+age;issued=issued+1;
            if(tracked_lane1[i])lane1_issued=lane1_issued+1;
            if(age>latency_max)latency_max=age;
            if(age==0)same_cycle=same_cycle+1;
            else if(age==1)next_cycle=next_cycle+1;
            else if(age==2)two_cycles=two_cycles+1;
            else later=later+1;
            tracked[i]=0;
          end
        end
      end
      cycles=cycles+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LOAD_USE cycles=%0d opportunities=%0d issued=%0d canceled=%0d vanished=%0d latency_sum=%0d latency_max=%0d same_cycle=%0d next_cycle=%0d two_cycles=%0d later=%0d lane1_candidates=%0d lane1_issued=%0d",cycles,opportunities,issued,canceled,vanished,latency_sum,latency_max,same_cycle,next_cycle,two_cycles,later,lane1_candidates,lane1_issued);
endmodule

bind backend_ooo perf_load_use #(.D(`CPU_RS_DEPTH),.PW(PW),.R(`CPU_CDB_NUM)) perf_load_use_monitor (
  .clk(clk),.reset(reset),.squash_valid(sq_valid),.squash_seq(squash_seq),
  .load_fire(lsu_load_valid && cdb_src_ready[2]),.load_tag(lsu_load_tag),
  .valid(u_iq.valid),.src1_ready(u_iq.src1_ready),.src2_ready(u_iq.src2_ready),
  .lane1_eligible(u_iq.lane1_eligible),.src1_tag(u_iq.src1_tag),.src2_tag(u_iq.src2_tag),.seq(u_iq.seq),
  .wake_valid(cdb_wake_valid),.wake_tag(cdb_wake_tag),
  .issue_valid(iq_out_valid & ~iq_out_addr_only),.issue_ready(issue_ready),.issue_seq(issue_seq)
);
`endif
