// -----------------------------------------------------------------------------
// alu.sv — 组合逻辑算术/逻辑单元
//
// 覆盖 RV32I 整数运算与 M 扩展乘除法，全部在一个周期内组合完成。
//
// 设计要点：
//   1. MULH/MULHSU/MULHU 需要 64 位乘积的高 32 位，因此先把操作数扩展到
//      64 位再相乘（低 32 位结果对有无符号一致，MUL 直接用 32 位乘法）。
//   2. 除法的边界语义按 RISC-V 规范显式处理，不依赖主机 C++ 的除法行为：
//        - 除零：DIV 返回 -1，REM 返回被除数；
//        - INT_MIN / -1 溢出：DIV 返回 INT_MIN，REM 返回 0。
//   3. 综合时行为级 "/" "%" 会展开成大面积组合除法器，是当前频率瓶颈；
//      后续阶段将替换为多周期串行除法器。
// -----------------------------------------------------------------------------

module alu (
  input  logic [31:0] a,   // 操作数 A（来自 rs1 / PC / 0）
  input  logic [31:0] b,   // 操作数 B（来自 rs2 / 立即数；移位时取 b[4:0]）
  input  logic [4:0]  op,  // 操作码，取值见 rv32_defs.sv
  output logic [31:0] y    // 运算结果
);

  // 64 位扩展操作数，用于取乘法高位
  logic signed [63:0] a_s;   // a 符号扩展
  logic signed [63:0] b_s;   // b 符号扩展
  logic        [63:0] b_u;   // b 零扩展（MULHSU 用）
  logic        [63:0] prod_ss;
  logic        [63:0] prod_su;
  logic        [63:0] prod_uu;

  // 除法结果缓存
  logic signed [31:0] quot_s;
  logic signed [31:0] rem_s;
  logic        [31:0] quot_u;
  logic        [31:0] rem_u;

  assign a_s = {{32{a[31]}}, a};
  assign b_s = {{32{b[31]}}, b};
  assign b_u = {32'b0, b};
  assign prod_ss = a_s * b_s;
  assign prod_su = a_s * b_u;
  assign prod_uu = {32'b0, a} * {32'b0, b};

  // 除法与取余：先处理除零与 INT_MIN / -1 两个边界，再走主机运算符。
  // 主机 C++ 的有符号除法向零截断，与 RISC-V 定义一致；边界单独处理
  // 既满足规范，也避免 INT_MIN / -1 在主机侧产生溢出未定义行为。
  always_comb begin
    if (b == 32'b0) begin
      quot_s = 32'hffff_ffff;  // 除零：商为 -1
      rem_s  = a;              // 除零：余数为被除数
    end else if (a == 32'h8000_0000 && b == 32'hffff_ffff) begin
      quot_s = 32'h8000_0000;  // 溢出：商为 INT_MIN
      rem_s  = 32'b0;          // 溢出：余数为 0
    end else begin
      quot_s = $signed(a) / $signed(b);
      rem_s  = $signed(a) % $signed(b);
    end
    quot_u = (b == 32'b0) ? 32'hffff_ffff : a / b;
    rem_u  = (b == 32'b0) ? a : a % b;
  end

  always_comb begin
    unique case (op)
      `ALU_ADD:    y = a + b;
      `ALU_SUB:    y = a - b;
      `ALU_SLL:    y = a << b[4:0];
      `ALU_SLT:    y = {31'b0, $signed(a) < $signed(b)};
      `ALU_SLTU:   y = {31'b0, a < b};
      `ALU_XOR:    y = a ^ b;
      `ALU_SRL:    y = a >> b[4:0];
      `ALU_SRA:    y = $signed(a) >>> b[4:0];
      `ALU_OR:     y = a | b;
      `ALU_AND:    y = a & b;
      `ALU_MUL:    y = a * b;
      `ALU_MULH:   y = prod_ss[63:32];
      `ALU_MULHSU: y = prod_su[63:32];
      `ALU_MULHU:  y = prod_uu[63:32];
      `ALU_DIV:    y = quot_s;
      `ALU_DIVU:   y = (b == 32'b0) ? 32'hffff_ffff : quot_u;
      `ALU_REM:    y = rem_s;
      `ALU_REMU:   y = (b == 32'b0) ? a : rem_u;
      default:     y = 32'b0;
    endcase
  end

endmodule
