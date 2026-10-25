// Input-only simulation monitors. Inject with LOCAL_STATS; never add to filelist.f.
`ifdef LOCAL_STATS
module perf_iq_stats #(parameter D=8, PW=6, R=2, IW=2) (
  input logic clk, reset, squash_valid,
  input logic [31:0] squash_seq,
  input logic [D-1:0] valid, src1_ready, src2_ready, cand_issue, cand_prefill,
  input logic [D*PW-1:0] src1_tag, src2_tag,
  input logic [D*32-1:0] seq,
  input logic [R-1:0] wake_valid,
  input logic [R*PW-1:0] wake_tag,
  input logic [IW-1:0] out_valid, out_ready
);
  longint cycles, empty, wait_sources, cancel_no_offer, other_no_offer;
  longint offered, no_fire, wake_opportunity, occ_sum;
  integer max_occ, occ, i, r;
  logic wake_ready, h1, h2;
  always_comb begin
    occ=0; wake_ready=0; h1=0; h2=0;
    for (i=0;i<D;i=i+1) begin
      if(valid[i]) occ=occ+1;
      h1=src1_ready[i]; h2=src2_ready[i];
      for(r=0;r<R;r=r+1) begin
        h1=h1 || (wake_valid[r] && wake_tag[r*PW+:PW]==src1_tag[i*PW+:PW]);
        h2=h2 || (wake_valid[r] && wake_tag[r*PW+:PW]==src2_tag[i*PW+:PW]);
      end
      if(valid[i] && !(squash_valid && seq[i*32+:32]>squash_seq) && h1 && h2)
        wake_ready=1;
    end
  end
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0; empty<=0; wait_sources<=0; cancel_no_offer<=0; other_no_offer<=0;
      offered<=0; no_fire<=0; wake_opportunity<=0; occ_sum<=0; max_occ<=0;
    end else begin
      cycles<=cycles+1; occ_sum<=occ_sum+occ;
      if(occ>max_occ) max_occ<=occ;
      if(|out_valid) offered<=offered+1;
      else if(!(|valid)) empty<=empty+1;
      else if(squash_valid) cancel_no_offer<=cancel_no_offer+1;
      else if(!(|(cand_issue|cand_prefill))) wait_sources<=wait_sources+1;
      else other_no_offer<=other_no_offer+1;
      if(!(|(out_valid & out_ready))) no_fire<=no_fire+1;
      // Opportunity only: issue would also require data forwarding and admission.
      if(!squash_valid && !(|out_valid) && wake_ready) wake_opportunity<=wake_opportunity+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] IQ_EXTRA cycles=%0d empty=%0d wait_sources=%0d cancel_no_offer=%0d other_no_offer=%0d offered=%0d no_fire=%0d wake_opportunity=%0d occ_sum=%0d max_occ=%0d",cycles,empty,wait_sources,cancel_no_offer,other_no_offer,offered,no_fire,wake_opportunity,occ_sum,max_occ);
endmodule

bind issue_queue perf_iq_stats #(.D(D),.PW(PW),.R(R),.IW(IW)) perf_iq_monitor (
  .clk(clk),.reset(reset),.squash_valid(squash_valid),.squash_seq(squash_seq),
  .valid(valid),.src1_ready(src1_ready),.src2_ready(src2_ready),
  .cand_issue(cand_issue),.cand_prefill(cand_prefill),.src1_tag(src1_tag),.src2_tag(src2_tag),
  .seq(seq),.wake_valid(wake_valid),.wake_tag(wake_tag),.out_valid(out_valid),.out_ready(out_ready)
);

module perf_lsu_stats #(parameter D=16) (
  input logic clk, reset, squash_valid,
  input logic [D-1:0] lp_valid,
  input logic q_active, r_active, query_send, query_blocked, query_ready,
  input logic load_enqueue, load_issue, r_illegal, ld_fwd, ld_space, result_space,
  input logic ld_req_ready, md_resp_fire
);
  longint cycles, pending, lp_occ_sum, enqueues, queries, q_busy, r_busy;
  longint pending_squash, executed, blocked, credits, mem_wait, result_wait, other_wait, pending_no_r;
  integer i, occ, max_occ;
  always_comb begin
    occ=0;
    for(i=0;i<D;i=i+1) if(lp_valid[i]) occ=occ+1;
  end
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0; pending<=0; lp_occ_sum<=0; enqueues<=0; queries<=0; q_busy<=0; r_busy<=0;
      pending_squash<=0; executed<=0; blocked<=0; credits<=0; mem_wait<=0;
      result_wait<=0; other_wait<=0; pending_no_r<=0; max_occ<=0;
    end else begin
      cycles<=cycles+1; lp_occ_sum<=lp_occ_sum+occ;
      if(occ>max_occ) max_occ<=occ;
      if(load_enqueue) enqueues<=enqueues+1;
      if(query_send) queries<=queries+1;
      if(q_active) q_busy<=q_busy+1;
      if(r_active) r_busy<=r_busy+1;
      // Exclusive state classification, conditional on pending load ownership.
      if(|lp_valid) begin
        pending<=pending+1;
        if(squash_valid) pending_squash<=pending_squash+1;
        else if(load_issue) executed<=executed+1;
        else if(!r_active) pending_no_r<=pending_no_r+1;
        else if(query_blocked) blocked<=blocked+1;
        else if(!result_space || (!(r_illegal || ld_fwd) && !ld_space)) credits<=credits+1;
        else if(!(r_illegal || ld_fwd) && !ld_req_ready) mem_wait<=mem_wait+1;
        else if((r_illegal || ld_fwd) && md_resp_fire) result_wait<=result_wait+1;
        else other_wait<=other_wait+1;
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LSU_EXTRA cycles=%0d pending=%0d lp_occ_sum=%0d max_occ=%0d enqueues=%0d queries=%0d q_busy=%0d r_busy=%0d pending_squash=%0d executed=%0d blocked=%0d credits=%0d mem_wait=%0d result_wait=%0d other_wait=%0d pending_no_r=%0d",cycles,pending,lp_occ_sum,max_occ,enqueues,queries,q_busy,r_busy,pending_squash,executed,blocked,credits,mem_wait,result_wait,other_wait,pending_no_r);
endmodule

bind lsu perf_lsu_stats #(.D(LP_DEPTH)) perf_lsu_monitor (
  .clk(clk),.reset(reset),.squash_valid(squash_valid),.lp_valid(lp_valid),
  .q_active(q_active),.r_active(r_active),.query_send(query_send),.query_blocked(query_blocked),
  .query_ready(query_ready),.load_enqueue(load_enqueue),.load_issue(load_issue),
  .r_illegal(r_illegal),.ld_fwd(ld_fwd),.ld_space(ld_space),.result_space(result_space),
  .ld_req_ready(ld_req_ready),.md_resp_fire(md_resp_fire)
);

module perf_rob_stats #(parameter W=2, D=16) (
  input logic clk, reset, head_valid, head_done, head_control, head_resolved,
  input logic head_load, head_store, recover_valid, redirect_valid, flush_young,
  input logic [W-1:0] commit_valid,
  input logic [$clog2(D+1)-1:0] count
);
  longint cycles, recovery, empty, load_wait, store_wait, control_wait, other_wait;
  longint resolution_wait, commit_cycles, other_hold;
  longint one_slot, full;
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0; recovery<=0; empty<=0; load_wait<=0; store_wait<=0;
      control_wait<=0; other_wait<=0; resolution_wait<=0; commit_cycles<=0; other_hold<=0;
      one_slot<=0; full<=0;
    end else begin
      cycles<=cycles+1;
      if(count==D-1) one_slot<=one_slot+1;
      if(count==D) full<=full+1;
      if(recover_valid || redirect_valid || flush_young) recovery<=recovery+1;
      else if(!head_valid) empty<=empty+1;
      else if(!head_done) begin
        if(head_load) load_wait<=load_wait+1;
        else if(head_store) store_wait<=store_wait+1;
        else if(head_control) control_wait<=control_wait+1;
        else other_wait<=other_wait+1;
      end else if(head_control && !head_resolved) resolution_wait<=resolution_wait+1;
      else if(|commit_valid) commit_cycles<=commit_cycles+1;
      else other_hold<=other_hold+1;
    end
  end
  final $fdisplay(32'h80000002,"[STATS] ROB_EXTRA cycles=%0d recovery=%0d empty=%0d load_wait=%0d store_wait=%0d control_wait=%0d other_wait=%0d resolution_wait=%0d commit_cycles=%0d other_hold=%0d one_slot=%0d full=%0d",cycles,recovery,empty,load_wait,store_wait,control_wait,other_wait,resolution_wait,commit_cycles,other_hold,one_slot,full);
endmodule

bind rob perf_rob_stats #(.W(W),.D(DEPTH)) perf_rob_monitor (
  .clk(clk),.reset(reset),.head_valid(head_valid[0]),.head_done(head_done[0]),
  .head_control(head_control[0]),.head_resolved(head_resolved[0]),
  .head_load(entry_is_load[head]),.head_store(entry_is_store[head]),
  .recover_valid(recover_valid),.redirect_valid(redirect_valid),.flush_young(flush_young),
  .commit_valid(commit_valid),.count(count)
);

module perf_load_head_stats #(parameter ID=8, DW=150, PW=6, LD=16, MD=8, TAG_OFF=122,
                             MW=(MD>1)?$clog2(MD):1) (
  input logic clk, reset, head_wait,
  input logic [PW-1:0] head_tag,
  input logic [ID-1:0] iq_valid, iq_src1_ready, iq_src2_ready,
  input logic [ID*DW-1:0] iq_uop,
  input logic [LD-1:0] lp_valid,
  input logic [LD*PW-1:0] lp_tag,
  input logic [MD-1:0] md_valid, rq_valid,
  input logic [MD*PW-1:0] md_tag, rq_tag,
  input logic [MW-1:0] md_head, rq_head,
  input logic [MW:0] md_count, rq_count
);
  logic iq_hit, iq_wait, lp_hit, md_hit, rq_hit;
  integer i;
  longint cycles, total, iq_sources, iq_ready, pending, memory, result_queue, other, overlap;
  always_comb begin
    iq_hit=0; iq_wait=0; lp_hit=0; md_hit=0; rq_hit=0;
    for(i=0;i<ID;i=i+1) begin
      if(iq_valid[i] && iq_uop[i*DW+TAG_OFF+:PW]==head_tag) begin
        iq_hit=1; iq_wait=!iq_src1_ready[i] || !iq_src2_ready[i];
      end
    end
    for(i=0;i<LD;i=i+1) if(lp_valid[i] && lp_tag[i*PW+:PW]==head_tag) lp_hit=1;
    for(i=0;i<MD;i=i+1) begin
      // valid bits are historical write markers, not FIFO occupancy bits.
      // Only slots in the live head/count window represent current owners.
      if(((i+MD-int'(md_head))%MD)<md_count && md_valid[i] && md_tag[i*PW+:PW]==head_tag) md_hit=1;
      if(((i+MD-int'(rq_head))%MD)<rq_count && rq_valid[i] && rq_tag[i*PW+:PW]==head_tag) rq_hit=1;
    end
  end
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0; total<=0; iq_sources<=0; iq_ready<=0; pending<=0;
      memory<=0; result_queue<=0; other<=0; overlap<=0;
    end else begin
      cycles<=cycles+1;
      if(head_wait) begin
        total<=total+1;
        if((int'(iq_hit)+int'(lp_hit)+int'(md_hit)+int'(rq_hit))>1) overlap<=overlap+1;
        if(iq_hit && iq_wait) iq_sources<=iq_sources+1;
        else if(iq_hit) iq_ready<=iq_ready+1;
        else if(lp_hit) pending<=pending+1;
        else if(md_hit) memory<=memory+1;
        else if(rq_hit) result_queue<=result_queue+1;
        else other<=other+1;
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LOAD_HEAD cycles=%0d total=%0d iq_sources=%0d iq_ready=%0d pending=%0d memory=%0d result_queue=%0d other=%0d overlap=%0d",cycles,total,iq_sources,iq_ready,pending,memory,result_queue,other,overlap);
endmodule

bind lsu perf_load_head_stats #(
  .ID(`CPU_RS_DEPTH),.DW(`CPU_DISPATCH_W),.PW(`CPU_PRF_IDX_W),.LD(`CPU_LSQ_DEPTH),
  .MD(LDQ_DEPTH),.TAG_OFF(`CPU_DISPATCH_DEST_TAG_OFF)
) perf_load_head_monitor (
  .clk(clk),.reset(reset),
  .head_wait($root.student_top.u_core.u_rob.head_valid[0] && !$root.student_top.u_core.u_rob.head_done[0] &&
    $root.student_top.u_core.u_rob.entry_is_load[$root.student_top.u_core.u_rob.head] && !$root.student_top.u_core.u_rob.recover_valid &&
    !$root.student_top.u_core.u_rob.redirect_valid && !$root.student_top.u_core.u_rob.flush_young),
  .head_tag($root.student_top.u_core.u_rob.entry_dest_tag[$root.student_top.u_core.u_rob.head]),
  .iq_valid($root.student_top.u_backend.u_iq.valid),.iq_src1_ready($root.student_top.u_backend.u_iq.src1_ready),
  .iq_src2_ready($root.student_top.u_backend.u_iq.src2_ready),.iq_uop($root.student_top.u_backend.u_iq.uop),
  .lp_valid($root.student_top.u_backend.u_lsu.lp_valid),.lp_tag($root.student_top.u_backend.u_lsu.lp_tag),
  .md_valid($root.student_top.u_backend.u_lsu.md_valid & ~$root.student_top.u_backend.u_lsu.md_discard),.md_tag($root.student_top.u_backend.u_lsu.md_tag),
  .rq_valid($root.student_top.u_backend.u_lsu.rq_valid & ~$root.student_top.u_backend.u_lsu.rq_discard),.rq_tag($root.student_top.u_backend.u_lsu.rq_tag),
  .md_head(md_head),.rq_head(rq_head),.md_count(ld_count),.rq_count(rq_count)
);
// Probe admission opportunities before changing the scalar group handshake.
module perf_admission_stats #(parameter W=2) (
  input logic clk, reset, one_slot, controls_ok, free_tag, committing, accept_fire,
  input logic [31:0] fq_count
);
  longint cycles, one_slot_cycles, gated, empty, single, pair, no_tag;
  longint single_no_commit, pair_no_commit, accepted, accepted_no_commit;
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0;one_slot_cycles<=0;gated<=0;empty<=0;single<=0;pair<=0;no_tag<=0;
      single_no_commit<=0;pair_no_commit<=0;accepted<=0;accepted_no_commit<=0;
    end else begin
      cycles<=cycles+1;
      if(one_slot) begin
        one_slot_cycles<=one_slot_cycles+1;
        if(accept_fire) begin
          accepted<=accepted+1;if(!committing) accepted_no_commit<=accepted_no_commit+1;
        end
        if(!controls_ok) gated<=gated+1;
        else if(fq_count==0) empty<=empty+1;
        else if(!free_tag) no_tag<=no_tag+1;
        else if(fq_count==1) begin
          single<=single+1;if(!committing) single_no_commit<=single_no_commit+1;
        end else begin
          pair<=pair+1;if(!committing) pair_no_commit<=pair_no_commit+1;
        end
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] ADMISSION cycles=%0d one_slot=%0d gated=%0d empty=%0d single=%0d pair=%0d no_tag=%0d single_no_commit=%0d pair_no_commit=%0d accepted=%0d accepted_no_commit=%0d",cycles,one_slot_cycles,gated,empty,single,pair,no_tag,single_no_commit,pair_no_commit,accepted,accepted_no_commit);
endmodule
bind core_ooo perf_admission_stats #(.W(W)) perf_admission_monitor (
  .clk(clk),.reset(reset),.one_slot(u_rob.count==(`CPU_ROB_DEPTH-1)),
  .controls_ok(backend_ready && !u_rob.flush_young && !u_rob.recover_valid && !rob_redirect_valid),
  .free_tag(u_rename.free_count!=0),.committing(|rob_cm_valid),
  .fq_count(32'(u_front.fq_count)),.accept_fire(|ren_fire)
);

// Count real ALU1 alternatives, excluding the lane0 reservation even when
// lane0 is backpressured. This is an opportunity count, not saved cycles.
module perf_lane1_stats #(parameter D=8, DW=`CPU_DISPATCH_W) (
  input logic clk, reset, squash_valid, lane1_accept,
  input logic [31:0] squash_seq,
  input logic [D-1:0] valid, src1_ready, src2_ready,
  input logic [D*DW-1:0] uop,
  input logic [D*32-1:0] seq,
  input logic [7:0] lane0_slot,
  input logic [1:0] out_valid, out_ready,
  input logic lane1_ok
);
  longint cycles, unsupported, alternative, alternative_accept, selected, fired, bypass_fire;
  integer i, legacy_slot;
  logic available, legacy_ok, eligible;
  logic [31:0] legacy_seq;
  logic [4:0] op;
  always_comb begin
    available=0;op='0;legacy_slot=-1;legacy_seq='1;legacy_ok=0;eligible=0;
    for(i=0;i<D;i=i+1) begin
      op=uop[i*DW+`CPU_DISPATCH_ALU_OP_OFF+:5];
      eligible=uop[i*DW+`CPU_DISPATCH_REG_WE_OFF] &&
         !uop[i*DW+`CPU_DISPATCH_IS_LOAD_OFF] && !uop[i*DW+`CPU_DISPATCH_IS_STORE_OFF] &&
         !uop[i*DW+`CPU_DISPATCH_IS_BRANCH_OFF] && !uop[i*DW+`CPU_DISPATCH_IS_JAL_OFF] &&
         !uop[i*DW+`CPU_DISPATCH_IS_JALR_OFF] && !uop[i*DW+`CPU_DISPATCH_ILLEGAL_OFF] &&
         op!=`ALU_DIV && op!=`ALU_DIVU && op!=`ALU_REM && op!=`ALU_REMU;
      if(valid[i] && src1_ready[i] && src2_ready[i] &&
         !(squash_valid && seq[i*32+:32]>squash_seq) && i!=int'(lane0_slot)) begin
        if(eligible) available=1;
        if(legacy_slot<0 || seq[i*32+:32]<legacy_seq) begin
          legacy_slot=i;legacy_seq=seq[i*32+:32];legacy_ok=eligible;
        end
      end
    end
  end
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0;unsupported<=0;alternative<=0;alternative_accept<=0;selected<=0;fired<=0;bypass_fire<=0;
    end else begin
      cycles<=cycles+1;
      if(out_valid[1]) selected<=selected+1;
      if(out_valid[1] && out_ready[1]) fired<=fired+1;
      if(out_valid[1] && out_ready[1] && lane1_ok && legacy_slot>=0 && !legacy_ok)
        bypass_fire<=bypass_fire+1;
      if(out_valid[1] && !lane1_ok) begin
        unsupported<=unsupported+1;
        if(available) begin
          alternative<=alternative+1;
          if(lane1_accept) alternative_accept<=alternative_accept+1;
        end
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] LANE1 cycles=%0d unsupported=%0d alternative=%0d alternative_accept=%0d selected=%0d fired=%0d bypass_fire=%0d",cycles,unsupported,alternative,alternative_accept,selected,fired,bypass_fire);
endmodule
bind backend_ooo perf_lane1_stats #(.D(`CPU_RS_DEPTH)) perf_lane1_monitor (
  .clk(clk),.reset(reset),.squash_valid(sq_valid),.squash_seq(squash_seq),.lane1_accept(a1_accept),
  .valid(u_iq.valid),.src1_ready(u_iq.src1_ready),.src2_ready(u_iq.src2_ready),
  .uop(u_iq.uop),.seq(u_iq.seq),.lane0_slot(u_iq.sel_idx[0]),
  .out_valid(iq_out_valid),.out_ready(issue_ready),.lane1_ok(j_lane_ok)
);

// Hypothetical ALU1 wake-through selection; source data is read only after
// the ALU1 buffer edge, at which the same CDB has written the PRF.
module perf_early1_stats #(parameter D=8, PW=`CPU_PRF_IDX_W, R=`CPU_CDB_NUM) (
  input logic clk, reset, squash_valid, lane1_accept,
  input logic [31:0] squash_seq,
  input logic [D-1:0] valid, eligible, src1_ready, src2_ready,
  input logic [D*PW-1:0] src1_tag, src2_tag,
  input logic [D*32-1:0] seq,
  input logic [R-1:0] wake_valid,
  input logic [R*PW-1:0] wake_tag,
  input logic [7:0] lane0_slot, lane1_slot,
  input logic [1:0] out_valid, out_ready
);
  longint cycles, opportunity, can_accept, idle_opportunity, no_offer_opportunity;
  longint actual_early, one_source, two_sources;
  integer i, r, best;
  logic h1, h2, early_wins;
  logic [31:0] best_seq;
  always_comb begin
    best=-1;best_seq='1;h1=0;h2=0;early_wins=0;
    for(i=0;i<D;i=i+1) begin
      h1=src1_ready[i];h2=src2_ready[i];
      for(r=0;r<R;r=r+1) begin
        h1=h1||(wake_valid[r]&&wake_tag[r*PW+:PW]==src1_tag[i*PW+:PW]);
        h2=h2||(wake_valid[r]&&wake_tag[r*PW+:PW]==src2_tag[i*PW+:PW]);
      end
      if(valid[i]&&eligible[i]&&h1&&h2&&
         !(squash_valid&&seq[i*32+:32]>squash_seq)&&
         !(out_valid[0]&&i==int'(lane0_slot))&&
         (best<0||seq[i*32+:32]<best_seq)) begin
        best=i;best_seq=seq[i*32+:32];early_wins=!(src1_ready[i]&&src2_ready[i]);
      end
    end
  end
  always_ff @(posedge clk) begin
    if(reset) begin
      cycles<=0;opportunity<=0;can_accept<=0;idle_opportunity<=0;no_offer_opportunity<=0;
      actual_early<=0;one_source<=0;two_sources<=0;
    end else begin
      cycles<=cycles+1;
      if(early_wins) begin
        opportunity<=opportunity+1;
        if(lane1_accept) can_accept<=can_accept+1;
        if(!out_valid[1]) idle_opportunity<=idle_opportunity+1;
        if(!(|out_valid)) no_offer_opportunity<=no_offer_opportunity+1;
      end
      if(out_valid[1]&&out_ready[1]&&!(src1_ready[lane1_slot]&&src2_ready[lane1_slot])) begin
        actual_early<=actual_early+1;
        if(!src1_ready[lane1_slot]&&!src2_ready[lane1_slot]) two_sources<=two_sources+1;
        else one_source<=one_source+1;
      end
    end
  end
  final $fdisplay(32'h80000002,"[STATS] EARLY1 cycles=%0d opportunity=%0d can_accept=%0d idle_opportunity=%0d no_offer_opportunity=%0d actual_early=%0d one_source=%0d two_sources=%0d",cycles,opportunity,can_accept,idle_opportunity,no_offer_opportunity,actual_early,one_source,two_sources);
endmodule
bind backend_ooo perf_early1_stats #(.D(`CPU_RS_DEPTH)) perf_early1_monitor (
  .clk(clk),.reset(reset),.squash_valid(sq_valid),.squash_seq(squash_seq),.lane1_accept(a1_accept),
  .valid(u_iq.valid),.eligible(u_iq.lane1_eligible),
  .src1_ready(u_iq.src1_ready),.src2_ready(u_iq.src2_ready),
  .src1_tag(u_iq.src1_tag),.src2_tag(u_iq.src2_tag),.seq(u_iq.seq),
  .wake_valid(cdb_wake_valid),.wake_tag(cdb_wake_tag),
  .lane0_slot(u_iq.sel_idx[0]),.lane1_slot(u_iq.sel_idx[1]),
  .out_valid(iq_out_valid),.out_ready(issue_ready)
);
`endif
