// -----------------------------------------------------------------------------
// backend_ooo.sv — 乱序执行后端薄封装（P1）
//
// 组成：
//   issue_queue -> PRF 读 -> ALU / divider / LSU
//   cdb 仲裁 -> ROB/rename + PRF 写 + IQ 唤醒
//   lsu（内含 lsq）-> data_mem
//
// P1 发射宽度固定 1（IW=1），但 dispatch 仍按 W 路整体吸收；W=2 时先证明
// 前端双 slot dispatch 能被后端正确接收，执行端口后续 P2 再扩宽。
// -----------------------------------------------------------------------------

module backend_ooo #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic clk,
  input  logic reset,

  // core_ooo 冻结接口
  input  logic [`CPU_DISPATCH_BUS_W-1:0] dispatch,
  input  logic [`CPU_COMMIT_BUS_W-1:0]   commit,
  input  logic [`CPU_SQUASH_W-1:0]       squash,
  output logic [`CPU_CDB_BUS_W-1:0]      cdb,
  output logic [`CPU_COMPLETE_BUS_W-1:0] complete,
  output logic [`CPU_BR_UPDATE_W-1:0]    br_update,
  output logic                           backend_ready,

  // pipelined load interface (to mem_subsystem)
  output logic        ld_req_valid,
  output logic [31:0] ld_req_addr,
  input  logic        ld_req_ready,
  input  logic        ld_resp_valid,
  input  logic [31:0] ld_resp_rdata,

  // store invalidation for the read-only D-Cache
  output logic        st_inv_valid,
  output logic [31:0] st_inv_addr,

  // pipelined store interface (to mem_subsystem)
  output logic        st_req_valid,
  output logic [31:0] st_req_addr,
  output logic [31:0] st_req_wdata,
  output logic [3:0]  st_req_wstrb,
  input  logic        st_req_ready,
  input  logic        st_resp_valid
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer RW = `CPU_ROB_TAG_W;
  localparam integer LW = `CPU_LSQ_IDX_W;
  localparam integer DW = `CPU_DISPATCH_W;
  localparam integer CW = `CPU_CDB_W;
  localparam integer MW = `CPU_COMPLETE_W;
  localparam integer R  = `CPU_CDB_NUM;

  // ---------------------------------------------------------------------------
  // dispatch / commit / squash 解包
  // ---------------------------------------------------------------------------
  logic [W-1:0]        disp_valid;
  integer i;
  always_comb begin
    for (i = 0; i < W; i = i + 1)
      disp_valid[i] = dispatch[i*DW + `CPU_DISPATCH_VALID_OFF];
  end

  // dispatch skid buffer: breaks the combinational loop
  // backend_ready -> ren_ready -> dispatch.valid -> iq/lsq ready -> backend_ready.
  logic                 skid_valid;
  logic [W-1:0]         skid_vmask;
  logic [W*DW-1:0]      skid_uop;
  logic [W-1:0]         skid_is_load, skid_is_store;
  logic [W*LW-1:0]      skid_lsq;
  logic [W*RW-1:0]      skid_rob;
  logic                 skid_drain;

  // unified dispatch sequence for IQ/LSQ squash
  logic [31:0]          disp_seq;
  logic [31:0]          rob_seq [0:`CPU_ROB_DEPTH-1];
  logic [31:0]          squash_seq;
  logic [3:0]           n_disp;

  assign squash_seq = rob_seq[sq_rob];

  always_comb begin
    n_disp = '0;
    for (i = 0; i < W; i = i + 1)
      if (skid_vmask[i]) n_disp = n_disp + 1'b1;
  end

  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      skid_is_load[i]  = skid_uop[i*DW + `CPU_DISPATCH_IS_LOAD_OFF];
      skid_is_store[i] = skid_uop[i*DW + `CPU_DISPATCH_IS_STORE_OFF];
      skid_lsq[i*LW +: LW] = skid_uop[i*DW + `CPU_DISPATCH_LSQ_ID_OFF +: LW];
      skid_rob[i*RW +: RW] = skid_uop[i*DW + `CPU_DISPATCH_ROB_IDX_OFF +: RW];
    end
  end

  // skid 持有期间 producer 可能已经通过 CDB 完成；必须更新保存的 ready 位，
  // 否则 IQ 会等待一个已经过去的广播。
  logic [W*DW-1:0] skid_uop_next;
  logic [W*DW-1:0] disp_uop_woken;

  function automatic logic wake_hit(input logic [PW-1:0] tag);
    integer w;
    begin
      wake_hit = 1'b0;
      for (w = 0; w < R; w = w + 1)
        if (cdb_wake_valid[w] && (cdb_wake_tag[w*PW +: PW] == tag))
          wake_hit = 1'b1;
    end
  endfunction

  always_comb begin
    skid_uop_next  = skid_uop;
    disp_uop_woken = dispatch;
    for (i = 0; i < W; i = i + 1) begin
      if (!skid_uop_next[i*DW + `CPU_DISPATCH_SRC1_READY_OFF] &&
          wake_hit(skid_uop_next[i*DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW]))
        skid_uop_next[i*DW + `CPU_DISPATCH_SRC1_READY_OFF] = 1'b1;
      if (!skid_uop_next[i*DW + `CPU_DISPATCH_SRC2_READY_OFF] &&
          wake_hit(skid_uop_next[i*DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW]))
        skid_uop_next[i*DW + `CPU_DISPATCH_SRC2_READY_OFF] = 1'b1;

      if (!disp_uop_woken[i*DW + `CPU_DISPATCH_SRC1_READY_OFF] &&
          wake_hit(disp_uop_woken[i*DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW]))
        disp_uop_woken[i*DW + `CPU_DISPATCH_SRC1_READY_OFF] = 1'b1;
      if (!disp_uop_woken[i*DW + `CPU_DISPATCH_SRC2_READY_OFF] &&
          wake_hit(disp_uop_woken[i*DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW]))
        disp_uop_woken[i*DW + `CPU_DISPATCH_SRC2_READY_OFF] = 1'b1;
    end
  end

  // squash 也要清 skid：被解析的 branch 已经离开 skid，skid 里的内容必然
  // 比它年轻，属于错误路径。整组丢弃，避免 seq 映射边界问题。
  logic [W-1:0] skid_vmask_next;
  always_comb begin
    skid_vmask_next = skid_vmask;
    if (sq_valid)
      skid_vmask_next = '0;
  end

  logic [W-1:0]    cm_valid, cm_is_store, cm_is_load;
  logic [W*LW-1:0] cm_lsq;

  always_comb begin
    for (i = 0; i < W; i = i + 1) begin
      cm_valid[i]    = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_VALID_OFF];
      cm_is_store[i] = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_IS_STORE_OFF];
      cm_is_load[i]  = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_IS_LOAD_OFF];
      cm_lsq[i*LW +: LW] = commit[i*`CPU_COMMIT_W + `CPU_COMMIT_LSQ_ID_OFF +: LW];
    end
  end

  logic        sq_valid;
  logic [RW-1:0] sq_rob;
  assign sq_valid = squash[`CPU_SQUASH_VALID_OFF];
  assign sq_rob   = squash[`CPU_SQUASH_ROB_IDX_OFF +: RW];

  // CDB -> IQ 唤醒（提前声明：IQ 例化使用）
  logic [R-1:0]    cdb_wake_valid;
  logic [R*PW-1:0] cdb_wake_tag;

  // ---------------------------------------------------------------------------
  // Issue Queue
  // ---------------------------------------------------------------------------
  logic        iq_in_ready;
  logic [1:0]  iq_out_valid;
  logic [1:0]  iq_out_addr_only;
  logic [2*DW-1:0] issue_uop;
  logic [2*32-1:0] issue_seq;
  logic [1:0]  issue_ready;
  logic [7:0]  iq_count, iq_free;

  issue_queue #(.W(W), .IW(2)) u_iq (
    .clk            (clk),
    .reset          (reset),
    .in_valid       (skid_drain ? skid_vmask : '0),
    .in_alloc_mask  (skid_valid ? skid_vmask : '0),
    .in_uop         (skid_uop),
    .in_ready       (iq_in_ready),
    .wake_valid     (cdb_wake_valid),
    .wake_tag       (cdb_wake_tag),
    .seq_base       (disp_seq),
    .squash_valid   (sq_valid),
    .squash_seq     (squash_seq),
    .out_valid      (iq_out_valid),
    .out_addr_only  (iq_out_addr_only),
    .out_uop        (issue_uop),
    .out_seq        (issue_seq),
    .out_ready      (issue_ready),
    .count          (iq_count),
    .free_count     (iq_free)
  );

  // ---------------------------------------------------------------------------
  // issue uop 字段
  // ---------------------------------------------------------------------------
  logic [31:0]   i_pc, i_inst, i_imm;
  logic [PW-1:0] i_dest, i_src1_tag, i_src2_tag;
  logic [RW-1:0] i_rob;
  logic [4:0]    i_alu_op;
  logic [1:0]    i_a_sel, i_wb_sel;
  logic          i_b_sel, i_reg_we, i_illegal;
  logic          i_is_branch, i_is_jal, i_is_jalr;
  logic          i_is_load, i_is_store;

  assign i_pc          = issue_uop[`CPU_DISPATCH_PC_OFF +: 32];
  assign i_inst        = issue_uop[`CPU_DISPATCH_INST_OFF +: 32];
  assign i_imm         = issue_uop[`CPU_DISPATCH_IMM_OFF +: 32];
  assign i_dest        = issue_uop[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign i_src1_tag    = issue_uop[`CPU_DISPATCH_SRC1_TAG_OFF +: PW];
  assign i_src2_tag    = issue_uop[`CPU_DISPATCH_SRC2_TAG_OFF +: PW];
  assign i_rob         = issue_uop[`CPU_DISPATCH_ROB_IDX_OFF +: RW];
  assign i_alu_op      = issue_uop[`CPU_DISPATCH_ALU_OP_OFF +: 5];
  assign i_a_sel       = issue_uop[`CPU_DISPATCH_A_SEL_OFF +: 2];
  assign i_b_sel       = issue_uop[`CPU_DISPATCH_B_SEL_OFF];
  assign i_wb_sel      = issue_uop[`CPU_DISPATCH_WB_SEL_OFF +: 2];
  assign i_reg_we      = issue_uop[`CPU_DISPATCH_REG_WE_OFF];
  assign i_illegal     = issue_uop[`CPU_DISPATCH_ILLEGAL_OFF];
  assign i_is_branch   = issue_uop[`CPU_DISPATCH_IS_BRANCH_OFF];
  assign i_is_jal      = issue_uop[`CPU_DISPATCH_IS_JAL_OFF];
  assign i_is_jalr     = issue_uop[`CPU_DISPATCH_IS_JALR_OFF];
  assign i_is_load     = issue_uop[`CPU_DISPATCH_IS_LOAD_OFF];
  assign i_is_store    = issue_uop[`CPU_DISPATCH_IS_STORE_OFF];

  logic i_is_mem, i_is_div, i_is_branch_any;
  assign i_is_mem        = i_is_load | i_is_store;
  assign i_is_div        = (i_alu_op == `ALU_DIV) || (i_alu_op == `ALU_DIVU) ||
                           (i_alu_op == `ALU_REM) || (i_alu_op == `ALU_REMU);
  assign i_is_branch_any = i_is_branch | i_is_jal | i_is_jalr;

  // ---- lane 1（只做普通 ALU；访存/除法/分支只走 lane 0） ------------------
  logic [31:0]   j_pc, j_inst, j_imm;
  logic [PW-1:0] j_dest, j_src1_tag, j_src2_tag;
  logic [4:0]    j_alu_op;
  logic [1:0]    j_a_sel, j_wb_sel;
  logic          j_b_sel, j_reg_we, j_illegal;
  logic          j_is_branch, j_is_jal, j_is_jalr;
  logic          j_is_load, j_is_store;
  logic          j_is_mem, j_is_div, j_is_branch_any;
  logic          j_lane_ok;

  assign j_pc          = issue_uop[DW + `CPU_DISPATCH_PC_OFF +: 32];
  assign j_inst        = issue_uop[DW + `CPU_DISPATCH_INST_OFF +: 32];
  assign j_imm         = issue_uop[DW + `CPU_DISPATCH_IMM_OFF +: 32];
  assign j_dest        = issue_uop[DW + `CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign j_src1_tag    = issue_uop[DW + `CPU_DISPATCH_SRC1_TAG_OFF +: PW];
  assign j_src2_tag    = issue_uop[DW + `CPU_DISPATCH_SRC2_TAG_OFF +: PW];
  assign j_alu_op      = issue_uop[DW + `CPU_DISPATCH_ALU_OP_OFF +: 5];
  assign j_a_sel       = issue_uop[DW + `CPU_DISPATCH_A_SEL_OFF +: 2];
  assign j_b_sel       = issue_uop[DW + `CPU_DISPATCH_B_SEL_OFF];
  assign j_wb_sel      = issue_uop[DW + `CPU_DISPATCH_WB_SEL_OFF +: 2];
  assign j_reg_we      = issue_uop[DW + `CPU_DISPATCH_REG_WE_OFF];
  assign j_illegal     = issue_uop[DW + `CPU_DISPATCH_ILLEGAL_OFF];
  assign j_is_branch   = issue_uop[DW + `CPU_DISPATCH_IS_BRANCH_OFF];
  assign j_is_jal      = issue_uop[DW + `CPU_DISPATCH_IS_JAL_OFF];
  assign j_is_jalr     = issue_uop[DW + `CPU_DISPATCH_IS_JALR_OFF];
  assign j_is_load     = issue_uop[DW + `CPU_DISPATCH_IS_LOAD_OFF];
  assign j_is_store    = issue_uop[DW + `CPU_DISPATCH_IS_STORE_OFF];

  assign j_is_mem        = j_is_load | j_is_store;
  assign j_is_div        = (j_alu_op == `ALU_DIV) || (j_alu_op == `ALU_DIVU) ||
                           (j_alu_op == `ALU_REM) || (j_alu_op == `ALU_REMU);
  assign j_is_branch_any = j_is_branch | j_is_jal | j_is_jalr;
  assign j_lane_ok       = j_reg_we && !j_is_mem && !j_is_div &&
                           !j_is_branch_any && !j_illegal;

  // ---- lane1 ALU pipeline register ----------------------------------------
  // IQ 选择 -> ALU1 缓冲 -> PRF 读/ALU。lane0 和 load/store 仍是原来的
  // 同拍路径；这里只切断 lane1 的“IQ 选择 + PRF 读 + ALU”长组合路径。
  logic          a1_valid_q;
  logic [DW-1:0] a1_uop_q;
  logic [31:0]   a1_seq_q;
  logic          a1_accept, a1_discard, a1_squashed, a1_push;
  logic          a1_issue, a1_issue_ready;

  logic [31:0]   p_pc, p_imm;
  logic [PW-1:0] p_dest, p_src1_tag, p_src2_tag;
  logic [4:0]    p_alu_op;
  logic [1:0]    p_a_sel, p_wb_sel;
  logic          p_b_sel, p_reg_we, p_illegal;
  logic          p_is_load, p_is_store, p_is_div, p_is_branch_any;
  logic          p_needs_alu_result;

  assign p_pc          = a1_uop_q[`CPU_DISPATCH_PC_OFF +: 32];
  assign p_imm         = a1_uop_q[`CPU_DISPATCH_IMM_OFF +: 32];
  assign p_dest        = a1_uop_q[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign p_src1_tag    = a1_uop_q[`CPU_DISPATCH_SRC1_TAG_OFF +: PW];
  assign p_src2_tag    = a1_uop_q[`CPU_DISPATCH_SRC2_TAG_OFF +: PW];
  assign p_alu_op      = a1_uop_q[`CPU_DISPATCH_ALU_OP_OFF +: 5];
  assign p_a_sel       = a1_uop_q[`CPU_DISPATCH_A_SEL_OFF +: 2];
  assign p_b_sel       = a1_uop_q[`CPU_DISPATCH_B_SEL_OFF];
  assign p_wb_sel      = a1_uop_q[`CPU_DISPATCH_WB_SEL_OFF +: 2];
  assign p_reg_we      = a1_uop_q[`CPU_DISPATCH_REG_WE_OFF];
  assign p_illegal     = a1_uop_q[`CPU_DISPATCH_ILLEGAL_OFF];
  assign p_is_load     = a1_uop_q[`CPU_DISPATCH_IS_LOAD_OFF];
  assign p_is_store    = a1_uop_q[`CPU_DISPATCH_IS_STORE_OFF];
  assign p_is_div      = (p_alu_op == `ALU_DIV) || (p_alu_op == `ALU_DIVU) ||
                         (p_alu_op == `ALU_REM) || (p_alu_op == `ALU_REMU);
  assign p_is_branch_any = a1_uop_q[`CPU_DISPATCH_IS_BRANCH_OFF] |
                           a1_uop_q[`CPU_DISPATCH_IS_JAL_OFF] |
                           a1_uop_q[`CPU_DISPATCH_IS_JALR_OFF];
  assign p_needs_alu_result = !p_is_load && !p_is_store && !p_is_div &&
                              p_reg_we && !p_illegal && !p_is_branch_any;

  // ---- lane0 非访存流水缓冲 ------------------------------------------------
  // load/store 仍然从 IQ 直接进 LSU；只有非访存 uop 进入这个缓冲，下一拍
  // 再做 PRF 读和 ALU/div/branch。这样不会把访存放进流水级，避免旧实验
  // 的 load/store 所有权死锁。
  logic          a0_valid_q;
  logic [DW-1:0] a0_uop_q;
  logic [31:0]   a0_seq_q;
  logic          a0_accept, a0_discard, a0_squashed, a0_push, a0_issue;
  logic          a0_issue_ready;

  logic [31:0]   a0_pc, a0_inst, a0_imm;
  logic [PW-1:0] a0_dest, a0_src1_tag, a0_src2_tag;
  logic [4:0]    a0_alu_op;
  logic [1:0]    a0_a_sel, a0_wb_sel;
  logic          a0_b_sel, a0_reg_we, a0_illegal;
  logic          a0_is_load, a0_is_store, a0_is_div, a0_is_branch_any;
  logic          a0_is_branch, a0_is_jal, a0_is_jalr;
  logic          a0_needs_alu_result;

  assign a0_pc          = a0_uop_q[`CPU_DISPATCH_PC_OFF +: 32];
  assign a0_inst        = a0_uop_q[`CPU_DISPATCH_INST_OFF +: 32];
  assign a0_imm         = a0_uop_q[`CPU_DISPATCH_IMM_OFF +: 32];
  assign a0_dest        = a0_uop_q[`CPU_DISPATCH_DEST_TAG_OFF +: PW];
  assign a0_src1_tag    = a0_uop_q[`CPU_DISPATCH_SRC1_TAG_OFF +: PW];
  assign a0_src2_tag    = a0_uop_q[`CPU_DISPATCH_SRC2_TAG_OFF +: PW];
  assign a0_alu_op      = a0_uop_q[`CPU_DISPATCH_ALU_OP_OFF +: 5];
  assign a0_a_sel       = a0_uop_q[`CPU_DISPATCH_A_SEL_OFF +: 2];
  assign a0_b_sel       = a0_uop_q[`CPU_DISPATCH_B_SEL_OFF];
  assign a0_wb_sel      = a0_uop_q[`CPU_DISPATCH_WB_SEL_OFF +: 2];
  assign a0_reg_we      = a0_uop_q[`CPU_DISPATCH_REG_WE_OFF];
  assign a0_illegal     = a0_uop_q[`CPU_DISPATCH_ILLEGAL_OFF];
  assign a0_is_load     = a0_uop_q[`CPU_DISPATCH_IS_LOAD_OFF];
  assign a0_is_store    = a0_uop_q[`CPU_DISPATCH_IS_STORE_OFF];
  assign a0_is_branch   = a0_uop_q[`CPU_DISPATCH_IS_BRANCH_OFF];
  assign a0_is_jal      = a0_uop_q[`CPU_DISPATCH_IS_JAL_OFF];
  assign a0_is_jalr     = a0_uop_q[`CPU_DISPATCH_IS_JALR_OFF];
  assign a0_is_div      = (a0_alu_op == `ALU_DIV) || (a0_alu_op == `ALU_DIVU) ||
                          (a0_alu_op == `ALU_REM) || (a0_alu_op == `ALU_REMU);
  assign a0_is_branch_any = a0_is_branch | a0_is_jal | a0_is_jalr;
  assign a0_needs_alu_result = !a0_is_load && !a0_is_store && !a0_is_div &&
                               a0_reg_we && !a0_illegal;

  // ---------------------------------------------------------------------------
  // PRF（6 个读口：lane0 直连 + lane0 缓冲 + lane1 缓冲）
  // ---------------------------------------------------------------------------
  logic [6*PW-1:0] prf_raddr;
  logic [6*32-1:0] prf_rdata;
  logic [R-1:0]      prf_we;
  logic [R*PW-1:0]   prf_waddr;
  logic [R*32-1:0]   prf_wdata;

  always_comb begin
    prf_raddr = '0;
    prf_raddr[0 +: PW]    = i_src1_tag;
    prf_raddr[PW +: PW]   = i_src2_tag;
    prf_raddr[2*PW +: PW] = p_src1_tag;
    prf_raddr[3*PW +: PW] = p_src2_tag;
    prf_raddr[4*PW +: PW] = a0_src1_tag;
    prf_raddr[5*PW +: PW] = a0_src2_tag;
  end

  logic [31:0] issue_src1, issue_src2;
  logic [31:0] p_src1, p_src2;
  logic [31:0] a0_src1, a0_src2;
  logic        cdb_bypass1, cdb_bypass2;
  logic        cdb_bypass3, cdb_bypass4, cdb_bypass5, cdb_bypass6;
  logic [31:0] cdb_bp1, cdb_bp2, cdb_bp3, cdb_bp4, cdb_bp5, cdb_bp6;
  integer ib;

  // 同拍 CDB 旁路（R 条 CDB 都要检查；lane 0 优先）。
  always_comb begin
    cdb_bypass1 = 1'b0; cdb_bp1 = 32'b0;
    cdb_bypass2 = 1'b0; cdb_bp2 = 32'b0;
    cdb_bypass3 = 1'b0; cdb_bp3 = 32'b0;
    cdb_bypass4 = 1'b0; cdb_bp4 = 32'b0;
    cdb_bypass5 = 1'b0; cdb_bp5 = 32'b0;
    cdb_bypass6 = 1'b0; cdb_bp6 = 32'b0;
    for (ib = 0; ib < R; ib = ib + 1) begin
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == i_src1_tag)) begin
        cdb_bypass1 = 1'b1; cdb_bp1 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == i_src2_tag)) begin
        cdb_bypass2 = 1'b1; cdb_bp2 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == p_src1_tag)) begin
        cdb_bypass3 = 1'b1; cdb_bp3 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == p_src2_tag)) begin
        cdb_bypass4 = 1'b1; cdb_bp4 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == a0_src1_tag)) begin
        cdb_bypass5 = 1'b1; cdb_bp5 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
      if (cdb[ib*CW + `CPU_CDB_VALID_OFF] &&
          (cdb[ib*CW + `CPU_CDB_TAG_OFF +: PW] == a0_src2_tag)) begin
        cdb_bypass6 = 1'b1; cdb_bp6 = cdb[ib*CW + `CPU_CDB_VALUE_OFF +: 32];
      end
    end
  end

  assign issue_src1 = cdb_bypass1 ? cdb_bp1 : prf_rdata[0 +: 32];
  assign issue_src2 = cdb_bypass2 ? cdb_bp2 : prf_rdata[32 +: 32];
  assign p_src1 = cdb_bypass3 ? cdb_bp3 : prf_rdata[2*32 +: 32];
  assign p_src2 = cdb_bypass4 ? cdb_bp4 : prf_rdata[3*32 +: 32];
  assign a0_src1 = cdb_bypass5 ? cdb_bp5 : prf_rdata[4*32 +: 32];
  assign a0_src2 = cdb_bypass6 ? cdb_bp6 : prf_rdata[5*32 +: 32];

  always_comb begin
    for (i = 0; i < R; i = i + 1) begin
      prf_we[i] = cdb[i*CW + `CPU_CDB_VALID_OFF];
      prf_waddr[i*PW +: PW] = cdb[i*CW + `CPU_CDB_TAG_OFF +: PW];
      prf_wdata[i*32 +: 32] = cdb[i*CW + `CPU_CDB_VALUE_OFF +: 32];
    end
  end

  prf #(.W(3), .R(R)) u_prf (
    .clk   (clk),
    .reset (reset),
    .raddr (prf_raddr),
    .rdata (prf_rdata),
    .we    (prf_we),
    .waddr (prf_waddr),
    .wdata (prf_wdata)
  );

  // ---------------------------------------------------------------------------
  // ALU
  // ---------------------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_y;
  logic [31:0] a0_pc_plus4;
  assign a0_pc_plus4 = a0_pc + 32'd4;

  always_comb begin
    alu_a = (a0_a_sel == `A_REG)  ? a0_src1 :
            (a0_a_sel == `A_PC)   ? a0_pc :
                                    32'b0;
    alu_b = a0_b_sel ? a0_imm : a0_src2;
  end

  alu u_alu (
    .a  (alu_a),
    .b  (alu_b),
    .op (a0_alu_op),
    .y  (alu_y)
  );

  logic [31:0] wb_value;
  assign wb_value = (a0_wb_sel == `WB_PC4) ? a0_pc_plus4 : alu_y;

  // lane 1 ALU（只处理普通写回 ALU 指令）
  logic [31:0] alu1_a, alu1_b, alu1_y;
  logic [31:0] p_pc_plus4, wb1_value;
  assign p_pc_plus4 = p_pc + 32'd4;

  always_comb begin
    alu1_a = (p_a_sel == `A_REG)  ? p_src1 :
             (p_a_sel == `A_PC)   ? p_pc :
                                    32'b0;
    alu1_b = p_b_sel ? p_imm : p_src2;
  end

  alu u_alu1 (
    .a  (alu1_a),
    .b  (alu1_b),
    .op (p_alu_op),
    .y  (alu1_y)
  );

  assign wb1_value = (p_wb_sel == `WB_PC4) ? p_pc_plus4 : alu1_y;

  // ---------------------------------------------------------------------------
  // 分支解析
  // ---------------------------------------------------------------------------
  logic        br_taken;
  logic [31:0] br_target;

  always_comb begin
    br_taken  = 1'b0;
    br_target = a0_pc + a0_imm;
    if (a0_is_jal) begin
      br_taken  = 1'b1;
      br_target = a0_pc + a0_imm;
    end else if (a0_is_jalr) begin
      br_taken  = 1'b1;
      br_target = (a0_src1 + a0_imm) & ~32'h1;
    end else if (a0_is_branch) begin
      unique case (a0_inst[14:12])
        3'b000: br_taken = (a0_src1 == a0_src2);
        3'b001: br_taken = (a0_src1 != a0_src2);
        3'b100: br_taken = ($signed(a0_src1) < $signed(a0_src2));
        3'b101: br_taken = ($signed(a0_src1) >= $signed(a0_src2));
        3'b110: br_taken = (a0_src1 < a0_src2);
        3'b111: br_taken = (a0_src1 >= a0_src2);
        default: br_taken = 1'b0;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // 执行结果缓冲（P1 单发射）
  // ---------------------------------------------------------------------------
  logic        alu_valid_q;
  logic [PW-1:0] alu_tag_q;
  logic [31:0]  alu_seq_q;
  logic [31:0] alu_value_q;
  logic        alu_exc_q;

  logic        alu1_valid_q;
  logic [PW-1:0] alu1_tag_q;
  logic [31:0]  alu1_seq_q;
  logic [31:0] alu1_value_q;
  logic        alu1_exc_q;

  logic        div_valid_q;
  logic [PW-1:0] div_tag_q;
  logic [31:0]  div_seq_q;
  logic [31:0] div_value_q;
  logic        div_exc_q;
  logic [31:0]  div_pending_seq;
  logic        div_discard;

  logic        br_valid_q;
  logic [31:0] br_pc_q, br_target_q;
  logic        br_taken_q, br_jalr_q;
  logic [PW-1:0] br_tag_q;
  logic [31:0]  br_seq_q;

  // 无值完成（store/branch/非写回 ALU/非法）先进入小 FIFO，避免同一拍
  // 多个来源互相覆盖，也允许连续 store 每拍完成。
  localparam integer CF_DEPTH = 4;
  logic [CF_DEPTH-1:0]      cf_discard;
  logic [CF_DEPTH*PW-1:0]   cf_tag;
  logic [CF_DEPTH-1:0]      cf_exc;
  logic [CF_DEPTH*32-1:0]   cf_seq;
  logic [2:0]               cf_head, cf_tail, cf_count;
  logic                     cf_push, cf_pop, cf_allow;
  logic [PW-1:0]            cf_tag_in;
  logic                     cf_exc_in;
  logic [31:0]              cf_seq_in;
  logic                     noval_issue, noval_expected;

  // 需要 ALU 产生 CDB 值的 uop
  logic needs_alu_result;
  assign needs_alu_result = a0_needs_alu_result;

  assign a0_issue_ready = a0_is_div ? div_issue_ready :
                          (!a0_needs_alu_result ||
                           !alu_valid_q || cdb_src_ready[0]);
  assign a1_issue_ready = !p_needs_alu_result ||
                          !alu1_valid_q || cdb_src_ready[1];
  assign a0_squashed = a0_valid_q && sq_valid && (a0_seq_q > squash_seq);
  assign a0_discard  = a0_squashed;
  assign a0_accept   = !a0_valid_q || a0_discard || a0_issue_ready;
  assign a0_issue    = a0_valid_q && !a0_squashed && a0_issue_ready;
  assign a1_squashed = a1_valid_q && sq_valid && (a1_seq_q > squash_seq);
  assign a1_discard  = a1_squashed;
  assign a1_accept   = !a1_valid_q || a1_discard || a1_issue_ready;
  assign a1_issue    = a1_valid_q && !a1_squashed && a1_issue_ready;

  assign noval_expected = i_is_store ||
                          (!i_is_load && !i_is_div &&
                           (i_illegal || !i_reg_we));
  assign cf_allow = (cf_count < CF_DEPTH) || cf_pop;

  // divider
  logic        div_start, div_busy, div_done;
  logic        div_is_signed;
  logic [31:0] div_quot, div_rem;
  logic [4:0]  div_op_q;
  logic [PW-1:0] div_tag_pending;
  logic        div_exc_pending;

  assign div_is_signed = (a0_alu_op == `ALU_DIV) || (a0_alu_op == `ALU_REM);

  logic div_issue_ready;
  assign div_issue_ready = !div_busy && !div_done && !div_valid_q;

  divider u_div (
    .clk       (clk),
    .reset     (reset),
    .start     (div_start),
    .is_signed (div_is_signed),
    .a         (a0_src1),
    .b         (a0_src2),
    .busy      (div_busy),
    .done      (div_done),
    .quotient  (div_quot),
    .remainder (div_rem)
  );

  // LSU
  logic        lsu_issue_ready;
  logic        lsu_load_valid;
  logic [PW-1:0] lsu_load_tag;
  logic [31:0] lsu_load_value;
  logic        lsu_load_exc;
  logic        lsu_store_valid;
  logic [PW-1:0] lsu_store_tag;
  logic        lsu_store_exc;
  logic        lsu_alloc_ready;
  logic        lsu_busy;

  lsu #(.W(W)) u_lsu (
    .clk                  (clk),
    .reset                (reset),
    .alloc_valid          (skid_valid ?
                           (skid_vmask & (skid_is_load | skid_is_store)) : '0),
    .alloc_id             (skid_lsq),
    .alloc_rob            (skid_rob),
    .alloc_is_store       (skid_is_store),
    .alloc_ready          (lsu_alloc_ready),
    .alloc_fire           (skid_drain),
    .seq_base             (disp_seq),
    .squash_seq           (squash_seq),
    .issue_valid          (iq_out_valid[0] && issue_ready[0] && i_is_mem),
    .issue_uop            (issue_uop[DW-1:0]),
    .issue_seq            (issue_seq[31:0]),
    .issue_src1           (issue_src1),
    .issue_src2           (issue_src2),
    .issue_addr_only      (addr_only_issue),
    .issue_ready          (lsu_issue_ready),
    .commit_valid         (cm_valid),
    .commit_is_store      (cm_is_store),
    .commit_is_load       (cm_is_load),
    .commit_id            (cm_lsq),
    .squash_valid         (sq_valid),
    .squash_rob_idx       (sq_rob),
    .load_result_valid    (lsu_load_valid),
    .load_result_tag      (lsu_load_tag),
    .load_result_value    (lsu_load_value),
    .load_result_exception(lsu_load_exc),
    .load_result_ready    (cdb_src_ready[2]),
    .store_complete_valid (lsu_store_valid),
    .store_complete_tag   (lsu_store_tag),
    .store_complete_exception (lsu_store_exc),
    .ld_req_valid         (ld_req_valid),
    .ld_req_addr          (ld_req_addr),
    .ld_req_ready         (ld_req_ready),
    .ld_resp_valid        (ld_resp_valid),
    .ld_resp_rdata        (ld_resp_rdata),
    .st_inv_valid         (st_inv_valid),
    .st_inv_addr          (st_inv_addr),
    .st_req_valid         (st_req_valid),
    .st_req_addr          (st_req_addr),
    .st_req_wdata         (st_req_wdata),
    .st_req_wstrb         (st_req_wstrb),
    .st_req_ready         (st_req_ready),
    .st_resp_valid        (st_resp_valid),
    .busy                 (lsu_busy)
  );

  // ---------------------------------------------------------------------------
  // issue 路由
  // ---------------------------------------------------------------------------
  logic addr_only_issue, i_mem_ready;
  // address-only store 不产生 complete，不占用 complete FIFO。
  assign addr_only_issue = iq_out_valid[0] && iq_out_addr_only[0] && i_is_store;
  assign i_mem_ready = lsu_issue_ready &&
                       (addr_only_issue || !noval_expected || cf_allow);
  // lane0：load/store 仍然直连 LSU；非访存进入 a0 缓冲，下一拍执行。
  assign issue_ready[0] = i_is_mem ? i_mem_ready :
                          (a0_accept && (!noval_expected || cf_allow));
  assign a0_push = iq_out_valid[0] && issue_ready[0] && !i_is_mem;
  // lane 1 只接收普通写回 ALU；资源独立且不产生有副作用的完成。
  // IQ 选中后先进入 a1 缓冲，下一拍再做 PRF 读/ALU；缓冲能吸收时即可
  // 从 IQ 弹出，保持 lane1 每拍一条的吞吐。
  assign issue_ready[1] = iq_out_valid[1] && j_lane_ok && a1_accept;
  assign a1_push        = iq_out_valid[1] && issue_ready[1];

  logic alu_issue, div_issue, alu1_issue;
  assign alu_issue  = a0_issue && !a0_is_div;
  assign div_issue  = a0_issue && a0_is_div;
  assign alu1_issue = a1_issue;

  assign div_start = div_issue;

  // ---------------------------------------------------------------------------
  // CDB
  // ---------------------------------------------------------------------------
  localparam integer N = 4;  // alu0, alu1, load, div
  logic [N-1:0]                   cdb_src_valid;
  logic [N*PW-1:0]                cdb_src_tag;
  logic [N*32-1:0]                cdb_src_value;
  logic [N-1:0]                   cdb_src_exc;
  logic [N-1:0]                   cdb_src_ready;
  logic [`CPU_CDB_BUS_W-1:0]      cdb_out;

  always_comb begin
    cdb_src_valid = '0;
    cdb_src_tag   = '0;
    cdb_src_value = '0;
    cdb_src_exc   = '0;

    cdb_src_valid[0] = alu_valid_q;
    cdb_src_tag[0 +: PW] = alu_tag_q;
    cdb_src_value[0 +: 32] = alu_value_q;
    cdb_src_exc[0] = alu_exc_q;

    cdb_src_valid[1] = alu1_valid_q;
    cdb_src_tag[1*PW +: PW] = alu1_tag_q;
    cdb_src_value[1*32 +: 32] = alu1_value_q;
    cdb_src_exc[1] = alu1_exc_q;

    cdb_src_valid[2] = lsu_load_valid;
    cdb_src_tag[2*PW +: PW] = lsu_load_tag;
    cdb_src_value[2*32 +: 32] = lsu_load_value;
    cdb_src_exc[2] = lsu_load_exc;

    cdb_src_valid[3] = div_valid_q;
    cdb_src_tag[3*PW +: PW] = div_tag_q;
    cdb_src_value[3*32 +: 32] = div_value_q;
    cdb_src_exc[3] = div_exc_q;
  end

  cdb #(.W(2), .R(R)) u_cdb (
    .clk           (clk),
    .reset         (reset),
    .src_valid     (cdb_src_valid),
    .src_tag       (cdb_src_tag),
    .src_value     (cdb_src_value),
    .src_exception (cdb_src_exc),
    .src_ready     (cdb_src_ready),
    .cdb_out       (cdb_out)
  );

  assign cdb = cdb_out;

  // CDB -> IQ 唤醒
  always_comb begin
    for (i = 0; i < R; i = i + 1) begin
      cdb_wake_valid[i] = cdb_out[i*CW + `CPU_CDB_VALID_OFF];
      cdb_wake_tag[i*PW +: PW] = cdb_out[i*CW + `CPU_CDB_TAG_OFF +: PW];
    end
  end

  // ---------------------------------------------------------------------------
  // 结果缓冲时序
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      skid_valid <= 1'b0;
      skid_vmask <= '0;
      skid_uop   <= '0;
      disp_seq   <= '0;
      for (i = 0; i < `CPU_ROB_DEPTH; i = i + 1)
        rob_seq[i] <= '0;
    end else begin
      if (skid_drain) begin
        skid_valid <= 1'b0;
        for (i = 0; i < W; i = i + 1)
          if (skid_vmask[i])
            rob_seq[skid_rob[i*RW +: RW]] <= disp_seq + i;
        disp_seq <= disp_seq + n_disp;
`ifdef LOCAL_TRACE
        $display("[SKID_DRAIN] t=%0t seq=%0d rob=%0d mask=%b",
                 $time, disp_seq, skid_rob[0 +: RW], skid_vmask);
`endif
      end
      if (skid_valid && !skid_drain) begin
        skid_uop   <= skid_uop_next;
        skid_vmask <= skid_vmask_next;
        if (skid_vmask_next == '0)
          skid_valid <= 1'b0;
      end
      if ((|disp_valid) && backend_ready) begin
        skid_valid <= 1'b1;
        skid_vmask <= disp_valid;
        skid_uop   <= disp_uop_woken;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      alu_valid_q  <= 1'b0;
      alu1_valid_q <= 1'b0;
      a0_valid_q   <= 1'b0;
      a0_uop_q     <= '0;
      a0_seq_q     <= '0;
      a1_valid_q   <= 1'b0;
      a1_uop_q     <= '0;
      a1_seq_q     <= '0;
      div_valid_q  <= 1'b0;
      br_valid_q   <= 1'b0;
      div_tag_pending <= '0;
      div_op_q <= '0;
      div_exc_pending <= 1'b0;
      div_pending_seq <= '0;
      div_discard <= 1'b0;
    end else begin
      // squash 丢弃已发射的年轻结果，防止污染重新分配的 tag
      if (sq_valid && alu_valid_q && (alu_seq_q > squash_seq))
        alu_valid_q <= 1'b0;
      if (sq_valid && alu1_valid_q && (alu1_seq_q > squash_seq))
        alu1_valid_q <= 1'b0;
      if (sq_valid && div_valid_q && (div_seq_q > squash_seq))
        div_valid_q <= 1'b0;
      if (sq_valid && br_valid_q && (br_seq_q > squash_seq))
        br_valid_q <= 1'b0;
      if (sq_valid && div_busy &&
          (div_pending_seq > squash_seq))
        div_discard <= 1'b1;

      // lane0 非访存缓冲：丢弃/执行后释放；新选中覆盖旧内容。
      if (a0_discard || a0_issue)
        a0_valid_q <= 1'b0;
      if (a0_push && !(sq_valid && (issue_seq[31:0] > squash_seq))) begin
        a0_valid_q <= 1'b1;
        a0_uop_q   <= issue_uop[DW-1:0];
        a0_seq_q   <= issue_seq[31:0];
      end

      // lane1 发射缓冲：丢弃/执行后释放；新选中覆盖旧内容。
      if (a1_discard || a1_issue)
        a1_valid_q <= 1'b0;
      if (a1_push && !(sq_valid && (issue_seq[63:32] > squash_seq))) begin
        a1_valid_q <= 1'b1;
        a1_uop_q   <= issue_uop[2*DW-1:DW];
        a1_seq_q   <= issue_seq[63:32];
      end
`ifdef LOCAL_TRACE
      if (a1_push)
        $display("[A1_PUSH] t=%0t seq=%0d pc=%08x accept=%0b sq=%0b",
                 $time, issue_seq[63:32], issue_uop[DW + `CPU_DISPATCH_PC_OFF +: 32],
                 a1_accept, sq_valid);
`endif

      // ALU 结果
      if (alu_valid_q && cdb_src_ready[0])
        alu_valid_q <= 1'b0;
      if (alu_issue && needs_alu_result) begin
        alu_valid_q  <= 1'b1;
        alu_tag_q    <= a0_dest;
        alu_seq_q    <= a0_seq_q;
        alu_value_q  <= wb_value;
        alu_exc_q    <= 1'b0;
      end
      if (alu1_valid_q && cdb_src_ready[1])
        alu1_valid_q <= 1'b0;
      if (alu1_issue && p_needs_alu_result) begin
        alu1_valid_q <= 1'b1;
        alu1_tag_q   <= p_dest;
        alu1_seq_q   <= a1_seq_q;
        alu1_value_q <= wb1_value;
        alu1_exc_q   <= 1'b0;
      end
`ifdef LOCAL_TRACE
      if (alu1_issue)
        $display("[ALU1_SET] t=%0t tag=%0d val=%08x", $time, p_dest, wb1_value);
      if (cdb_src_valid[1])
        $display("[CDBSRC1] t=%0t tag=%0d raw=%0b ready1=%0b last=%0d", $time,
                 cdb_src_tag[1*PW +: PW], cdb_src_valid, cdb_src_ready[1],
                 u_cdb.last);
`endif

      // divider 结果
      if (div_valid_q && cdb_src_ready[3])
        div_valid_q <= 1'b0;
      if (div_issue) begin
        div_tag_pending <= a0_dest;
        div_op_q        <= a0_alu_op;
        div_exc_pending <= a0_illegal;
        div_pending_seq <= a0_seq_q;
        div_discard     <= 1'b0;
      end
      if (div_done) begin
        if (!div_discard) begin
          div_valid_q <= 1'b1;
          div_tag_q   <= div_tag_pending;
          div_seq_q   <= div_pending_seq;
          div_value_q <= ((div_op_q == `ALU_DIV) || (div_op_q == `ALU_DIVU))
                         ? div_quot : div_rem;
          div_exc_q   <= div_exc_pending;
        end
        div_discard <= 1'b0;
      end

      // 分支更新 / 无值完成
      br_valid_q <= 1'b0;
      if (alu_issue && a0_is_branch_any) begin
        br_valid_q  <= 1'b1;
        br_pc_q     <= a0_pc;
        br_taken_q  <= br_taken;
        br_target_q <= br_target;
        br_jalr_q   <= a0_is_jalr;
        br_tag_q    <= a0_dest;
        br_seq_q    <= a0_seq_q;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // complete / br_update 打包
  // ---------------------------------------------------------------------------
  // ---- complete FIFO ------------------------------------------------------
  // 在 issue 当拍就压入，避免“上一拍 store complete”与“本拍新 issue”
  // 同时产生两个 complete 源。单发射保证每拍最多一个。
  assign noval_issue = iq_out_valid[0] && issue_ready[0] &&
                       !(iq_out_addr_only[0] && i_is_store) &&
                       (i_is_store ||
                        (!i_is_load && !i_is_div &&
                         (i_illegal || !i_reg_we)));
  assign cf_push = noval_issue;
  assign cf_pop  = (cf_count != 0);

  assign cf_tag_in = i_dest;
  assign cf_exc_in = i_illegal;
  assign cf_seq_in = issue_seq[31:0];

  always_comb begin
    complete = '0;
    if ((cf_count != 0) && !cf_discard[cf_head] &&
        !(sq_valid && (cf_seq[cf_head*32 +: 32] > squash_seq))) begin
      complete[`CPU_COMPLETE_VALID_OFF] = 1'b1;
      complete[`CPU_COMPLETE_TAG_OFF +: PW] = cf_tag[cf_head*PW +: PW];
      complete[`CPU_COMPLETE_EXCEPTION_OFF] = cf_exc[cf_head];
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      cf_discard <= '0;
      cf_head    <= '0;
      cf_tail    <= '0;
      cf_count   <= '0;
    end else begin
      if (cf_pop)
        cf_head <= (cf_head == CF_DEPTH - 1) ? '0 : cf_head + 1'b1;

      if (sq_valid) begin
        for (i = 0; i < CF_DEPTH; i = i + 1)
          if (cf_seq[i*32 +: 32] > squash_seq)
            cf_discard[i] <= 1'b1;
      end

      // push 必须放在 squash 循环之后：同一拍 push 与 squash 落到同一
      // slot 时，旧表项的 squash 结果不能覆盖新表项的 discard。
      if (cf_push) begin
        cf_discard[cf_tail]       <= sq_valid && (cf_seq_in > squash_seq);
        cf_tag[cf_tail*PW +: PW]  <= cf_tag_in;
        cf_exc[cf_tail]           <= cf_exc_in;
        cf_seq[cf_tail*32 +: 32]  <= cf_seq_in;
        cf_tail <= (cf_tail == CF_DEPTH - 1) ? '0 : cf_tail + 1'b1;
      end

      cf_count <= cf_count + (cf_push ? 1'b1 : 1'b0) -
                             (cf_pop  ? 1'b1 : 1'b0);
`ifdef LOCAL_TRACE
      if (cf_push)
        $display("[CF_PUSH] t=%0t tag=%0d exc=%0b seq=%0d disc=%0b cnt=%0d",
                 $time, cf_tag_in, cf_exc_in, cf_seq_in,
                 sq_valid && (cf_seq_in > squash_seq), cf_count);
      if (cf_pop)
        $display("[CF_POP] t=%0t head=%0d tag=%0d cnt=%0d disc=%0b sqv=%0b seq=%0d sqseq=%0d compv=%0b",
                 $time, cf_head, cf_tag[cf_head*PW +: PW], cf_count,
                 cf_discard[cf_head], sq_valid,
                 cf_seq[cf_head*32 +: 32], squash_seq,
                 complete[`CPU_COMPLETE_VALID_OFF]);
`endif
    end
  end

  logic br_issue;
  assign br_issue = alu_issue && a0_is_branch_any &&
                    !(sq_valid && (a0_seq_q > squash_seq));

  always_comb begin
    br_update = '0;
    if (br_issue) begin
      br_update[`CPU_BR_VALID_OFF] = 1'b1;
      br_update[`CPU_BR_PC_OFF +: 32] = a0_pc;
      br_update[`CPU_BR_TAKEN_OFF] = br_taken;
      br_update[`CPU_BR_TARGET_OFF +: 32] = br_target;
      br_update[`CPU_BR_IS_JALR_OFF] = a0_is_jalr;
      br_update[`CPU_BR_TAG_OFF +: PW] = a0_dest;
    end
  end

  // ---------------------------------------------------------------------------
  // backend_ready
  // ---------------------------------------------------------------------------
  assign skid_drain    = skid_valid && iq_in_ready && lsu_alloc_ready &&
                         !sq_valid;
  assign backend_ready = !skid_valid || skid_drain;

`ifdef LOCAL_TRACE
  integer stall_dbg = 0;
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (iq_out_valid[0] && !issue_ready[0] && stall_dbg < 12) begin
        $display("[STALL] t=%0t pc=%08x inst=%08x dest=%0d rob=%0d mem=%0b div=%0b alu_rdy=%0b div_rdy=%0b lsu_rdy=%0b alu_buf=%0b cdb_rdy0=%0b",
                 $time, i_pc, i_inst, i_dest, i_rob, i_is_mem, i_is_div,
                 a0_accept, div_issue_ready, lsu_issue_ready,
                 a0_valid_q, cdb_src_ready[0]);
        stall_dbg <= stall_dbg + 1;
      end
      if (iq_out_valid[0] && issue_ready[0])
        $display("[ISSUE] t=%0t pc=%08x inst=%08x dest=%0d rob=%0d mem=%0b div=%0b we=%0b br=%0b",
                 $time, i_pc, i_inst, i_dest, i_rob, i_is_mem, i_is_div,
                 i_reg_we, i_is_branch_any);
      if (iq_out_valid[1] && issue_ready[1])
        $display("[ISSUE1] t=%0t pc=%08x inst=%08x dest=%0d", $time,
                 j_pc, j_inst, j_dest);
      if (cdb_out[`CPU_CDB_VALID_OFF])
        $display("[CDB] t=%0t tag=%0d val=%08x exc=%0b",
                 $time, cdb_out[`CPU_CDB_TAG_OFF +: PW],
                 cdb_out[`CPU_CDB_VALUE_OFF +: 32],
                 cdb_out[`CPU_CDB_EXCEPTION_OFF]);
      if (complete[`CPU_COMPLETE_VALID_OFF])
        $display("[COMPLETE] t=%0t tag=%0d exc=%0b",
                 $time, complete[`CPU_COMPLETE_TAG_OFF +: PW],
                 complete[`CPU_COMPLETE_EXCEPTION_OFF]);
      if (sq_valid)
        $display("[SQUASH] t=%0t rob=%0d", $time, sq_rob);
      if (br_issue)
        $display("[BR] t=%0t pc=%08x taken=%0b target=%08x jalr=%0b tag=%0d",
                 $time, a0_pc, br_taken, br_target, a0_is_jalr, a0_dest);
      if (alu_issue && needs_alu_result)
        $display("[ALU_SET] t=%0t tag=%0d rob=%0d val=%08x",
                 $time, a0_dest,
                 a0_uop_q[`CPU_DISPATCH_ROB_IDX_OFF +: RW], wb_value);
      if (div_done)
        $display("[DIV_DONE] t=%0t discard=%0b tag=%0d rob=%0d",
                 $time, div_discard, div_tag_pending, div_pending_seq);
    end
  end
`endif

`ifdef LOCAL_STATS
  // 仅仿真统计；默认构建/综合不会实例化这些计数器。
  longint st_cycles, st_disp, st_issue0, st_issue1;
  longint st_iq_empty, st_stall0, st_stall_lsu, st_stall_div;
  longint st_stall_alu, st_stall_cf, st_stall_other;
  longint st_stall1, st_lane1_unsup, st_lane1_buf, st_lane1_other;
  longint st_cdb_conflict, st_cdb_lost, st_div_busy, st_lsu_busy;
  longint st_ld_issue, st_ld_resp, st_st_issue, st_st_resp, st_addr_only;
  longint st_skid_cycles, st_iq_full_stall, st_backend_bubble;
  integer st_i, st_lost;

  always_ff @(posedge clk) begin
    if (reset) begin
      st_cycles         <= 0;
      st_disp           <= 0;
      st_issue0         <= 0;
      st_issue1         <= 0;
      st_iq_empty       <= 0;
      st_stall0         <= 0;
      st_stall_lsu      <= 0;
      st_stall_div      <= 0;
      st_stall_alu      <= 0;
      st_stall_cf       <= 0;
      st_stall_other    <= 0;
      st_stall1         <= 0;
      st_lane1_unsup    <= 0;
      st_lane1_buf      <= 0;
      st_lane1_other    <= 0;
      st_cdb_conflict   <= 0;
      st_cdb_lost       <= 0;
      st_div_busy       <= 0;
      st_lsu_busy       <= 0;
      st_ld_issue       <= 0;
      st_ld_resp        <= 0;
      st_st_issue       <= 0;
      st_st_resp        <= 0;
      st_addr_only      <= 0;
      st_skid_cycles    <= 0;
      st_iq_full_stall  <= 0;
      st_backend_bubble <= 0;
    end else begin
      st_cycles <= st_cycles + 1;
      if (skid_drain) st_disp <= st_disp + n_disp;
      if (iq_out_valid[0] && issue_ready[0]) st_issue0 <= st_issue0 + 1;
      if (iq_out_valid[1] && issue_ready[1]) st_issue1 <= st_issue1 + 1;
      if (!iq_out_valid[0]) st_iq_empty <= st_iq_empty + 1;
      if (!backend_ready) st_backend_bubble <= st_backend_bubble + 1;
      if (skid_valid) st_skid_cycles <= st_skid_cycles + 1;
      if (skid_valid && !iq_in_ready) st_iq_full_stall <= st_iq_full_stall + 1;
      if (div_busy) st_div_busy <= st_div_busy + 1;
      if (lsu_busy) st_lsu_busy <= st_lsu_busy + 1;

      if (addr_only_issue) st_addr_only <= st_addr_only + 1;
      if (ld_req_valid && ld_req_ready) st_ld_issue <= st_ld_issue + 1;
      if (ld_resp_valid) st_ld_resp <= st_ld_resp + 1;
      if (st_req_valid && st_req_ready) st_st_issue <= st_st_issue + 1;
      if (st_resp_valid) st_st_resp <= st_st_resp + 1;

      if (iq_out_valid[0] && !issue_ready[0]) begin
        st_stall0 <= st_stall0 + 1;
        if (noval_expected && !cf_allow)
          st_stall_cf <= st_stall_cf + 1;
        else if (i_is_mem && !lsu_issue_ready)
          st_stall_lsu <= st_stall_lsu + 1;
        else if (i_is_div && !div_issue_ready)
          st_stall_div <= st_stall_div + 1;
        else if (!i_is_mem && !i_is_div && !a0_accept)
          st_stall_alu <= st_stall_alu + 1;
        else
          st_stall_other <= st_stall_other + 1;
      end

      if (iq_out_valid[1] && !issue_ready[1]) begin
        st_stall1 <= st_stall1 + 1;
        if (!j_lane_ok)
          st_lane1_unsup <= st_lane1_unsup + 1;
        else if (!a1_accept)
          st_lane1_buf <= st_lane1_buf + 1;
        else
          st_lane1_other <= st_lane1_other + 1;
      end

      st_lost = 0;
      for (st_i = 0; st_i < N; st_i = st_i + 1)
        if (cdb_src_valid[st_i] && !cdb_src_ready[st_i])
          st_lost = st_lost + 1;
      if (st_lost != 0) begin
        st_cdb_conflict <= st_cdb_conflict + 1;
        st_cdb_lost     <= st_cdb_lost + st_lost;
      end
    end
  end

  final $fdisplay(32'h80000002,
      "[STATS] BE cycles=%0d dispatch=%0d issue0=%0d issue1=%0d iq_empty=%0d stall0=%0d stall_lsu=%0d stall_div=%0d stall_alu=%0d stall_cf=%0d stall_other=%0d stall1=%0d lane1_unsup=%0d lane1_buf=%0d lane1_other=%0d cdb_conflict=%0d cdb_lost=%0d div_busy=%0d lsu_busy=%0d addr_only=%0d ld_issue=%0d ld_resp=%0d st_issue=%0d st_resp=%0d skid_cycles=%0d iq_full_stall=%0d backend_bubble=%0d",
      st_cycles, st_disp, st_issue0, st_issue1, st_iq_empty, st_stall0,
      st_stall_lsu, st_stall_div, st_stall_alu, st_stall_cf, st_stall_other,
      st_stall1, st_lane1_unsup, st_lane1_buf, st_lane1_other,
      st_cdb_conflict, st_cdb_lost, st_div_busy, st_lsu_busy, st_addr_only,
      st_ld_issue, st_ld_resp, st_st_issue, st_st_resp,
      st_skid_cycles, st_iq_full_stall, st_backend_bubble);
`endif

endmodule
