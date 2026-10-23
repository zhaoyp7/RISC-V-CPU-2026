// -----------------------------------------------------------------------------
// alu.sv — 组合逻辑算术/逻辑单元
//
// 覆盖 RV32I 整数运算与 M 扩展乘除法，全部在一个周期内组合完成。
//
// 设计要点：
//   1. MUL/MULH/MULHSU/MULHU 共享一个无符号乘积；有符号高位通过减去
//      负操作数对应的修正项得到，低 32 位与符号无关。
//   2. 除法的边界语义按 RISC-V 规范显式处理，不依赖主机 C++ 的除法行为：
//        - 除零：DIV 返回 -1，REM 返回被除数；
//        - INT_MIN / -1 溢出：DIV 返回 INT_MIN，REM 返回 0。
//   3. ENABLE_DIV=0 时不生成组合除法/取余。OoO 后端使用独立的多周期
//      divider；默认保留组合实现，供顺序基线等调用方使用。
// -----------------------------------------------------------------------------

module alu #(
  parameter bit ENABLE_DIV = 1'b1
) (
  input  logic [31:0] a,   // 操作数 A（来自 rs1 / PC / 0）
  input  logic [31:0] b,   // 操作数 B（来自 rs2 / 立即数；移位时取 b[4:0]）
  input  logic [4:0]  op,  // 操作码，取值见 rv32_defs.sv
  output logic [31:0] y    // 运算结果
);

  logic [63:0] mul_product;
  logic [31:0] mul_high, mul_correct_a, mul_correct_b;

  // signed(a) = unsigned(a) - a[31]*2^32。乘积的高半字因此只需减去
  // a 为负时的 b，以及 b 为负时的 a；修正项按 32 位自然回绕。
  assign mul_product = {32'b0, a} * {32'b0, b};
  assign mul_correct_a = a[31] && ((op == `ALU_MULH) || (op == `ALU_MULHSU))
                         ? b : 32'b0;
  assign mul_correct_b = b[31] && (op == `ALU_MULH) ? a : 32'b0;
  assign mul_high = mul_product[63:32] - mul_correct_a - mul_correct_b;

  // 除法结果缓存
  logic signed [31:0] quot_s;
  logic signed [31:0] rem_s;
  logic        [31:0] quot_u;
  logic        [31:0] rem_u;

  // 除法与取余：先处理除零与 INT_MIN / -1 两个边界，再走主机运算符。
  // 主机 C++ 的有符号除法向零截断，与 RISC-V 定义一致；边界单独处理
  // 既满足规范，也避免 INT_MIN / -1 在主机侧产生溢出未定义行为。
  generate
    if (ENABLE_DIV) begin : gen_div
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
    end else begin : gen_no_div
      assign quot_s = 32'b0;
      assign rem_s  = 32'b0;
      assign quot_u = 32'b0;
      assign rem_u  = 32'b0;
    end
  endgenerate

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
      `ALU_MUL:    y = mul_product[31:0];
      `ALU_MULH,
      `ALU_MULHSU,
      `ALU_MULHU:  y = mul_high;
      `ALU_DIV:    y = quot_s;
      `ALU_DIVU:   y = (b == 32'b0) ? 32'hffff_ffff : quot_u;
      `ALU_REM:    y = rem_s;
      `ALU_REMU:   y = (b == 32'b0) ? a : rem_u;
      default:     y = 32'b0;
    endcase
  end

endmodule
