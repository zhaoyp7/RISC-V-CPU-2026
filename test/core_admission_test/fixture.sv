package core_admission_controls; logic free_ready, rob_ready; endpackage

module frontend_ooo #(
  parameter integer W      = `CPU_ISSUE_WIDTH,
  parameter integer FDEPTH = 8,
  parameter integer WORD_BANKING = 0
) (
  input  logic        clk,
  input  logic        reset,

  input  logic        backend_ready,
  input  logic [W-1:0] decode_capacity,

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
  assign dec_valid = {W{!reset}};
  assign dec_uop = '0;
  assign dec_pred_taken = '0;
  assign dec_pred_target = '0;
  assign pc_out = '0;
  assign refill_valid = '0;
  assign refill_addr = '0;
  assign refill_valid1 = '0;
  assign refill_addr1 = '0;
endmodule

module rename #(
  parameter integer W = `CPU_ISSUE_WIDTH
) (
  input  logic        clk,
  input  logic        reset,

  // decoded uop 输入（dispatch 低 122 位布局）
  input  logic [W-1:0]                 in_valid,
  input  logic [W*`CPU_DECODE_W-1:0]   in_uop,
  output logic                         in_ready,

  // renamed uop 输出（dispatch 去掉 rob_idx 的布局）
  output logic [W-1:0]                 out_valid,
  output logic [W*`CPU_RENAME_W-1:0]   out_uop,
  output logic [W*`CPU_PRF_IDX_W-1:0]  out_old_tag,
  input  logic                         out_ready,

  // 提交（来自 ROB/commit）
  input  logic [W-1:0]                 commit_valid,
  input  logic [W*5-1:0]               commit_rd,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  commit_dest_tag,
  input  logic [W-1:0]                 commit_reg_we,
  input  logic [W-1:0]                 commit_free_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  commit_free_tag,

  // 写回/完成唤醒（CDB + complete 汇总为掩码；同拍可有多条）
  input  logic [`CPU_PRF_SIZE-1:0]     wake_mask,

  // 恢复（squash 到某分支时由 ROB 给出）
  input  logic                         recover_valid,
  input  logic [`CPU_PRF_SIZE-1:0]     recover_free_mask,
  input  logic [`CPU_PRF_SIZE-1:0]     recover_busy_mask,
  input  logic [`CPU_LSQ_IDX_W-1:0]    recover_lsq_ptr,
  input  logic [32*`CPU_PRF_IDX_W-1:0] recover_rat
);
  assign in_ready = out_ready && core_admission_controls::free_ready && !reset;
  assign out_valid = in_valid;
  assign out_uop = '0;
  assign out_old_tag = '0;
endmodule

module rob #(
  parameter integer W     = `CPU_ISSUE_WIDTH,
  parameter integer DEPTH = `CPU_ROB_DEPTH,
  parameter integer BRANCH_PC_FROM_UPDATE = 0
) (
  input  logic        clk,
  input  logic        reset,

  // 分配口（来自 rename）
  input  logic [W-1:0]                 in_valid,
  input  logic [W*`CPU_RENAME_W-1:0]   in_uop,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  in_old_tag,
  input  logic [W-1:0]                 in_pred_taken,
  input  logic [W*32-1:0]              in_pred_target,
  output logic                         in_ready,
  output logic [W-1:0]                 in_capacity,
  output logic [W*`CPU_ROB_TAG_W-1:0]  alloc_rob_idx,

  // 完成口（R 条 CDB）
  input  logic [`CPU_CDB_NUM-1:0]            cdb_valid,
  input  logic [`CPU_CDB_NUM*`CPU_PRF_IDX_W-1:0] cdb_tag,
  input  logic [`CPU_CDB_NUM-1:0]            cdb_exception,
  input  logic [W-1:0]                 complete_valid,
  input  logic [W*`CPU_PRF_IDX_W-1:0]  complete_tag,
  input  logic [W-1:0]                 complete_exception,

  // 分支解析
  input  logic                         br_update_valid,
  input  logic [31:0]                  br_update_pc,
  input  logic                         br_update_taken,
  input  logic [31:0]                  br_update_target,
  input  logic                         br_update_is_jalr,
  input  logic [`CPU_PRF_IDX_W-1:0]    br_update_tag,

  // 提交总线
  output logic [W-1:0]                 commit_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_tag,
  output logic [W-1:0]                 commit_is_store,
  output logic [W-1:0]                 commit_is_load,
  output logic [W*`CPU_LSQ_IDX_W-1:0]  commit_lsq_id,
  output logic [W*32-1:0]              commit_pc,
  output logic [W*32-1:0]              commit_inst,
  output logic                         commit_halt,

  // 给 rename 的提交反馈
  output logic [W-1:0]                 commit_reg_we,
  output logic [W*5-1:0]               commit_rd,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_dest_tag,
  output logic [W-1:0]                 commit_free_valid,
  output logic [W*`CPU_PRF_IDX_W-1:0]  commit_free_tag,

  // 恢复（给 rename）
  output logic                         recover_valid,
  output logic [`CPU_PRF_SIZE-1:0]     recover_free_mask,
  output logic [`CPU_PRF_SIZE-1:0]     recover_busy_mask,
  output logic [`CPU_LSQ_IDX_W-1:0]    recover_lsq_ptr,
  output logic [32*`CPU_PRF_IDX_W-1:0] recover_rat,

  // 重定向 / squash
  output logic                         redirect_valid,
  output logic [31:0]                  redirect_pc,
  output logic                         squash_valid,
  output logic [`CPU_ROB_TAG_W-1:0]    squash_rob_idx,
  output logic                         br_update_uncond
);
  assign in_ready = core_admission_controls::rob_ready && !reset;
  assign in_capacity = W;
  assign alloc_rob_idx = '0;
  assign commit_valid = '0;
  assign commit_tag = '0;
  assign commit_is_store = '0;
  assign commit_is_load = '0;
  assign commit_lsq_id = '0;
  assign commit_pc = '0;
  assign commit_inst = '0;
  assign commit_halt = '0;
  assign commit_reg_we = '0;
  assign commit_rd = '0;
  assign commit_dest_tag = '0;
  assign commit_free_valid = '0;
  assign commit_free_tag = '0;
  assign recover_valid = '0;
  assign recover_free_mask = '0;
  assign recover_busy_mask = '0;
  assign recover_lsq_ptr = '0;
  assign recover_rat = '0;
  assign redirect_valid = '0;
  assign redirect_pc = '0;
  assign squash_valid = '0;
  assign squash_rob_idx = '0;
  assign br_update_uncond = '0;
endmodule

module core_admission_top(input logic clk,reset,backend_ready,free_ready,rob_ready,
 output logic [`CPU_ISSUE_WIDTH-1:0] dispatched,rob_received,rename_received);
 assign core_admission_controls::free_ready=free_ready;
 assign core_admission_controls::rob_ready=rob_ready;
 wire [`CPU_DISPATCH_BUS_W-1:0] bus_dispatch;
 core_ooo u_core(.clk(clk),.reset(reset),.backend_ready(backend_ready),
 .cdb('0),.complete('0),.br_update('0),.dispatch(bus_dispatch),.commit(),.squash(),.halt(),
 .refill_valid(),.refill_addr(),.refill_resp_valid(1'b0),.refill_rdata('0),
 .refill_valid1(),.refill_addr1(),.refill_resp_valid1(1'b0),.refill_rdata1('0));
 for(genvar i=0;i<`CPU_ISSUE_WIDTH;i=i+1)begin
  assign dispatched[i]=bus_dispatch[i*`CPU_DISPATCH_W+`CPU_DISPATCH_VALID_OFF];
 end
 assign rob_received=u_core.u_rob.in_valid;
 assign rename_received=u_core.rename_ready ? u_core.dec_valid : '0;
endmodule
