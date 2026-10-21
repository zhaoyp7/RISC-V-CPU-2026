// -----------------------------------------------------------------------------
// lsu.sv — load/store 执行单元 v2（流水化）
//
// load：
//   - 从 IQ 接收一条 load，地址消歧通过后立即发到 mem_subsystem；
//   - 最多 LDQ_DEPTH 笔在途，元数据按序入队；响应按序返回并格式化；
//   - 结果进入结果 FIFO，经 CDB 写回；
//   - squash 按 seq 标记丢弃；已发出的请求等响应到达后静默丢弃。
// store：
//   - issue 时填 LSQ 并立即发 complete（提交前不写内存）；
//   - commit 后由 LSQ 按序 drain 到 store 流；写响应返回后释放 LSQ 表项；
//   - 写请求/响应都是流水线，不再一次只等一个 store。
// -----------------------------------------------------------------------------

module lsu #(
  parameter integer W         = `CPU_ISSUE_WIDTH,
  parameter integer LDQ_DEPTH = 8
) (
  input  logic clk,
  input  logic reset,

  // dispatch allocation (from backend, driven by dispatch lanes)
  input  logic [W-1:0]                 alloc_valid,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  alloc_id,
  input  logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob,
  input  logic [W-1:0]                 alloc_is_store,
  output logic                         alloc_ready,
  input  logic                         alloc_fire,
  input  logic [31:0]                  seq_base,
  input  logic [31:0]                  squash_seq,

  // issue from IQ (single lane)
  input  logic                         issue_valid,
  input  logic [`CPU_DISPATCH_W-1:0]   issue_uop,
  input  logic [31:0]                  issue_seq,
  input  logic [31:0]                  issue_src1,
  input  logic [31:0]                  issue_src2,
  output logic                         issue_ready,

  // commit
  input  logic [W-1:0]                 commit_valid,
  input  logic [W-1:0]                 commit_is_store,
  input  logic [W-1:0]                 commit_is_load,
  input  logic [W*`CPU_LSQ_IDX_W-1:0]  commit_id,

  // squash
  input  logic                         squash_valid,
  input  logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,

  // load result (goes to CDB)
  output logic                         load_result_valid,
  output logic [`CPU_PRF_IDX_W-1:0]    load_result_tag,
  output logic [31:0]                  load_result_value,
  output logic                         load_result_exception,
  input  logic                         load_result_ready,

  // store complete (goes to complete bus)
  output logic                         store_complete_valid,
  output logic [`CPU_PRF_IDX_W-1:0]    store_complete_tag,
  output logic                         store_complete_exception,

  // pipelined load memory interface
  output logic                         ld_req_valid,
  output logic [31:0]                  ld_req_addr,
  input  logic                         ld_req_ready,
  input  logic                         ld_resp_valid,
  input  logic [31:0]                  ld_resp_rdata,

  // store invalidation for the read-only D-Cache
  output logic                         st_inv_valid,
  output logic [31:0]                  st_inv_addr,

  // pipelined store memory interface
  output logic                         st_req_valid,
  output logic [31:0]                  st_req_addr,
  output logic [31:0]                  st_req_wdata,
  output logic [3:0]                   st_req_wstrb,
  input  logic                         st_req_ready,
  input  logic                         st_resp_valid,

  output logic                         busy
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer DW = `CPU_DISPATCH_W;
  localparam integer MDW = (LDQ_DEPTH > 1) ? $clog2(LDQ_DEPTH) : 1;

  // ---- issue uop 解包 ------------------------------------------------------
  logic [31:0] issue_pc, issue_imm, issue_inst;
  logic [PW-1:0] issue_dest;
  logic [LW-1:0] issue_lsq;
  logic [RW-1:0] issue_rob;
  logic [1:0]  issue_mem_size;
  logic        issue_mem_unsigned;
  logic        issue_is_load, issue_is_store, issue_illegal;
  logic [31:0] issue_addr;

  assign issue_pc           = issue_uop[`CPU_DISPATCH_PC_OFF +: 32];
  assign issue_inst         = issue_uop[`CPU_DISPATCH_INST_OFF +: 32];
  assign issue_imm          = issue_uop[`CPU_DISPATCH_IMM_OFF +: 32];
  assign issue_dest         = issue_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign issue_lsq          = issue_uop[`CPU_DISPATCH_LSQ_ID_OFF +: LW];
  assign issue_rob          = issue_uop[`CPU_DISPATCH_ROB_IDX_OFF +: RW];
  assign issue_mem_size     = issue_uop[`CPU_DISPATCH_MEM_SIZE_OFF +: 2];
  assign issue_mem_unsigned = issue_uop[`CPU_DISPATCH_MEM_UNSIGNED_OFF];
  assign issue_is_load      = issue_uop[`CPU_DISPATCH_IS_LOAD_OFF];
  assign issue_is_store     = issue_uop[`CPU_DISPATCH_IS_STORE_OFF];
  assign issue_illegal      = issue_uop[`CPU_DISPATCH_ILLEGAL_OFF];
  assign issue_addr         = issue_src1 + issue_imm;

  // ---- 写掩码 / 写数据 ----------------------------------------------------
  function automatic [3:0] make_wstrb(input logic [1:0] size,
                                      input logic [1:0] off);
    begin
      case (size)
        `SZ_BYTE: make_wstrb = 4'b0001 << off;
        `SZ_HALF: make_wstrb = off[1] ? 4'b1100 : 4'b0011;
        default:  make_wstrb = 4'b1111;
      endcase
    end
  endfunction

  logic [3:0]  issue_wstrb;
  logic [31:0] issue_wdata;

  assign issue_wstrb = make_wstrb(issue_mem_size, issue_addr[1:0]);
  assign issue_wdata = (issue_mem_size == `SZ_WORD) ? issue_src2 :
                       (issue_src2 << (8 * issue_addr[1:0]));

  // ---- load 数据格式化 ----------------------------------------------------
  function automatic [31:0] format_load(input logic [31:0] word,
                                        input logic [1:0] size,
                                        input logic [1:0] off,
                                        input logic unsigned_load);
    logic [31:0] shifted;
    begin
      shifted = word >> (8 * off);
      case (size)
        `SZ_BYTE: format_load = unsigned_load ? {24'b0, shifted[7:0]} :
                                                {{24{shifted[7]}}, shifted[7:0]};
        `SZ_HALF: format_load = unsigned_load ? {16'b0, shifted[15:0]} :
                                                {{16{shifted[15]}}, shifted[15:0]};
        default:  format_load = word;
      endcase
    end
  endfunction

  // ---- load 元数据 / 结果队列索引 ----------------------------------------
  logic [MDW-1:0]              md_head, md_tail;
  logic [MDW:0]                ld_count;
  logic [LDQ_DEPTH-1:0]        md_valid;
  logic [LDQ_DEPTH*PW-1:0]     md_tag;
  logic [LDQ_DEPTH*32-1:0]     md_seq;
  logic [LDQ_DEPTH*LW-1:0]     md_lsq;
  logic [LDQ_DEPTH*2-1:0]      md_off;
  logic [LDQ_DEPTH*2-1:0]      md_size;
  logic [LDQ_DEPTH-1:0]        md_unsigned;
  logic [LDQ_DEPTH-1:0]        md_discard;

  logic [MDW-1:0]              rq_head, rq_tail;
  logic [MDW:0]                rq_count;
  logic [LDQ_DEPTH-1:0]        rq_valid;
  logic [LDQ_DEPTH*PW-1:0]     rq_tag;
  logic [LDQ_DEPTH*32-1:0]     rq_value;
  logic [LDQ_DEPTH*32-1:0]     rq_seq;
  logic [LDQ_DEPTH-1:0]        rq_exc;
  logic [LDQ_DEPTH-1:0]        rq_discard;

  // ---- LSQ 查询 -----------------------------------------------------------
  logic lsq_query_blocked;
  logic lsq_query_fwd_valid;
  logic [31:0] lsq_query_fwd_data;
  logic query_blocked;
  logic ld_fwd;
  logic [31:0] ld_fwd_data;
  assign query_blocked = issue_is_load && !issue_illegal && lsq_query_blocked;
  assign ld_fwd        = issue_is_load && !issue_illegal &&
                         !lsq_query_blocked && lsq_query_fwd_valid;
  assign ld_fwd_data   = lsq_query_fwd_data;

  // ---- issue 握手 ---------------------------------------------------------
  logic ld_space;
  logic illegal_slot_ok;

  assign ld_space = (ld_count < LDQ_DEPTH);

  always_comb begin
    issue_ready = 1'b1;
    if (issue_is_load) begin
      if (issue_illegal) begin
        // 非法 load 走结果队列，不能和已有响应同拍压入。
        issue_ready = illegal_slot_ok;
      end else if (ld_fwd) begin
        // 同地址整字 store 前递：不访问内存，直接产生结果。
        issue_ready = illegal_slot_ok;
      end else begin
        issue_ready = !query_blocked && ld_space && ld_req_ready;
      end
    end
  end

  logic load_issue, store_issue;
  assign load_issue  = issue_valid && issue_ready && issue_is_load;
  assign store_issue = issue_valid && issue_ready && issue_is_store;

  assign ld_req_valid = load_issue && !issue_illegal && !ld_fwd;
  assign ld_req_addr  = issue_addr;

  // ---- store 流 -----------------------------------------------------------
  logic        drain_valid;
  logic [LW-1:0] drain_id;
  logic [31:0] drain_addr, drain_wdata;
  logic [3:0]  drain_wstrb;
  logic        drain_fire;

  assign st_inv_valid = store_issue;
  assign st_inv_addr  = issue_addr;

  assign st_req_valid = drain_valid;
  assign st_req_addr  = drain_addr;
  assign st_req_wdata = drain_wdata;
  assign st_req_wstrb = drain_wstrb;
  assign drain_fire   = drain_valid && st_req_ready;

  // ---- LSQ ----------------------------------------------------------------
  logic [7:0] lsq_count;

  lsq #(.W(W)) u_lsq (
    .clk             (clk),
    .reset           (reset),
    .alloc_valid     (alloc_valid),
    .alloc_id        (alloc_id),
    .alloc_rob       (alloc_rob),
    .alloc_is_store  (alloc_is_store),
    .alloc_ready     (alloc_ready),
    .alloc_fire      (alloc_fire),
    .seq_base        (seq_base),
    .squash_seq      (squash_seq),
    .fill_valid      (load_issue || store_issue),
    .fill_id         (issue_lsq),
    .fill_addr       (issue_addr),
    .fill_wdata      (issue_wdata),
    .fill_wstrb      (issue_illegal ? 4'b0 : issue_wstrb),
    .fill_is_store   (issue_is_store),
    .commit_valid    (commit_valid),
    .commit_is_store (commit_is_store),
    .commit_is_load  (commit_is_load),
    .commit_id       (commit_id),
    .squash_valid    (squash_valid),
    .drain_valid     (drain_valid),
    .drain_id        (drain_id),
    .drain_addr      (drain_addr),
    .drain_wdata     (drain_wdata),
    .drain_wstrb     (drain_wstrb),
    .drain_fire      (drain_fire),
    .store_resp_valid(st_resp_valid),
    .query_valid     (issue_is_load && !issue_illegal),
    .query_seq       (issue_seq),
    .query_addr      (issue_addr),
    .query_blocked   (lsq_query_blocked),
    .query_fwd_valid (lsq_query_fwd_valid),
    .query_fwd_data  (lsq_query_fwd_data),
    .count           (lsq_count)
  );

  // ---- 本拍结果入队条件 ---------------------------------------------------
  logic md_resp_fire;
  logic md_resp_keep;
  logic rq_push;
  logic rq_pop;

  assign md_resp_fire = ld_resp_valid && (ld_count != 0);
  assign md_resp_keep = md_resp_fire && !md_discard[md_head] &&
                        !(squash_valid &&
                          (md_seq[md_head*32 +: 32] > squash_seq));
  assign rq_push = md_resp_keep ||
                   (load_issue && (issue_illegal || ld_fwd));
  assign rq_pop  = (rq_count != 0) &&
                   (rq_discard[rq_head] || load_result_ready);

  // 非法 load 与已有响应同拍会需要两个结果写口，直接延后一拍。
  // （load issue 需要 issue_valid，响应同拍只会发生在该 load 已入 IQ 后）
  assign illegal_slot_ok = !md_resp_fire;

  // ---- 结果输出 -----------------------------------------------------------
  assign load_result_valid     = (rq_count != 0) && !rq_discard[rq_head] &&
                                 !(squash_valid &&
                                   (rq_seq[rq_head*32 +: 32] > squash_seq));
  assign load_result_tag       = rq_tag[rq_head*PW +: PW];
  assign load_result_value     = rq_value[rq_head*32 +: 32];
  assign load_result_exception = rq_exc[rq_head];

  // ---- store complete -----------------------------------------------------
  logic                         store_complete_valid_q;
  logic [PW-1:0]                store_complete_tag_q;
  logic                         store_complete_exc_q;

  assign store_complete_valid     = store_complete_valid_q;
  assign store_complete_tag       = store_complete_tag_q;
  assign store_complete_exception = store_complete_exc_q;

  assign busy = (ld_count != 0) || (rq_count != 0) || (lsq_count != 0);

  // ---- 时序 ---------------------------------------------------------------
  integer i;

  always_ff @(posedge clk) begin
    if (reset) begin
      md_valid      <= '0;
      md_discard    <= '0;
      md_head       <= '0;
      md_tail       <= '0;
      ld_count      <= '0;
      rq_valid      <= '0;
      rq_discard    <= '0;
      rq_head       <= '0;
      rq_tail       <= '0;
      rq_count      <= '0;
      store_complete_valid_q <= 1'b0;
    end else begin
      store_complete_valid_q <= 1'b0;

      // ---- load issue：入元数据队列 --------------------------------------
      if (load_issue && !issue_illegal && !ld_fwd) begin
        md_valid[md_tail]         <= 1'b1;
        md_tag[md_tail*PW +: PW]  <= issue_dest;
        md_seq[md_tail*32 +: 32]  <= issue_seq;
        md_lsq[md_tail*LW +: LW]  <= issue_lsq;
        md_off[md_tail*2 +: 2]    <= issue_addr[1:0];
        md_size[md_tail*2 +: 2]   <= issue_mem_size;
        md_unsigned[md_tail]      <= issue_mem_unsigned;
        md_discard[md_tail]       <= 1'b0;
        md_tail <= (md_tail == LDQ_DEPTH - 1) ? '0 : md_tail + 1'b1;
      end

      // ---- load response：出队、格式化、入结果队列 ------------------------
      if (md_resp_fire)
        md_head <= (md_head == LDQ_DEPTH - 1) ? '0 : md_head + 1'b1;

      if (rq_push) begin
        rq_valid[rq_tail]          <= 1'b1;
        rq_tag[rq_tail*PW +: PW]   <= (load_issue && (issue_illegal || ld_fwd)) ?
                                      issue_dest : md_tag[md_head*PW +: PW];
        rq_value[rq_tail*32 +: 32] <=
            (load_issue && issue_illegal) ? 32'b0 :
            (load_issue && ld_fwd) ?
              format_load(ld_fwd_data, issue_mem_size, issue_addr[1:0],
                          issue_mem_unsigned) :
              format_load(ld_resp_rdata, md_size[md_head*2 +: 2],
                          md_off[md_head*2 +: 2], md_unsigned[md_head]);
        rq_seq[rq_tail*32 +: 32]   <= (load_issue && (issue_illegal || ld_fwd)) ?
                                      issue_seq : md_seq[md_head*32 +: 32];
        rq_exc[rq_tail]            <= load_issue && issue_illegal;
        rq_discard[rq_tail]        <= squash_valid &&
                                      (((load_issue && (issue_illegal || ld_fwd)) ?
                                        issue_seq : md_seq[md_head*32 +: 32])
                                       > squash_seq);
        rq_tail <= (rq_tail == LDQ_DEPTH - 1) ? '0 : rq_tail + 1'b1;
      end

      // ---- 结果队列出队 ---------------------------------------------------
      if (rq_pop)
        rq_head <= (rq_head == LDQ_DEPTH - 1) ? '0 : rq_head + 1'b1;

      // ---- squash：标记年轻条目 ------------------------------------------
      if (squash_valid) begin
        for (i = 0; i < LDQ_DEPTH; i = i + 1) begin
          if (md_valid[i] && (md_seq[i*32 +: 32] > squash_seq))
            md_discard[i] <= 1'b1;
          if (rq_valid[i] && (rq_seq[i*32 +: 32] > squash_seq))
            rq_discard[i] <= 1'b1;
        end
      end

      // ---- 计数 -----------------------------------------------------------
      ld_count <= ld_count +
                  ((load_issue && !issue_illegal && !ld_fwd) ? 1'b1 : 1'b0) -
                  (md_resp_fire ? 1'b1 : 1'b0);
      rq_count <= rq_count + (rq_push ? 1'b1 : 1'b0) -
                             (rq_pop  ? 1'b1 : 1'b0);

      // ---- store complete -------------------------------------------------
      if (store_issue) begin
        store_complete_valid_q <= !(squash_valid && (issue_seq > squash_seq));
        store_complete_tag_q   <= issue_dest;
        store_complete_exc_q   <= issue_illegal;
      end
    end
  end

`ifdef LOCAL_TRACE
  integer dbg_stalls = 0;
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (issue_is_load && !issue_ready && dbg_stalls < 20) begin
        $display("[LSU_STALL] t=%0t pc=%08x ld_count=%0d rq=%0d qblk=%0b ld_rdy=%0b lsq=%0d drv=%0b",
                 $time, issue_pc, ld_count, rq_count, lsq_query_blocked,
                 ld_req_ready, lsq_count, drain_valid);
        dbg_stalls <= dbg_stalls + 1;
      end
      if (drain_valid && drain_fire)
        $display("[LSU_ST_SEND] t=%0t id=%0d addr=%08x", $time, drain_id, drain_addr);
      if (st_resp_valid)
        $display("[LSU_ST_RESP] t=%0t", $time);
      if (ld_resp_valid)
        $display("[LSU_LD_RESP] t=%0t head=%0d cnt=%0d", $time, md_head, ld_count);
    end
  end
`endif

endmodule
