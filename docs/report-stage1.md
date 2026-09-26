# 第一阶段报告：单周期顺序 RISC-V CPU 基线

## 1. 阶段目标

本阶段不追求性能，目标是先建立**正确、可综合、可验证**的最小内核，为后续
流水线与乱序改造提供稳定的数据通路边界。具体验收标准：

- 实现完整 RV32IM 用户态指令（M 扩展、全部 Load/Store）；
- 通过全部 19 个 `correctness_*` 测试（OJ 退出协议）；
- 综合面积不超过阶段 1 的 9,000 um^2 限制；
- 顶层 `student_top` 严格符合课程 AXI4-Lite 端口规范。

## 2. 关键设计决策

### 2.1 为什么是"单周期执行 + 多周期访存"

外部内存是 AXI4-Lite 从机，默认响应延迟 10 个周期。若严格 1 CPI，仅一次
取指就需要十多个周期，因此物理上不存在真正的单周期机。本设计取如下折中：

> **执行阶段（译码、读寄存器、ALU、写回、PC 更新）在一个周期内完成；
> 取指与 Load/Store 由 FSM 拆成多个周期。**

对纯 ALU 指令而言执行仍是一拍完成；访存类指令则额外经历若干周期。

### 2.2 单一 AXI 主机 + I-Cache

顶层只有一个 AXI 端口，而取指（I-Cache 回填）与数据访存都需要访问内存。
由于同一时刻只有一条指令在飞，两者在实际时间上互斥：

- I-Cache 回填只在 `core` 处于取指状态时发起；
- 数据访存只在 `core` 处于访存状态时发起。

因此用一个 `axi_mem_if` 即可，请求地址按 `refill_valid` 二选一，响应广播给
两个消费者，各自只在自己等待的状态采样。无需仲裁器。

### 2.3 I-Cache 的必要性

`correctness_pi` 有 3,117,658 条动态指令。无 Cache 时每条指令的取指都要
访问一次 10 周期延迟的 AXI 内存，实测需要 54,728,322 周期，远超本地默认
`MAX_CYCLES=1000000`。加入 4 KiB 直接映射 I-Cache 后降到 17,317,609 周期。

### 2.4 编码集中定义而非 SystemVerilog package

Yosys 0.63 的 SV 前端不支持模块头 `import` 与 package typedef 端口，而
Verilator 又不搜索源文件所在目录、无法 `include` 同目录头文件。最终方案是
把编码常量以 `` `define`` 放入 `rv32_defs.sv` 并置于 `filelist.f` 首位：
Verilator 与 Yosys 的预处理器都按文件顺序共享宏，从而在两种工具下都能工作。

## 3. 微架构

### 3.1 总体结构

```text
                            student_top
  +------------------------------------------------------------------+
  |                                                                  |
  |   +-----------+  fetch_req   +--------------------------+        |
  |   |  icache   |<-------------|          core            |        |
  |   | 1024 x 32 |------------->|  FETCH -> EXEC -> MEM    |        |
  |   +-----+-----+  fetch_inst  |        -> HALT           |        |
  |         |                    +------------+-------------+        |
  |         | refill                          | data_req             |
  |         +---------------+-----------------+                      |
  |                         v                                        |
  |                  +-------------+   AXI4-Lite (AR/R, AW/W/B)      |
  |                  | axi_mem_if  |<===============================> 外部内存
  |                  +-------------+                                |
  +------------------------------------------------------------------+
```

### 3.2 模块职责

| 模块 | 类型 | 职责 | 关键实现 |
| --- | --- | --- | --- |
| `student_top` | 顶层 | AXI 端口、请求仲裁、响应广播 | refill 与 data 互斥，无仲裁器 |
| `axi_mem_if` | 时序 | AXI4-Lite 主机适配 | 5 状态 FSM；AW/W 分别记录完成；valid 不依赖 ready |
| `icache` | 时序 | 直接映射指令 Cache | 1024 行 x 32 位；tag/data 用 `sram_fakeram`；valid 为 FF 阵列 |
| `core` | 时序 | 顺序执行 FSM + 数据通路 | 4 状态 FSM；无相关无前递；检测退出 store |
| `decoder` | 组合 | 译码、立即数拼装、控制信号 | 覆盖 RV32IM；非法指令置 `illegal` |
| `alu` | 组合 | 算术/逻辑/移位/比较/乘除 | 显式处理除零与 `INT_MIN / -1` |
| `regfile` | 时序 | 32 x 32 寄存器堆 | x0 恒 0；组合读、同步写 |

### 3.3 core 状态机

| 状态 | 行为 | 出口 |
| --- | --- | --- |
| `ST_FETCH` | 拉高 `fetch_valid`，等待 I-Cache 命中或回填完成 | 取回指令进入 `ST_EXEC` |
| `ST_EXEC` | 组合译码、读寄存器、算 ALU 与 `next_pc` | 非访存指令本拍写回并回 `ST_FETCH`；访存指令 PC+4 后进入 `ST_MEM`；非法指令进 `ST_HALT` |
| `ST_MEM` | 发起数据读/写，等待 AXI 响应 | Load 写回 rd；退出 store 进 `ST_HALT`；否则回 `ST_FETCH` |
| `ST_HALT` | 停机，不再发起总线请求 | — |

因为同一时刻只有一条指令在飞、寄存器写只发生在指令边界，所以不存在数据
相关，不需要前递网络；分支也不需要预测，EXEC 算出目标后直接更新 PC。

### 3.4 退出协议

程序最后执行一条写入 `0x80000000` 的 `sw`（`wstrb = 4'hf`）。内核不特判
该地址，而是把它当普通 store 发给内存，等写响应后停机；仿真器在写响应
握手瞬间捕获 `WDATA` 作为返回值并结束仿真。

### 3.5 I-Cache 时序

- 命中：`IDLE`（发起 SRAM 读）-> `LOOKUP`（比 tag，组合输出指令），共 2 拍；
- 缺失：`LOOKUP` 发现 miss 后进入 `REFILL`，AXI 回填数据写入 SRAM/tag 并置
  valid，同时把返回的指令直接旁路给内核，无需重读 SRAM。

## 4. 指令集覆盖

完整 RV32IM：

- **U/J 型**：`LUI`、`AUIPC`、`JAL`、`JALR`
- **分支**：`BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU`
- **OP-IMM**：`ADDI`、`SLTI`、`SLTIU`、`XORI`、`ORI`、`ANDI`、`SLLI`、
  `SRLI`、`SRAI`
- **OP**：`ADD`、`SUB`、`SLL`、`SLT`、`SLTU`、`XOR`、`SRL`、`SRA`、`OR`、`AND`
- **M 扩展**：`MUL`、`MULH`、`MULHSU`、`MULHU`、`DIV`、`DIVU`、`REM`、`REMU`
- **Load/Store**：`LB`、`LBU`、`LH`、`LHU`、`LW`、`SB`、`SH`、`SW`

课程不要求的 `CSR*`、`FENCE`、`ECALL/EBREAK` 统一被视为非法指令。

## 5. 验证方法与结果

### 5.1 验证流程

全部验证使用课程统一 OJ stdin/stdout 协议，不依赖波形：

```sh
make build                               # Verilator 编译
make test                                # 全部 correctness
make test Case=correctness_add_to_100    # 单点
make perf                                # IPC 基线
```

注意：仿真期 RTL 内不允许 `$display`，否则会污染 OJ 模式的 stdout。

### 5.2 正确性结果（19/19 通过）

```sh
make test MAX_CYCLES=200000000
# Results: 19 passed, 0 failed
```

| 用例 | 动态指令数 | 周期数 | CPI |
| --- | ---: | ---: | ---: |
| correctness_add_to_100 | 421 | 2,978 | 7.07 |
| correctness_array_test1 | 131 | 1,714 | 13.08 |
| correctness_array_test2 | 149 | 2,051 | 13.77 |
| correctness_basicopt1 | 142,059 | 790,097 | 5.56 |
| correctness_bulgarian | 265,654 | 1,916,726 | 7.22 |
| correctness_expr | 291 | 1,941 | 6.67 |
| correctness_gcd | 82 | 1,115 | 13.60 |
| correctness_hanoi | 3,674 | 28,690 | 7.81 |
| correctness_lvalue2 | 53 | 781 | 14.74 |
| correctness_magic | 441,938 | 3,916,753 | 8.86 |
| correctness_manyarguments | 37 | 677 | 18.30 |
| correctness_multiarray | 1,543 | 12,015 | 7.79 |
| correctness_naive | 37 | 677 | 18.30 |
| correctness_pi | 3,117,658 | 17,317,609 | 5.55 |
| correctness_qsort | 1,097,111 | 6,775,092 | 6.18 |
| correctness_queens | 265,167 | 2,238,777 | 8.44 |
| correctness_statement_test | 546 | 4,984 | 9.13 |
| correctness_superloop | 371,607 | 1,115,855 | 3.00 |
| correctness_tak | 1,221,227 | 11,304,801 | 9.26 |

CPI 在 3.0 ~ 18.3 之间，差异来自访存指令占比：纯计算循环（superloop）CPI
接近 3，而小用例因冷启动取指缺失摊薄，CPI 较高。

### 5.3 I-Cache 效果对比

| 用例 | 无 Cache 周期 | 有 I-Cache 周期 | 加速比 |
| --- | ---: | ---: | ---: |
| correctness_add_to_100 | 7,757 | 2,978 | 2.60x |
| correctness_magic | 9,217,110 | 3,916,753 | 2.35x |
| correctness_pi | 54,728,322 | 17,317,609 | 3.16x |
| correctness_qsort | 19,938,591 | 6,775,092 | 2.94x |
| correctness_queens | 5,418,987 | 2,238,777 | 2.42x |
| correctness_superloop | 5,574,203 | 1,115,855 | 4.99x |
| correctness_tak | 25,958,303 | 11,304,801 | 2.30x |

### 5.4 性能基线（`make perf`）

| 基准 | 动态指令数 | 周期数 | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 55,275 | 0.1259 |
| perf_multiply | 21,722 | 73,221 | 0.2967 |
| perf_qsort | 139,900 | 1,048,405 | 0.1334 |
| perf_rsort | 195,719 | 1,521,960 | 0.1286 |
| perf_towers | 5,278 | 63,202 | 0.0835 |
| perf_vvadd | 4,524 | 35,093 | 0.1289 |
| **几何平均** | | | **0.1380** |

IPC 距离阶段 1 的 0.6 还有很大差距，主要瓶颈是**数据访存没有 Cache**：
每次 Load/Store 都要付 10 周期 AXI 延迟。这是下一阶段的首要优化方向。

## 6. 综合结果（Yosys + ASAP7 7.5T RVT TT）

目标时钟周期 2.0 ns，两个模式的结果如下：

| 指标 | diagnose | opt |
| --- | ---: | ---: |
| 总面积 | 5,396.16 um^2 | 5,444.23 um^2 |
| 组合逻辑 | 2,521.36 um^2 | 2,565.06 um^2 |
| 时序逻辑 | 638.90 um^2 | 643.27 um^2 |
| SRAM | 2,235.91 um^2 | 2,235.91 um^2 |
| 估计频率 | 48.04 MHz | 47.00 MHz |
| 最小时钟周期 | 20.82 ns | 21.27 ns |
| 建立裕量 | -18.82 ns | -19.27 ns |

面积构成（diagnose，模块含子模块）：

| 模块 | 面积 (um^2) | 占比 | 直接面积 (um^2) |
| --- | ---: | ---: | ---: |
| student_top | 5,396.16 | 100.00% | 5.72 |
| u_icache | 2,809.44 | 52.06% | 573.53 |
| u_core | 2,543.09 | 47.13% | 117.08 |
| └ u_alu | 1,794.54 | 33.26% | 1,794.54 |
| └ u_regfile | 621.27 | 11.51% | 621.27 |
| └ u_decoder | 10.21 | 0.19% | 10.21 |
| u_mem_if | 37.92 | 0.70% | 37.92 |

结论与问题：

1. **面积满足阶段 1 的 9,000 um^2 限制**，其中 SRAM 2,235.91 um^2 来自
   I-Cache 的 tag/data 阵列。
2. **频率只有约 47 MHz**，关键路径为 `core` 寄存器 -> ALU 组合网络 ->
   寄存器堆，即行为级组合除法器（`/` `%`）导致的超长组合路径。
   这是本阶段的已知缺陷，需要"流水线 + 多周期串行除法器"解决。
3. ALU 单独占 1,794.54 um^2（约 33%），主要也是乘除法器。

## 7. 遇到的问题与解决

| 问题 | 现象 | 解决方案 |
| --- | --- | --- |
| `$display` 污染 OJ 协议 | `make test` 全部 FAIL，实际结果正确 | 移除 RTL 内调试打印；调试改用 `make run LOG=` |
| Yosys 不支持模块头 `import`/package | `make synth` 报 `unexpected TOK_IMPORT` | 删除 package，编码集中到 `rv32_defs.sv` 的宏 |
| Verilator 不搜索文件所在目录 | `` `include "rv32_defs.vh" `` 编译失败 | 改为把宏文件列为第一个源文件，靠编译顺序共享宏 |
| 除法边界语义 | 主机 C++ 的除零/溢出行为与 RISC-V 不一致 | 在 ALU 中显式处理除零与 `INT_MIN / -1` 两种情况 |
| pi 超周期上限 | 无 Cache 需要 5,472 万周期 | 加入 4 KiB 直接映射 I-Cache，降到 1,732 万周期 |

## 8. 不足与下一阶段计划

按优先级：

1. **流水线化**：把取指/译码/执行/访存/写回切开，缓存的关键路径拆散；
   同时把行为级除法器换成多周期串行除法器，提高可达频率。
2. **D-Cache**：当前 IPC 0.138 的主要瓶颈；加上数据 Cache 后才有望接近
   阶段 1 的 0.6。
3. **参数化与敏感度分析**：I-Cache 的行数 `INDEX_BITS` 已参数化；后续把发射
   宽度、ROB 深度、物理寄存器堆大小、保留站深度、D-Cache 容量与相联度都
   做成参数，为最终报告的参数敏感度分析提供数据。
4. **乱序改造**：重命名 + ROB + 发射队列 + 按序提交。

## 附录：复现方式

```sh
git clone <repo> && cd RISC-V-CPU-2026
make build JOBS=8
make test MAX_CYCLES=200000000     # 19/19 通过
make perf MAX_CYCLES=200000000     # IPC 基线
make synth                        # opt 模式面积/时序
make code                         # OJ 提交产物 ./code
```

源码位于 `verilog/`，计划文档见 `docs/baseline-plan.md`。
