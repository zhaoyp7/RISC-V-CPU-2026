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
  logic [31:0] mul_high;

  // Signedness is included in Booth partial products, so high-half results
  // do not need carry-propagating correction subtractors after the tree.
  mul_booth_wallace u_multiplier (
    .a(a), .b(b),
    .a_signed((op==`ALU_MULH)||(op==`ALU_MULHSU)),
    .b_signed(op==`ALU_MULH),
    .product(mul_product)
  );
  assign mul_high=mul_product[63:32];

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

// Shared 32x32 product with independently signed/unsigned operands.
// Radix-4 Booth needs 17 digits because the multiplier is zero-extended to
// 33 bits. Negative rows use one's complement plus correction bits, avoiding
// a carry-propagating negation for every partial product.
module mul_booth_wallace (
  input wire [31:0] a,
  input wire [31:0] b,
  input wire a_signed,
  input wire b_signed,
  output wire [63:0] product
);
  localparam integer ROWS=18;
  localparam integer LEVELS=6;
  wire [34:0] recode_b={{2{b_signed && b[31]}},b,1'b0};
  wire [33:0] extended_a={{2{a_signed && a[31]}},a};
  wire [16:0] negative;
  wire [63:0] correction;
  wire [ROWS*64-1:0] tree [0:LEVELS] /* verilator split_var */;

  function automatic integer row_count(input integer level);
    integer n,k;
    begin
      n=ROWS;
      for(k=0;k<level;k=k+1)n=2*(n/3)+(n%3);
      row_count=n;
    end
  endfunction

  for(genvar digit=0;digit<17;digit=digit+1)begin:gen_booth
    wire [2:0] code=recode_b[digit*2+:3];
    logic [33:0] magnitude;
    logic negate;
    always_comb begin
      magnitude='0;
      negate=1'b0;
      case(code)
        3'b001,3'b010: magnitude=extended_a;
        3'b011: magnitude=extended_a<<1;
        3'b100: begin magnitude=extended_a<<1;negate=1'b1;end
        3'b101,3'b110: begin magnitude=extended_a;negate=1'b1;end
        default: begin magnitude='0;negate=1'b0;end
      endcase
    end
    assign negative[digit]=negate;
    wire [63:0] encoded={{30{magnitude[33]^negate}},(magnitude^{34{negate}})};
    assign tree[0][digit*64+:64]=encoded<<(2*digit);
  end
  for(genvar bit_idx=0;bit_idx<64;bit_idx=bit_idx+1)begin:gen_correction
    if((bit_idx%2)==0 && bit_idx/2<17)begin:gen_negative_correction
      assign correction[bit_idx]=negative[bit_idx/2];
    end else begin:gen_no_correction
      assign correction[bit_idx]=1'b0;
    end
  end
  assign tree[0][17*64+:64]=correction;

  // Row-based pseudo-Wallace compression: 18 -> 12 -> 8 -> 6 -> 4 -> 3 -> 2.
  // Each 3:2 compressor uses XOR sums and shifted majority carries; carries
  // propagate between compression levels, never along a 64-bit row here.
  for(genvar level=0;level<LEVELS;level=level+1)begin:gen_compress
    localparam integer INPUTS=row_count(level);
    localparam integer OUTPUTS=row_count(level+1);
    for(genvar group=0;group<INPUTS/3;group=group+1)begin:gen_triple
      wire [63:0] x=tree[level][(3*group)*64+:64];
      wire [63:0] y=tree[level][(3*group+1)*64+:64];
      wire [63:0] z=tree[level][(3*group+2)*64+:64];
      assign tree[level+1][(2*group)*64+:64]=x^y^z;
      assign tree[level+1][(2*group+1)*64+:64]=((x&y)|(x&z)|(y&z))<<1;
    end
    for(genvar rest=0;rest<INPUTS%3;rest=rest+1)begin:gen_rest
      assign tree[level+1][(2*(INPUTS/3)+rest)*64+:64]=
          tree[level][(3*(INPUTS/3)+rest)*64+:64];
    end
    assign tree[level+1][OUTPUTS*64+:(ROWS-OUTPUTS)*64]='0;
  end
  // Modulo-2^64 arithmetic gives the full signed/unsigned 32x32 bit pattern.
  function automatic [63:0] final_prefix_add(input logic [63:0] a,b);
    logic [4:0] sum0 [0:15];
    logic [3:0] sum1 [1:15];
    logic [15:0] group_p [0:4],group_g [0:4];
    integer block_idx,level_idx;
    begin
      for(block_idx=0;block_idx<16;block_idx=block_idx+1)begin
        sum0[block_idx]={1'b0,a[block_idx*4+:4]}+{1'b0,b[block_idx*4+:4]};
        if(block_idx!=0)sum1[block_idx]=a[block_idx*4+:4]+b[block_idx*4+:4]+4'd1;
        group_p[0][block_idx]=&(a[block_idx*4+:4]^b[block_idx*4+:4]);
        group_g[0][block_idx]=sum0[block_idx][4];
      end
      for(level_idx=0;level_idx<4;level_idx=level_idx+1)
        for(block_idx=0;block_idx<16;block_idx=block_idx+1)begin
          if(block_idx>=(1<<level_idx))begin
            group_g[level_idx+1][block_idx]=group_g[level_idx][block_idx] |
              (group_p[level_idx][block_idx]&group_g[level_idx][block_idx-(1<<level_idx)]);
            group_p[level_idx+1][block_idx]=group_p[level_idx][block_idx]&group_p[level_idx][block_idx-(1<<level_idx)];
          end else begin
            group_g[level_idx+1][block_idx]=group_g[level_idx][block_idx];
            group_p[level_idx+1][block_idx]=group_p[level_idx][block_idx];
          end
        end
      final_prefix_add[3:0]=sum0[0][3:0];
      for(block_idx=1;block_idx<16;block_idx=block_idx+1)
        final_prefix_add[block_idx*4+:4]=group_g[4][block_idx-1]?sum1[block_idx]:sum0[block_idx][3:0];
    end
  endfunction
  assign product=final_prefix_add(tree[LEVELS][0+:64],tree[LEVELS][64+:64]);
endmodule
