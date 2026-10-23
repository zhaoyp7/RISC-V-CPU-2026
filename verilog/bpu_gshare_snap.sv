// -----------------------------------------------------------------------------
// bpu_gshare_snap.sv — BTB + tournament(local BHT / gshare)，带 GHR 快照
//
// 结构：
//   - 本地 BHT：按 PC 索引的 2-bit 方向表；
//   - gshare BHT：按 PC xor GHR 索引的 2-bit 方向表；
//   - choice：按 PC 索引的 2-bit 选择器，决定本分支用哪个预测器；
//   - GHR 在取指侧按预测方向投机更新；
//   - 预测时输出 GHR 快照，经 frontend→rename→ROB 保存；
//   - 解析时用快照索引 gshare 更新，误预测时用快照恢复 GHR。
//
// BTB 结构、双取指口和更新策略与 bpu.sv 保持一致。
// -----------------------------------------------------------------------------

module bpu_gshare_snap #(
  parameter integer BTB_INDEX_BITS = `CPU_BTB_INDEX_BITS,
  parameter integer BHT_INDEX_BITS = `CPU_BHT_INDEX_BITS,
  parameter integer GHIST_BITS     = `CPU_BHT_INDEX_BITS
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        fetch_valid,
  input  logic [31:0] fetch_pc,
  output logic        predict_taken,
  output logic [31:0] predict_target,
  output logic [GHIST_BITS-1:0] predict_ghr,

  input  logic        fetch2_valid,
  input  logic [31:0] fetch_pc2,
  output logic        predict_taken2,
  output logic [31:0] predict_target2,
  output logic [GHIST_BITS-1:0] predict_ghr2,

  input  logic        upd_valid,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target,
  input  logic        upd_is_uncond,
  input  logic [GHIST_BITS-1:0] upd_ghr,

  input  logic        recover_valid,
  input  logic [GHIST_BITS-1:0] recover_ghr,
  input  logic        recover_taken,
  input  logic        recover_uncond
);

  localparam integer BTB_DEPTH    = 1 << BTB_INDEX_BITS;
  localparam integer BHT_DEPTH    = 1 << BHT_INDEX_BITS;
  localparam integer BTB_TAG_BITS = 32 - BTB_INDEX_BITS - 2;
  localparam integer GHW = (GHIST_BITS < BHT_INDEX_BITS) ? GHIST_BITS : BHT_INDEX_BITS;

  // BTB
  logic [BTB_DEPTH-1:0]    btb_valid;
  logic [BTB_TAG_BITS-1:0] btb_tag    [0:BTB_DEPTH-1];
  logic [31:0]             btb_target [0:BTB_DEPTH-1];
  logic                    btb_uncond [0:BTB_DEPTH-1];

  // tournament 预测器
  logic [1:0]            bht_loc [0:BHT_DEPTH-1];
  logic [1:0]            bht_gsh [0:BHT_DEPTH-1];
  logic [1:0]            choice  [0:BHT_DEPTH-1];
  logic [BHT_DEPTH-1:0]  loc_valid, gsh_valid, choice_valid;
  logic [GHIST_BITS-1:0] ghr;

  // ---- 索引 ----------------------------------------------------------------
  logic [BTB_INDEX_BITS-1:0] fetch_btb_index, fetch2_btb_index, upd_btb_index;
  logic [BTB_TAG_BITS-1:0]   fetch_tag, fetch2_tag, upd_tag;
  logic [BHT_INDEX_BITS-1:0] fetch_loc_index, fetch_gsh_index;
  logic [BHT_INDEX_BITS-1:0] fetch2_loc_index, fetch2_gsh_index;
  logic [BHT_INDEX_BITS-1:0] upd_loc_index, upd_gsh_index;

  assign fetch_btb_index  = fetch_pc[BTB_INDEX_BITS+1:2];
  assign fetch_tag        = fetch_pc[31:BTB_INDEX_BITS+2];
  assign fetch2_btb_index = fetch_pc2[BTB_INDEX_BITS+1:2];
  assign fetch2_tag       = fetch_pc2[31:BTB_INDEX_BITS+2];
  assign upd_btb_index    = upd_pc[BTB_INDEX_BITS+1:2];
  assign upd_tag          = upd_pc[31:BTB_INDEX_BITS+2];

  assign fetch_loc_index  = fetch_pc[BHT_INDEX_BITS+1:2];
  assign fetch2_loc_index = fetch_pc2[BHT_INDEX_BITS+1:2];
  assign upd_loc_index    = upd_pc[BHT_INDEX_BITS+1:2];

  // GHR 在取指侧投机更新：pc 预测方向 -> ghr_after0，pc+4 -> ghr_after1。
  logic [GHIST_BITS-1:0] ghr_after0, ghr_after1;
  logic                  pred_dir0, pred_dir1;
  logic                  loc_dir0, gsh_dir0, loc_dir1, gsh_dir1;
  logic                  use_gsh0, use_gsh1;

  logic        btb_valid_sel0, btb_valid_sel1;
  logic [BTB_TAG_BITS-1:0] btb_tag_sel0, btb_tag_sel1;
  logic [31:0] btb_target_sel0, btb_target_sel1;
  logic        btb_uncond_sel0, btb_uncond_sel1;
  logic        btb_hit0, btb_hit1;
  logic [1:0]  loc_sel0, gsh_sel0, choice_sel0;
  logic [1:0]  loc_sel1, gsh_sel1, choice_sel1;

  assign fetch_gsh_index  = fetch_pc[BHT_INDEX_BITS+1:2] ^ ghr[GHW-1:0];
  assign fetch2_gsh_index = fetch_pc2[BHT_INDEX_BITS+1:2] ^ ghr_after0[GHW-1:0];

  always_comb begin
    btb_valid_sel0  = btb_valid[fetch_btb_index];
    btb_tag_sel0    = btb_tag[fetch_btb_index];
    btb_target_sel0 = btb_target[fetch_btb_index];
    btb_uncond_sel0 = btb_uncond[fetch_btb_index];
    btb_hit0        = btb_valid_sel0 && (btb_tag_sel0 == fetch_tag);

    loc_sel0    = loc_valid[fetch_loc_index] ? bht_loc[fetch_loc_index] : 2'b01;
    gsh_sel0    = gsh_valid[fetch_gsh_index] ? bht_gsh[fetch_gsh_index] : 2'b01;
    choice_sel0 = choice_valid[fetch_loc_index] ? choice[fetch_loc_index] : 2'b10;
    use_gsh0    = choice_sel0[1];
    loc_dir0    = loc_sel0[1];
    gsh_dir0    = gsh_sel0[1];
    pred_dir0   = use_gsh0 ? gsh_dir0 : loc_dir0;

    ghr_after0 = ghr;
    if (btb_hit0 && !btb_uncond_sel0)
      ghr_after0 = {ghr[GHIST_BITS-2:0], pred_dir0};

    btb_valid_sel1  = btb_valid[fetch2_btb_index];
    btb_tag_sel1    = btb_tag[fetch2_btb_index];
    btb_target_sel1 = btb_target[fetch2_btb_index];
    btb_uncond_sel1 = btb_uncond[fetch2_btb_index];
    btb_hit1        = btb_valid_sel1 && (btb_tag_sel1 == fetch2_tag);

    loc_sel1    = loc_valid[fetch2_loc_index] ? bht_loc[fetch2_loc_index] : 2'b01;
    gsh_sel1    = gsh_valid[fetch2_gsh_index] ? bht_gsh[fetch2_gsh_index] : 2'b01;
    choice_sel1 = choice_valid[fetch2_loc_index] ? choice[fetch2_loc_index] : 2'b10;
    use_gsh1    = choice_sel1[1];
    loc_dir1    = loc_sel1[1];
    gsh_dir1    = gsh_sel1[1];
    pred_dir1   = use_gsh1 ? gsh_dir1 : loc_dir1;

    ghr_after1 = ghr_after0;
    if (btb_hit1 && !btb_uncond_sel1)
      ghr_after1 = {ghr_after0[GHIST_BITS-2:0], pred_dir1};
  end

  assign predict_taken   = btb_hit0 && (btb_uncond_sel0 || pred_dir0);
  assign predict_target  = btb_hit0 ? btb_target_sel0 : 32'b0;
  assign predict_ghr     = ghr;
  assign predict_taken2  = btb_hit1 && (btb_uncond_sel1 || pred_dir1);
  assign predict_target2 = btb_hit1 ? btb_target_sel1 : 32'b0;
  assign predict_ghr2    = ghr_after0;

  // ---- 更新（gshare 使用 ROB 快照） ----------------------------------------
  assign upd_gsh_index = upd_pc[BHT_INDEX_BITS+1:2] ^ upd_ghr[GHW-1:0];

  logic [1:0] loc_cur, loc_next, gsh_cur, gsh_next, choice_cur, choice_next;
  logic       upd_btb_hit;
  assign upd_btb_hit = btb_valid[upd_btb_index] &&
                       (btb_tag[upd_btb_index] == upd_tag);

  always_comb begin
    loc_cur    = loc_valid[upd_loc_index] ? bht_loc[upd_loc_index] : 2'b01;
    gsh_cur    = gsh_valid[upd_gsh_index] ? bht_gsh[upd_gsh_index] : 2'b01;
    choice_cur = choice_valid[upd_loc_index] ? choice[upd_loc_index] : 2'b10;

    loc_next = loc_cur;
    gsh_next = gsh_cur;
    if (upd_valid) begin
      if (upd_is_uncond) begin
        loc_next = 2'b11;
        gsh_next = 2'b11;
      end else if (upd_taken) begin
        if (loc_cur != 2'b11) loc_next = loc_cur + 2'b01;
        if (gsh_cur != 2'b11) gsh_next = gsh_cur + 2'b01;
      end else begin
        if (loc_cur != 2'b00) loc_next = loc_cur - 2'b01;
        if (gsh_cur != 2'b00) gsh_next = gsh_cur - 2'b01;
      end
    end

    choice_next = choice_cur;
    if (upd_valid && !upd_is_uncond) begin
      if ((gsh_cur[1] == upd_taken) && (loc_cur[1] != upd_taken)) begin
        if (choice_cur != 2'b11) choice_next = choice_cur + 2'b01;
      end else if ((loc_cur[1] == upd_taken) && (gsh_cur[1] != upd_taken)) begin
        if (choice_cur != 2'b00) choice_next = choice_cur - 2'b01;
      end
    end
  end

  // ---- 时序 ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      ghr          <= '0;
      btb_valid    <= '0;
      loc_valid    <= '0;
      gsh_valid    <= '0;
      choice_valid <= '0;
    end else begin
      if (recover_valid) begin
        if (recover_uncond)
          ghr <= recover_ghr;
        else
          ghr <= {recover_ghr[GHIST_BITS-2:0], recover_taken};
      end else if (fetch_valid) begin
        ghr <= fetch2_valid ? ghr_after1 : ghr_after0;
      end

      if (upd_valid) begin
        // 两个方向表都更新
        bht_loc[upd_loc_index]  <= loc_next;
        bht_gsh[upd_gsh_index]  <= gsh_next;
        loc_valid[upd_loc_index] <= 1'b1;
        gsh_valid[upd_gsh_index] <= 1'b1;
        choice[upd_loc_index]    <= choice_next;
        choice_valid[upd_loc_index] <= 1'b1;

        // BTB
        if (upd_is_uncond) begin
          btb_valid[upd_btb_index]  <= 1'b1;
          btb_tag[upd_btb_index]    <= upd_tag;
          btb_target[upd_btb_index] <= upd_target;
          btb_uncond[upd_btb_index] <= 1'b1;
        end else if (upd_taken) begin
          btb_valid[upd_btb_index]  <= 1'b1;
          btb_tag[upd_btb_index]    <= upd_tag;
          btb_target[upd_btb_index] <= upd_target;
          btb_uncond[upd_btb_index] <= 1'b0;
        end else if (upd_btb_hit) begin
          btb_uncond[upd_btb_index] <= 1'b0;
        end
      end
    end
  end

endmodule
