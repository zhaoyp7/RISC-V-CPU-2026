// -----------------------------------------------------------------------------
// prf.sv — 参数化物理寄存器堆
//
// 读口：2*W 个组合读口（每个发射 lane 的 src1/src2）。
// 写口：R 个 CDB 写口，与 cdb 广播同拍写入。
//
// 约定：
//   - 物理寄存器 0 恒为 0：读 0 返回 0，写 0 被忽略；
//   - 其他表项在复位时清 0，便于 bring-up/单测；rename 的 busy 语义保证
//     不会读取尚未写过的已分配 tag；
//   - 同拍多写口不检查冲突（CDB 仲裁保证 tag 唯一）。
// -----------------------------------------------------------------------------

module prf #(
  parameter integer W = `CPU_ISSUE_WIDTH,
  parameter integer R = `CPU_CDB_NUM,
  parameter logic [2*W-1:0] PREDECODED_READS = '0
) (
  input  logic clk,
  input  logic reset,

  // 读口：lane p 的地址位于 [p*PW +: PW]
  input  logic [2*W*`CPU_PRF_IDX_W-1:0] raddr,
  input logic [2*W*`CPU_PRF_SIZE-1:0] rselect,
  output logic [2*W*32-1:0]             rdata,

  // 写口：CDB lane r
  input  logic [R-1:0]                    we,
  input  logic [R*`CPU_PRF_IDX_W-1:0]     waddr,
  input  logic [R*32-1:0]                 wdata
);

  localparam integer PW = `CPU_PRF_IDX_W;
  localparam integer PRF = `CPU_PRF_SIZE;

  logic [31:0] regs [0:PRF-1];

  // Decode tags in parallel, then reduce selected data. Register zero is
  // excluded from the data cone and remains a constant on every read port.
  for(genvar port=0;port<2*W;port=port+1)begin:gen_read_port
    wire [PRF-1:0] select;
    assign select[0]=1'b0;
    for(genvar row=1;row<PRF;row=row+1)begin:gen_read_decode
      assign select[row]=PREDECODED_READS[port] ? rselect[port*PRF+row] : raddr[port*PW+:PW]==PW'(row);
    end
    always_comb begin
      rdata[port*32+:32]=0;
      for(integer row=1;row<PRF;row=row+1)
        rdata[port*32+:32]=rdata[port*32+:32] | (regs[row] & {32{select[row]}});
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk)if(!reset)begin
    for(integer port=0;port<2*W;port=port+1)begin
      if(PREDECODED_READS[port] && raddr[port*PW+:PW]<PRF)begin
        automatic logic [31:0] expected;
        expected=raddr[port*PW+:PW]==0 ? 32'b0 : regs[raddr[port*PW+:PW]];
        if(rdata[port*32+:32]!=expected)$fatal(1,"predecoded PRF read differs from binary-tag reference");
      end
    end
  end
`endif

  integer r, k;
  always_ff @(posedge clk) begin
    if (reset) begin
      for (k = 0; k < PRF; k = k + 1)
        regs[k] = 32'b0;
    end else begin
      for (r = 0; r < R; r = r + 1) begin
        if (we[r] && (waddr[r*PW +: PW] != '0))
          regs[waddr[r*PW +: PW]] <= wdata[r*32 +: 32];
      end
    end
  end

endmodule
