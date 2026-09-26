# 单周期顺序 RISC-V CPU 基线计划

本计划描述进入流水线/乱序改造之前的第一阶段目标：用一个正确性优先的顺序内核通过
全部 `correctness_*` 测试。基线完成后，再逐步演进为乱序执行微架构。

## 0. 前提与设计决策

- **HDL**：SystemVerilog（Verilator 支持 `always_ff` / `always_comb` / `enum`）。
- **内存路径**：第一阶段直连 AXI4-Lite，不实现 Cache；pi 等大程序在最后阶段用
  直接映射 I-Cache 解决（见第 5 步）。
- **实现范围**：完整 RV32IM + 全部正确性测试。
- **"单周期"的含义**：外部内存是 AXI4-Lite 且响应延迟固定 10 周期，物理上不存在
  1 CPI 的单周期机（取指一次即约 12 周期）。因此基线采用：

  > **单周期执行数据通路 + 多周期访存 FSM**：ALU 指令为取指（约 12 周期）+ 执行
  > （1 周期）；load/store 额外经历约 12 周期访存。执行阶段本身在一个周期内完成。

## 1. 微架构设计

- 单个 AXI4-Lite 主端口串行复用；同一时刻只有一笔事务，天然无需仲裁。
- 指令执行 FSM：`FETCH → EXEC → MEM（仅 load/store）→ WB → FETCH`。
- 取指：AR 握手后等待 `rvalid`；顺序 PC 每次 +4，分支/跳转目标在 EXEC 阶段写入 PC。
- 访存：load 走 AR/R 通道；store 走 AW/W/B 通道并等待 B 响应。
- **Halt 协议**：不特判退出地址；向 `0x80000000` 的 32 位 Store 作为普通 store 发出，
  在 `bvalid && bready` 握手后置 done 并停止取指。
- 寄存器堆：32 x 32，x0 恒为 0，组合读，无需复位。
- AXI 握手纪律：`arvalid/awvalid/wvalid` 由状态寄存器驱动，**不得组合依赖 ready**。

## 2. 文件结构

`verilog/filelist.f` 按相对路径登记全部源文件，顶层模块固定为 `student_top`：

```text
verilog/
├── filelist.f        # RTL 源文件列表
├── student_top.sv    # 顶层，对接 AXI4-Lite 端口，取指/访存共享一个 AXI 引擎
├── rv32_defs.sv      # 全局宏定义（ALU 操作/选择信号编码），必须在 filelist 首位
├── axi_mem_if.sv     # AXI 读写引擎：mem_req/mem_resp 简单接口，一次一笔事务
├── icache.sv         # 直接映射 I-Cache（1024 行 x 32 位，SRAM 数据/标签 + valid FF）
├── core.sv           # FSM + PC + 数据通路 + halt 控制
├── decoder.sv        # 译码与立即数生成
├── alu.sv            # 算术逻辑/比较/M 扩展/分支条件
└── regfile.sv        # 寄存器堆
```

## 3. ISA 分三批实现

按测试用例的依赖顺序推进：

- **Batch 1（跑通 `correctness_add_to_100`）**：
  `LUI`、`AUIPC`、`ADDI`、`ADD`、`LW`、`SW`、`BEQ`、`BNE`、`BLT`、`BGE`、
  `BGEU`、`BLTU`、`JAL`、`JALR`。
- **Batch 2（其余 correctness）**：
  `SUB`、`AND/OR/XOR` 及其立即数版、`SLL/SRL/SRA` 及其立即数版、
  `SLT/SLTU/SLTI/SLTIU`、`LB/LBU/LH/LHU`、`SB/SH`。
- **Batch 3（M 扩展）**：
  `MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU`。

## 4. 实施与验证步骤

每一步都以构建或测试结果验证，不依赖波形调试：

1. 编写 `student_top.sv` + `axi_mem_if.sv`，用只发 AR 的取指循环验证能读到
   `program.data` 的第一个字（`make run ... LOG=run.log` 查看 `$display`）。
2. 编写 `regfile.sv` + `decoder.sv`(Batch 1) + `alu.sv` + `core.sv`，
   更新 `filelist.f`，通过
   `make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050`。
3. 补齐 Batch 2，按动态指令数从小到大逐个验证：
   `make test Case=correctness_naive`、`correctness_gcd`、`correctness_lvalue2`、
   `correctness_array_test1/2`、`correctness_expr`、`correctness_hanoi` 等。
4. 实现 Batch 3（注意除零与 `INT_MIN / -1` 的 RISC-V 语义，不依赖主机 `/` `%` 行为），
   跑通除 pi 外的全部 correctness。
5. 为取指路径加直接映射 I-Cache，解决 `correctness_pi`（310 万条动态指令）在默认
   `MAX_CYCLES=1000000` 下的超时问题；必要时本地先调大 `MAX_CYCLES` 验证功能。
6. 验收：全量 `make test` 通过，并运行 `make synth MODE=diagnose` 确认面积在
   阶段 1（9000 um^2）量级。

## 5. 已知风险与对策

| 风险 | 对策 |
| --- | --- |
| pi 动态指令数 310 万，无 Cache 至少 3100 万周期 | 第 5 步加 I-Cache；本地先调大 `MAX_CYCLES` |
| 有符号右移 / SLT 的 `$signed` 误用 | decoder 明确 op，ALU 统一转 signed 处理 |
| LH/LBU/SH 的字节选择与符号扩展 | 用地址低 2 位做字节选择 + 单独扩展逻辑 |
| 除零、`INT_MIN / -1` 语义 | 单独 case 实现，不依赖主机语义 |
| 综合时除法面积过大 | 基线先用运算符，后续替换为多周期串行除法器 |

## 6. 本阶段不做

流水线、Cache（除 pi 需要的 I-Cache）、分支预测、乱序执行相关结构。
基线目标是优先拿满正确性分数，并为后续演进保留清晰的数据通路边界。

## 7. 实施结果

- 功能：`make test MAX_CYCLES=200000000` 全部 19 个 `correctness_*` 通过。
  - `correctness_add_to_100`：421 条指令 / 2978 周期。
  - `correctness_pi`：3,117,658 条指令 / 17,317,609 周期（1 KiB 直接映射
    I-Cache，未加 Cache 前为 54,728,322 周期）。
- 综合（Yosys + ASAP7，`CLOCK_PERIOD_NS=2.0`）：
  - `opt` 模式：总面积 5,444.5 um^2（组合 2,565.4 / 时序 643.3 / SRAM 2,235.9），
    满足阶段 1 的 9,000 um^2 限制。
  - 估计频率仅约 46.6 MHz，关键路径为单周期 ALU 内综合出的除法器。
    频率问题留待流水线阶段：将除法改为多周期串行实现，并把取指/译码/执行切开。
- 交付文件：`verilog/` 下 8 个源文件（`rv32_defs.sv` 必须在 `filelist.f` 首位，
  宏跨文件生效），顶层 `student_top`。
- 代码风格：不使用 SystemVerilog package（Yosys 0.63 对 package 支持不足），
  编码常量以 `` `define`` 放在 `rv32_defs.sv`，经 filelist 顺序实现跨文件共享。

## 8. 后续路线

1. 顺序流水线化（IF/ID/EX/MEM/WB + 前递），解决频率瓶颈。
2. 多周期串行除法器，压缩 ALU 面积与关键路径。
3. D-Cache，提升 IPC（当前 pi 仍受 10 周期访存延迟主导）。
4. 乱序改造：重命名 + ROB + 发射队列 + 按序提交。
