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
  output logic                         query_blocked,
  output logic                         query_fwd_valid,
  output logic [31:0]                  query_fwd_data,

  output logic [7:0]                   count
);

  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer QW = (D > 1) ? $clog2(D) : 1;
  localparam integer FN = (D > 1) ? $clog2(D + 1) : 2;

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
  integer i_squash, i_drain, i_query, i_count, lane_count;
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

  // ---- load ordering query + store-to-load forwarding ---------------------
  logic        any_unknown;
  logic        same_found, same_full;
  logic [31:0] same_seq, same_data;

  always_comb begin
    any_unknown  = 1'b0;
    same_found   = 1'b0;
    same_full    = 1'b0;
    same_seq     = 32'b0;
    same_data    = 32'b0;
    for (i_query = 0; i_query < D; i_query = i_query + 1) begin
      if (query_valid && valid[i_query] && is_store[i_query] &&
          (seq[i_query*32 +: 32] < query_seq)) begin
        if (!addr_known[i_query]) begin
          any_unknown = 1'b1;
        end else if ((addr[i_query*32 +: 32] & ~32'h3) ==
                     (query_addr & ~32'h3)) begin
          // 取最年轻的同字 store；整字写可直接前递。
          if (!same_found || (seq[i_query*32 +: 32] > same_seq)) begin
            same_found = 1'b1;
            same_seq   = seq[i_query*32 +: 32];
            same_full  = (wstrb[i_query*4 +: 4] == 4'b1111);
            same_data  = wdata[i_query*32 +: 32];
          end
        end
      end
    end
    query_blocked   = any_unknown || (same_found && !same_full);
    query_fwd_valid = !any_unknown && same_found && same_full;
    query_fwd_data  = same_data;
  end

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
    if (!reset && query_valid && query_blocked && dbg_q < 20) begin
      for (i = 0; i < D; i = i + 1)
        if (valid[i] && is_store[i] && (seq[i*32 +: 32] < query_seq))
          $display("[LSQ_BLK] t=%0t qseq=%0d slot=%0d seq=%0d known=%0b addr=%08x committed=%0b sent=%0b",
                   $time, query_seq, i, seq[i*32 +: 32], addr_known[i],
                   addr[i*32 +: 32], committed[i], sent[i]);
      dbg_q <= dbg_q + 1;
    end
  end
`endif

endmodule
