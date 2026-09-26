// -----------------------------------------------------------------------------
// regfile.sv — 32 x 32 位通用寄存器堆
//
// 结构：
//   - 两个组合读端口（raddr1/raddr2），读写同拍互不冲突；
//   - 一个同步写端口，在时钟上升沿写入；
//   - x0 恒为 0：读端口对地址 0 直接返回 0，写端口忽略对 x0 的写入。
//
// 由于基线是顺序执行（同一时刻只有一条指令在飞），且每条指令之间至少
// 间隔一次取指（数十周期），天然不存在 RAW 相关，无需前递网络。
// 后续流水线化时再为这里补上写-读同拍的前递/旁路。
// -----------------------------------------------------------------------------

module regfile (
  input  logic        clk,
  input  logic        we,      // 写使能
  input  logic [4:0]  waddr,   // 写地址
  input  logic [31:0] wdata,   // 写数据
  input  logic [4:0]  raddr1,  // 读地址 1
  input  logic [4:0]  raddr2,  // 读地址 2
  output logic [31:0] rdata1,  // 读数据 1
  output logic [31:0] rdata2   // 读数据 2
);

  // 只存储 x1..x31；x0 由读端口旁路保证恒 0
  logic [31:0] regs [1:31];

  assign rdata1 = (raddr1 == 5'b0) ? 32'b0 : regs[raddr1];
  assign rdata2 = (raddr2 == 5'b0) ? 32'b0 : regs[raddr2];

  always_ff @(posedge clk) begin
    if (we && (waddr != 5'b0)) begin
      regs[waddr] <= wdata;
    end
  end

endmodule
