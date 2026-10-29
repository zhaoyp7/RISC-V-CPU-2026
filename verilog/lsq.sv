// -----------------------------------------------------------------------------
// lsq.sv — load/store queue v2
//
// 表项按 rename 分配的 lsq_id 索引（CPU_LSQ_DEPTH 项）。职责：
//   - dispatch 时按 lsq_id 占用表项，满/复用冲突时反压；
//   - issue 时填入地址/写数据/写掩码；
//   - commit：load 立即释放；store 标记 committed；
//   - store drain：最老的已提交且未发送的 store 进入写流；drain_fire 表示
//     已被内存接收；写响应（按序）返回后释放表项；
//   - load 排序：更老 store 地址未知则阻塞；同字地址则等它真正写完成；
//   - squash 按 dispatch seq 清除年轻表项。已发送的 store 必然已提交，
//     不会被 squash。
// -----------------------------------------------------------------------------

module lsq #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer D = `CPU_LSQ_DEPTH,
  parameter integer STORE_DATA_CAPTURE = 0,
  parameter integer ORDERED_STORE_COMMIT = 0,
  parameter integer PAIRWISE_AGE = 1
) (
  input  logic clk,
  input  logic reset,

  // dispatch allocation
  input  logic [W-1:0]                 alloc_valid,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  alloc_id,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob,
  input  logic [W-1:0]                 alloc_is_store,
  output logic                         alloc_ready,
  input  logic                         alloc_fire,

  // issue fill
  input  logic                         fill_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    fill_id,
  input  logic [31:0]                  fill_addr,
  input  logic [31:0]                  fill_wdata,
  input  logic [3:0]                   fill_wstrb,
  input  logic                         fill_is_store,

  // store address prefill (address known before data is ready)
  input  logic                         prefill_valid,
  input  logic [`CPU_LSQ_IDX_W-1:0]    prefill_id,
  input  logic [31:0]                  prefill_addr,

  // Optional source capture after an address-only store leaves the IQ.
  input logic [`CPU_PRF_IDX_W-1:0] prefill_data_tag,
  input logic [3:0] prefill_wstrb,
  input logic [`CPU_CDB_BUS_W-1:0] store_cdb,

  // commit
  input  logic [W-1:0]                 commit_valid,
  input  logic [W-1:0]                 commit_is_store,
  input  logic [W-1:0]                 commit_is_load,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  commit_id,

  // dispatch sequence: lane i is seq_base + i
  input  logic [31:0]                  seq_base,

  // squash: keep seq == squash_seq, drop seq > squash_seq
  input  logic                         squash_valid,
  input  logic [31:0]                  squash_seq,

  // store drain
  output logic                         drain_valid,
  output logic [`CPU_LSQ_IDX_W-1:0]    drain_id,
  output logic [31:0]                  drain_addr,
  output logic [31:0]                  drain_wdata,
  output logic [3:0]                   drain_wstrb,
  input  logic                         drain_fire,
  input  logic                         store_resp_valid,

  // load ordering query (speculative, before fill)
  input  logic                         query_valid,
  input  logic [31:0]                  query_seq,
  input  logic [31:0]                  query_addr,
  output logic                         query_ready,
  output logic                         query_resp_valid,
  input  logic                         query_resp_ready,
  input  logic                         query_flush,
  output logic                         query_blocked,
  output logic                         query_fwd_valid,
  output logic [31:0]                  query_fwd_data,

  output logic [7:0]                   count
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer CW = `CPU_CDB_W;
  localparam integer R = `CPU_CDB_NUM;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer QW = (D > 1) ? $clog2(D) : 1;
  localparam integer FN = (D > 1) ? $clog2(D + 1) : 2;
  localparam integer QLEAVES = 1 << $clog2(D);

  logic [D-1:0]    valid;
  logic [D-1:0]    is_store;
  logic [D*RW-1:0] rob;
  logic [D*32-1:0] seq;
  logic [D-1:0]    addr_known;
  logic [D*32-1:0] addr;
  logic [D*32-1:0] wdata;
  logic [D*4-1:0]  wstrb;
  logic [D-1:0]    data_known, data_raw;
  logic [D*PW-1:0] data_tag;
  logic [D-1:0]    committed;
  logic [D-1:0]    sent;

  // sent FIFO：记录已发往内存但尚未收到写响应的 store id
  logic [D*LW-1:0] sent_fifo;
  logic [QW-1:0]   sent_head, sent_tail;
  logic [FN-1:0]   sent_count;
  logic [QW-1:0] commit_tail;
  logic [FN-1:0] ordered_count;
  logic [W-1:0] new_commit;
  logic [QW-1:0] commit_position [0:W-1];
  logic [FN-1:0] commit_count;
  integer ci,cj;
  logic duplicate_commit;
  always_comb begin
    new_commit='0;commit_count='0;duplicate_commit=0;
    for(ci=0;ci<W;ci=ci+1)begin
      commit_position[ci]=commit_tail+QW'(commit_count);
      duplicate_commit=0;
      for(cj=0;cj<ci;cj=cj+1)
        if(new_commit[cj] && commit_id[cj*LW+:LW]==commit_id[ci*LW+:LW])duplicate_commit=1;
      if(commit_valid[ci] && commit_is_store[ci] && valid[commit_id[ci*LW+:LW]] &&
         is_store[commit_id[ci*LW+:LW]] && !committed[commit_id[ci*LW+:LW]] && !duplicate_commit)begin
        new_commit[ci]=1;commit_count=commit_count+1'b1;
      end
    end
  end


  integer i, lane;
  integer lane_free;
  integer i_squash, i_count, lane_count;
  logic [`CPU_LSQ_IDX_W-1:0] id;

  // ---- allocation ---------------------------------------------------------
  logic [D-1:0] alloc_used;
  logic         alloc_ok;

  // 分配只使用寄存占用；commit/B 响应释放在下一拍才可见，
  // 切断 ROB 提交或内存响应经 alloc_ready 回传到 IQ 的组合路径。
  always_comb begin
    alloc_ok = 1'b1;
    alloc_used = '0;
    id = '0;
    for (lane_free = 0; lane_free < W; lane_free = lane_free + 1) begin
      if (alloc_valid[lane_free]) begin
        id = alloc_id[lane_free*LW +: LW];
        if (valid[id] || alloc_used[id])
          alloc_ok = 1'b0;
        alloc_used[id] = 1'b1;
      end
    end
    alloc_ready = alloc_ok;
  end

  // ---- squash -------------------------------------------------------------
  logic [D-1:0] squash_mask;

  always_comb begin
    squash_mask = '0;
    for (i_squash = 0; i_squash < D; i_squash = i_squash + 1) begin
      if (valid[i_squash] && !committed[i_squash] && squash_valid &&
          (seq[i_squash*32 +: 32] > squash_seq))
        squash_mask[i_squash] = 1'b1;
    end
  end

  // ---- store drain selection ---------------------------------------------
  // 候选保持为已提交、未发送的 store；按 seq 最老、同龄低 id 优先。
  // 选择树不增加拍数，发送与写响应释放仍由原 sent FIFO 管理。
  wire drain_tree_valid [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] drain_tree_seq [0:2*QLEAVES-1] /* verilator split_var */;
  wire [LW-1:0] drain_tree_id [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] drain_tree_addr [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] drain_tree_wdata [0:2*QLEAVES-1] /* verilator split_var */;
  wire [3:0] drain_tree_wstrb [0:2*QLEAVES-1] /* verilator split_var */;
  wire drain_tree_raw [0:2*QLEAVES-1] /* verilator split_var */;
  assign drain_tree_raw[0]=1'b0;
  wire drain_tree_ready [0:2*QLEAVES-1] /* verilator split_var */;
  assign drain_tree_ready[0] = 1'b0;
  assign drain_tree_valid[0] = 1'b0;
  assign drain_tree_seq[0] = '0;
  assign drain_tree_id[0] = '0;
  assign drain_tree_addr[0] = '0;
  assign drain_tree_wdata[0] = '0;
  assign drain_tree_wstrb[0] = '0;
  generate
    for (genvar g = 0; g < QLEAVES; g = g + 1) begin : gen_drain_leaf
      if (g < D) begin : gen_entry
        assign drain_tree_valid[QLEAVES+g] = valid[g] && is_store[g] &&
                                            committed[g] && !sent[g];
        assign drain_tree_raw[QLEAVES+g] = data_raw[g];
        assign drain_tree_ready[QLEAVES+g] = data_known[g];
        assign drain_tree_seq[QLEAVES+g] = seq[g*32 +: 32];
        assign drain_tree_id[QLEAVES+g] = LW'(g);
        assign drain_tree_addr[QLEAVES+g] = addr[g*32 +: 32];
        assign drain_tree_wdata[QLEAVES+g] = wdata[g*32 +: 32];
        assign drain_tree_wstrb[QLEAVES+g] = wstrb[g*4 +: 4];
      end else begin : gen_pad
        assign drain_tree_valid[QLEAVES+g] = 1'b0;
        assign drain_tree_raw[QLEAVES+g] = 1'b0;
        assign drain_tree_ready[QLEAVES+g] = 1'b0;
        assign drain_tree_seq[QLEAVES+g] = '0;
        assign drain_tree_id[QLEAVES+g] = '0;
        assign drain_tree_addr[QLEAVES+g] = '0;
        assign drain_tree_wdata[QLEAVES+g] = '0;
        assign drain_tree_wstrb[QLEAVES+g] = '0;
      end
    end
    for (genvar g = 1; g < QLEAVES; g = g + 1) begin : gen_drain_merge
      wire take_right = drain_tree_valid[2*g+1] &&
                         (!drain_tree_valid[2*g] ||
                          drain_tree_seq[2*g+1] < drain_tree_seq[2*g]);
      assign drain_tree_valid[g] = drain_tree_valid[2*g] || drain_tree_valid[2*g+1];
      assign drain_tree_raw[g] = take_right ? drain_tree_raw[2*g+1] : drain_tree_raw[2*g];
      assign drain_tree_ready[g] = take_right ? drain_tree_ready[2*g+1] : drain_tree_ready[2*g];
      assign drain_tree_seq[g] = take_right ? drain_tree_seq[2*g+1] : drain_tree_seq[2*g];
      assign drain_tree_id[g] = take_right ? drain_tree_id[2*g+1] : drain_tree_id[2*g];
      assign drain_tree_addr[g] = take_right ? drain_tree_addr[2*g+1] : drain_tree_addr[2*g];
      assign drain_tree_wdata[g] = take_right ? drain_tree_wdata[2*g+1] : drain_tree_wdata[2*g];
      assign drain_tree_wstrb[g] = take_right ? drain_tree_wstrb[2*g+1] : drain_tree_wstrb[2*g];
    end
  endgenerate
  // A committed id stays in the shared ring through send and write response.
  // The send cursor cannot bypass a data-waiting oldest committed store.
  wire [LW-1:0] raw_drain_id = ORDERED_STORE_COMMIT ? sent_fifo[sent_tail*LW+:LW] : drain_tree_id[1];
  wire raw_drain_valid = ORDERED_STORE_COMMIT ? ordered_count!=0 : drain_tree_valid[1];
  wire raw_drain_ready = ORDERED_STORE_COMMIT ? data_known[raw_drain_id] : drain_tree_ready[1];
  wire [31:0] raw_drain_addr = ORDERED_STORE_COMMIT ? addr[raw_drain_id*32+:32] : drain_tree_addr[1];
  wire [31:0] raw_drain_data = ORDERED_STORE_COMMIT ? wdata[raw_drain_id*32+:32] : drain_tree_wdata[1];
  wire [3:0] raw_drain_mask = ORDERED_STORE_COMMIT ? wstrb[raw_drain_id*4+:4] : drain_tree_wstrb[1];
  wire raw_drain_unshifted = ORDERED_STORE_COMMIT ? data_raw[raw_drain_id] : drain_tree_raw[1];
  assign drain_valid = raw_drain_valid && (!STORE_DATA_CAPTURE || raw_drain_ready);
  // Readiness qualifies the transaction, without feeding its address/data mux.
  assign drain_id = raw_drain_valid ? raw_drain_id : '0;
  assign drain_addr = raw_drain_valid ? raw_drain_addr : '0;
  assign drain_wstrb = raw_drain_valid ? raw_drain_mask : '0;
  assign drain_wdata = !raw_drain_valid ? '0 :
    ((STORE_DATA_CAPTURE && raw_drain_unshifted && raw_drain_mask!=4'hf) ?
      raw_drain_data << {raw_drain_addr[1:0],3'b000} : raw_drain_data);

  localparam integer AGE_PAIRS=(D>1)?D*(D-1)/2:1;
  logic [AGE_PAIRS-1:0] age_low_newer, snap_age_low_newer;
  wire [W*32-1:0] age_alloc_seq;
  wire [W*D-1:0] age_alloc_gt,age_alloc_ge;
  generate if(PAIRWISE_AGE)begin:gen_registered_age
    for(genvar lane=0;lane<W;lane=lane+1)begin:gen_age_alloc
      assign age_alloc_seq[lane*32+:32]=seq_base+32'(lane);
      for(genvar slot=0;slot<D;slot=slot+1)begin:gen_age_cmp
        assign age_alloc_gt[lane*D+slot]=age_alloc_seq[lane*32+:32]>seq[slot*32+:32];
        assign age_alloc_ge[lane*D+slot]=age_alloc_seq[lane*32+:32]>=seq[slot*32+:32];
      end
    end
    for(genvar hi=1;hi<D;hi=hi+1)begin:gen_age_hi
      for(genvar lo=0;lo<hi;lo=lo+1)begin:gen_age_lo
        localparam integer P=hi*(hi-1)/2+lo;
        logic next_age,write_age;
        always_comb begin
          next_age=age_low_newer[P];write_age=0;
          for(integer a=0;a<W;a=a+1)begin
            if(alloc_valid[a]&&alloc_id[a*LW+:LW]==LW'(lo))begin next_age=age_alloc_ge[a*D+hi];write_age=1;end
            if(alloc_valid[a]&&alloc_id[a*LW+:LW]==LW'(hi))begin next_age=!age_alloc_gt[a*D+lo];write_age=1;end
          end
          for(integer a=0;a<W;a=a+1)for(integer b=0;b<W;b=b+1)
            if(alloc_valid[a]&&alloc_id[a*LW+:LW]==LW'(lo)&&alloc_valid[b]&&alloc_id[b*LW+:LW]==LW'(hi))
              next_age=age_alloc_seq[a*32+:32]>=age_alloc_seq[b*32+:32];
        end
        always_ff @(posedge clk)begin
          if(reset)age_low_newer[P]<=0;
          else if(alloc_ready&&alloc_fire&&write_age)age_low_newer[P]<=next_age;
        end
      end
    end
  end endgenerate

  // ---- query stage 1: independent comparisons and a coherent snapshot ------
  // 不只保存 slot id：store 可在下一拍释放并复用。候选的 seq/data/full
  // 必须随匹配结果一起保存，直到响应被消费。
  logic [D-1:0] query_match, query_unknown, query_full;
  logic snap_valid, snap_unknown;
  logic [D-1:0] snap_match, snap_full;
  logic [D*32-1:0] snap_seq, snap_data;
  genvar qg;
  generate
    for (qg = 0; qg < D; qg = qg + 1) begin : gen_query_compare
      wire older_store = valid[qg] && is_store[qg] &&
                         (seq[qg*32 +: 32] < query_seq);
      assign query_unknown[qg] = older_store && !addr_known[qg];
      assign query_match[qg] = older_store && addr_known[qg] &&
                               (addr[qg*32+2 +: 30] == query_addr[31:2]);
      assign query_full[qg] = (wstrb[qg*4 +: 4] == 4'b1111) &&
                              (!STORE_DATA_CAPTURE || data_known[qg]);
    end
  endgenerate

  assign query_ready = !snap_valid || query_resp_ready || query_flush;
  assign query_resp_valid = snap_valid;
  always_ff @(posedge clk) begin
    if (reset) begin
      snap_valid <= 1'b0;
      snap_unknown <= 1'b0;
      snap_match <= '0;
      snap_full <= '0;
    end else begin
      // Payload may be sampled whenever the snapshot slot can be replaced.
      // Request validity controls ownership only; stalled live snapshots hold.
      if(query_ready)begin
        if(PAIRWISE_AGE)snap_age_low_newer <= age_low_newer;
        else snap_seq <= seq;
        snap_data <= wdata;
      end
      if (query_resp_ready || query_flush)
        snap_valid <= 1'b0;
      // 新请求可在旧响应消费 / flush 的同拍进入，必须优先保留新快照。
      if (query_valid && query_ready) begin
        snap_valid <= 1'b1;
        snap_unknown <= |query_unknown;
        snap_match <= query_match;
        snap_full <= query_full;

      end
    end
  end

  logic any_unknown,same_found,same_full;
  logic [31:0] same_seq,same_data;
  assign any_unknown=snap_unknown;
  generate if(PAIRWISE_AGE)begin:gen_pairwise_query
    wire [D-1:0] winner;
    for(genvar slot=0;slot<D;slot=slot+1)begin:gen_winner
      wire [D-1:0] beats;
      for(genvar other=0;other<D;other=other+1)begin:gen_beats
        if(other<slot)assign beats[other]=snap_match[other]&&snap_age_low_newer[slot*(slot-1)/2+other];
        else if(other>slot)assign beats[other]=snap_match[other]&&!snap_age_low_newer[other*(other-1)/2+slot];
        else assign beats[other]=0;
      end
      assign winner[slot]=snap_match[slot]&&!(|beats);
    end
    always_comb begin
      same_found=|snap_match;same_full=0;same_data=0;same_seq=0;
      for(integer n=0;n<D;n=n+1)begin
        same_full=same_full||(winner[n]&&snap_full[n]);
        same_data=same_data|(snap_data[n*32+:32]&{32{winner[n]}});
      end
      if(!same_found)begin same_data=snap_data[0+:32];same_full=snap_full[0];end
    end
`ifndef SYNTHESIS
    // Independent full-width scan checks cached order and snapshot ownership.
    logic [D*32-1:0] reference_seq;
    always_ff @(posedge clk)if(!reset&&query_ready)reference_seq<=seq;
    always_ff @(posedge clk)if(!reset&&snap_valid&&query_resp_ready)begin
      automatic integer best=-1;
      automatic logic [31:0] best_seq=0;
      for(integer k=0;k<D;k=k+1)if(snap_match[k]&&
          (best<0||reference_seq[k*32+:32]>best_seq))begin
        best=k;best_seq=reference_seq[k*32+:32];
      end
      if(best<0)begin
        if(winner!='0)$fatal(1,"cached LSQ age selected absent store");
      end else begin
        if(winner!=(D'(1)<<best))$fatal(1,"cached LSQ age differs from full-width scan");
        if(same_data!=snap_data[best*32+:32]||same_full!=snap_full[best])
          $fatal(1,"cached LSQ age selected mismatched snapshot payload");
      end
    end
    always_ff @(posedge clk)if(!reset&&snap_valid)begin
      if(!$onehot0(winner))$fatal(1,"LSQ age snapshot has multiple forwarding winners");
      if((|snap_match)!=(|winner))$fatal(1,"LSQ age snapshot lost matching store");
    end
`endif
  end else begin:gen_sequence_tree
  // ---- query stage 2: balanced youngest-match selection -------------------
  wire qt_valid [0:2*QLEAVES-1] /* verilator split_var */;
  wire qt_full [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] qt_seq [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] qt_data [0:2*QLEAVES-1] /* verilator split_var */;
  assign qt_valid[0] = 1'b0;
  assign qt_full[0] = 1'b0;
  assign qt_seq[0] = '0;
  assign qt_data[0] = '0;
    for (qg = 0; qg < QLEAVES; qg = qg + 1) begin : gen_query_leaf
      if (qg < D) begin : gen_entry
        assign qt_valid[QLEAVES+qg] = snap_match[qg];
        assign qt_full[QLEAVES+qg] = snap_full[qg];
        assign qt_seq[(QLEAVES+qg)] = snap_seq[qg*32 +: 32];
        assign qt_data[(QLEAVES+qg)] = snap_data[qg*32 +: 32];
      end else begin : gen_pad
        assign qt_valid[QLEAVES+qg] = 1'b0;
        assign qt_full[QLEAVES+qg] = 1'b0;
        assign qt_seq[(QLEAVES+qg)] = '0;
        assign qt_data[(QLEAVES+qg)] = '0;
      end
    end
    for (qg = 1; qg < QLEAVES; qg = qg + 1) begin : gen_query_merge
      // 相等 seq 时左侧优先，保持原扫描逻辑的低 slot 优先规则。
      wire take_right = qt_valid[2*qg+1] &&
                         (!qt_valid[2*qg] ||
                          (qt_seq[(2*qg+1)] > qt_seq[2*qg]));
      assign qt_valid[qg] = qt_valid[2*qg] || qt_valid[2*qg+1];
      assign qt_full[qg] = take_right ? qt_full[2*qg+1] : qt_full[2*qg];
      assign qt_seq[qg] = take_right ? qt_seq[(2*qg+1)] :
                                               qt_seq[2*qg];
      assign qt_data[qg] = take_right ? qt_data[(2*qg+1)] :
                                                qt_data[2*qg];
    end


  assign same_found = qt_valid[1];
  assign same_full = qt_full[1];
  assign same_seq = qt_seq[1];
  assign same_data = qt_data[1];
  end endgenerate
  assign query_blocked = snap_valid && (any_unknown || (same_found && !same_full));
  assign query_fwd_valid = snap_valid && !any_unknown && same_found && same_full;
  assign query_fwd_data = same_data;

  // ---- count --------------------------------------------------------------
  always_comb begin
    count = '0;
    for (i_count = 0; i_count < D; i_count = i_count + 1)
      if (valid[i_count]) count = count + 1'b1;
  end

  // ---- sequential ---------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      valid     <= '0;
      addr_known<= '0;
      data_known<= '0;
      data_raw<= '0;
      committed <= '0;
      sent      <= '0;
      sent_head <= '0;
      sent_tail <= '0;
      sent_count<= '0;
      commit_tail<='0;ordered_count<='0;
    end else begin
      // Capture once, before a physical tag can be recycled. Squash and a
      // fresh allocation below override this update for the affected owner.
      if(STORE_DATA_CAPTURE)begin
        for(integer k=0;k<D;k=k+1)begin
          if(valid[k] && is_store[k] && addr_known[k] && !data_known[k] && !squash_mask[k])begin
            for(integer r=0;r<R;r=r+1)
              if(store_cdb[r*CW+`CPU_CDB_VALID_OFF] &&
                 store_cdb[r*CW+`CPU_CDB_TAG_OFF+:PW]==data_tag[k*PW+:PW])begin
                wdata[k*32+:32] <= store_cdb[r*CW+`CPU_CDB_VALUE_OFF+:32];
                data_known[k] <= 1'b1;
              end
          end
        end
      end
      // squash
      for (i = 0; i < D; i = i + 1) begin
        if (squash_mask[i]) begin
          valid[i]      <= 1'b0;
          addr_known[i] <= 1'b0;
          data_known[i] <= 1'b0;
          committed[i]  <= 1'b0;
          sent[i]       <= 1'b0;
        end
      end

      // fill on issue
      if (fill_valid) begin
        addr[fill_id*32 +: 32]      <= fill_addr;
        wdata[fill_id*32 +: 32]     <= fill_wdata;
        wstrb[fill_id*4 +: 4]       <= fill_wstrb;
        is_store[fill_id]           <= fill_is_store;
        addr_known[fill_id]         <= 1'b1;
        data_known[fill_id]         <= 1'b1;
        data_raw[fill_id]           <= 1'b0;
      end

      // address-only fill on issue: data/wstrb 留到 store 真正发射时再填。
      // 必须显式清 wstrb，避免 load 查询把上一位占用者的旧掩码当成有效写。
      if (prefill_valid && valid[prefill_id] && !squash_mask[prefill_id]) begin
        addr[prefill_id*32 +: 32]   <= prefill_addr;
        wdata[prefill_id*32 +: 32]  <= 32'b0;
        wstrb[prefill_id*4 +: 4]    <= STORE_DATA_CAPTURE ? prefill_wstrb : 4'b0;
        data_known[prefill_id] <= STORE_DATA_CAPTURE && prefill_wstrb==0;
        data_tag[prefill_id*PW+:PW] <= prefill_data_tag;
        data_raw[prefill_id] <= STORE_DATA_CAPTURE!=0;
        is_store[prefill_id]        <= 1'b1;
        addr_known[prefill_id]      <= 1'b1;
        if(STORE_DATA_CAPTURE)for(integer r=0;r<R;r=r+1)
          if(store_cdb[r*CW+`CPU_CDB_VALID_OFF] &&
             store_cdb[r*CW+`CPU_CDB_TAG_OFF+:PW]==prefill_data_tag)begin
            wdata[prefill_id*32+:32] <= store_cdb[r*CW+`CPU_CDB_VALUE_OFF+:32];
            data_known[prefill_id] <= 1'b1;
          end
      end

      // commit release / mark
      for (lane = 0; lane < W; lane = lane + 1) begin
        if (commit_valid[lane]) begin
          if (commit_is_load[lane]) begin
            valid[commit_id[lane*LW +: LW]]      <= 1'b0;
            addr_known[commit_id[lane*LW +: LW]] <= 1'b0;
            committed[commit_id[lane*LW +: LW]]  <= 1'b0;
            sent[commit_id[lane*LW +: LW]]       <= 1'b0;
          end else if (commit_is_store[lane]) begin
            committed[commit_id[lane*LW +: LW]] <= 1'b1;
          end
        end
      end

      if(ORDERED_STORE_COMMIT)begin
        for(integer c=0;c<W;c=c+1)
          if(new_commit[c])sent_fifo[commit_position[c]*LW+:LW]<=commit_id[c*LW+:LW];
        commit_tail<=commit_tail+QW'(commit_count);
        ordered_count<=ordered_count+commit_count-FN'(drain_valid&&drain_fire);
      end

      // store drain accepted by memory
      if (drain_valid && drain_fire) begin
        sent[drain_id] <= 1'b1;
        if(!ORDERED_STORE_COMMIT)sent_fifo[sent_tail*LW +: LW] <= drain_id;
        sent_tail  <= (sent_tail == D - 1) ? '0 : sent_tail + 1'b1;
      end

      // store write response: free entry
      if (store_resp_valid && (sent_count != 0)) begin
        valid[sent_fifo[sent_head*LW +: LW]]      <= 1'b0;
        addr_known[sent_fifo[sent_head*LW +: LW]] <= 1'b0;
        committed[sent_fifo[sent_head*LW +: LW]]  <= 1'b0;
        sent[sent_fifo[sent_head*LW +: LW]]       <= 1'b0;
        sent_head  <= (sent_head == D - 1) ? '0 : sent_head + 1'b1;
      end

      sent_count <= sent_count +
                    ((drain_valid && drain_fire) ? 1'b1 : 1'b0) -
                    ((store_resp_valid && (sent_count != 0)) ? 1'b1 : 1'b0);

      // allocation：释放沿后的下一拍才允许新 owner 占用该 id。
      if (alloc_ready && alloc_fire) begin
        for (lane = 0; lane < W; lane = lane + 1) begin
          if (alloc_valid[lane]) begin
            valid[alloc_id[lane*LW +: LW]]      <= 1'b1;
            is_store[alloc_id[lane*LW +: LW]]   <= alloc_is_store[lane];
            rob[alloc_id[lane*LW +: LW]*RW +: RW] <= alloc_rob[lane*RW +: RW];
            seq[alloc_id[lane*LW +: LW]*32 +: 32] <= seq_base + lane;
            addr[alloc_id[lane*LW +: LW]*32 +: 32] <= 32'b0;
            wdata[alloc_id[lane*LW +: LW]*32 +: 32] <= 32'b0;
            wstrb[alloc_id[lane*LW +: LW]*4 +: 4]   <= 4'b0;
            addr_known[alloc_id[lane*LW +: LW]] <= 1'b0;
            data_known[alloc_id[lane*LW +: LW]] <= 1'b0;
            data_raw[alloc_id[lane*LW +: LW]] <= 1'b0;
            committed[alloc_id[lane*LW +: LW]]  <= 1'b0;
            sent[alloc_id[lane*LW +: LW]]       <= 1'b0;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  integer ref_stores,ref_oldest;
  logic [31:0] ref_seq;
  always @(posedge clk)if(!reset && ORDERED_STORE_COMMIT)begin
    ref_stores=0;ref_oldest=-1;ref_seq='1;
    for(integer k=0;k<D;k=k+1)if(valid[k]&&is_store[k]&&committed[k]&&!sent[k])begin
      ref_stores=ref_stores+1;
      if(ref_oldest<0 || seq[k*32+:32]<ref_seq)begin ref_seq=seq[k*32+:32];ref_oldest=k;end
    end
    if(ref_stores!=int'(ordered_count))$fatal(1,"committed store ring count mismatch");
    if(raw_drain_valid && (ref_oldest<0 || raw_drain_id!=LW'(ref_oldest)))
      $fatal(1,"commit ring differs from independent oldest-store selection");
    if(int'(ordered_count)+int'(sent_count)>D)$fatal(1,"committed store ring overflow");
  end
  initial if(ORDERED_STORE_COMMIT && (D&(D-1))!=0)$fatal(1,"ordered store ring requires power-of-two depth");
`endif

`ifdef LOCAL_TRACE
  integer dbg_q = 0;
  always_ff @(posedge clk) begin
    if (!reset && query_resp_valid && query_resp_ready && !query_flush &&
        query_blocked && dbg_q < 20) begin
      $display("[LSQ_BLK] t=%0t unknown=%0b same=%0b full=%0b",
               $time, snap_unknown, same_found, same_full);
      dbg_q <= dbg_q + 1;
    end
  end
`endif

`ifdef LOCAL_STATS
  // 仅仿真统计；默认构建/综合不会实例化这些计数器。
  longint st_cycles, st_query, st_blocked, st_unknown, st_partial, st_fwd;
  longint st_clear, st_alloc, st_full_cycles, st_count_sum;
  integer st_max_count;

  always_ff @(posedge clk) begin
    if (reset) begin
      st_cycles     <= 0;
      st_query      <= 0;
      st_blocked    <= 0;
      st_unknown    <= 0;
      st_partial    <= 0;
      st_fwd        <= 0;
      st_clear      <= 0;
      st_alloc      <= 0;
      st_full_cycles<= 0;
      st_count_sum  <= 0;
      st_max_count  <= 0;
    end else begin
      st_cycles <= st_cycles + 1;
      st_count_sum <= st_count_sum + count;
      if (count > st_max_count) st_max_count <= count;
      if (!alloc_ready) st_full_cycles <= st_full_cycles + 1;
      if (alloc_ready && alloc_fire) st_alloc <= st_alloc + 1;

      if (query_resp_valid && query_resp_ready && !query_flush) begin
        st_query <= st_query + 1;
        if (any_unknown)
          st_unknown <= st_unknown + 1;
        else if (same_found && !same_full)
          st_partial <= st_partial + 1;
        else if (query_fwd_valid)
          st_fwd <= st_fwd + 1;
        else
          st_clear <= st_clear + 1;
      end
      if (query_resp_valid && query_resp_ready && !query_flush && query_blocked) st_blocked <= st_blocked + 1;
    end
  end

  final $fdisplay(32'h80000002,
      "[STATS] LSQ cycles=%0d queries=%0d blocked=%0d unknown=%0d partial=%0d fwd=%0d clear=%0d alloc_fire=%0d full_cycles=%0d count_sum=%0d max_count=%0d",
      st_cycles, st_query, st_blocked, st_unknown, st_partial, st_fwd,
      st_clear, st_alloc, st_full_cycles, st_count_sum, st_max_count);
`endif

endmodule
