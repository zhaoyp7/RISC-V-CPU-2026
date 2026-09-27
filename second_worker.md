# 乙的工作手册（执行 & 存储线）

> 你是**乙**：负责执行与存储线。甲负责前端与提交线（取指、译码、BPU、RAT、
> ROB、提交）。完整分工见 `division.md`，本文只讲**你每一步具体做什么**。
>
> 你的背景：写过 C++ Tomasulo RV32I 模拟器（`RISCV_CPU-simulator`），
> 熟悉 ROB/RAT/RS/CDB/LSQ/ALU/DMEM 的**逻辑**，但没写过 RTL。
> 你拥有的现有资产：`alu.sv`、`axi_mem_if.sv`、`mem_subsystem` 要包的旧逻辑，
> 以及你自己那台 C++ 模拟器（用来做黄金模型）。

---

## 0. 总览：你的路线图

| 阶段 | 你的工作包 | 交付物 | 完成标志 |
| --- | --- | --- | --- |
| P0 | W1 单元测试设施 + ALU 冒烟 | `tools/unit/build.py`、`alu_tb.cpp` | 随机对拍 0 fail |
| P0 | W2 串行除法器（热身独立任务） | `verilog/divider.sv` + TB | 边界/随机全过，≤ 40 拍 |
| P0 | W3 `mem_subsystem.sv` v1 | 包住 `axi_mem_if` 的双客户内存口 | TB 过，接缝不变 |
| P0 | W4 黄金模型 + 轨迹对拍 | `tools/golden/`、`tools/trace_diff.py` | 对 `.data` 输出正确结果与轨迹 |
| P1 | backend：EX/MEM/WB、前递、停顿、分支、除法接入 | `verilog/backend.sv` | 与甲集成后 19/19 + 300 MHz |
| P2 | D-Cache + 仲裁 + 写缓冲 + 统计 | `verilog/dcache.sv`、升级 `mem_subsystem.sv` | IPC ≥ 0.6、面积 ≤ 9000 |
| P3 | PRF + 发射队列 + CDB + LSQ v1 | 四个 `.sv` | IPC ≥ 0.845、面积 ≤ 18000 |
| P4 | 第二执行端口 + LSQ 完整版 + Cache 参数化 | 同上扩展 | IPC ≥ 1.0985、面积 ≤ 36000 |

**三条自我保护原则**（违反会浪费大量时间）：

1. **不碰甲的文件**：`frontend*.sv`、`if_stage.sv`、`decoder.sv`、`icache.sv`、
   `bpu.sv`、`rename.sv`、`rob.sv`、`commit.sv`。需要改动就提需求给甲。
2. **不碰课程框架**：`scripts/`、`Makefile`、`config.mk`；你自己的脚本放 `tools/`。
3. **你的 stub / TB 文件永远不进 `verilog/filelist.f`**，否则 OJ 综合会炸。
   只有你写的**设计文件**才登记进去（P0 时甲会帮你登记，你告诉他文件名即可）。

---

## 1. P0：四个热身任务（按顺序做，全部互相独立）

顺序建议：**W1 → W2 → W3 → W4**。理由：W1 让你学会 Verilator 单元测试这个
最重要的工具；W2 是完全独立、边界明确、能出成果的第一块 RTL；W3 复用现成
代码；W4 回到你最熟的 C++，同时也是后面所有调试的基础设施。

### 热身 0（半天）：先把现有环境和代码读明白

```sh
git submodule update --init --recursive          # 拉测试用例（当前目录是空的）
make build                                       # 确认能编译
make test Case=correctness_add_to_100 MAX_CYCLES=200000000
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 LOG=run.log
```

同时精读（用 `explanation.md` 对照）：
- `verilog/alu.sv`：你要扩展/替换除法的对象，`alu.sv:47-60` 是除法边界语义；
- `verilog/axi_mem_if.sv`：5 状态 FSM、valid 不依赖 ready 的纪律；
- `verilog/student_top.sv:82-93`：现在是"I-Cache 回填 / 数据访存互斥 mux"，
  P2 你要把它升级为真正的仲裁器；
- `scripts/sim.cpp`：内存从机与退出协议（`bvalid && bready` 时结束仿真，
  见 `sim.cpp:119-121`）——**退出 store 不需要特判**，它就是一个普通 store。

### W1（1 天）：单元测试设施 + ALU 冒烟测试

**目标**：不依赖任何人、不依赖 `student_top`，单独编译并测试一个模块。

**Step 1**：新建 `tools/unit/build.py`，抄 `scripts/build.py` 的骨架，但支持
任意顶层模块。要点：

- `sys.path.insert(0, "<repo>/scripts")` 后 `from toolchain import enter_appimage,
  DEFAULT_APPIMAGE`、`from build import verilator_command`，这样 AppImage / 原生
  Verilator 的选择逻辑和 `make build` 完全一致；
- 命令行：`--top alu --tb tools/unit/alu_tb.cpp --sources verilog/rv32_defs.sv
  verilog/alu.sv --out build/unit/alu`；
- 核心命令（注意 `--top-module`、`-CFLAGS -std=c++17`、`--build`）：

```sh
verilator --cc --exe --build --assert -Wall -Wno-fatal \
  --top-module alu -Mdir build/unit/alu \
  verilog/rv32_defs.sv verilog/alu.sv tools/unit/alu_tb.cpp \
  -CFLAGS -std=c++17 -o build/unit/alu/tb
```

- 包装一个 `tools/unit/run.sh MODULE` 依次调用各 TB。

**Step 2**：写 `tools/unit/alu_tb.cpp`，模式如下（以后每个 TB 都长这样）：

```cpp
#include "Valu.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>

static uint32_t rng = 12345;
static uint32_t next() { rng ^= rng<<13; rng ^= rng>>17; rng ^= rng<<5; return rng; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Valu* dut = new Valu;
    int fails = 0;
    for (int trial = 0; trial < 200000; ++trial) {
        uint32_t a = next(), b = next();
        for (int op = 0; op < 18; ++op) {
            dut->a = a; dut->b = b; dut->op = op;   // op 编码见 rv32_defs.sv
            dut->eval();
            if (dut->y != ref_alu(op, a, b)) {       // 你自己写参考函数
                if (++fails < 20) printf("a=%08x b=%08x op=%d got=%08x want=%08x\n",
                                         a, b, op, dut->y, ref_alu(op, a, b));
            }
        }
    }
    printf("%s fails=%d\n", fails ? "FAIL" : "PASS", fails);
    return fails != 0;
}
```

**参考函数注意事项**（以后所有对拍同理）：M 扩展语义必须按 RISC-V 规范写，
有符号除法用 `int64_t` 中转避免 `INT_MIN / -1` 的 UB，余数符号跟被除数。
这个参考函数直接复用你 C++ 模拟器里的实现即可。

**验收**：`tools/unit/run.sh alu` 输出 `PASS`。顺手记录一下编译耗时——后面
你每天都会跑它。

### W2（2~3 天）：`verilog/divider.sv` 串行除法器（★最佳热身 RTL）

**为什么第一个写它**：零依赖（不碰任何人的接口）、规格明确（RISC-V 除法语义
你已经烂熟）、能立刻用 W1 的框架测试。

**接口（建议，甲不认识它也没关系）**：

```systemverilog
module divider (
  input  logic        clk,
  input  logic        reset,
  input  logic        start,        // 1 拍脉冲；busy=1 时应忽略
  input  logic        is_signed,    // 1: DIV/REM, 0: DIVU/REMU
  input  logic [31:0] a,            // 被除数
  input  logic [31:0] b,            // 除数
  output logic        busy,
  output logic        done,         // 完成时 1 拍脉冲
  output logic [31:0] quotient,
  output logic [31:0] remainder
);
```

**算法（恢复余数法 / shift-subtract）**：

1. `start=1` 且 `busy=0`：锁存操作数，busy=1；
2. 边界情况可以直接在 start 拍组合判定、下一拍 done：
   - `b == 0`：`quotient = 32'hffffffff`，`remainder = a`；
   - 有符号且 `a == 32'h8000_0000 && b == 32'hffff_ffff`：
     `quotient = a`，`remainder = 0`；
3. 其余情况：有符号先取绝对值、记符号，然后 32 次"左移 + 比较 + 减"循环：
   ```
   rem = 0; for i in 31..0: rem = (rem<<1)|a[i]; if (rem>=b) { rem-=b; q[i]=1; }
   ```
   无符号直接算；有符号最后按"商向零取整、余数取被除数符号"修正：
   `q = (a_neg ^ b_neg) ? -qu : qu; r = a_neg ? -ru : ru;`
4. 第 32 次迭代结束时拉高 `done`（1 拍），busy 拉低。

**用状态机写**：`IDLE / RUN / FIN` 三态即可。每拍做一次移位（32 拍），
比"一拍做完 32 位"友好得多——这就是你躲开当前 ALU 那个 47 MHz 关键路径的办法。

**单元测试 `divider_tb.cpp`** 至少覆盖：

- 随机 10 万组（含负数）× 有/无符号，与 C++ 参考对拍；
- 除零 4 种（DIV/DIVU/REM/REMU 语义不同）；
- `INT_MIN / -1`、`INT_MIN / 1`、`0 / b`、`a / 1`、最大数；
- 握手边界：`busy` 期间再拉 `start` 不能出问题；
- 数周期：从 `start` 到 `done` 应 ≤ 40 拍（后面综合报告要用）。

**验收**：`tools/unit/run.sh divider` 全过；把周期数和资源直觉（面积后面看）
记到 `docs/perf-log.md`。

### W3（1 天）：`mem_subsystem.sv` v1（两客户版）

**目标**：把 `student_top.sv:82-93` 的 mux 搬进来，变成正式模块，接口给
I-Cache 回填（甲）和数据访存（你）两个客户。**对外行为与现在完全一致**，
方便集成时一次通过。

```systemverilog
module mem_subsystem (
  input  logic        clk, reset,
  // 客户 0：I-Cache 回填（读）
  input  logic        ireq_valid,
  input  logic [31:0] ireq_addr,
  output logic        iresp_valid,
  output logic [31:0] iresp_rdata,
  // 客户 1：数据访存（读/写）
  input  logic        dreq_valid, dreq_we,
  input  logic [31:0] dreq_addr, dreq_wdata,
  input  logic [3:0]  dreq_wstrb,
  output logic        dresp_valid,
  output logic [31:0] dresp_rdata,
  // AXI4-Lite（端口与 student_top 一致，内部接 axi_mem_if）
  input  logic [31:0] rdata, input logic [1:0] rresp, input logic rvalid, output logic rready,
  output logic [31:0] araddr, output logic arvalid, input logic arready,
  output logic [31:0] awaddr, output logic awvalid, input logic awready,
  output logic [31:0] wdata, output logic [3:0] wstrb, output logic wvalid, input logic wready,
  input  logic [1:0] bresp, input logic bvalid, output logic bready
);
```

**实现要点**：

- 例化现有 `axi_mem_if`，把请求 mux 进去；
- **锁存"这笔事务属于谁"**（`owner` 寄存器）：发起请求时确定 owner，响应来时
  只给对应客户。比现在的"广播给两人"更规范，也为 P2 的 D-Cache 做准备；
- 优先级：I-Cache 回填 > 数据（和现有行为一致）。因为回填是短突发，不会
  饿死数据客户。

**单元测试**：TB 里写一个简化的 AXI 从机模型（数组 + 延迟计数，参考
`scripts/sim.cpp` 的 `Memory` 但只保留必需部分），验证读/写/owner 路由。
**验收**：`run.sh mem_subsystem` 全过；接缝行为没有变化。

### W4（1.5 天）：黄金模型 + 轨迹对拍（回到 C++ 舒适区）

**目标**：有一个"权威答案机"，以后 RTL 每提交一条指令就和它对一次轨迹。
这也是 `issue.pdf` 建议的 naïve interpreter，只不过你是站在 Tomasulo 版基础上写。

**做法**：

1. 新建 `tools/golden/`，**不要**直接改你旧仓库，复制需要的文件过来；
2. 写一个顺序解释器（约 200 行 C++ 就够，不用 Tomasulo 那套）：
   - 读 `.data`（你的老加载器直接复用）；
   - 实现 RV32IM + 新退出协议：遇到向 `0x80000000` 的 `sw` 就停，返回值 = `wdata`；
   - 逐条提交打印轨迹：`pc rd wdata`（不写寄存器时 `rd=0`），可加
     `--trace file` 与 `--max-cycles N`；轨迹文件格式固定，
     例如 `%08x %0d %08x\n`；
3. 写 `tools/trace_diff.py`：读两份轨迹，输出第一条不一致的行号与上下文；
4. RTL 侧的轨迹打印：后续在 backend 写回时加
   ```systemverilog
   `ifdef LOCAL_TRACE
     $display("T %08x %0d %08x", pc_q, rd_q, wdata);
   `endif
   ```
   **OJ 构建不带 `LOCAL_TRACE`，不会污染 stdout**；本地用 W1 的脚本加
   `-DLOCAL_TRACE` 单独编一个调试仿真器。

**验收**：对小用例（`add_to_100`、`expr`、`gcd`）黄金模型的结果 = `expected.txt`；
轨迹自洽。到了 P1 集成，你们就靠它逐条定位 RTL 的第一个错误。

### P0 收尾：和甲对齐接口

- 一起 review `docs/interface.md`：`fetch_packet / backend_ready / redirect /
  if_refill / data_mem` 的**每个字段位宽**；
- 告诉甲 `mem_subsystem` 的端口（他要把 I-Cache 的 refill 接过来）；
- 让甲在 `filelist.f` 登记你的 `divider.sv`、`mem_subsystem.sv`（其余新文件
  等用到时再登记）。

---

## 2. P1：`backend.sv`（顺序流水线的执行段）

**目标**：EX/MEM/WB 三级 + 寄存器堆 + 前递 + load-use 停顿 + 分支解析 +
除法器接入。与甲的 frontend 对接后，19/19 通过、频率 ≥ 300 MHz。

### Step P1-1（0.5 天）：对齐接口

和甲确认（写进 `docs/interface.md`）：

- `fetch_packet`：乙接收 `valid, pc, inst, imm, rs1, rs2, rd, reg_we, wb_sel,
  alu_op, a_sel, b_sel, is_branch, is_jal, is_jalr, is_load, is_store, mem_size,
  mem_unsigned, illegal`（译码在前端完成）；
- `backend_ready`：低电平 = 前端下拍停顿（load-use、除法忙、访存等待都拉低）；
- `redirect`：`valid, target_pc, flush`——你在 EX 拍末给出；
- 别忘 **x0 特判**：`reg_we && rd==0` 不写、不前递。

### Step P1-2（2 天）：流水线骨架

- 新建 `verilog/backend.sv`，内部就三组流水寄存器：
  `ID/EX`、`EX/MEM`、`MEM/WB`；
- EX 级：操作数选择（复用 `rv32_defs.sv` 的 `A_*`/`B_*`）→ `alu`；分支比较；
  访存地址计算；`next_pc` 不再由你算（甲负责）——你只输出 `redirect`；
- MEM 级：驱动 `data_mem` 端口；**同一时刻只允许一笔访存在飞**（P1 简化：
  发起后拉低 `backend_ready`，等 `dresp_valid` 再放行）；
- WB 级：写回 `regfile.sv`（沿用现有模块，x0 已处理）。
- `illegal` 在 P1 可以先当作普通指令吞掉（P3 再进异常）。

### Step P1-3（1 天）：前递 + load-use

EX 操作数公式（两个源都同理）：

```systemverilog
// 优先级：EX/MEM > MEM/WB > 寄存器堆
src1 = (exmem.reg_we && exmem.rd != 0 && exmem.rd == idex.rs1) ? exmem.wb_data :
       (memwb.reg_we && memwb.rd != 0 && memwb.rd == idex.rs1) ? memwb.wb_data :
       rf_rdata1;
```

- store 的写数据（rs2）、分支比较也都要用**前递后**的值；
- load-use 停顿条件：`idex.is_load && idex.rd != 0` 且 ID 段指令要用 `idex.rd`；
  停顿 = 保持 IF/ID、给 ID/EX 插气泡、拉低 `backend_ready` 1 拍；
- **MEM 段 load 可以前递**（`memwb.wb_data`），别多停。

### Step P1-4（0.5 天）：分支与跳转

- 分支/JAL/JALR 都在 EX 解析（复用现成的比较逻辑，见 `core.sv:129-148`）；
- P1 策略：顺序取指（预测不跳）；分支真跳或 `jal/jalr` 时输出
  `redirect_valid=1 + target`，前端负责冲刷。**JAL/JALR 无条件重定向**；
- 退出 store 不特判：当作普通 store 走 `data_mem`；仿真器在写响应握手时
  自己结束（`sim.cpp:119-121`）。

### Step P1-5（0.5 天）：接入除法器

- `DIV/DIVU/REM/REMU` 进入 EX：若 `divider.busy==0` 则给 `start`，之后拉低
  `backend_ready` 直到 `done`；done 拍用 `quotient/remainder` 写 `EX/MEM`；
- 乘法和其它运算先保持现有组合逻辑（P4 有需要再改），综合报告出来后再决定
  是否把乘法也切一拍。

### Step P1-6（1 天）：单元测试（stub_frontend + 你的 TB）

- 写 `tools/unit/stub_frontend.sv`：从 TB 传入的"指令队列"依次产生
  `fetch_packet`（可以事先用甲的真 `decoder.sv` 例化生成，**只读**）；
- TB 覆盖：前递（连续 ALU 依赖）、load-use（load→用）、分支命中/不命中、
  JAL/JALR、各宽度 load/store、除零、除法忙时的停顿；
- 每个 case 结束检查寄存器堆内容（TB 里层次引用 `dut->backend__DOT__u_regfile...`
  不可靠，建议给 backend 加 **只用于调试的输出端口** 或在 `LOCAL_TRACE` 下
  打印写回）。

### Step P1-7（集成窗口 1.5 天，和甲一起）

按 `division.md` §4.3 逐边替换：
1. 真前端 + `stub_backend` → 看取指流；
2. `stub_frontend` + 真后端 → 看执行；
3. 全真 + 真 `mem_subsystem` → 小用例（`add_to_100`、`expr`、`gcd`）→
   全量 `make test MAX_CYCLES=200000000`；
4. `make perf`、`make synth MODE=opt`（频率必须 ≥ 300 MHz；
   如果不够，先查你的除法器和访存等待路径）；
5. 用 W4 的 `trace_diff.py` 逐条对拍；
6. 打 tag `p1-pipeline`。

**P1 完成标准**：19/19 通过；频率 ≥ 300 MHz；`docs/perf-log.md` 有一行记录。

---

## 3. P2：D-Cache + 内存子系统（课程阶段 1）

**目标**：IPC ≥ 0.6、面积 ≤ 9000 µm²。你的核心交付是 D-Cache 和真正的仲裁器。

### Step P2-1（2 天）：`dcache.sv` v1（直接映射、1 字行、写直达）

```systemverilog
module dcache #(parameter INDEX_BITS = 8) (
  input  logic        clk, reset,
  // 来自 MEM 级
  input  logic        req_valid, req_we,
  input  logic [31:0] req_addr, req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic        resp_valid, resp_rdata,
  output logic        stall,          // 缺失或写缓冲满时拉低 backend_ready
  // 到 mem_subsystem 的 AXI 客户端口（读/写）
  output logic        mreq_valid, mreq_we,
  output logic [31:0] mreq_addr, mreq_wdata,
  output logic [3:0]  mreq_wstrb,
  input  logic        mresp_valid, mresp_rdata
);
```

- 结构照抄 `icache.sv`：data/tag 用 `sram_fakeram`，valid 用触发器阵列；
- 写策略：**写直达 + 写缓冲**。store 命中：写 cache + 推进写缓冲；store 缺失：
  **不分配**，直接进写缓冲；
- 写缓冲 2~4 项、按序排空；**load 缺失且写缓冲非空时，先把缓冲排空再发起
  读**（保守但正确，避免读到旧数据）；
- 缺失时一次只回填一个字（和 I-Cache 一样），P4 再把行加宽成 4 字。

**单元测试**：TB 里放迷你 AXI 从机（复用 W3 的模型，加延迟参数），
覆盖：命中读写、缺失回填、写缓冲反压、连续 store、store→load 同地址。

### Step P2-2（1 天）：`mem_subsystem.sv` 升级为仲裁器

- 三个客户端：I-Cache refill（甲）、D-Cache 缺失读、D-Cache 写缓冲写；
- 仲裁策略：I-Cache refill 优先，其次 D-Cache（读写轮转防止写饿死）；
  关键是**锁存 owner**，响应只回给对应客户；
- 接口对甲保持 `if_refill` 字段不变——**这样甲完全不用改前端**；
- 单客户端行为保持"一次一笔事务"，直接复用 `axi_mem_if`。

### Step P2-3（0.5 天）：统计

- D-Cache 命中/缺失、写缓冲排空次数、AXI 事务数；
- **只在 `ifdef LOCAL_TRACE` 下 `$display`**，OJ 构建禁止输出；
- 数据交给甲做分支预测对比，一起填 `docs/perf-log.md`。

### Step P2-4（集成窗口 1.5 天）

- 逐边替换 + 全量回归；
- 做 4 组性能实验并记录：`P1 纯流水 / +I$ / +D$ / +BPU`（BPU 是甲的，
  但你负责把数据整理成表，写进 `docs/perf-log.md`）；
- `make synth MODE=diagnose`：如果面积紧张，先缩 D-Cache（INDEX_BITS 减 1）、
  再考虑写缓冲深度；
- 验收：IPC ≥ 0.6、面积 ≤ 9000、频率 ≥ 300、19/19；tag `p2-stage1`。

---

## 4. P3：乱序后端（课程阶段 2）

**目标**：与甲的 rename/ROB/commit 对接，实现单发射乱序执行 + 按序提交，
IPC ≥ 0.845。**先抄一遍你模拟器里的结构，再考虑优化。**

### Step P3-1（0.5 天）：冻结四条总线

和甲把 `docs/interface.md` 补到 P3 版（字段/位宽都定死）：

- `dispatch`（甲→你）：`valid, pc, inst, 控制位, imm, dest_tag, src1_tag,
  src1_ready, src2_tag, src2_ready`；
- `cdb`（你→甲+你自己）：`valid, tag, value, exception`；
- `complete`（你→甲）：`valid, tag, exception`（如果 cdb 带了异常可以合并）；
- `commit`（甲→你）：`valid, tag, is_store, lsq_id`（释放 store、通知写内存）。

约定：`ROB_TAG_W = $clog2(ROB_DEPTH)`；x0 由甲固定映射到零 tag。

### Step P3-2（1 天）：`prf.sv`

- 物理寄存器堆：2 读口 + 1 写口（CDB 写），x0 映射的物理寄存器永不写；
- 读口是组合的（唤醒后的指令同拍读）——若综合跑不到 300 MHz，再改成
  "select 拍 + 读一拍"的两级发射，先别提前优化。

### Step P3-3（1.5~2 天）：`issue_queue.sv` + 唤醒/选择

每个表项：`valid, busy1, tag1, busy2, tag2, uop 负载, age`。

- **唤醒**：CDB 广播的 `tag` 与表项的 `tag1/tag2` 比较，相同则清 busy；
- **选择**：所有 `valid && !busy1 && !busy2` 的表项中选 age 最老者发射
  （用递增序号或 age 矩阵）；
- **发射**：把 uop + 两个源操作数（读 PRF）送给执行单元；单发射时每拍发 1 条；
- 满时向甲反压（dispatch 侧 ready 拉低）；
- 除法器作为**非流水功能单元**：busy 期间它占住的那条指令不能发射后续依赖；
  简单做法：除法在 EX 停留直到 `done`，期间该 RS 表项保持 busy。

**测试**（用甲的 `stub_front_ooo.sv`）：脚本化发 100 条乱序可完成的指令，
检查发射顺序满足"就绪且最老"。

### Step P3-4（0.5 天）：`cdb.sv`

- 结果来源：ALU（每拍最多 1 条）、除法 `done`、load 数据回来了；
- 仲裁优先级：load > ALU > 除法（load 通常在最关键路径上）；
- 广播 `tag + value`，同时写 PRF（同一个时钟沿）和清唤醒位；
- 未获胜的结果下一拍重试（要锁存）。

### Step P3-5（1.5~2 天）：`lsu.sv` / `lsq.sv` v1

先做**保守但正确**的版本，跑通再提速：

- dispatch 时按序分配 LSQ 表项，`lsq_id` 回给甲（放进 ROB 里）；
- 地址生成：当 base 寄存器就绪（源 tag 已唤醒）时算地址；用一条地址生成
  通路即可，不必乱序；
- load：地址就绪且**所有更老 store 的地址已知**（否则等）→ 读 D-Cache；
  若命中更老 store 且该 store 数据已就绪，可以前递（v1 可以先不做，
  直接等 store commit 后再读，慢但简单）；
- store：数据+地址都就绪后挂在 LSQ，等甲的 `commit` 信号到了才写 D-Cache；
- 所有访存都经 D-Cache，保持 P2 的接口。

### Step P3-6（1 天）：乱序后端单元测试

- 用 `stub_front_ooo` 构造：长依赖链、除法、load 后紧跟使用者、分支；
- 检查：无死锁、每拍最多一条 CDB、ROB 满/RS 满/LSQ 满时反压正确；
- 把你在 C++ 模拟器里踩过的坑（唤醒顺序、store 地址未就绪）都做成用例。

### Step P3-7（集成窗口 2 天）

- 逐边替换（这次接缝是四条总线，先接 `dispatch/cdb` 再补 `complete/commit`）；
- 小用例 → 全量 → 压力；（`add_to_100` 过不了先查 store commit 释放）
- `trace_diff.py` 对拍逐条定位；
- `make perf`（目标 ≥ 0.845）、`make synth`（面积 ≤ 18000）；
- tag `p3-stage2`。

---

## 5. P4：多发射 + LSQ 完整版 + 参数化（课程阶段 3）

**目标**：IPC ≥ 1.0985、面积 ≤ 36000 µm²。

### Step P4-1（1.5 天）：第二执行端口

- 新增一个 ALU（或"ALU + 分支"组件），发射队列支持**每拍选 2 条**（两条
  age 最老的就绪项）；
- dispatch 仍是 2 条/拍（甲负责把前端加宽），你要保证：
  - 2 个读口冲突时用 PRF 多读口或读口仲裁（两个指令读同一物理寄存器没问题）；
  - 两条同时要除法器时按 age 排队。

### Step P4-2（2 天）：LSQ 完整版

- store 地址 CAM：load 可以**乱序执行**，只要没有更老 store 地址匹配；
- store-to-load forwarding：匹配且数据就绪直接转发，不等 commit；
- 更老 store 地址未知时 load 停顿（或按预测执行，有余力再做）；
- 这是 IPC 上 1.0 的关键之一，先用 `perf_qsort/rsort` 这类访存密集用例
  验证收益。

### Step P4-3（1 天）：Cache 参数化 + 除法器流水化

- `dcache` 增加 `LINE_WORDS`（4 字）、`ASSOC`（1/2 路）、写回可选；
  每加一个参数都要跑一遍全量正确性；
- 除法器若成为频率瓶颈（看 `make synth` 的关键路径），改成"每拍迭代一次、
  可重叠"的流水除法（或至少把除法器路径寄存器切开）。

### Step P4-4（集成窗口 2 天）

- `make test` 全绿；`make perf` 达 1.0985；`make synth` 面积 ≤ 36000、
  频率 ≥ 300（有余力冲 400/500）；
- 报告里属于你的章节：D-Cache 设计与参数影响、LSQ/前递、除法器权衡、
  后端关键路径分析；
- 参数扫描分工：你跑 PRF/RS/Cache/除法器相关配置，甲跑 ROB/宽度/BPU 相关，
  结果合并；
- tag `p4-final`。

---

## 6. 每个阶段的固定动作（照做就行）

| 时点 | 动作 |
| --- | --- |
| 阶段开始 | 和甲对齐接口 → 更新 `docs/interface.md` → 更新各自 stub |
| 开发中 | 只在自己的 feature 分支；每个模块先在 `tools/unit` 里过 TB |
| 合并前 | `tools/unit/run.sh` 全部 PASS + `make test` 全量绿 |
| 集成窗口 | 逐边替换 → 小用例 → 全量 → perf/synth → tag → 更新 `docs/perf-log.md` |
| 阶段结束 | 写半页 `docs/journal-乙.md`；和甲对一次人日账（见 `division.md` §6） |

**常用命令**：

```sh
tools/unit/run.sh divider                                # 你的单元测试
make test Case=correctness_add_to_100 MAX_CYCLES=200000000   # 开发期小步快跑
make test MAX_CYCLES=200000000                           # 里程碑全量
make perf MAX_CYCLES=200000000                           # IPC
make synth MODE=diagnose                                 # 看你的模块占多少面积
make synth MODE=opt                                      # 最终面积/频率
```

---

## 7. 新手坑清单（RTL 与 Verilator）

1. **组合逻辑没给默认值/分支不全** → 综合出锁存器（Verilator 会报
   `LATCH`）；每个 `always_comb` 开头把所有输出赋默认值。
2. `always_ff` 里**忘复位**的状态（尤其 valid/busy/计数器）→ 仿真通过、
   复位不稳定；所有状态都要有 reset 分支。
3. **valid 依赖 ready** → AXI 死锁；`axi_mem_if` 已经是对的，照抄纪律。
4. **SRAM 读延迟 1 拍**：本拍 `en=1, we=0`，下拍才有 `rdata`；写周期
   `rdata` 未定义（`docs/sram.md` §3）。
5. **位宽截断**：`assign x = a + b;` 会按左边宽度截；常量写全 `32'd4`。
6. **有符号运算**：比较/右移要显式 `$signed(...)`；除法参考函数用 `int64_t`。
7. **`$display` 只能在 `ifdef LOCAL_TRACE` 里**，否则 OJ stdout 被污染，
   `make test` 全 FAIL（`report-stage1.md` §7 有血泪记录）。
8. **Yosys 0.63 不支持 package/struct 端口**（`report-stage1.md` §2.4）：
   接口用扁平信号 + `rv32_defs.sv` 宏，别用 SystemVerilog interface。
9. **stub / TB 文件绝不写进 `filelist.f`**；OJ 会把 `filelist.f` 全部拿去综合。
10. **别对着波形调**：先看 `LOG=` 日志和你自己的 `$display` 轨迹；波形只在
    最后没有办法时看一小段。
11. **一次只改一个模块并立刻跑 TB**；乱序阶段"改了三个地方重启仿真碰运气"
    会浪费一整天。
12. 时间紧时按 `division.md` §8 降级，**永远保住 19/19 和最近的 tag**。

---

## 8. 你的第一个月节奏（建议）

| 时间 | 你做什么 |
| --- | --- |
| 第 1 天 | 热身 0 + W1（ALU TB 跑通） |
| 第 2~4 天 | W2 除法器 + 单测 |
| 第 5 天 | W3 mem_subsystem v1 |
| 第 6~7 天 | W4 黄金模型 + trace_diff |
| 第 2~3 周 | P1 backend（含单元测试）；周末集成窗口 |
| 第 4~5 周 | P2 D-Cache + 仲裁 + 性能实验；集成窗口 |
| 第 6~8 周 | P3 PRF/IQ/CDB/LSQ；集成窗口 |
| 第 9~11 周 | P4 双发射/LSQ 完整版/参数化；报告；DDL 前留 1~2 周缓冲 |

> 第一周结束时你应该有：一个能测任意模块的 `tools/unit`、一个通过随机对拍
> 的串行除法器、一个轨迹对拍工具。**这三个东西会让后面每一步都快很多。**
