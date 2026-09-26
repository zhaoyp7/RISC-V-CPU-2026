// -----------------------------------------------------------------------------
// decoder.sv — 指令译码器（纯组合逻辑）
//
// 输入一条 32 位指令，输出：
//   - 寄存器地址 rs1/rs2/rd；
//   - 各类控制信号（写回使能、写回来源、ALU 操作、操作数选择、访存控制等）；
//   - 已按指令格式拼装并符号扩展好的立即数 imm；
//   - illegal：非法指令标志（core 收到后停机，便于发现编码错误）。
//
// 立即数格式（RISC-V 规范）：
//   I 型：instr[31:20] 符号扩展；
//   S 型：instr[31:25] 与 instr[11:7] 拼接后符号扩展；
//   B 型：instr[31] [7] [30:25] [11:8] 0，再符号扩展；
//   U 型：instr[31:12] 左移 12 位；
//   J 型：instr[31] [19:12] [20] [30:21] 0，再符号扩展。
//
// 译码结果编码（ALU 操作等）见 rv32_defs.sv。
// 本模块不做时序逻辑，不含状态，输出只取决于 instr。
// -----------------------------------------------------------------------------

module decoder (
  input  logic [31:0] instr,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd,
  output logic        reg_we,       // 是否写回 rd
  output logic [1:0]  wb_sel,       // 写回来源：ALU / MEM / PC+4
  output logic [4:0]  alu_op,       // ALU 操作码
  output logic [1:0]  a_sel,        // ALU A 操作数来源：rs1 / PC / 0
  output logic        b_sel,        // ALU B 操作数来源：rs2 / imm
  output logic [31:0] imm,          // 拼装好的立即数
  output logic        is_branch,    // 条件分支
  output logic        is_jal,       // 直接跳转
  output logic        is_jalr,      // 寄存器跳转
  output logic        is_load,      // 读内存
  output logic        is_store,     // 写内存
  output logic [1:0]  mem_size,     // 访存宽度：字节 / 半字 / 字
  output logic        mem_unsigned, // Load 是否零扩展（LBU/LHU）
  output logic        illegal       // 非法指令
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];

  // ---- 立即数拼装 ----------------------------------------------------------
  always_comb begin
    unique case (opcode)
      7'b0010011,  // OP-IMM
      7'b0000011,  // LOAD
      7'b1100111,  // JALR
      7'b1110011:  // SYSTEM（本课程不要求，立即数仍按 I 型拼装）
        imm = {{20{instr[31]}}, instr[31:20]};
      7'b0100011:  // STORE
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      7'b1100011:  // BRANCH
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      7'b0110111,  // LUI
      7'b0010111:  // AUIPC
        imm = {instr[31:12], 12'b0};
      7'b1101111:  // JAL
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      default:
        imm = 32'b0;
    endcase
  end

  // ---- 控制信号 ------------------------------------------------------------
  always_comb begin
    // 先给所有输出赋默认值，保证纯组合、无锁存器
    reg_we       = 1'b0;
    wb_sel       = `WB_ALU;
    alu_op       = `ALU_ADD;
    a_sel        = `A_REG;
    b_sel        = `B_REG;
    is_branch    = 1'b0;
    is_jal       = 1'b0;
    is_jalr      = 1'b0;
    is_load      = 1'b0;
    is_store     = 1'b0;
    mem_size     = `SZ_WORD;
    mem_unsigned = 1'b0;
    illegal      = 1'b0;

    unique case (opcode)
      // LUI：rd = 0 + imm
      7'b0110111: begin
        reg_we = 1'b1;
        a_sel  = `A_ZERO;
        b_sel  = `B_IMM;
        alu_op = `ALU_ADD;
      end
      // AUIPC：rd = pc + imm
      7'b0010111: begin
        reg_we = 1'b1;
        a_sel  = `A_PC;
        b_sel  = `B_IMM;
        alu_op = `ALU_ADD;
      end
      // JAL：rd = pc + 4，PC 跳转由 core 计算
      7'b1101111: begin
        reg_we = 1'b1;
        wb_sel = `WB_PC4;
        is_jal = 1'b1;
      end
      // JALR：rd = pc + 4，目标地址 = (rs1 + imm) & ~1
      7'b1100111: begin
        reg_we = 1'b1;
        wb_sel = `WB_PC4;
        is_jalr = 1'b1;
        b_sel  = `B_IMM;
        if (funct3 != 3'b000) illegal = 1'b1;
      end
      // 条件分支：比较由 core 完成，ALU/写回都不参与
      7'b1100011: begin
        is_branch = 1'b1;
        b_sel     = `B_IMM;
        if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
      end
      // Load：地址 = rs1 + imm，写回来源为内存数据
      7'b0000011: begin
        reg_we  = 1'b1;
        wb_sel  = `WB_MEM;
        is_load = 1'b1;
        b_sel   = `B_IMM;
        unique case (funct3)
          3'b000: mem_size = `SZ_BYTE;                          // LB
          3'b001: mem_size = `SZ_HALF;                          // LH
          3'b010: mem_size = `SZ_WORD;                          // LW
          3'b100: begin mem_size = `SZ_BYTE; mem_unsigned = 1'b1; end  // LBU
          3'b101: begin mem_size = `SZ_HALF; mem_unsigned = 1'b1; end  // LHU
          default: illegal = 1'b1;
        endcase
      end
      // Store：地址 = rs1 + imm，数据来自 rs2
      7'b0100011: begin
        is_store = 1'b1;
        b_sel    = `B_IMM;
        unique case (funct3)
          3'b000: mem_size = `SZ_BYTE;  // SB
          3'b001: mem_size = `SZ_HALF;  // SH
          3'b010: mem_size = `SZ_WORD;  // SW
          default: illegal = 1'b1;
        endcase
      end
      // OP-IMM：立即数参与运算
      7'b0010011: begin
        reg_we = 1'b1;
        b_sel  = `B_IMM;
        case (funct3)
          3'b000: alu_op = `ALU_ADD;
          3'b001: begin  // SLLI：RV32 要求 funct7 = 0000000
            alu_op = `ALU_SLL;
            if (funct7 != 7'b0000000) illegal = 1'b1;
          end
          3'b010: alu_op = `ALU_SLT;
          3'b011: alu_op = `ALU_SLTU;
          3'b100: alu_op = `ALU_XOR;
          3'b101: begin  // SRLI / SRAI 由 funct7[30] 区分
            if (funct7 == 7'b0000000) alu_op = `ALU_SRL;
            else if (funct7 == 7'b0100000) alu_op = `ALU_SRA;
            else illegal = 1'b1;
          end
          3'b110: alu_op = `ALU_OR;
          3'b111: alu_op = `ALU_AND;
          default: illegal = 1'b1;
        endcase
      end
      // OP：寄存器-寄存器运算，含 M 扩展
      7'b0110011: begin
        reg_we = 1'b1;
        if (funct7 == 7'b0000001) begin
          // M 扩展：funct3 逐一对应 8 条乘除指令
          unique case (funct3)
            3'b000: alu_op = `ALU_MUL;
            3'b001: alu_op = `ALU_MULH;
            3'b010: alu_op = `ALU_MULHSU;
            3'b011: alu_op = `ALU_MULHU;
            3'b100: alu_op = `ALU_DIV;
            3'b101: alu_op = `ALU_DIVU;
            3'b110: alu_op = `ALU_REM;
            3'b111: alu_op = `ALU_REMU;
          endcase
        end else begin
          case (funct3)
            3'b000: alu_op = (funct7 == 7'b0100000) ? `ALU_SUB : `ALU_ADD;
            3'b001: begin
              alu_op = `ALU_SLL;
              if (funct7 != 7'b0000000) illegal = 1'b1;
            end
            3'b010: alu_op = `ALU_SLT;
            3'b011: alu_op = `ALU_SLTU;
            3'b100: alu_op = `ALU_XOR;
            3'b101: alu_op = (funct7 == 7'b0100000) ? `ALU_SRA : `ALU_SRL;
            3'b110: alu_op = `ALU_OR;
            3'b111: alu_op = `ALU_AND;
            default: illegal = 1'b1;
          endcase
          // funct7 只允许 0000000（基础运算）与 0100000（SUB/SRA）
          if (funct7 != 7'b0000000 && funct7 != 7'b0100000) illegal = 1'b1;
          if (funct7 == 7'b0100000 && funct3 != 3'b000 && funct3 != 3'b101) illegal = 1'b1;
        end
      end
      // FENCE / SYSTEM / AMO 等一律视为非法（课程不要求）
      default: illegal = 1'b1;
    endcase
  end

endmodule
