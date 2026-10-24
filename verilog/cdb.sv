// -----------------------------------------------------------------------------
// cdb.sv — 公共数据总线仲裁器
//
// 源：W 个 ALU lane + 1 个 load + 1 个 divider = W+2 个结果源。
// 输出：R 条 CDB lane（默认 1）。
//
// 协议：
//   - 源保持 valid/tag/value 直到 src_ready=1（同一拍即被 CDB 吸收）；
//   - 每拍每条 CDB lane 最多选一个源，同一源不会在同一拍被选两次；
//   - 轮转优先级避免固定低编号源饿死高编号源；
//   - 未获胜的源必须由调用方保持，下一拍重试。
// -----------------------------------------------------------------------------

module cdb #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer R = `CPU_CDB_NUM
) (
  input  logic clk,
  input  logic reset,

  input  logic [W+1:0]                   src_valid,
  input  logic [(W+2)*`CPU_PRF_IDX_W-1:0] src_tag,
  input  logic [(W+2)*32-1:0]            src_value,
  input  logic [W+1:0]                   src_exception,
  output logic [W+1:0]                   src_ready,

  output logic [R*`CPU_CDB_W-1:0]        cdb_out
);

  localparam integer N  = W + 2;
  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer CW = `CPU_CDB_W;

  logic [3:0]     last;
  localparam integer NW = $clog2(N + 1);
  // 对每个寄存轮转位置并行计算授权。第r条lane选轮转序列中第r个有效源；
  // 与原逐lane扫描、排除已选源完全一致，避免ready穿过串行动态索引。
  wire [R*N-1:0] rotated_grant [0:N-1] /* verilator split_var */;
  for (genvar start = 0; start < N; start = start + 1) begin : gen_rotation
    wire [NW-1:0] before_count [0:N] /* verilator split_var */;
    assign before_count[0] = '0;
    for (genvar pos = 0; pos < N; pos = pos + 1) begin : gen_count
      localparam integer SRC = (start + pos + 1) % N;
      assign before_count[pos+1] = before_count[pos] + NW'(src_valid[SRC]);
    end
    for (genvar l = 0; l < R; l = l + 1) begin : gen_lane
      for (genvar s = 0; s < N; s = s + 1) begin : gen_source
        localparam integer POS = (s + N - start - 1) % N;
        assign rotated_grant[start][l*N+s] = src_valid[s] &&
                                                   (before_count[POS] == l);
      end
    end
  end

  logic [R*N-1:0] grant;
  integer r, s, rotation;
  always_comb begin
    grant = '0;
    for (rotation = 0; rotation < N; rotation = rotation + 1)
      grant = grant | (rotated_grant[rotation] & {R*N{last == rotation}});
    cdb_out = '0;
    src_ready = '0;
    for (r = 0; r < R; r = r + 1) begin
      for (s = 0; s < N; s = s + 1) begin
        src_ready[s] = src_ready[s] | grant[r*N+s];
        cdb_out[r*CW + `CPU_CDB_VALID_OFF] =
            cdb_out[r*CW + `CPU_CDB_VALID_OFF] | grant[r*N+s];
        cdb_out[r*CW + `CPU_CDB_TAG_OFF +: PW] =
            cdb_out[r*CW + `CPU_CDB_TAG_OFF +: PW] |
            (src_tag[s*PW +: PW] & {PW{grant[r*N+s]}});
        cdb_out[r*CW + `CPU_CDB_VALUE_OFF +: 32] =
            cdb_out[r*CW + `CPU_CDB_VALUE_OFF +: 32] |
            (src_value[s*32 +: 32] & {32{grant[r*N+s]}});
        cdb_out[r*CW + `CPU_CDB_EXCEPTION_OFF] =
            cdb_out[r*CW + `CPU_CDB_EXCEPTION_OFF] |
            (src_exception[s] & grant[r*N+s]);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (reset)
      last <= 4'b0;
    else if (|src_valid)
      last <= (last == N-1) ? 4'b0 : last + 4'b1;
  end

endmodule
