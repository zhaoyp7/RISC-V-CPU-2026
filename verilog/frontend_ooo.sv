// -----------------------------------------------------------------------------
// frontend_ooo.sv — 取指 / 译码 / 分支预测前端
//
// 组成：
//   pc_unit + icache_pipe + decoder + bpu
//   + W 项 decoded-uop 输出 + 小型 fetch FIFO（吸收 rename/后端反压）
//
// P2：I-Cache 仍每拍取一条，但用 FIFO 解耦取指与 rename。这样 W=1 可以
// 连续每拍送出一条，W=2 也能在 FIFO 有积压时成组送出两条。
// 预测 taken 的分支是 FIFO 中最年轻的项（取指在下一拍被切断），不会把
// 错误路径送进 FIFO。
//
// 控制：
//   - backend_ready=0 时冻结取指；
//   - ROB redirect 清空 FIFO 并切 PC；
//   - bpu_redirect_q 只切 PC / 冲刷 I-Cache 流水，FIFO 中已有指令继续送。
// -----------------------------------------------------------------------------

module frontend_ooo #(
  parameter integer W     = `CPU_ISSUE_WIDTH,
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
  input  logic [31:0] refill_rdata
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer FW = (FDEPTH > 1) ? $clog2(FDEPTH) : 1;
  localparam integer FCW = FW + 1;

  // ---- PC ----------------------------------------------------------------
  logic [31:0] pc;
  logic        pc_advance;
  logic        fetch_ready;
  logic        bpu_redirect_comb;

  pc_unit u_pc (
    .clk            (clk),
    .reset          (reset),
    .advance        (pc_advance),
    .stall          (1'b0),
    .redirect_valid (redirect_valid || bpu_redirect_comb),
    .redirect_pc    (redirect_valid ? redirect_pc : bpu_target),
    .pc             (pc)
  );

  assign pc_out = pc;

  // ---- fetch FIFO --------------------------------------------------------
  logic [FDEPTH-1:0]              fq_valid;
  logic [FDEPTH*`CPU_DECODE_W-1:0] fq_uop;
  logic [FDEPTH-1:0]              fq_pred_taken;
  logic [FDEPTH*32-1:0]           fq_pred_target;
  logic [FW-1:0]                  fq_head, fq_tail;
  logic [FCW-1:0]                 fq_count;

  logic        fetch_valid;
  logic        resp_valid;
  logic [31:0] resp_pc;
  logic [31:0] resp_inst;
  logic        resp_ready;

  logic        pop_fire;
  logic [FCW-1:0] pop_n;
  logic        fq_has_space;

  assign pop_n     = (fq_count >= W) ? W[FCW-1:0] : fq_count;
  assign pop_fire  = (fq_count != 0) && rename_ready;
  assign fq_has_space = (fq_count < FDEPTH) || pop_fire;

  // BPU 预测 taken：分支响应当拍切断顺序取指，并用组合重定向切 PC。
  // I-Cache 用 discard（只清 s1/s2 的年轻项，不压制当前 resp）而不是 flush，
  // 避免 bpu_redirect -> flush -> resp 的组合环，同时省掉一拍重定向气泡。
  assign bpu_redirect_comb = resp_valid && resp_ready && !redirect_valid &&
                             (dec_is_branch || dec_is_jal || dec_is_jalr) &&
                             bpu_taken;
  assign fetch_valid = backend_ready && !redirect_valid &&
                       !bpu_redirect_comb && fq_has_space && !reset;
  assign pc_advance  = fetch_valid && fetch_ready;
  assign resp_ready  = backend_ready && !redirect_valid && fq_has_space;

  icache_pipe #(
    .INDEX_BITS (`CPU_ICACHE_INDEX_BITS)
  ) u_icache (
    .clk               (clk),
    .reset             (reset),
    .flush             (redirect_valid),
    .discard           (bpu_redirect_comb),
    .fetch_valid       (fetch_valid),
    .fetch_pc          (pc),
    .fetch_ready       (fetch_ready),
    .fetch_resp_valid  (resp_valid),
    .fetch_resp_pc     (resp_pc),
    .fetch_inst        (resp_inst),
    .fetch_resp_ready  (resp_ready),
    .refill_valid      (refill_valid),
    .refill_addr       (refill_addr),
    .refill_resp_valid (refill_resp_valid),
    .refill_rdata      (refill_rdata)
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
    .instr        (resp_inst),
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

  // ---- BPU ---------------------------------------------------------------
  logic        bpu_taken;
  logic [31:0] bpu_target;

  bpu u_bpu (
    .clk             (clk),
    .reset           (reset),
    .fetch_pc        (resp_pc),
    .predict_taken   (bpu_taken),
    .predict_target  (bpu_target),
    .upd_valid       (br_update_valid),
    .upd_pc          (br_update_pc),
    .upd_taken       (br_update_taken),
    .upd_target      (br_update_target),
    .upd_is_uncond   (br_update_uncond)
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

  // ---- FIFO 时序 ---------------------------------------------------------
  integer i_slot;
  always_ff @(posedge clk) begin
    if (reset || redirect_valid) begin
      fq_valid <= '0;
      fq_head  <= '0;
      fq_tail  <= '0;
      fq_count <= '0;
    end else begin
      // push 译码结果
      if (resp_valid && resp_ready) begin
        fq_valid[fq_tail] <= 1'b1;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_PC_OFF +: 32]    <= resp_pc;
        fq_uop[fq_tail*`CPU_DECODE_W + `CPU_DISPATCH_INST_OFF +: 32]  <= resp_inst;
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
        fq_pred_taken[fq_tail]  <= bpu_taken;
        fq_pred_target[fq_tail*32 +: 32] <= bpu_target;
        fq_tail <= (fq_tail == FDEPTH - 1) ? '0 : fq_tail + 1'b1;
      end

      // pop：一次送 W 条（或 FIFO 里剩余的全部）
      if (pop_fire) begin
        for (i_slot = 0; i_slot < W; i_slot = i_slot + 1) begin
          if (i_slot < fq_count) begin
            fq_valid[(fq_head + i_slot) % FDEPTH] <= 1'b0;
          end
        end
        fq_head  <= (fq_head + pop_n) % FDEPTH;
      end

      fq_count <= fq_count +
                  ((resp_valid && resp_ready) ? 1'b1 : 1'b0) -
                  (pop_fire ? pop_n : '0);
    end
  end

endmodule
