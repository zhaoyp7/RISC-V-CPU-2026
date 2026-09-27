# 甲的工作手册（前端 & 提交线）

> 你是**甲**：负责前端与提交线。乙负责执行与存储线（`backend.sv`、ALU、
> 除法器、PRF、发射队列、CDB、LSQ、D-Cache、`mem_subsystem.sv`）。
> 完整分工见 `division.md`，乙的任务见 `second_worker.md`。
>
> 你的背景：写过 C++ Tomasulo RV32I 模拟器（`RISCV_CPU-simulator`：IF_IS /
> decoder / RAT / ROB / RegFile / ArithRS / BranchRS / LSQ / ALU / BU / CDB /
> DMEM），熟悉乱序的**逻辑**，但没写过 RTL。
> 你的现有资产：`decoder.sv`、`icache.sv`、`core.sv` 的前端部分，以及你
> 对 RAT/ROB/分支预测的理解。

---

## 0. 总览：你的路线图

| 阶段 | 你的工作包 | 交付物 | 完成标志 |
| --- | --- | --- | --- |
| P0 | W1 `decoder.sv` 全量单测 | `tools/unit/decoder_tb.cpp` | 全指令编码对拍 0 fail |
| P0 | W2 `pc_unit.sv` / `if_stage.sv`（独立任务） | PC + 重定向模块 + TB | 脚本化 PC 序列全过 |
| P0 | W3 `bpu.sv` 原型（独立任务，P2 直接用） | BTB + 2-bit BHT | 随机分支流对拍 |
| P0 | W4 骨架与接口冻结 | `cpu_config.sv`、`docs/interface.md`、tag/branch | 双方 review 通过 |
| P1 | frontend：PC、IF/ID、取指握手、重定向、冲刷 | `verilog/frontend.sv`、改造 `icache.sv` | 与乙集成后 19/19 + 300 MHz |
| P2 | BPU 接入 + 预测恢复 + 统计 | `bpu.sv` 实装 | IPC ≥ 0.6、面积 ≤ 9000 |
| P3 | 重命名 + ROB + 提交 + 恢复 | `rename.sv`、`rob.sv`、`frontend_ooo.sv` | IPC ≥ 0.845、面积 ≤ 18000 |
| P4 | 2 宽前端 + BPU 增强 + 前端侧调优 | 扩展上述模块 | IPC ≥ 1.0985、报告/CR |

**三条自我保护原则**（违反会浪费大量时间）：

1. **不碰乙的文件**：`backend*.sv`、`alu.sv`、`divider.sv`、`regfile.sv`/
   `prf.sv`、`issue_queue.sv`、`cdb.sv`、`lsu.sv`、`lsq.sv`、`dcache.sv`、
   `mem_subsystem.sv`、`axi_mem_if.sv`。需要改动就提需求给乙。
2. **不碰课程框架**：`scripts/`、`Makefile`、`config.mk`（`config.mk` 已有
   环境修复行，别动）；自己的脚本放 `tools/`（和乙共用，新文件名加前缀
   避免冲突，如 `decoder_tb.cpp`）。
3. **你的 stub / TB 文件永远不进 `verilog/filelist.f`**。`filelist.f` 由你
   维护：只有被 `student_top` 真正实例化的设计文件才登记；新增文件先和乙
   确认文件名，登记后立刻 `make build` 验证。

> 环境已配好，见 `environment.md`：`make build/test/perf/synth` 都可用；
> 本机路径含中文，Yosys 走 `tools/yosys-wrap.sh`，不要删 `config.mk` 里那行。

---

## 1. P0：四个热身任务（按顺序做，全部互相独立）

顺序建议：**W1 → W2 → W3 → W4**。理由：W1 复习译码并搭好"改完立刻测"的
习惯；W2 是你 P1 前端的核心积木，独立可测；W3 是纯查表模块，练 RTL 手感且
P2 直接用；W4 把两人的接口一次性定死。

### 热身 0（半天）：环境与基线

```sh
make build JOBS=8
make test Case=correctness_add_to_100 MAX_CYCLES=200000000
make test MAX_CYCLES=200000000          # 19/19，确认起点
```

精读（配合 `explanation.md`）：
- `verilog/decoder.sv`：你 W1 要测的对象，也是 P1 后接缝的一半；
- `verilog/icache.sv`：注意命中的 2 拍是**串行 FSM**（IDLE→LOOKUP），
  每 2 拍才收一个新 PC——**P1 必须把它改成每拍可接收的流水线**，否则 IPC
  上限只有 0.5，够不到 P2 的 0.6；
- `verilog/core.sv:226-265`：现有 4 状态 FSM，P1 要拆掉；
- `docs/interface.md`（P0 你新建）：两人唯一契约。

### W1（1 天）：`decoder.sv` 全量单测（★最适合的第一块 RTL 练习）

**为什么先做它**：`decoder.sv` 是你自己的文件、纯组合、没有依赖；你在
Tomasulo 模拟器里写过 `decoder_test.cpp`，可以把它翻译成 Verilator 版本。

**Step 1**：乙在 P0 会提供 `tools/unit/build.py`。如果还没就绪，先用一条
命令直接编（`--top-module decoder`）：

```sh
verilator --cc --exe --build --assert -Wall -Wno-fatal \
  --top-module decoder -Mdir build/unit/decoder \
  verilog/rv32_defs.sv verilog/decoder.sv tools/unit/decoder_tb.cpp \
  -CFLAGS -std=c++17 -o build/unit/decoder/tb && build/unit/decoder/tb
```

**Step 2**：写 `tools/unit/decoder_tb.cpp`。不要只测几条，要**穷举结构**：

- 按 opcode 分组，遍历合法/非法 `funct3`、`funct7` 组合；
- 每条指令验证：`rs1/rs2/rd` 字段、`reg_we`、`wb_sel`、`alu_op`、
  `a_sel/b_sel`、`is_branch/is_jal/is_jalr/is_load/is_store`、`mem_size`、
  `mem_unsigned`、`illegal`；
- 五种立即数格式用**手工构造的边界值**（正负、最大最小、`-1`）验证符号扩展：
  重点核对 B 型/J 型的位重排（`decoder.sv:62-69`）；
- 用 `testcases/*/program.dump` 里的真实指令做交叉验证：写个小脚本从
  `.dump` 提取机器码（也可以用 `.data`），单测里喂进去比对期望控制信号。

**验收**：`tools/unit/run.sh decoder`（或上面的命令）输出 PASS；这个 TB 以后
每阶段都跑。

### W2（1 天）：`if_stage.sv` 的 PC/重定向核心（独立积木）

**目标**：先不接 I-Cache，只做"PC 怎么走"的时序逻辑，独立单测。它会是
P1 `frontend.sv` 的内部模块。

**接口建议**（P1 再扩大）：

```systemverilog
module pc_unit (
  input  logic        clk, reset,
  input  logic        advance,        // 下游接收，pc <= pc+4
  input  logic        stall,          // 保持（后端忙/取指未回）
  input  logic        redirect_valid, // 分支/跳转/预测失败
  input  logic [31:0] redirect_pc,
  output logic [31:0] pc
);
```

**优先级**：`redirect_valid > stall > advance`。写清注释，和乙对齐这个语义
（他的 redirect 在 EX 拍末有效，你下一拍必须已经切到新 PC）。

**单元测试 `pc_unit_tb.cpp`**：脚本化序列——
1. 复位后 pc=0，advance 连续 → 0,4,8,...；
2. 插 stall → PC 不动，stall 撤掉继续；
3. 同拍 `stall=1, redirect_valid=1` → 必须跳转；
4. 同拍 `advance=1, redirect_valid=1` → 必须跳转；
5. `pc+4` 溢出回绕（`0xffff_fffc → 0x0`）；
6. 随机序列与 C++ 参考模型对拍 10 万拍。

**验收**：TB PASS；把"redirect 优先"的语义写进 `docs/interface.md`。

### W3（1.5 天）：`bpu.sv` 原型（BTB + 2-bit BHT，P2 直接实装）

**为什么现在做**：它完全不依赖流水线/乱序，任何阶段都能独立开发和测试；
提前做完，P2 只剩"接线"。

**接口建议**：

```systemverilog
module bpu #(parameter BTB_INDEX_BITS = 8, BHT_INDEX_BITS = 10) (
  input  logic        clk, reset,
  // 预测端口（组合读，随取指 PC）
  input  logic [31:0] fetch_pc,
  output logic        predict_taken,
  output logic [31:0] predict_target,
  // 更新端口（来自 EX 解析结果，乙产生）
  input  logic        update_valid,
  input  logic [31:0] update_pc,
  input  logic        update_taken,
  input  logic [31:0] update_target
);
```

**实现**：
- BTB：直接映射 `{valid, tag, target}`，`fetch_pc` 查表；
- BHT：2-bit 饱和计数器（00/01/10/11），`predict_taken = counter[1]`；
- 只在 BTB 命中且计数器≥2 时给出 taken + 目标，否则顺序取指；
- 更新：同拍读写冲突时**先写后读/旁路**，避免预测读到旧表项。

**单元测试**：用 C++ 生成带循环/交替的分支流（如 `for` 循环的
"taken×N + not-taken×1"），喂给 RTL 与 C++ 参考模型，比较每一拍的预测与
最终准确率；再测冷启动、别名冲突（不同 PC 映射同一表项）。

**验收**：TB PASS；记录预测准确率，P2 集成时直接换成这个模块。

### W4（1.5 天）：骨架与接口冻结

**Step 1**：新建 `verilog/cpu_config.sv`（放在 `rv32_defs.sv` 之后），把
两人共用的参数集中定义（Yosys 0.63 不支持 package，用 `` `define``）：

```systemverilog
`define CPU_FETCH_WIDTH      1     // P4 改 2
`define CPU_ROB_DEPTH        32    // P4 扫参数
`define CPU_PRF_SIZE         64
`define CPU_IQ_DEPTH         8
`define CPU_LSQ_DEPTH        8
```

各模块用 `parameter X = `CPU_X` 引用，既集中又能被例化覆盖。

**Step 2**：写 `docs/interface.md` v1，把 `division.md` §2 的 bundle 全部
落成表格：字段名、位宽、方向、valid/ready 语义、时序约定。重点写清：

- `fetch_packet`（你→乙）：`valid, pc, inst, imm, rs1, rs2, rd, reg_we,
  wb_sel, alu_op, a_sel, b_sel, is_branch, is_jal, is_jalr, is_load,
  is_store, mem_size, mem_unsigned, illegal`；
- `backend_ready`（乙→你）：低 = 下拍停顿；
- `redirect`（乙→你）：`valid, target_pc`，同拍有效、下一拍 PC 已切换；
- `if_refill` / `data_mem`（甲乙↔mem_subsystem）；
- P3 的 `dispatch / cdb / complete / commit` 先写"预留"章节。

**Step 3**：打 tag、开分支、建记录：

```sh
git tag p0-baseline
git push origin p0-baseline
git checkout -b p1-front
```

同时让乙把 `divider.sv`、`mem_subsystem.sv` 文件名报给你，在
`filelist.f` 中登记（登记后立即 `make build` 验证，保持 main 绿）。

**验收**：`cpu_config.sv` 编译通过；`docs/interface.md` 乙 review 无异议；
tag 已推；两人各自的 feature 分支建好。

---

## 2. P1：`frontend.sv`（顺序流水线的前端）

**目标**：IF/ID 两级 + 取指握手 + 重定向/冲刷 + 反压；与乙的 backend 集成后
19/19、频率 ≥ 300 MHz。

### Step P1-1（0.5 天）：对齐接口

和乙逐条过 `docs/interface.md` 的 P1 版本；特别确认：

- `backend_ready` 的时序：你收到低电平的**下一拍**停止推进 IF/ID；
- `redirect` 的时序：EX 拍末有效，你下一拍必须已切 PC 且清掉错误路径指令；
- 谁清什么：**你清 IF/ID 和取指请求**，**乙清 ID/EX（插气泡）**；
- `if_refill`/`data_mem` 都是"一次一笔事务"的 req/resp，valid 不得依赖 ready
  （AXI 纪律，`docs/axi-lite.md` §3）。

### Step P1-2（2 天）：把 `icache.sv` 改成流水线（关键！）

现状是 FSM 串行：每 2 拍才收一个 PC。P2 要 IPC ≥ 0.6，取指吞吐必须 ≥ 1 条/拍，
所以先改 I-Cache：

- 做成 2 级流水：每拍接收一个新 PC 并锁存（stage A），下一拍 SRAM 数据回来
  做 tag 比较并输出（stage B）；用 valid 位随请求走，**命中时吞吐 = 1 条/拍**；
- 缺失：暂停接收（或把后续请求标为等待），发起 refill，回填后把该行的
  等待请求按序放行；回填数据旁路给等待中的那一条；
- 重定向：给取指流打"epoch/valid"随请求传播，redirect 后旧请求的结果直接丢弃。

> 这个改造是 P1 最重要的性能点，也是你独立可做的（接口只有 `fetch_valid/
> fetch_pc → fetch_resp_valid/fetch_inst` 和 refill 端口）。

### Step P1-3（2 天）：`frontend.sv` 组装

- 内部例化 `icache` + `pc_unit`（W2）+ 新增 `if_id_reg`（valid/pc/inst +
  译码好的控制包）；
- `decoder.sv` 放在前端：IF/ID 里存**已译码的控制包**（P3 可直接升级为
  dispatch uop）；
- 取指推进条件：`!backend_ready && !stall_icache && !redirect`；
- redirect 同拍：清 IF/ID valid、切 PC、丢弃在途取指结果；
- 非法指令：P1 交给后端处理（乙在 P3 才做异常），你只要保证 `illegal`
  字段正确送达。

### Step P1-4（0.5 天）：与后端的分工边界

- **分支/JAL/JALR 的解析在乙那边（EX）**，你只消费 `redirect`；
- P1 没有分支预测：分支按"不跳"顺序取指，真跳时乙给 redirect，你冲刷。
  **JAL/JALR 同理会产生 redirect**；
- 退出 store 走到乙的 MEM 阶段后仿真自然结束（`sim.cpp:119-121`），
  前端不需要停机逻辑。

### Step P1-5（1 天）：单元测试（`stub_backend.sv`）

- 自己写 `tools/unit/stub_backend.sv`：永远 `ready`、按脚本发 `redirect`、
  转发 refill/data 端口。**不进 `filelist.f`**；
- TB 覆盖：连续取指吞吐（命中时 1 条/拍）、I-Cache 缺失回填、后端反压时
  IF/ID 保持、redirect 同拍/延迟场景、重定向与指令回填冲突；
- 检查输出指令流与 PC 序列，和 W1/W2 的参考模型对拍。

### Step P1-6（集成窗口 1.5 天，和乙一起）

按 `division.md` §4.3 逐边替换：真前端 + 乙的 `stub_backend` → 全真；
小用例（`add_to_100`、`expr`、`gcd`）→ 全量：

```sh
make test MAX_CYCLES=200000000
make perf MAX_CYCLES=200000000
make synth MODE=opt            # 频率必须 ≥ 300 MHz
```

用乙的 `tools/trace_diff.py` 逐条对拍；打 tag `p1-pipeline`。

**P1 完成标准**：19/19；频率 ≥ 300 MHz；`docs/perf-log.md` 记录一行。

---

## 3. P2：BPU 接入（课程阶段 1）

### Step P2-1（1 天）：实装 `bpu.sv`

把 W3 的原型接进前端：取指时先查 BPU，命中且预测 taken 就直接给出目标 PC；
同时让"预测路径"带上标记，方便预测失败时只冲刷错误路径。

### Step P2-2（1 天）：预测失败恢复

- 乙在 EX 解析后发 `br_update`（真实方向+目标）和 `redirect`（仅当预测错误
  或非预测跳转）；你负责：
  - 用 `br_update` 更新 BTB/BHT（**每条分支都更新**，不只失败时）；
  - 收到 redirect 时冲刷错误路径；
- 边界：同拍"预测正确但目标不同"也要重定向（BTB 目标过期）。

### Step P2-3（0.5 天）：统计

- `branches / mispredicts / branch_types`，只在 `ifdef LOCAL_TRACE` 下
  `$display`（OJ 构建禁止输出）；数据交给乙汇总进 `docs/perf-log.md`。

### Step P2-4（集成窗口 1.5 天）

- 逐边替换 + 全量回归；和乙一起做 4 组性能实验（纯流水 / +I$ / +D$ / +BPU）；
- `make synth MODE=diagnose`：BTB/BHT 的 SRAM 面积如果挤压预算，先缩小表；
- 验收：IPC ≥ 0.6、面积 ≤ 9000、19/19；tag `p2-stage1`。

---

## 4. P3：重命名 + ROB + 提交（课程阶段 2）

先按你 Tomasulo 模拟器里的结构抄一遍，再考虑优化。**四条总线的字段在
P0/P1 已冻结**。

### Step P3-1（0.5 天）：冻结 P3 总线

和乙把 `docs/interface.md` 补全：`dispatch`（含 `dest_tag/src1_tag/src1_ready/
src2_tag/src2_ready`）、`cdb`、`complete`、`commit`；约定 `ROB_TAG_W =
$clog2(ROB_DEPTH)`、x0 永远映射到零 tag 且 ready=1。

### Step P3-2（1.5 天）：`rename.sv`

- 两张映射表：**重命名表**（推测态）和**提交表**（架构态）；
- 空闲列表管理物理寄存器；dispatch 时分配 `dest_preg`，把 `old_preg`
  存进 ROB（提交时释放）；
- `src_ready`：映射项不是 in-flight 就绪，直接给 PRF 索引；x0 特殊处理
  （ready=1，索引 0 恒零）；
- 反压：空闲列表/ROB 满时拉低前端推进。

### Step P3-3（2 天）：`rob.sv` + `commit.sv`

- ROB 表项：`valid, pc, rd, dest_preg, old_preg, is_store, lsq_id, done,
  exception`；指针式环形缓冲；
- 完成：收到 CDB/`complete` 置 `done`（带异常标记）；
- 提交（按序、每拍 1 条）：更新提交表、释放 `old_preg`、给乙发 `commit`
  （store 释放）、处理异常（P1 简化：非法指令提交时停）；
- **恢复**：分支失败/异常时，把提交表拷回重命名表、重建空闲列表，同时
  向取指发 redirect；这个恢复流程和你在模拟器里做 ROB 恢复是同一件事，
  但要**一个时钟沿内完成或明确停几拍**，写进注释和 interface 文档。

### Step P3-4（1 天）：`frontend_ooo.sv` 组装

- fetch → decode → rename → dispatch；接收 `cdb` 通知 ROB 完成；发 `commit`；
- `backend_ready` 语义升级为"ROB/空闲列表/发射队列任一满"；
- 分支预测失败的重定向和你 P2 的路径合并（现在冲刷的是 ROB 里分支之后的
  所有表项）。

### Step P3-5（1 天）：单元测试（`stub_exec.sv`）

- 写 `tools/unit/stub_exec.sv`：收 `dispatch`，按随机延迟回 `cdb`/`complete`，
  并可伪造异常；
- TB 覆盖：乱序完成但按序提交、ROB 满反压、分支失败后映射表/空闲列表
  一致（连续两次失败）、异常提交、x0 不分配、同拍完成与提交。

### Step P3-6（集成窗口 2 天）

- 逐边替换（先 `dispatch/cdb`，再 `complete/commit`）；
- 全量 + 压力 + `trace_diff` 逐条对拍；
- `make perf` ≥ 0.845、`make synth` ≤ 18000；tag `p3-stage2`。

---

## 5. P4：2 宽前端 + 调优（课程阶段 3）

### Step P4-1（2.5 天）：取指/重命名/提交加宽到 2

- I-Cache 每拍出 2 条（两个 bank 或按 2 字行取），取指单元处理跨行/重定向；
- `rename.sv` 双路：空闲列表一次分配 2 个、两张映射表双写，注意两路
  同时读同一旧映射、同时写同一目的寄存器的处理；
- ROB 双提交口：README 对齐、空闲列表一次回收 2 个、`commit` 一次发 2 条；
- 和乙把 `dispatch[2]`、`commit[2]`、`cdb` 条数的接口 v2 定好（只加宽，
  不加字段）。

### Step P4-2（1 天）：BPU 增强

- gshare（全局历史 XOR PC 索引）或 RAS（返回地址栈）；用 `perf` 里函数/
  循环多的用例测收益；准确率统计继续记录。

### Step P4-3（0.5 天）：前端侧面积/时序优化

- `make synth MODE=diagnose` 看你的模块（I-Cache tag/data、BTB、ROB、
  映射表、比较器）面积；关键路径过长时把"发射/唤醒相关比较"交给乙，
  前端重点切分取指与译码。

### Step P4-4（集成窗口 2 天）

- `make test` 全绿；`make perf` ≥ 1.0985；`make synth` ≤ 36000、频率
  ≥ 300（冲 400/500 加分）；
- 报告章节（你负责）：I-Cache/BPU 设计与准确率、重命名/ROB 结构与恢复、
  前端关键路径、前端相关参数扫描（发射宽度/ROB/BPU）；
- tag `p4-final`。

---

## 6. 每个阶段的固定动作

| 时点 | 动作 |
| --- | --- |
| 阶段开始 | 和乙对齐接口 → 更新 `docs/interface.md` → 更新各自 stub |
| 开发中 | 只在自己的 feature 分支；每个模块先在 `tools/unit` 过 TB |
| 合并前 | `tools/unit/run.sh` 全 PASS + `make test` 全量绿 |
| 集成窗口 | 逐边替换 → 小用例 → 全量 → perf/synth → tag → 更新 `docs/perf-log.md` |
| 阶段结束 | 写半页 `docs/journal-甲.md`；和乙对一次人日账（`division.md` §6） |

**常用命令**：

```sh
tools/unit/run.sh decoder                                 # W1 的 TB
make test Case=correctness_add_to_100 MAX_CYCLES=200000000
make test MAX_CYCLES=200000000 SIM="$PWD/build/sim"       # 跳过重编译
make perf MAX_CYCLES=200000000 SIM="$PWD/build/sim"
make synth MODE=diagnose                                  # 看你的模块面积
make synth MODE=opt
git tag p1-pipeline && git push origin p1-pipeline
```

---

## 7. 坑清单（前端/提交线专属）

1. **I-Cache 吞吐**：不改流水线的话命中只有 0.5 条/拍，IPC 卡在 0.5；
   这是 P1 第一优先级。
2. **redirect 时序**：定义"同拍有效、下一拍 PC 切换"；`redirect` 必须
   优先于 `stall` 和顺序推进（W2 已测）。
3. **冲刷边界**：分支在 EX 时，IF 和 ID 里各有一条年轻指令；你清 IF/ID，
   乙清 ID/EX，别两不管。写进 `docs/interface.md`。
4. **x0 特判**：重命名时 x0 不分配物理寄存器、永远 ready、值恒 0；
   忘记会让空闲列表错乱。
5. **恢复一致性**：RAT/空闲列表/ROB 三者必须同步恢复；连续两次分支失败
   是最好用的一致性测试。
6. **ROB 满反压**：满信号必须传回前端并**保持**，不能丢一拍；否则覆盖
   未提交表项。
7. **组合逻辑默认值**：`always_comb` 开头给所有输出默认值，防止综合出
   锁存器（Verilator 会报 LATCH）。
8. **`always_ff` 全部复位**：valid/busy/指针/计数器都要有 reset 分支。
9. **`$display` 只能在 `ifdef LOCAL_TRACE` 里**，否则 OJ 模式 stdout 被污染，
   `make test` 全 FAIL。
10. **Yosys 0.63 不支持 package/struct 端口**：接口用扁平总线 +
    `rv32_defs.sv`/`cpu_config.sv` 宏；`unique case` 必须有 `default`。
11. **本机路径含中文**：`make synth` 依赖 `tools/yosys-wrap.sh`（见
    `environment.md`），别把 `config.mk` 里那行删掉；`tools/` 新文件不要
    加进 `filelist.f`。
12. **不对着波形调**：先用 `trace_diff.py` 和 `LOCAL_TRACE` 日志；波形
    只看最后嫌疑段。
13. 时间紧时按 `division.md` §8 降级，**永远保住 19/19 和最近的 tag**。

---

## 8. 你的第一个月节奏（建议）

| 时间 | 你做什么 |
| --- | --- |
| 第 1 天 | 热身 0 + W1（decoder 单测跑通） |
| 第 2 天 | W2 pc_unit + 单测 |
| 第 3~4 天 | W3 bpu 原型 + 单测 |
| 第 5~6 天 | W4 `cpu_config.sv` + `docs/interface.md` + tag/分支 |
| 第 2~3 周 | P1 流水线 I-Cache + `frontend.sv` + 单测；周末集成窗口 |
| 第 4~5 周 | P2 BPU 接入 + 恢复 + 统计；集成窗口 |
| 第 6~8 周 | P3 rename/ROB/提交；集成窗口 |
| 第 9~11 周 | P4 2 宽前端/BPU 增强；报告；DDL 前留 1~2 周缓冲 |

> 第一周结束时你应该有：一个覆盖全部 RV32IM 编码的 decoder 单测、一个通过
> 随机对拍的 PC/重定向模块、一个可与 C++ 参考对拍的 BPU 原型，以及两人
> 签字的接口文档。**这四样东西会让后面每个阶段都快很多。**
