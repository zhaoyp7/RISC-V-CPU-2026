// -----------------------------------------------------------------------------
// rv32_defs.sv — 全局编码定义
//
// 本文件必须排在 filelist.f 的第一位：其中的 `define 宏对后续所有源文件
// 生效（Verilator 与 Yosys 的预处理器都按文件顺序共享宏定义）。
//
// 之所以用 `define 而不是 SystemVerilog package，是因为 Yosys 0.63 的
// SV 前端不支持模块头 import 与 package 内 typedef 端口。
//
// 译码器（decoder.sv）产生这些编码，ALU（alu.sv）与 core.sv 消费它们，
// 集中定义可避免各模块对同一操作码出现不一致的硬件语义。
// -----------------------------------------------------------------------------

`ifndef RV32_DEFS_VH
`define RV32_DEFS_VH

// ---- ALU 操作码（5 bit）----------------------------------------------------
`define ALU_ADD    5'd0    // 加法（也用于 LUI/AUIPC/地址计算）
`define ALU_SUB    5'd1    // 减法
`define ALU_SLL    5'd2    // 逻辑左移
`define ALU_SLT    5'd3    // 有符号小于置 1
`define ALU_SLTU   5'd4    // 无符号小于置 1
`define ALU_XOR    5'd5    // 按位异或
`define ALU_SRL    5'd6    // 逻辑右移
`define ALU_SRA    5'd7    // 算术右移
`define ALU_OR     5'd8    // 按位或
`define ALU_AND    5'd9    // 按位与
`define ALU_MUL    5'd10   // M 扩展：乘法低 32 位
`define ALU_MULH   5'd11   // M 扩展：有符号 x 有符号高 32 位
`define ALU_MULHSU 5'd12   // M 扩展：有符号 x 无符号高 32 位
`define ALU_MULHU  5'd13   // M 扩展：无符号 x 无符号高 32 位
`define ALU_DIV    5'd14   // M 扩展：有符号除法
`define ALU_DIVU   5'd15   // M 扩展：无符号除法
`define ALU_REM    5'd16   // M 扩展：有符号取余
`define ALU_REMU   5'd17   // M 扩展：无符号取余

// ---- ALU 操作数 A 的选择（2 bit）-------------------------------------------
`define A_REG  2'd0        // 取 rs1 读出值
`define A_PC   2'd1        // 取当前 PC（AUIPC）
`define A_ZERO 2'd2        // 取 0（LUI：0 + imm 即立即数本身）

// ---- ALU 操作数 B 的选择（1 bit）-------------------------------------------
`define B_REG 1'b0         // 取 rs2 读出值
`define B_IMM 1'b1         // 取立即数

// ---- 写回数据来源（2 bit）--------------------------------------------------
`define WB_ALU 2'd0        // ALU 结果
`define WB_MEM 2'd1        // Load 数据
`define WB_PC4 2'd2        // PC + 4（JAL/JALR 的返回地址）

// ---- 访存宽度（2 bit）------------------------------------------------------
`define SZ_BYTE 2'd0       // 字节
`define SZ_HALF 2'd1       // 半字
`define SZ_WORD 2'd2       // 字

`endif
