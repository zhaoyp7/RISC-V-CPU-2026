// -----------------------------------------------------------------------------
// issue_queue.sv — 统一发射队列（P1）
//
// 结构：
//   - W 路 dispatch 写入；D 项表项，按 age 选择最老的 ready uop；
//   - 源操作数就绪位在 dispatch 同拍用本拍 CDB 做旁路比较（关键，避免漏唤醒）；
//   - CDB 广播清 busy；squash 按 dispatch seq 丢弃更年轻的表项；
//   - 输出 IW 路发射（P1 用 IW=1；dispatch 宽度仍可以是 W=2）。
//
// 表项字段只保存发射所需信息：完整 dispatch uop、两个源 tag/ready、age。
// 结果写回、PRF 读、执行单元由 backend_ooo 负责。
// -----------------------------------------------------------------------------

module issue_queue #(
  parameter integer W  = `CPU_ISSUE_WIDTH,
  parameter integer D  = `CPU_RS_DEPTH,
  parameter integer IW = 1,
  // 后端第二通道只支持普通写回ALU；通用IQ默认仍保持逐年龄选择。
  parameter integer LANE1_ALU_ONLY = 0,
  parameter integer LANE1_LOOKAHEAD = 0,
  parameter integer LANE0_CONTROL_LOOKAHEAD = 0,
  parameter integer LANE0_SPECIAL_PRIORITY = 0,
  parameter integer LANE0_ALU_LOOKAHEAD = 0,
  parameter integer REUSE_ISSUED_SLOTS = 0,
  parameter integer LANE0_MEMORY_LOOKAHEAD = 0,
  parameter integer RETIRE_STORE_PREFILL = 0
) (
  input  logic clk,
  input  logic reset,

  // dispatch
  input  logic [W-1:0]                       in_valid,
  input  logic [W-1:0]                       in_alloc_mask,
  input  logic [W*`CPU_DISPATCH_W-1:0]       in_uop,
  output logic                               in_ready,

  // CDB wake (R lanes)
  input  logic [`CPU_CDB_NUM-1:0]            wake_valid,
  input  logic [`CPU_CDB_NUM*`CPU_PRF_IDX_W-1:0] wake_tag,

  // 保证本沿写PRF的独立提示，仅供后接寄存级的普通ALU1提前选择。
  // 不用于持久ready或lane0/访存选择；实际CDB仍负责状态更新。
  input  logic                               lookahead_valid,
  input  logic [`CPU_PRF_IDX_W-1:0]           lookahead_tag,
  input logic execute1_lookahead_valid,
  input logic [`CPU_PRF_IDX_W-1:0] execute1_lookahead_tag,
  input logic execute_lookahead_valid,
  input logic [`CPU_PRF_IDX_W-1:0] execute_lookahead_tag,
  input  logic                               lookahead_load_valid,
  input  logic [`CPU_PRF_IDX_W-1:0]           lookahead_load_tag,

  // dispatch sequence: lane i is seq_base + i
  input  logic [31:0]                        seq_base,

  // squash: keep seq == squash_seq, drop seq > squash_seq
  input  logic                               squash_valid,
  input  logic [31:0]                        squash_seq,

  // issue
  output logic [IW-1:0]                      out_valid,
  output logic [IW-1:0]                      out_addr_only,
  output logic [IW*`CPU_DISPATCH_W-1:0]      out_uop,
  output logic [IW*32-1:0]                   out_seq,
  input  logic [IW-1:0]                      out_ready,

  // The direct LSU payload is selected only from registered-ready memory
  // candidates. A control hint can suppress its valid, without changing the
  // PRF/AGU input cone. Meaningful only when lane 0 actually issues memory.
  output logic [`CPU_DISPATCH_W-1:0] memory_uop,
  output logic [31:0] memory_seq,
  output logic memory_addr_only,

  // status
  output logic registered_alu_ready,
  output logic [7:0]                         count,
  output logic [7:0]                         free_count
);

  localparam integer PW  = `CPU_PRF_IDX_W;
  localparam integer DW  = `CPU_DISPATCH_W;
  localparam integer R   = `CPU_CDB_NUM;

  logic [D-1:0]       valid;
  logic [D-1:0]       addr_sent;
  logic [D*DW-1:0]    uop;
  logic [D*PW-1:0]    src1_tag;
  logic [D*PW-1:0]    src2_tag;
  logic [D-1:0]       src1_ready;
  logic [D-1:0]       src2_ready;
  logic [D-1:0]       lane1_eligible;
  logic [D*32-1:0]    seq;


  // ---- dispatch 字段解包 --------------------------------------------------
  logic [PW-1:0]      in_src1_tag [0:W-1];
  logic [PW-1:0]      in_src2_tag [0:W-1];
  logic               in_src1_rdy [0:W-1];
  logic               in_src2_rdy [0:W-1];
  assign registered_alu_ready=|(valid & src1_ready & src2_ready & lane1_eligible);
  integer             i, lane;

  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      in_src1_tag[i] = in_uop[i*DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW];
      in_src2_tag[i] = in_uop[i*DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW];
      in_src1_rdy[i] = in_uop[i*DW + `CPU_DISPATCH_SRC1_READY_OFF];
      in_src2_rdy[i] = in_uop[i*DW + `CPU_DISPATCH_SRC2_READY_OFF];
    end
  end

  // ---- 计数 / squash ------------------------------------------------------
  logic [7:0] n_in;
  logic [D-1:0] squash_mask;
  logic [7:0] n_squash;
  logic [7:0] free_after;
  logic [D-1:0] released;
  logic [7:0] n_released;
  always_comb begin
    released='0; n_released='0;
    if(REUSE_ISSUED_SLOTS) begin
      for(integer q=0;q<IW;q=q+1)
        if(out_valid[q] && out_ready[q] && (!out_addr_only[q] || RETIRE_STORE_PREFILL))
          released[sel_idx[q]]=1'b1;
      for(integer q=0;q<D;q=q+1)
        if(released[q] && !squash_mask[q]) n_released=n_released+1'b1;
    end
  end

  always_comb begin
    n_in = '0;
    for (i = 0; i < W; i = i + 1)
      if (in_alloc_mask[i]) n_in = n_in + 1'b1;
  end

  always_comb begin
    squash_mask = '0;
    n_squash = '0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i] && squash_valid && (seq[i*32 +: 32] > squash_seq))
        squash_mask[i] = 1'b1;
    end
    for (i = 0; i < D; i = i + 1)
      if (squash_mask[i]) n_squash = n_squash + 1'b1;
  end

  always_comb begin
    count = '0;
    free_count = '0;
    for (i = 0; i < D; i = i + 1) begin
      if (valid[i]) count = count + 1'b1;
      else          free_count = free_count + 1'b1;
    end
  end

  assign free_after = free_count + n_squash + n_released;

  assign in_ready = (free_after >= n_in);

  // ---- 分配槽位（squash 槽可复用）----------------------------------------
  logic [D-1:0] alloc_used;
  logic [7:0]   alloc_slot [0:W-1];
  logic [7:0]   slot_found;

  always_comb begin
    alloc_used = '0;
    for (lane = 0; lane < W; lane = lane + 1) begin
      alloc_slot[lane] = '0;
      slot_found = 1'b0;
      for (i = 0; i < D; i = i + 1) begin
        if (!slot_found && !alloc_used[i] &&
            (!valid[i] || squash_mask[i] || released[i])) begin
          alloc_slot[lane] = i[7:0];
          alloc_used[i] = 1'b1;
          slot_found = 1'b1;
        end
      end
    end
  end

  // ---- 同拍 CDB 旁路匹配 --------------------------------------------------
  function automatic logic tag_hit(input logic [PW-1:0] tag);
    integer w;
    begin
      tag_hit = 1'b0;
      for (w = 0; w < R; w = w + 1)
        if (wake_valid[w] && (wake_tag[w*PW +: PW] == tag))
          tag_hit = 1'b1;
    end
  endfunction

  function automatic logic lane1_alu(input logic [DW-1:0] entry);
    logic [4:0] op;
    begin
      op = entry[`CPU_DISPATCH_ALU_OP_OFF +: 5];
      lane1_alu = entry[`CPU_DISPATCH_REG_WE_OFF] &&
          !entry[`CPU_DISPATCH_IS_LOAD_OFF] && !entry[`CPU_DISPATCH_IS_STORE_OFF] &&
          !entry[`CPU_DISPATCH_IS_BRANCH_OFF] && !entry[`CPU_DISPATCH_IS_JAL_OFF] &&
          !entry[`CPU_DISPATCH_IS_JALR_OFF] && !entry[`CPU_DISPATCH_ILLEGAL_OFF] &&
          op != `ALU_DIV && op != `ALU_DIVU && op != `ALU_REM && op != `ALU_REMU;
    end
  endfunction

  // ---- 发射选择：最老的 ready 表项 ---------------------------------------
  // lane 0 除了普通发射，还可以对 store 做 address-only 发射：地址源 ready
  // 但数据源尚未 ready 时，先把地址填入 LSQ，store 本体仍留在 IQ 等数据。
  // 这样后面的 load 不会被一个地址未知的 store 长期阻塞。
  wire [D-1:0] memory_base_ready;
  for(genvar m=0;m<D;m=m+1)begin : gen_memory_base_ready
    assign memory_base_ready[m]=src1_ready[m] ||
      (LANE0_MEMORY_LOOKAHEAD && lookahead_valid && src1_tag[m*PW+:PW]==lookahead_tag);
  end
  logic [D-1:0] cand_issue;
  logic [D-1:0] cand_prefill;
  logic [IW-1:0] sel_valid;
  logic [IW-1:0] sel_addr_only;
  logic [7:0] sel_idx [0:IW-1];
  logic [31:0] sel_seq [0:IW-1];
  logic [PW-1:0] sel_src1_tag [0:IW-1];
  logic [PW-1:0] sel_src2_tag [0:IW-1];

  always_comb begin
    cand_issue = '0;
    cand_prefill = '0;
    // CDB 本拍只更新 ready，下一拍才参与选择。
    for (i = 0; i < D; i = i + 1) begin
      cand_issue[i] = valid[i] &&
          ((src1_ready[i] && src2_ready[i]) ||
           (LANE0_MEMORY_LOOKAHEAD &&
            (uop[i*DW+`CPU_DISPATCH_IS_LOAD_OFF] || uop[i*DW+`CPU_DISPATCH_IS_STORE_OFF]) &&
            memory_base_ready[i] && src2_ready[i]) ||
           (((LANE0_CONTROL_LOOKAHEAD &&
            (uop[i*DW + `CPU_DISPATCH_IS_BRANCH_OFF] ||
             uop[i*DW + `CPU_DISPATCH_IS_JALR_OFF])) ||
             (LANE0_ALU_LOOKAHEAD && lane1_eligible[i])) &&
            (src1_ready[i] || (lookahead_valid && src1_tag[i*PW +: PW] == lookahead_tag) ||
             (lookahead_load_valid && src1_tag[i*PW +: PW] == lookahead_load_tag)) &&
            (src2_ready[i] || (lookahead_valid && src2_tag[i*PW +: PW] == lookahead_tag) ||
             (lookahead_load_valid && src2_tag[i*PW +: PW] == lookahead_load_tag))));
      cand_prefill[i] = valid[i] && !addr_sent[i] &&
                        uop[i*DW + `CPU_DISPATCH_IS_STORE_OFF] &&
                        memory_base_ready[i] && !src2_ready[i];
    end
  end

  generate
    if (IW <= 2) begin : gen_select_age_matrix
      localparam integer LEAVES = 1 << $clog2(D);
      // 年龄关系在分配时计算，发射只查询寄存关系。每对物理槽保存一位，
      // 包括相等seq时较低槽优先；不依赖tag唯一或seq差值上界。
      logic [D-1:0] allocated;
      logic [D*32-1:0] next_seq;
      integer al;
      always_comb begin
        allocated = '0;
        next_seq = seq;
        for (al = 0; al < W; al = al + 1) begin
          if (in_valid[al] && in_ready) begin
            allocated[alloc_slot[al]] = 1'b1;
            next_seq[alloc_slot[al]*32 +: 32] = seq_base + al;
          end
        end
      end
      // older[i][j]表示j应排在i之前。无效槽的关系无关紧要；任一端重新
      // 分配时更新，两个槽同拍分配时使用两者的新seq，不使用旧表项年龄。
      wire [D-1:0] older [0:D-1];
      for (genvar g = 0; g < D; g = g + 1) begin : gen_age_row
        assign older[g][g] = 1'b0;
        for (genvar h = g + 1; h < D; h = h + 1) begin : gen_age_pair
          logic lower_first;
          always_ff @(posedge clk) begin
            if (!reset && (allocated[g] || allocated[h]))
              lower_first <= next_seq[g*32 +: 32] <= next_seq[h*32 +: 32];
          end
          assign older[g][h] = !lower_first;
          assign older[h][g] = lower_first;
        end
      end

      wire [D-1:0] full_first, full_second, pick0;
      wire [D-1:0] cand_any = cand_issue | cand_prefill;
      // Reserve the general port for work that cannot use the ALU-only port.
      wire [D-1:0] special_candidates = cand_any & ~lane1_eligible;
      wire [D-1:0] port0_candidates = (LANE0_SPECIAL_PRIORITY && LANE1_ALU_ONLY && IW==2 && |special_candidates)
          ? special_candidates : cand_any;
      for (genvar g = 0; g < D; g = g + 1) begin : gen_rank
        // 树节点只记录是否存在、是否至少两个更老的完整候选。
        // 不使用串行加法统计数量，也不再在选择树每层比较32位seq。
        wire [2*LEAVES-1:0] any_older, multi_older;
        assign any_older[0] = 1'b0;
        assign multi_older[0] = 1'b0;
        for (genvar h = 0; h < LEAVES; h = h + 1) begin : gen_leaf
          if (h < D) begin : gen_entry
            assign any_older[LEAVES+h] = cand_issue[h] && older[g][h];
          end else begin : gen_pad
            assign any_older[LEAVES+h] = 1'b0;
          end
          assign multi_older[LEAVES+h] = 1'b0;
        end
        for (genvar h = 1; h < LEAVES; h = h + 1) begin : gen_merge
          assign any_older[h] = any_older[2*h] | any_older[2*h+1];
          assign multi_older[h] = multi_older[2*h] | multi_older[2*h+1] |
                                     (any_older[2*h] & any_older[2*h+1]);
        end
        assign full_first[g] = cand_issue[g] && !any_older[1];
        assign full_second[g] = cand_issue[g] && any_older[1] && !multi_older[1];
        assign pick0[g] = port0_candidates[g] && !(|(older[g] & port0_candidates));
      end
      wire [D-1:0] memory_candidates, memory_pick;
      for(genvar g=0;g<D;g=g+1)begin : gen_memory_pick
        wire is_memory = uop[g*DW+`CPU_DISPATCH_IS_LOAD_OFF] || uop[g*DW+`CPU_DISPATCH_IS_STORE_OFF];
        assign memory_candidates[g] = valid[g] && is_memory && memory_base_ready[g] &&
          (src2_ready[g] || (uop[g*DW+`CPU_DISPATCH_IS_STORE_OFF] && !addr_sent[g]));
        assign memory_pick[g] = memory_candidates[g] && !(|(older[g] & memory_candidates));
      end
      always_comb begin
        memory_uop='0;memory_seq='0;
        for(integer k=0;k<D;k=k+1)begin
          memory_uop=memory_uop | (uop[k*DW+:DW] & {DW{memory_pick[k]}});
          memory_seq=memory_seq | (seq[k*32+:32] & {32{memory_pick[k]}});
        end
      end
      assign memory_addr_only = |(memory_pick & cand_prefill);
      wire take_prefill = |(pick0 & cand_prefill);
      wire [IW*D-1:0] picks;
      assign picks[0 +: D] = pick0;
      assign sel_valid[0] = |pick0;
      assign sel_addr_only[0] = take_prefill;
      if (IW == 2) begin : gen_lane1
        if (LANE1_ALU_ONLY) begin : gen_alu_only
          // 分类在入队时寄存；只在本通道候选中按原年龄关系选最老项。
          // lane0即使被反压也保留其候选，不能在两个通道重复输出。
          wire [D-1:0] ready_for_lane1, candidates;
          for (genvar g = 0; g < D; g = g + 1) begin : gen_ready
            if (LANE1_LOOKAHEAD) begin : gen_hint
              assign ready_for_lane1[g] = valid[g] &&
                  (src1_ready[g] || (execute_lookahead_valid && src1_tag[g*PW+:PW]==execute_lookahead_tag) ||
                   (execute1_lookahead_valid && src1_tag[g*PW+:PW]==execute1_lookahead_tag) ||
                   (lookahead_valid && src1_tag[g*PW +: PW] == lookahead_tag) ||
                   (lookahead_load_valid && src1_tag[g*PW +: PW] == lookahead_load_tag)) &&
                  (src2_ready[g] || (execute_lookahead_valid && src2_tag[g*PW+:PW]==execute_lookahead_tag) ||
                   (execute1_lookahead_valid && src2_tag[g*PW+:PW]==execute1_lookahead_tag) ||
                   (lookahead_valid && src2_tag[g*PW +: PW] == lookahead_tag) ||
                   (lookahead_load_valid && src2_tag[g*PW +: PW] == lookahead_load_tag));
            end else begin : gen_registered
              assign ready_for_lane1[g] = cand_issue[g];
            end
          end
          assign candidates = ready_for_lane1 & lane1_eligible & ~pick0;
          for (genvar g = 0; g < D; g = g + 1) begin : gen_pick
            assign picks[D+g] = candidates[g] && !(|(older[g] & candidates));
          end
        end else begin : gen_unrestricted
          assign picks[D +: D] = take_prefill ? full_first : full_second;
        end
        assign sel_valid[1] = |picks[D +: D];
        assign sel_addr_only[1] = 1'b0;
      end
      integer l, e;
      always_comb begin
        for (l = 0; l < IW; l = l + 1) begin
          sel_idx[l] = '0;
          sel_seq[l] = '0;
          sel_src1_tag[l] = '0;
          sel_src2_tag[l] = '0;
          for (e = 0; e < D; e = e + 1) begin
            sel_idx[l] = sel_idx[l] | (8'(e) & {8{picks[l*D+e]}});
            sel_seq[l] = sel_seq[l] | (seq[e*32 +: 32] & {32{picks[l*D+e]}});
            sel_src1_tag[l] = sel_src1_tag[l] |
                (src1_tag[e*PW +: PW] & {PW{picks[l*D+e]}});
            sel_src2_tag[l] = sel_src2_tag[l] |
                (src2_tag[e*PW +: PW] & {PW{picks[l*D+e]}});
          end
        end
      end
    end else begin : gen_select_wide
      assign memory_uop='0;
      assign memory_seq='0;
      assign memory_addr_only=1'b0;
      // 保留 IW>2 的通用逐 lane 选择语义；默认后端使用 IW=2。
      logic [D-1:0] chosen;
      logic [31:0] best_seq;
      logic [7:0] best_idx;
      logic found;
      integer l, j;
      always_comb begin
        chosen = '0;
        sel_valid = '0;
        sel_addr_only = '0;
        for (l = 0; l < IW; l = l + 1) begin
          best_seq = 32'hffff_ffff;
          best_idx = '0;
          found = 1'b0;
          for (j = 0; j < D; j = j + 1) begin
            if ((cand_issue[j] || ((l == 0) && cand_prefill[j])) &&
                !chosen[j] && (!found || seq[j*32 +: 32] < best_seq)) begin
              found = 1'b1;
              best_seq = seq[j*32 +: 32];
              best_idx = j[7:0];
            end
          end
          sel_valid[l] = found;
          sel_idx[l] = best_idx;
          sel_seq[l] = best_seq;
          sel_src1_tag[l] = src1_tag[best_idx*PW +: PW];
          sel_src2_tag[l] = src2_tag[best_idx*PW +: PW];
          if (found) begin
            sel_addr_only[l] = cand_prefill[best_idx] && !cand_issue[best_idx];
            chosen[best_idx] = 1'b1;
          end
        end
      end
    end
  endgenerate

  always_comb begin
    out_valid = '0;
    out_addr_only = '0;
    out_uop = '0;
    out_seq = '0;
    for (lane = 0; lane < IW; lane = lane + 1) begin
      // 年龄选择先于取消：<= squash_seq 的候选构成最老候选的前缀，
      // 因此只取消预选的年轻项，与先过滤再选择的有效输出相同。
      // 数据只依赖预选；无效输出的 uop/seq 不保证为零，消费者须按 valid 写状态。
      out_valid[lane] = sel_valid[lane] &&
                        !(squash_valid && sel_seq[lane] > squash_seq);
      out_addr_only[lane] = sel_addr_only[lane] && out_valid[lane];
      if (sel_valid[lane]) begin
        out_uop[lane*DW +: DW] = uop[sel_idx[lane]*DW +: DW];
        out_uop[lane*DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW] = sel_src1_tag[lane];
        out_uop[lane*DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW] = sel_src2_tag[lane];
        out_seq[lane*32 +: 32] = sel_seq[lane];
      end
    end
  end

  // ---- 时序 ----------------------------------------------------------------

  always_ff @(posedge clk) begin
    if (reset) begin
      valid      <= '0;
      addr_sent  <= '0;
      src1_ready <= '0;
      src2_ready <= '0;
      lane1_eligible <= '0;
    end else begin
      // 1) squash：清更年轻的表项
      for (i = 0; i < D; i = i + 1) begin
        if (squash_mask[i]) begin
          valid[i]      <= 1'b0;
          addr_sent[i]  <= 1'b0;
          src1_ready[i] <= 1'b0;
          src2_ready[i] <= 1'b0;
        end
      end

      // 2) CDB 唤醒：只清 busy 位，不丢表项
      for (i = 0; i < D; i = i + 1) begin
        if (valid[i] && !squash_mask[i]) begin
          if (!src1_ready[i] && tag_hit(src1_tag[i*PW +: PW]))
            src1_ready[i] <= 1'b1;
          if (!src2_ready[i] && tag_hit(src2_tag[i*PW +: PW]))
            src2_ready[i] <= 1'b1;
        end
      end

      // 3) 发射：按 lane 分别接收，未接收的 lane 留在队列里。
      //    address-only store 只标记 addr_sent，不删除表项。
      for (lane = 0; lane < IW; lane = lane + 1) begin
        if (out_ready[lane] && out_valid[lane]) begin
          if (sel_addr_only[lane] && !RETIRE_STORE_PREFILL)
            addr_sent[sel_idx[lane]] <= 1'b1;
          else
            valid[sel_idx[lane]] <= 1'b0;
        end
      end

      // 4) dispatch 写入（最后执行，允许复用 squash 槽）
      for (lane = 0; lane < W; lane = lane + 1) begin
        if (in_valid[lane] && in_ready) begin
          uop[alloc_slot[lane]*DW +: DW] <= in_uop[lane*DW +: DW];
          src1_tag[alloc_slot[lane]*PW +: PW] <= in_src1_tag[lane];
          src2_tag[alloc_slot[lane]*PW +: PW] <= in_src2_tag[lane];
          lane1_eligible[alloc_slot[lane]] <= lane1_alu(in_uop[lane*DW +: DW]);
          // 同拍 CDB 旁路：dispatch 写入时新 tag 已在本拍广播则直接 ready。
          src1_ready[alloc_slot[lane]] <= in_src1_rdy[lane] |
                                          tag_hit(in_src1_tag[lane]);
          src2_ready[alloc_slot[lane]] <= in_src2_rdy[lane] |
                                          tag_hit(in_src2_tag[lane]);
          seq[alloc_slot[lane]*32 +: 32] <= seq_base + lane;
          valid[alloc_slot[lane]] <= 1'b1;
          addr_sent[alloc_slot[lane]] <= 1'b0;
        end
      end
    end
  end

`ifdef LOCAL_TRACE
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (in_valid[0] && in_ready)
        $display("[IQ_PUSH] t=%0t pc=%08x inst=%08x rob=%0d dest=%0d s1=%0d/%0b s2=%0d/%0b",
                 $time,
                 in_uop[`CPU_DISPATCH_PC_OFF +: 32],
                 in_uop[`CPU_DISPATCH_INST_OFF +: 32],
                 in_uop[`CPU_DISPATCH_ROB_IDX_OFF +: `CPU_ROB_TAG_W],
                 in_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW],
                 in_uop[`CPU_DISPATCH_SRC1_TAG_OFF +: PW],
                 in_uop[`CPU_DISPATCH_SRC1_READY_OFF],
                 in_uop[`CPU_DISPATCH_SRC2_TAG_OFF +: PW],
                 in_uop[`CPU_DISPATCH_SRC2_READY_OFF]);
      if (out_valid[0] && out_ready[0])
        $display("[IQ_POP] t=%0t pc=%08x inst=%08x rob=%0d dest=%0d",
                 $time,
                 out_uop[`CPU_DISPATCH_PC_OFF +: 32],
                 out_uop[`CPU_DISPATCH_INST_OFF +: 32],
                 out_uop[`CPU_DISPATCH_ROB_IDX_OFF +: `CPU_ROB_TAG_W],
                 out_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW]);
      if (squash_valid)
        $display("[IQ_SQUASH] t=%0t seq=%0d mask=%08b", $time,
                 squash_seq, squash_mask);
    end
  end
`endif

endmodule
