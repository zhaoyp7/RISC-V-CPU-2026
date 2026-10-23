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
  parameter integer D = `CPU_LSQ_DEPTH
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
  logic [D-1:0]    committed;
  logic [D-1:0]    sent;

  // sent FIFO：记录已发往内存但尚未收到写响应的 store id
  logic [D*LW-1:0] sent_fifo;
  logic [QW-1:0]   sent_head, sent_tail;
  logic [FN-1:0]   sent_count;

  integer i, lane;
  integer i_commit, lane_commit;
  integer i_free, lane_free;
  integer i_squash, i_drain, i_count, lane_count;
  logic [`CPU_LSQ_IDX_W-1:0] id;

  // ---- allocation ---------------------------------------------------------
  logic [D-1:0] free_by_commit;
  logic [D-1:0] free_by_resp;
  logic [D-1:0] free_mask;
  logic [D-1:0] alloc_used;
  logic         alloc_ok;
  logic         commit_hit;

  always_comb begin
    free_by_commit = '0;
    for (i_commit = 0; i_commit < D; i_commit = i_commit + 1) begin
      commit_hit = 1'b0;
      for (lane_commit = 0; lane_commit < W; lane_commit = lane_commit + 1) begin
        if (commit_valid[lane_commit] && commit_is_load[lane_commit] &&
            (commit_id[lane_commit*LW +: LW] == i_commit[LW-1:0]))
          commit_hit = 1'b1;
      end
      free_by_commit[i_commit] = commit_hit;
    end
  end

  // 写响应释放表项（按序 FIFO 头部）
  always_comb begin
    free_by_resp = '0;
    if (store_resp_valid && (sent_count != 0))
      free_by_resp[sent_fifo[sent_head*LW +: LW]] = 1'b1;
  end

  always_comb begin
    free_mask = '0;
    for (i_free = 0; i_free < D; i_free = i_free + 1)
      free_mask[i_free] = !valid[i_free] || free_by_commit[i_free] ||
                          free_by_resp[i_free];

    alloc_ok = 1'b1;
    alloc_used = '0;
    id = '0;
    for (lane_free = 0; lane_free < W; lane_free = lane_free + 1) begin
      if (alloc_valid[lane_free]) begin
        id = alloc_id[lane_free*LW +: LW];
        if (!free_mask[id] || alloc_used[id])
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
  logic [31:0] best_seq;
  logic [`CPU_LSQ_IDX_W-1:0] best_id;
  logic        found;

  always_comb begin
    drain_valid = 1'b0;
    drain_id    = '0;
    drain_addr  = 32'b0;
    drain_wdata = 32'b0;
    drain_wstrb = 4'b0;
    best_seq    = 32'hffff_ffff;
    best_id     = '0;
    found       = 1'b0;
    for (i_drain = 0; i_drain < D; i_drain = i_drain + 1) begin
      if (valid[i_drain] && is_store[i_drain] && committed[i_drain] &&
          !sent[i_drain]) begin
        if (!found || (seq[i_drain*32 +: 32] < best_seq)) begin
          found       = 1'b1;
          best_seq    = seq[i_drain*32 +: 32];
          best_id     = i_drain[LW-1:0];
        end
      end
    end
    if (found) begin
      drain_valid = 1'b1;
      drain_id    = best_id;
      drain_addr  = addr[best_id*32 +: 32];
      drain_wdata = wdata[best_id*32 +: 32];
      drain_wstrb = wstrb[best_id*4 +: 4];
    end
  end

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
      assign query_full[qg] = (wstrb[qg*4 +: 4] == 4'b1111);
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
      if (query_resp_ready || query_flush)
        snap_valid <= 1'b0;
      // 新请求可在旧响应消费 / flush 的同拍进入，必须优先保留新快照。
      if (query_valid && query_ready) begin
        snap_valid <= 1'b1;
        snap_unknown <= |query_unknown;
        snap_match <= query_match;
        snap_full <= query_full;
        snap_seq <= seq;
        snap_data <= wdata;
      end
    end
  end

  // ---- query stage 2: balanced youngest-match selection -------------------
  wire qt_valid [0:2*QLEAVES-1] /* verilator split_var */;
  wire qt_full [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] qt_seq [0:2*QLEAVES-1] /* verilator split_var */;
  wire [31:0] qt_data [0:2*QLEAVES-1] /* verilator split_var */;
  assign qt_valid[0] = 1'b0;
  assign qt_full[0] = 1'b0;
  assign qt_seq[0] = '0;
  assign qt_data[0] = '0;
  generate
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
  endgenerate

  logic        any_unknown;
  logic        same_found, same_full;
  logic [31:0] same_seq, same_data;

  assign any_unknown = snap_unknown;
  assign same_found = qt_valid[1];
  assign same_full = qt_full[1];
  assign same_seq = qt_seq[1];
  assign same_data = qt_data[1];
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
      committed <= '0;
      sent      <= '0;
      sent_head <= '0;
      sent_tail <= '0;
      sent_count<= '0;
    end else begin
      // squash
      for (i = 0; i < D; i = i + 1) begin
        if (squash_mask[i]) begin
          valid[i]      <= 1'b0;
          addr_known[i] <= 1'b0;
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
      end

      // address-only fill on issue: data/wstrb 留到 store 真正发射时再填。
      // 必须显式清 wstrb，避免 load 查询把上一位占用者的旧掩码当成有效写。
      if (prefill_valid && valid[prefill_id] && !squash_mask[prefill_id]) begin
        addr[prefill_id*32 +: 32]   <= prefill_addr;
        wdata[prefill_id*32 +: 32]  <= 32'b0;
        wstrb[prefill_id*4 +: 4]    <= 4'b0;
        is_store[prefill_id]        <= 1'b1;
        addr_known[prefill_id]      <= 1'b1;
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

      // store drain accepted by memory
      if (drain_valid && drain_fire) begin
        sent[drain_id] <= 1'b1;
        sent_fifo[sent_tail*LW +: LW] <= drain_id;
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

      // allocation (last, so a freed id can be reused immediately)
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
            committed[alloc_id[lane*LW +: LW]]  <= 1'b0;
            sent[alloc_id[lane*LW +: LW]]       <= 1'b0;
          end
        end
      end
    end
  end

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
