// -----------------------------------------------------------------------------
// lsu.sv — load/store 执行单元 v2（流水化）
//
// load：
//   - IQ 接收后进入按 LSQ id 预留槽位的等待表，地址已在入口计算；
//   - 按年龄选择 -> 查询寄存器 -> LSQ 匹配快照 -> 前递选择/请求；阻塞的 load 留表重试；
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
  input  logic                         issue_addr_only,
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
  localparam integer LP_DEPTH = `CPU_LSQ_DEPTH;
  localparam integer LP_LEAVES = 1 << $clog2(LP_DEPTH);

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
  // 4-bit 局部和并行预计算；8 组进位用三级前缀合并，避免跨32位串行传播。
  // 结果仍是模 2^32 的 src1+imm，不增加访存级或改变接收时机。
  function automatic [31:0] address_add(input logic [31:0] a,
                                       input logic [31:0] b);
    logic [4:0] sum0 [0:7];
    logic [3:0] sum1 [1:7];
    logic [7:0] group_p [0:3], group_g [0:3];
    integer block_idx, level_idx;
    begin
      for (block_idx = 0; block_idx < 8; block_idx = block_idx + 1) begin
        sum0[block_idx] = {1'b0,a[block_idx*4 +: 4]} +
                          {1'b0,b[block_idx*4 +: 4]};
        if (block_idx != 0)
          sum1[block_idx] = a[block_idx*4 +: 4] + b[block_idx*4 +: 4] + 4'd1;
        group_p[0][block_idx] = &(a[block_idx*4 +: 4] ^ b[block_idx*4 +: 4]);
        group_g[0][block_idx] = sum0[block_idx][4];
      end
      for (level_idx = 0; level_idx < 3; level_idx = level_idx + 1) begin
        for (block_idx = 0; block_idx < 8; block_idx = block_idx + 1) begin
          if (block_idx >= (1 << level_idx)) begin
            group_g[level_idx+1][block_idx] = group_g[level_idx][block_idx] |
                (group_p[level_idx][block_idx] &
                 group_g[level_idx][block_idx-(1 << level_idx)]);
            group_p[level_idx+1][block_idx] = group_p[level_idx][block_idx] &
                 group_p[level_idx][block_idx-(1 << level_idx)];
          end else begin
            group_g[level_idx+1][block_idx] = group_g[level_idx][block_idx];
            group_p[level_idx+1][block_idx] = group_p[level_idx][block_idx];
          end
        end
      end
      address_add[3:0] = sum0[0][3:0];
      for (block_idx = 1; block_idx < 8; block_idx = block_idx + 1)
        address_add[block_idx*4 +: 4] = group_g[3][block_idx-1] ?
                                       sum1[block_idx] : sum0[block_idx][3:0];
    end
  endfunction
  assign issue_addr = address_add(issue_src1, issue_imm);

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

  // ---- 待执行 load：每个已分配 LSQ id 有独立槽位 ---------------------------
  // 不按入队顺序排 FIFO：老 load 可能比年轻 load 更晚就绪。按 LSQ id 保留
  // 容量，保证其入队不依赖年轻 load 先完成，避免 load -> store -> load 死锁。
  logic [LP_DEPTH-1:0]        lp_valid;
  logic [LP_DEPTH*32-1:0]     lp_addr, lp_seq;
  logic [LP_DEPTH*PW-1:0]     lp_tag;
  logic [LP_DEPTH*2-1:0]      lp_size;
  logic [LP_DEPTH-1:0]        lp_unsigned, lp_illegal;
  logic                      lp_select_valid;
  logic [LW-1:0]             lp_select_id;
  logic [31:0]               lp_best_seq;
  integer                    lp_squash_i;

  logic                      q_valid, q_squashed, q_active, q_accept;
  logic [LW-1:0]             q_id;
  logic [31:0]               q_addr, q_seq;
  logic [PW-1:0]             q_tag;
  logic [1:0]                q_size;
  logic                      q_unsigned, q_illegal;
  // r 元数据与 LSQ 匹配快照同拍捕获；完整响应被消费前保持不变。
  logic                      r_valid, r_squashed, r_active, r_accept;
  logic [LW-1:0]             r_id;
  logic [31:0]               r_addr, r_seq;
  logic [PW-1:0]             r_tag;
  logic [1:0]                r_size;
  logic                      r_unsigned, r_illegal;
  logic                      lsq_query_ready, lsq_query_resp_valid, query_send;
  logic                      query_ready, load_enqueue;

  assign q_squashed = q_valid && squash_valid && (q_seq > squash_seq);
  assign q_active = q_valid && !q_squashed;
  assign query_send = q_active && lsq_query_ready;
  assign r_squashed = r_valid && squash_valid && (r_seq > squash_seq);
  assign r_active = r_valid && !r_squashed && lsq_query_resp_valid;

  // 平衡最老选择：候选仅携带 valid/seq/id，元数据仍由获胜 id 读取。
  // 左子树覆盖低 id，相等 seq 时保留左侧，保持旧扫描的优先规则。
  wire lp_tree_valid [0:2*LP_LEAVES-1] /* verilator split_var */;
  wire [31:0] lp_tree_seq [0:2*LP_LEAVES-1] /* verilator split_var */;
  wire [LW-1:0] lp_tree_id [0:2*LP_LEAVES-1] /* verilator split_var */;
  assign lp_tree_valid[0] = 1'b0;
  assign lp_tree_seq[0] = '0;
  assign lp_tree_id[0] = '0;
  generate
    for (genvar g = 0; g < LP_LEAVES; g = g + 1) begin : gen_lp_leaf
      if (g < LP_DEPTH) begin : gen_entry
        assign lp_tree_valid[LP_LEAVES+g] = lp_valid[g] &&
            !(q_valid && (q_id == LW'(g))) &&
            !(r_valid && (r_id == LW'(g))) &&
            !(squash_valid && (lp_seq[g*32 +: 32] > squash_seq));
        assign lp_tree_seq[LP_LEAVES+g] = lp_seq[g*32 +: 32];
        assign lp_tree_id[LP_LEAVES+g] = LW'(g);
      end else begin : gen_pad
        assign lp_tree_valid[LP_LEAVES+g] = 1'b0;
        assign lp_tree_seq[LP_LEAVES+g] = '0;
        assign lp_tree_id[LP_LEAVES+g] = '0;
      end
    end
    for (genvar g = 1; g < LP_LEAVES; g = g + 1) begin : gen_lp_merge
      wire take_right = lp_tree_valid[2*g+1] &&
                         (!lp_tree_valid[2*g] ||
                          lp_tree_seq[2*g+1] < lp_tree_seq[2*g]);
      assign lp_tree_valid[g] = lp_tree_valid[2*g] || lp_tree_valid[2*g+1];
      assign lp_tree_seq[g] = take_right ? lp_tree_seq[2*g+1] : lp_tree_seq[2*g];
      assign lp_tree_id[g] = take_right ? lp_tree_id[2*g+1] : lp_tree_id[2*g];
    end
  endgenerate
  assign lp_select_valid = lp_tree_valid[1];
  assign lp_select_id = lp_tree_valid[1] ? lp_tree_id[1] : '0;
  assign lp_best_seq = lp_tree_valid[1] ? lp_tree_seq[1] : 32'hffff_ffff;

  // ---- LSQ 查询 -----------------------------------------------------------
  logic lsq_query_blocked;
  logic lsq_query_fwd_valid;
  logic [31:0] lsq_query_fwd_data;
  logic query_blocked;
  logic ld_fwd;
  logic [31:0] ld_fwd_data;
  assign query_blocked = r_active && !r_illegal && lsq_query_blocked;
  assign ld_fwd        = r_active && !r_illegal &&
                         !lsq_query_blocked && lsq_query_fwd_valid;
  assign ld_fwd_data   = lsq_query_fwd_data;

  // ---- issue 握手 ---------------------------------------------------------
  logic ld_space;
  logic illegal_slot_ok;
  logic [MDW+1:0] result_credits_used;
  logic result_space;

  // 每笔已发送请求都保留一个未来结果槽；CDB 停顿时也不能把 rq 写满后覆盖。
  assign result_credits_used = {1'b0, ld_count} + {1'b0, rq_count};
  assign result_space = (result_credits_used < LDQ_DEPTH);
  assign ld_space = (ld_count < LDQ_DEPTH) && result_space;
  // input ready 只表示等待表已接收，不能依赖当前 load 的 LSQ 查询结果。
  assign issue_ready = !issue_is_load || !lp_valid[issue_lsq];
  assign load_enqueue = issue_valid && issue_ready && issue_is_load &&
                         !(squash_valid && (issue_seq > squash_seq));

  always_comb begin
    query_ready = 1'b0;
    if (r_active) begin
      if (r_illegal) begin
        // 非法 load 走结果队列，不能和已有响应同拍压入。
        query_ready = illegal_slot_ok;
      end else if (ld_fwd) begin
        // 同地址整字 store 前递：不访问内存，直接产生结果。
        query_ready = illegal_slot_ok;
      end else begin
        query_ready = !query_blocked && ld_space && ld_req_ready;
      end
    end
  end

  logic load_issue, store_issue, store_addr_issue;
  assign load_issue       = r_active && query_ready;
  assign store_addr_issue = issue_valid && issue_ready && issue_is_store &&
                            issue_addr_only;
  assign store_issue      = issue_valid && issue_ready && issue_is_store &&
                            !issue_addr_only;

  assign ld_req_valid = r_active && !r_illegal && !query_blocked && !ld_fwd && ld_space;
  assign ld_req_addr  = r_addr;

  // 消歧阻塞时释放查询级，但不删除等待表项；内存 valid 等待 ready 时保留
  // 查询级，保证请求地址稳定。store 始终能通过独立入口填入 LSQ。
  assign r_accept = !r_valid || r_squashed || query_blocked || load_issue;
  assign q_accept = !q_valid || q_squashed || query_send;

  // address-only：只把 store 地址写进 LSQ，不产生 complete，也不触发写。
  logic        prefill_valid;
  logic [LW-1:0] prefill_id;
  logic [31:0] prefill_addr;
  assign prefill_valid = store_addr_issue;
  assign prefill_id    = issue_lsq;
  assign prefill_addr  = issue_addr;

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
    .fill_valid      (load_enqueue || store_issue),
    .fill_id         (issue_lsq),
    .fill_addr       (issue_addr),
    .fill_wdata      (issue_wdata),
    .fill_wstrb      (issue_illegal ? 4'b0 : issue_wstrb),
    .fill_is_store   (issue_is_store),
    .prefill_valid   (prefill_valid),
    .prefill_id      (prefill_id),
    .prefill_addr    (prefill_addr),
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
    .query_valid     (q_active),
    .query_seq       (q_seq),
    .query_addr      (q_addr),
    .query_ready     (lsq_query_ready),
    .query_resp_valid(lsq_query_resp_valid),
    .query_resp_ready(r_accept),
    .query_flush     (r_squashed),
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
  logic response_bypass_valid, response_bypass_fire;

  assign md_resp_fire = ld_resp_valid && (ld_count != 0);
  assign md_resp_keep = md_resp_fire && !md_discard[md_head] &&
                        !(squash_valid &&
                          (md_seq[md_head*32 +: 32] > squash_seq));
  // Empty result FIFO: expose the returning memory value immediately. A
  // stalled CDB still captures it in the reserved FIFO slot at this edge.
  // Existing queued results always retain priority over a new response.
  assign response_bypass_valid = (rq_count == 0) && md_resp_keep;
  assign response_bypass_fire = response_bypass_valid && load_result_ready;
  assign rq_push = (md_resp_keep && !response_bypass_fire) ||
                   (load_issue && (r_illegal || ld_fwd));
  assign rq_pop  = (rq_count != 0) &&
                   (rq_discard[rq_head] || load_result_ready);

  // 非法 load 与已有响应同拍会需要两个结果写口，直接延后一拍。
  // （load issue 需要 issue_valid，响应同拍只会发生在该 load 已入 IQ 后）
  assign illegal_slot_ok = !md_resp_fire && result_space;

  // ---- 结果输出 -----------------------------------------------------------
  assign load_result_valid     = response_bypass_valid ||
                                ((rq_count != 0) && !rq_discard[rq_head] &&
                                 !(squash_valid &&
                                   (rq_seq[rq_head*32 +: 32] > squash_seq)));
  assign load_result_tag       = response_bypass_valid ? md_tag[md_head*PW +: PW]
                                                     : rq_tag[rq_head*PW +: PW];
  assign load_result_value     = response_bypass_valid ?
                                  format_load(ld_resp_rdata, md_size[md_head*2 +: 2],
                                              md_off[md_head*2 +: 2], md_unsigned[md_head]) :
                                  rq_value[rq_head*32 +: 32];
  assign load_result_exception = !response_bypass_valid && rq_exc[rq_head];

  // ---- store complete -----------------------------------------------------
  logic                         store_complete_valid_q;
  logic [PW-1:0]                store_complete_tag_q;
  logic                         store_complete_exc_q;

  assign store_complete_valid     = store_complete_valid_q;
  assign store_complete_tag       = store_complete_tag_q;
  assign store_complete_exception = store_complete_exc_q;

  assign busy = (|lp_valid) || q_valid || r_valid ||
                (ld_count != 0) || (rq_count != 0) || (lsq_count != 0);

  always_ff @(posedge clk) begin
    if (reset) begin
      lp_valid <= '0;
      q_valid <= 1'b0;
      q_id <= '0;
      q_addr <= '0;
      q_seq <= '0;
      q_tag <= '0;
      q_size <= '0;
      q_unsigned <= 1'b0;
      q_illegal <= 1'b0;
      r_valid <= 1'b0;
      r_id <= '0;
      r_addr <= '0;
      r_seq <= '0;
      r_tag <= '0;
      r_size <= '0;
      r_unsigned <= 1'b0;
      r_illegal <= 1'b0;
    end else begin
      for (lp_squash_i = 0; lp_squash_i < LP_DEPTH; lp_squash_i = lp_squash_i + 1)
        if (squash_valid && lp_valid[lp_squash_i] &&
            (lp_seq[lp_squash_i*32 +: 32] > squash_seq))
          lp_valid[lp_squash_i] <= 1'b0;
      if (load_issue)
        lp_valid[r_id] <= 1'b0;
      if (load_enqueue) begin
        lp_valid[issue_lsq] <= 1'b1;
        lp_addr[issue_lsq*32 +: 32] <= issue_addr;
        lp_seq[issue_lsq*32 +: 32] <= issue_seq;
        lp_tag[issue_lsq*PW +: PW] <= issue_dest;
        lp_size[issue_lsq*2 +: 2] <= issue_mem_size;
        lp_unsigned[issue_lsq] <= issue_mem_unsigned;
        lp_illegal[issue_lsq] <= issue_illegal;
      end
      if (r_accept)
        r_valid <= 1'b0;
      // 消费/flush 旧快照与捕获新请求可同拍发生，新请求优先。
      if (query_send) begin
        r_valid <= 1'b1;
        r_id <= q_id;
        r_addr <= q_addr;
        r_seq <= q_seq;
        r_tag <= q_tag;
        r_size <= q_size;
        r_unsigned <= q_unsigned;
        r_illegal <= q_illegal;
      end
      if (q_accept) begin
        q_valid <= lp_select_valid;
        if (lp_select_valid) begin
          q_id <= lp_select_id;
          q_addr <= lp_addr[lp_select_id*32 +: 32];
          q_seq <= lp_best_seq;
          q_tag <= lp_tag[lp_select_id*PW +: PW];
          q_size <= lp_size[lp_select_id*2 +: 2];
          q_unsigned <= lp_unsigned[lp_select_id];
          q_illegal <= lp_illegal[lp_select_id];
        end
      end
    end
  end

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
      if (load_issue && !r_illegal && !ld_fwd) begin
        md_valid[md_tail]         <= 1'b1;
        md_tag[md_tail*PW +: PW]  <= r_tag;
        md_seq[md_tail*32 +: 32]  <= r_seq;
        md_lsq[md_tail*LW +: LW]  <= r_id;
        md_off[md_tail*2 +: 2]    <= r_addr[1:0];
        md_size[md_tail*2 +: 2]   <= r_size;
        md_unsigned[md_tail]      <= r_unsigned;
        md_discard[md_tail]       <= 1'b0;
        md_tail <= (md_tail == LDQ_DEPTH - 1) ? '0 : md_tail + 1'b1;
      end

      // ---- load response：出队、格式化、入结果队列 ------------------------
      if (md_resp_fire)
        md_head <= (md_head == LDQ_DEPTH - 1) ? '0 : md_head + 1'b1;

      if (rq_push) begin
        rq_valid[rq_tail]          <= 1'b1;
        rq_tag[rq_tail*PW +: PW]   <= (load_issue && (r_illegal || ld_fwd)) ?
                                      r_tag : md_tag[md_head*PW +: PW];
        rq_value[rq_tail*32 +: 32] <=
            (load_issue && r_illegal) ? 32'b0 :
            (load_issue && ld_fwd) ?
              format_load(ld_fwd_data, r_size, r_addr[1:0], r_unsigned) :
              format_load(ld_resp_rdata, md_size[md_head*2 +: 2],
                          md_off[md_head*2 +: 2], md_unsigned[md_head]);
        rq_seq[rq_tail*32 +: 32]   <= (load_issue && (r_illegal || ld_fwd)) ?
                                      r_seq : md_seq[md_head*32 +: 32];
        rq_exc[rq_tail]            <= load_issue && r_illegal;
        rq_discard[rq_tail]        <= squash_valid &&
                                      (((load_issue && (r_illegal || ld_fwd)) ?
                                        r_seq : md_seq[md_head*32 +: 32])
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
                  ((load_issue && !r_illegal && !ld_fwd) ? 1'b1 : 1'b0) -
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

`ifdef LOCAL_STATS
  // 仅仿真统计；默认构建/综合不会实例化这些计数器。
  longint st_cycles, st_ld_issue, st_ld_resp, st_ld_fwd, st_illegal_ld;
  longint st_load_result_wait, st_ldq_busy, st_rq_busy, st_ldq_full;
  longint st_mem_block, st_query_blocked, st_st_issue, st_st_drain, st_st_resp;
  longint st_prefill, st_ld_out_sum, st_rq_out_sum;
  integer st_max_ld_out, st_max_rq_out;

  always_ff @(posedge clk) begin
    if (reset) begin
      st_cycles          <= 0;
      st_ld_issue        <= 0;
      st_ld_resp         <= 0;
      st_ld_fwd          <= 0;
      st_illegal_ld      <= 0;
      st_load_result_wait<= 0;
      st_ldq_busy        <= 0;
      st_rq_busy         <= 0;
      st_ldq_full        <= 0;
      st_mem_block       <= 0;
      st_query_blocked   <= 0;
      st_st_issue        <= 0;
      st_st_drain        <= 0;
      st_st_resp         <= 0;
      st_prefill         <= 0;
      st_ld_out_sum      <= 0;
      st_rq_out_sum      <= 0;
      st_max_ld_out      <= 0;
      st_max_rq_out      <= 0;
    end else begin
      st_cycles <= st_cycles + 1;
      if (load_issue) st_ld_issue <= st_ld_issue + 1;
      if (load_issue && ld_fwd) st_ld_fwd <= st_ld_fwd + 1;
      if (load_issue && r_illegal) st_illegal_ld <= st_illegal_ld + 1;
      if (md_resp_fire) st_ld_resp <= st_ld_resp + 1;
      if (load_result_valid && !load_result_ready)
        st_load_result_wait <= st_load_result_wait + 1;
      if (ld_count != 0) st_ldq_busy <= st_ldq_busy + 1;
      if (rq_count != 0) st_rq_busy <= st_rq_busy + 1;
      if (!ld_space) st_ldq_full <= st_ldq_full + 1;
      if (!ld_req_ready) st_mem_block <= st_mem_block + 1;
      if (lsq_query_blocked) st_query_blocked <= st_query_blocked + 1;
      if (store_issue) st_st_issue <= st_st_issue + 1;
      if (store_addr_issue) st_prefill <= st_prefill + 1;
      if (drain_fire) st_st_drain <= st_st_drain + 1;
      if (st_resp_valid) st_st_resp <= st_st_resp + 1;

      st_ld_out_sum <= st_ld_out_sum + ld_count;
      st_rq_out_sum <= st_rq_out_sum + rq_count;
      if (ld_count > st_max_ld_out) st_max_ld_out <= ld_count;
      if (rq_count > st_max_rq_out) st_max_rq_out <= rq_count;
    end
  end

  final $fdisplay(32'h80000002,
      "[STATS] LSU cycles=%0d ld_issue=%0d ld_resp=%0d ld_fwd=%0d illegal_ld=%0d load_result_wait=%0d ldq_busy=%0d rq_busy=%0d ldq_full=%0d mem_block=%0d query_blocked=%0d prefill=%0d st_issue=%0d st_drain=%0d st_resp=%0d ld_out_sum=%0d max_ld_out=%0d rq_out_sum=%0d max_rq_out=%0d",
      st_cycles, st_ld_issue, st_ld_resp, st_ld_fwd, st_illegal_ld,
      st_load_result_wait, st_ldq_busy, st_rq_busy, st_ldq_full,
      st_mem_block, st_query_blocked, st_prefill, st_st_issue, st_st_drain,
      st_st_resp, st_ld_out_sum, st_max_ld_out, st_rq_out_sum, st_max_rq_out);
`endif

endmodule
