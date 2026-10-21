// -----------------------------------------------------------------------------
// frontend_ooo.sv — 双宽取指 / 译码 / 分支预测前端
//
// 组成：
//   - 两份 I-Cache（分别服务 PC 和 PC+4，各自有 refill 口）；
//   - 每拍最多取两条连续指令；PC 为奇数（pc[2]=1）时只取一条，下一拍对齐；
//   - BPU 在取指请求侧查询（两个只读副本，更新口相同），预测 taken 时下一拍
//     直接切目标，不等译码；
//   - decoded-uop FIFO 吸收 rename/后端反压，W=1/2 都能连续送出。
//
// 预测与指令的配对通过一个请求 FIFO 完成：每笔取指记录 use2 和两条指令的
// 预测，响应回来时整体压入 decode FIFO。
// -----------------------------------------------------------------------------

module frontend_ooo #(
  parameter integer W      = `CPU_ISSUE_WIDTH,
  parameter integer FDEPTH = 8
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        backend_ready,

  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,

  input  logic        br_update_valid,
  input  logic [31:0] br_update_pc,
  input  logic        br_update_taken,
  input  logic [31:0] br_update_target,
  input  logic        br_update_is_jalr,
  input  logic        br_update_uncond,
  input  logic [`CPU_PRF_IDX_W-1:0] br_update_tag,

  output logic [W-1:0]                 dec_valid,
  output logic [W*`CPU_DECODE_W-1:0]   dec_uop,
  output logic [W-1:0]                 dec_pred_taken,
  output logic [W*32-1:0]              dec_pred_target,
  input  logic                         rename_ready,

  output logic [31:0]                 pc_out,

  output logic        refill_valid,
  output logic [31:0] refill_addr,
  input  logic        refill_resp_valid,
  input  logic [31:0] refill_rdata,

  output logic        refill_valid1,
  output logic [31:0] refill_addr1,
  input  logic        refill_resp_valid1,
  input  logic [31:0] refill_rdata1
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer FW = (FDEPTH > 1) ? $clog2(FDEPTH) : 1;
  localparam integer FCW = FW + 1;
  localparam integer RDEPTH = 4;
  localparam integer RFW = (RDEPTH > 1) ? $clog2(RDEPTH) : 1;
  localparam integer RCW = RFW + 1;

  // ---- PC ----------------------------------------------------------------
  logic [31:0] pc_q;
  logic [31:0] pc1;
  assign pc1 = pc_q + 32'd4;
  assign pc_out = pc_q;

  // ---- BPU ---------------------------------------------------------------
  logic p0_taken, p1_taken;
  logic [31:0] p0_target, p1_target;

  bpu u_bpu (
    .clk             (clk),
    .reset           (reset),
    .fetch_pc        (pc_q),
    .predict_taken   (p0_taken),
    .predict_target  (p0_target),
    .fetch_pc2       (pc1),
    .predict_taken2  (p1_taken),
    .predict_target2 (p1_target),
    .upd_valid       (br_update_valid),
    .upd_pc          (br_update_pc),
    .upd_taken       (br_update_taken),
    .upd_target      (br_update_target),
    .upd_is_uncond   (br_update_uncond)
  );

  // ---- 请求 FIFO（预测/配对信息） ----------------------------------------
  logic [RDEPTH-1:0]   rq_use2, rq_p0t, rq_p1t;
  logic [RDEPTH*32-1:0] rq_p0tg, rq_p1tg;
  logic [RFW-1:0]      rq_head, rq_tail;
  logic [RCW-1:0]      rq_count;

  // ---- 取指握手 -----------------------------------------------------------
  logic fetch_ready0, fetch_ready1;
  logic resp0_valid, resp1_valid;
  logic [31:0] resp0_pc, resp1_pc;
  logic [31:0] resp0_inst, resp1_inst;
  logic resp_accept, resp_accept0, resp_accept1;
  logic fetch_fire;
  logic use2;

  // 两个 bank 是独立 Cache，不要求 8B 对齐；任意 pc/pc+4 都可成对取指。
  assign use2 = !p0_taken;

  // ---- decoded-uop FIFO --------------------------------------------------
  logic [FDEPTH-1:0]               fq_valid;
  logic [FDEPTH*`CPU_DECODE_W-1:0] fq_uop;
  logic [FDEPTH-1:0]               fq_pred_taken;
  logic [FDEPTH*32-1:0]            fq_pred_target;
  logic [FW-1:0]                   fq_head, fq_tail;
  logic [FCW-1:0]                  fq_count;

  logic pop_fire;
  logic [FCW-1:0] pop_n;

  assign pop_n    = (fq_count >= W) ? W[FCW-1:0] : fq_count;
  assign pop_fire = (fq_count != 0) && rename_ready;

  // 空间保守计算：response 最多 2 条、fetch 最多 2 条。
  logic fq_space_fetch, fq_space_resp;
  assign fq_space_fetch = (fq_count + 4 <= FDEPTH + pop_n) && (rq_count < RDEPTH);
  assign fq_space_resp  = (fq_count + 2 <= FDEPTH + pop_n);

  assign fetch_fire = backend_ready && !redirect_valid && fq_space_fetch &&
                      fetch_ready0 && (!use2 || fetch_ready1);
  assign resp_accept0 = resp0_valid && (rq_count != 0) && fq_space_resp &&
                        backend_ready && !redirect_valid &&
                        (!rq_use2[rq_head] || resp1_valid);
  // 只有当前请求使用第二条时才消费 cache1 的响应；否则它会属于后面的请求。
  assign resp_accept1 = resp_accept0 && rq_use2[rq_head];
  assign resp_accept  = resp_accept0;

  // ---- PC 更新 ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      pc_q <= 32'b0;
    end else if (redirect_valid) begin
      pc_q <= redirect_pc;
    end else if (fetch_fire) begin
      if (p0_taken)
        pc_q <= p0_target;
      else if (use2 && p1_taken)
        pc_q <= p1_target;
      else
        pc_q <= pc_q + (use2 ? 32'd8 : 32'd4);
    end
  end

  // ---- I-Cache 0 / 1 -----------------------------------------------------
  icache_pipe #(
    .INDEX_BITS (`CPU_ICACHE_INDEX_BITS)
  ) u_icache0 (
    .clk               (clk),
    .reset             (reset),
    .flush             (redirect_valid),
    .discard           (1'b0),
    .fetch_valid       (fetch_fire),
    .fetch_pc          (pc_q),
    .fetch_ready       (fetch_ready0),
    .fetch_resp_valid  (resp0_valid),
    .fetch_resp_pc     (resp0_pc),
    .fetch_inst        (resp0_inst),
    .fetch_resp_ready  (resp_accept0),
    .refill_valid      (refill_valid),
    .refill_addr       (refill_addr),
    .refill_resp_valid (refill_resp_valid),
    .refill_rdata      (refill_rdata)
  );

  icache_pipe #(
    .INDEX_BITS (`CPU_ICACHE_INDEX_BITS)
  ) u_icache1 (
    .clk               (clk),
    .reset             (reset),
    .flush             (redirect_valid),
    .discard           (1'b0),
    .fetch_valid       (fetch_fire && use2),
    .fetch_pc          (pc1),
    .fetch_ready       (fetch_ready1),
    .fetch_resp_valid  (resp1_valid),
    .fetch_resp_pc     (resp1_pc),
    .fetch_inst        (resp1_inst),
    .fetch_resp_ready  (resp_accept1),
    .refill_valid      (refill_valid1),
    .refill_addr       (refill_addr1),
    .refill_resp_valid (refill_resp_valid1),
    .refill_rdata      (refill_rdata1)
  );

  // ---- 译码 --------------------------------------------------------------
  logic [4:0]  dec_rs1, dec_rs2, dec_rd;
  logic        dec_reg_we;
  logic [1:0]  dec_wb_sel;
  logic [4:0]  dec_alu_op;
  logic [1:0]  dec_a_sel;
  logic        dec_b_sel;
  logic [31:0] dec_imm;
  logic        dec_is_branch, dec_is_jal, dec_is_jalr;
  logic        dec_is_load, dec_is_store;
  logic [1:0]  dec_mem_size;
  logic        dec_mem_unsigned;
  logic        dec_illegal;

  decoder u_decoder (
    .instr        (resp0_inst),
    .rs1          (dec_rs1),
    .rs2          (dec_rs2),
    .rd           (dec_rd),
    .reg_we       (dec_reg_we),
    .wb_sel       (dec_wb_sel),
    .alu_op       (dec_alu_op),
    .a_sel        (dec_a_sel),
    .b_sel        (dec_b_sel),
    .imm          (dec_imm),
    .is_branch    (dec_is_branch),
    .is_jal       (dec_is_jal),
    .is_jalr      (dec_is_jalr),
    .is_load      (dec_is_load),
    .is_store     (dec_is_store),
    .mem_size     (dec_mem_size),
    .mem_unsigned (dec_mem_unsigned),
    .illegal      (dec_illegal)
  );

  // 第二条指令的译码只在 use2 时使用，直接复用 resp1_inst；为节省面积，
  // 这里只对 lane1 做一份组合译码（独立 decoder 实例）。
  logic [4:0]  dec1_rs1, dec1_rs2, dec1_rd;
  logic        dec1_reg_we;
  logic [1:0]  dec1_wb_sel;
  logic [4:0]  dec1_alu_op;
  logic [1:0]  dec1_a_sel;
  logic        dec1_b_sel;
  logic [31:0] dec1_imm;
  logic        dec1_is_branch, dec1_is_jal, dec1_is_jalr;
  logic        dec1_is_load, dec1_is_store;
  logic [1:0]  dec1_mem_size;
  logic        dec1_mem_unsigned;
  logic        dec1_illegal;

  decoder u_decoder1 (
    .instr        (resp1_inst),
    .rs1          (dec1_rs1),
    .rs2          (dec1_rs2),
    .rd           (dec1_rd),
    .reg_we       (dec1_reg_we),
    .wb_sel       (dec1_wb_sel),
    .alu_op       (dec1_alu_op),
    .a_sel        (dec1_a_sel),
    .b_sel        (dec1_b_sel),
    .imm          (dec1_imm),
    .is_branch    (dec1_is_branch),
    .is_jal       (dec1_is_jal),
    .is_jalr      (dec1_is_jalr),
    .is_load      (dec1_is_load),
    .is_store     (dec1_is_store),
    .mem_size     (dec1_mem_size),
    .mem_unsigned (dec1_mem_unsigned),
    .illegal      (dec1_illegal)
  );

  // ---- 输出：FIFO 头部最多 W 条 ------------------------------------------
  integer i_out;
  always_comb begin
    dec_valid       = '0;
    dec_uop         = '0;
    dec_pred_taken  = '0;
    dec_pred_target = '0;
    for (i_out = 0; i_out < W; i_out = i_out + 1) begin
      if (i_out < fq_count) begin
        dec_valid[i_out] = fq_valid[(fq_head + i_out) % FDEPTH];
        dec_uop[i_out*`CPU_DECODE_W +: `CPU_DECODE_W] =
            fq_uop[((fq_head + i_out) % FDEPTH)*`CPU_DECODE_W +: `CPU_DECODE_W];
        dec_pred_taken[i_out]  = fq_pred_taken[(fq_head + i_out) % FDEPTH];
        dec_pred_target[i_out*32 +: 32] =
            fq_pred_target[((fq_head + i_out) % FDEPTH)*32 +: 32];
      end
    end
  end

  // ---- 请求 FIFO 时序 ----------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset || redirect_valid) begin
      rq_head  <= '0;
      rq_tail  <= '0;
      rq_count <= '0;
    end else begin
      if (fetch_fire) begin
        rq_use2[rq_tail]            <= use2;
        rq_p0t[rq_tail]             <= p0_taken;
        rq_p0tg[rq_tail*32 +: 32]   <= p0_target;
        rq_p1t[rq_tail]             <= p1_taken;
        rq_p1tg[rq_tail*32 +: 32]   <= p1_target;
        rq_tail <= (rq_tail == RDEPTH - 1) ? '0 : rq_tail + 1'b1;
      end
      if (resp_accept)
        rq_head <= (rq_head == RDEPTH - 1) ? '0 : rq_head + 1'b1;
      rq_count <= rq_count + (fetch_fire ? 1'b1 : 1'b0) -
                             (resp_accept ? 1'b1 : 1'b0);
    end
  end

  // ---- 压入 decoded-uop FIFO --------------------------------------------
  logic [1:0] push_n;
  assign push_n = resp_accept ? (rq_use2[rq_head] ? 2'd2 : 2'd1) : 2'd0;

  integer i_slot;
  always_ff @(posedge clk) begin
    if (reset || redirect_valid) begin
      fq_valid <= '0;
      fq_head  <= '0;
      fq_tail  <= '0;
      fq_count <= '0;
    end else begin
      // 先清 pop 的槽位，再写 push；若两者同槽，push 必须胜出。
      if (pop_fire) begin
        for (i_slot = 0; i_slot < W; i_slot = i_slot + 1)
          if (i_slot < fq_count)
            fq_valid[(fq_head + i_slot) % FDEPTH] <= 1'b0;
        fq_head <= (fq_head + pop_n) % FDEPTH;
      end

      // lane 0
      if (resp_accept) begin
        fq_valid[fq_tail] <= 1'b1;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_PC_OFF +: 32]    <= resp0_pc;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_INST_OFF +: 32]  <= resp0_inst;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IMM_OFF +: 32]   <= dec_imm;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_RD_OFF +: 5]     <= dec_rd;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_REG_WE_OFF]      <= dec_reg_we;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_ALU_OP_OFF +: 5] <= dec_alu_op;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_A_SEL_OFF +: 2]  <= dec_a_sel;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_B_SEL_OFF]       <= dec_b_sel;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_WB_SEL_OFF +: 2] <= dec_wb_sel;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IS_BRANCH_OFF]   <= dec_is_branch;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IS_JAL_OFF]      <= dec_is_jal;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IS_JALR_OFF]     <= dec_is_jalr;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IS_LOAD_OFF]     <= dec_is_load;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_IS_STORE_OFF]    <= dec_is_store;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_ILLEGAL_OFF]     <= dec_illegal;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_MEM_SIZE_OFF +: 2] <= dec_mem_size;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_MEM_UNSIGNED_OFF]  <= dec_mem_unsigned;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DECODE_RS1_OFF +: 5]      <= dec_rs1;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DECODE_RS2_OFF +: 5]      <= dec_rs2;
        fq_pred_taken[fq_tail]  <= rq_p0t[rq_head];
        fq_pred_target[fq_tail*32 +: 32] <= rq_p0tg[rq_head*32 +: 32];
      end

      // lane 1
      if (resp_accept && rq_use2[rq_head]) begin
        fq_valid[(fq_tail + 1) % FDEPTH] <= 1'b1;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_PC_OFF +: 32]    <= resp1_pc;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_INST_OFF +: 32]  <= resp1_inst;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IMM_OFF +: 32]   <= dec1_imm;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_RD_OFF +: 5]     <= dec1_rd;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_REG_WE_OFF]      <= dec1_reg_we;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_ALU_OP_OFF +: 5] <= dec1_alu_op;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_A_SEL_OFF +: 2]  <= dec1_a_sel;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_B_SEL_OFF]       <= dec1_b_sel;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_WB_SEL_OFF +: 2] <= dec1_wb_sel;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IS_BRANCH_OFF]   <= dec1_is_branch;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IS_JAL_OFF]      <= dec1_is_jal;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IS_JALR_OFF]     <= dec1_is_jalr;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IS_LOAD_OFF]     <= dec1_is_load;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_IS_STORE_OFF]    <= dec1_is_store;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_ILLEGAL_OFF]     <= dec1_illegal;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_MEM_SIZE_OFF +: 2] <= dec1_mem_size;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DISPATCH_MEM_UNSIGNED_OFF]  <= dec1_mem_unsigned;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DECODE_RS1_OFF +: 5]      <= dec1_rs1;
        fq_uop[((fq_tail + 1) % FDEPTH)*`CPU_DECODE_W + `CPU_DECODE_RS2_OFF +: 5]      <= dec1_rs2;
        fq_pred_taken[(fq_tail + 1) % FDEPTH]  <= rq_p1t[rq_head];
        fq_pred_target[((fq_tail + 1) % FDEPTH)*32 +: 32] <= rq_p1tg[rq_head*32 +: 32];
      end

      fq_count <= fq_count + push_n - (pop_fire ? pop_n : '0);

      if (resp_accept && rq_use2[rq_head])
        fq_tail <= (fq_tail + 2) % FDEPTH;
      else if (resp_accept)
        fq_tail <= (fq_tail + 1) % FDEPTH;
    end
  end

`ifdef LOCAL_TRACE
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (fetch_fire)
        $display("[FE_FETCH] t=%0t pc=%08x use2=%0b p0t=%0b p1t=%0b rq=%0d fq=%0d",
                 $time, pc_q, use2, p0_taken, p1_taken, rq_count, fq_count);
      if (resp_accept)
        $display("[FE_RESP] t=%0t pc0=%08x v1=%0b pc1=%08x rq=%0d fq=%0d",
                 $time, resp0_pc, resp1_valid, resp1_pc, rq_count, fq_count);
      if (refill_valid || refill_valid1)
        $display("[FE_REFILL] t=%0t v0=%0b a0=%08x v1=%0b a1=%08x rv0=%0b rv1=%0b",
                 $time, refill_valid, refill_addr, refill_valid1, refill_addr1,
                 refill_resp_valid, refill_resp_valid1);
    end
  end
`endif

endmodule
