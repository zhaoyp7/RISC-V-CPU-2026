# 仓库代码全解：从你的 Tomasulo 模拟器到 RTL CPU

> 写作背景：你已经写过一个 C++ 的 Tomasulo RV32I 乱序模拟器
> （`RISCV_CPU-simulator`，模块有 IF_IS / decoder / RAT / ROB / RegFile /
> ArithRS / BranchRS / LSQ / ALU / BU / CDB / DMEM）。这份文档假设你的
> CPU 知识全部来自那个项目，用你已经熟悉的概念来解释本仓库的每一部分代码。
>
> 仓库版本：`main` 分支，框架 commit `54fc150` + 基线 commit `186d97c`。

---

## 0. 一句话认识这个仓库

这是《计算机系统》课程（CPU 2026）的 **RTL 硬件设计** 仓库。目标不是用 C++
"模拟"一个乱序 CPU，而是用 SystemVerilog **描述一个真实电路**，由 Verilator
仿真、由 Yosys 综合成 ASAP7 标准单元、由 OpenSTA 评估频率，最后按
**面积 / IPC / 频率** 三项指标评分。

三条铁律先记住：

1. **框架代码（`Makefile`、`scripts/`、`docs/`、`Dockerfile`、`packaging/`）
   是课程提供的，基本不用改**；你要写、要改的是 `verilog/` 下的 RTL。
2. 当前 `verilog/` 里的代码是一个**顺序执行（非流水线）基线**：同一时刻只有
   一条指令在飞，靠一个 4 状态 FSM 逐条走。它能跑通全部 19 个 correctness，
   但 `perf` 的 IPC 只有 0.138，频率只有 47 MHz，**远未达到课程性能要求**。
3. 你的 Tomasulo 经验对应的是**下一阶段**：RAT / ROB / 保留站 / LSQ / CDB
   在这个仓库里一个都还没有，这正是后续要加的结构。

---

## 1. 从 C++ 模拟器到 RTL：必须先建立的 6 个概念

你的模拟器是"软件顺序执行 + 手工模拟并行"；RTL 是"描述电路，工具帮你实现
并行"。以下概念贯穿整份代码。

### 1.1 时钟与触发器（比 `cycle++` 严格得多）

- 你的模拟器里，一个周期就是主循环的一次迭代，你按**固定顺序**调用各模块
  的 `update()`：先 fetch、再 issue、再 exec……
- 硬件里没有"调用顺序"。所有 `always_ff @(posedge clk)` 块在同一个时钟沿
  **同时**采样输入、**同时**更新输出。这等价于你 issue.pdf 里被要求做的
  "每个部件存新旧两份状态、用旧状态算新状态、时钟沿统一覆盖"。
- `always_ff` 里用非阻塞赋值 `<=`，语义是"右边的值在时钟沿统一读取旧值再
  写回"，不会出现 `a = b; b = a;` 的交换 bug——这正好就是"新旧状态"机制。
- 组合逻辑 `always_comb` 没有时钟，输入一变输出立刻跟着变；它是"当前状态
  的函数"，相当于你 C++ 里的 `eval()` 计算。

### 1.2 模块 = 电路，端口 = 导线

`module core(...)` 不是函数，而是**一块电路板**；端口是焊在上面的引脚。
`student_top` 里 `core`、`icache`、`axi_mem_if` 三个模块是真实并排的电路，
靠 `assign` 连线。一个模块的 `output` 接到另一个模块的 `input`，就像两块
芯片之间的飞线。

### 1.3 组合逻辑 vs 时序逻辑

| | 组合逻辑 (`always_comb`) | 时序逻辑 (`always_ff @(posedge clk)`) |
| --- | --- | --- |
| 类比 | 你 C++ 里的纯函数 / `eval()` | 你模拟器里"周期末更新状态" |
| 例子 | ALU 运算、译码、地址计算 | PC、FSM 状态、寄存器堆、SRAM |
| 综合结果 | 与非门网络 | 触发器（D 触发器） |
| 本仓库 | `decoder`、`alu`、`core` 里的数据通路 | FSM、`regfile`、SRAM |

**关键差异**：组合逻辑再长，也必须在一个时钟周期内"传播完毕"；决定电路
最高频率的就是最长的那条组合路径（关键路径）。当前设计频率只有 47 MHz，
就是因为在 `alu.sv` 里用行为级 `/` `%` 综合出了一个巨大的组合除法器。

### 1.4 同步 SRAM：读数据要等一个周期

`docs/sram.md` 里的 `sram_fakeram` 是同步单端口 SRAM：
本周期给地址，**下一个周期**数据才出来。这直接解释了 I-Cache 命中为什么要
2 个周期（发地址 1 拍 + 数据回来比对 1 拍）。这点和你的 `DMEM.h` 很像：
你当时也是"不能立刻拿到内存值，要等延迟返回"。

### 1.5 AXI4-Lite：带握手的内存总线

你的 DMEM 模拟了"10 周期延迟返回"。硬件里这个交互由 **AXI4-Lite 总线协议**
完成，核心是 5 个通道各自独立的 `valid/ready` 握手：
**双方在同一个时钟沿同时为高时，一次传输才算发生**。
这相当于"带 backpressure 的请求-响应接口"：CPU 不能假设内存马上答复。

### 1.6 仿真 / 综合 / 时序分析是三套工具

- **Verilator**：把 RTL 编译成 C++ 周期精确仿真器，用来跑测试、数周期。
- **Yosys + ABC**：把 RTL 映射成 ASAP7 标准单元（真实电路面积）。
- **OpenSTA**：对门级网表做静态时序分析，估算最高频率。
这三者对你的代码有不同约束，例如 SystemVerilog package 在 Verilator 能用
但 Yosys 0.63 不支持，所以 `rv32_defs.sv` 只能用 `` `define`` 宏。

---

## 2. 仓库地图与 git 历史

```
RISC-V-CPU-2026/
├── README-ZH.md / README-EN.md   # 课程说明 + 评分标准（README.md 是符号链接）
├── config.mk                     # 工具路径与运行参数（少量本地配置）
├── Makefile                      # 所有操作的统一入口
├── Dockerfile                    # 构建工具链镜像（可不管）
├── docs/
│   ├── axi4-lite.md              # 课程框架：AXI 协议与内存约定
│   ├── sram.md                   # 课程框架：片上 SRAM 用法
│   ├── baseline-plan.md          # 你的基线实施计划
│   └── report-stage1.md          # 你的第一阶段报告（成绩、面积、IPC 数据）
├── verilog/                      # ★ 你的设计（核心）
│   ├── filelist.f                # 源文件清单（顺序敏感）
│   ├── rv32_defs.sv              # 全局宏（必须排第一）
│   ├── student_top.sv            # 顶层：AXI 端口 + 三模块互连
│   ├── axi_mem_if.sv             # AXI4-Lite 主机适配器
│   ├── icache.sv                 # 直接映射 I-Cache
│   ├── core.sv                   # 顺序执行 FSM + 数据通路
│   ├── decoder.sv                # 译码 + 立即数 + 控制信号
│   ├── alu.sv                    # 算术/逻辑/比较/乘除
│   └── regfile.sv                # 32x32 架构寄存器堆
├── scripts/                      # 课程框架：构建、测试、综合脚本（勿改）
│   ├── build.py / toolchain.py   # Verilator 构建
│   ├── sim.cpp                   # 仿真 testbench：256MiB 内存 + AXI 从机
│   ├── run.py / testcase.py / oj_io.py  # 本地跑测试，协议与 OJ 一致
│   ├── synth.py / synth_report.py / timing.py / timing.tcl  # 综合与 STA
│   ├── fakeram.py + ram/sram_fakeram.sv  # FakeRAM 面积/时序模型
│   └── ...
├── testcases/                    # 官方测试用例（git submodule，当前未初始化！）
└── packaging/appimage/           # AppImage 工具链打包（可不管）
```

`git log` 只有两个提交，正好把"框架"和"你的代码"分开了：

- `54fc150 Initial CPU 2026 framework`：课程框架，27 个文件，一行 RTL 都没有
  （`filelist.f` 当时是空的占位）。
- `186d97c Add RV32IM single-cycle baseline core with I-cache`：你（在 AI 辅助下）
  写的 8 个 `verilog/*.sv` 源文件 + `docs/baseline-plan.md` + `docs/report-stage1.md`。

📌 **当前 `testcases/` 目录是空的**（submodule 未拉取）。本地跑 `make test`
之前需要：

```sh
git submodule update --init --recursive
```

如果 SSH 拉取失败，可先执行 `git submodule set-url testcases <HTTPS_URL>`。

---

## 3. 课程框架代码逐个说明

### 3.1 `Makefile` + `config.mk`：统一入口

Makefile 定义了 7 个目标，全部是"转发到 Python 脚本"：

| 命令 | 作用 | 对应你的模拟器工作流 |
| --- | --- | --- |
| `make` / `make code` | 编译 RTL 并把可执行仿真器复制为根目录 `code`（OJ 提交产物） | 相当于编译你的 simulator |
| `make build` | Verilator 把 `verilog/filelist.f` 编译成 `build/sim` | `cmake --build` |
| `make run PROGRAM=x.data EXPECTED=5050` | 跑单个程序，和期望值比较 | 手动喂 `.data` 跑一个 case |
| `make test` | 跑全部 `correctness_*` | 跑下发数据对拍 |
| `make perf` | 跑全部 `perf_*`，输出每条 IPC 和几何平均 | 统计时钟周期数 |
| `make synth [MODE=opt|diagnose]` | Yosys + ASAP7 综合、OpenSTA 计时 | 新东西：面积/频率评估 |
| `make clean` | 删除 `build/` 与 `code` | — |

`config.mk` 里的关键变量：`APPIMAGE`（课程工具包路径，放根目录即可自动使用）、
`MAX_CYCLES`（默认 1,000,000，跑 pi 这种大程序要调大）、`LATENCY`（内存响应
延迟，默认 10）、`WAVE`（导出 VCD 波形）、`LOG`（保存日志）。命令行赋值优先。

### 3.2 `scripts/build.py` + `scripts/toolchain.py`：编译流程

`build.py` 做的事：

1. `read_sources(filelist)` 读 `verilog/filelist.f`，解析出源文件列表；
2. 选择 Verilator：命令行 `VERILATOR` 覆盖 > AppImage 内置 > 系统 PATH；
3. 调用 Verilator：
   ```
   verilator --cc --exe --build --trace --assert -Wall --top-module student_top
             ... RTL 源文件 ... scripts/sim.cpp
   ```
   `--top-module student_top` 说明顶层只能是 `student_top`；
   `sim.cpp` 是 testbench（见下）。
4. 输出 `build/sim`。

`toolchain.py` 负责"如果需要就用 AppImage"：它会把整个 Python 进程重启到
AppImage 环境里（`enter_appimage`），使 `make build`/`make synth` 自动获得
Verilator 5.020、Yosys 0.63、OpenSTA、ASAP7 库。对 OJ 或手动装好工具链的
环境，它会自动退回系统工具。

### 3.3 `scripts/sim.cpp`：仿真 testbench + 外部内存 + OJ 协议（★重点）

这是**唯一不是 RTL、但直接决定你能否拿分**的文件。它做四件事：

**(1) 模拟 256 MiB 外部内存和 AXI4-Lite 从机。**
`struct Memory` 维护 `bytes[256MiB]` 和 5 个深度 16 的 FIFO（ar/aw/w/r/b）。
- 请求握手后下一周期进入服务，`due = cycle + latency`（默认 10 拍）后响应；
- `arready/awready/wready` 在队列未满时为 1，`rvalid/bvalid` 在数据到点时拉高；
- 读优先/写优先随机交替，模拟真实内存带宽竞争；
- 地址未对齐 → `rresp/bresp = SLVERR`；超范围 → `DECERR`。

**(2) 驱动时钟与复位。**
`tick()` 手动做 `clock=0 → eval → clock=1 → eval`，先跑 5 拍复位（`reset=1`），
再进主循环直到 `memory.done` 或达到周期上限。每个 tick 记两倍时间，所以
VCD 波形里一拍 = 两个时间单位。

**(3) 实现退出协议。**
程序最后向 `0x80000000` 写一个字且 `wstrb=4'hf` 时，`Memory::write` 不真正写
内存，而是标记 `exit`；当写响应 `bvalid && bready` 握手时，捕获 `WDATA` 作为
返回值、`done = true`、仿真结束。**注意这和你旧模拟器的退出协议完全不同**：
旧协议是执行到 `0x0ff00513`（`li a0,255`）时取 `a0` 低 8 位；
新协议是"向 MMIO 地址 store"。

**(4) 提供两种运行模式。**
- 本地模式：`sim IMAGE EXPECTED MAX_CYCLES LATENCY [WAVE]`，打印 `PASS/FAIL`；
- OJ 模式（无参数）：从 stdin 读 `CPU2026-OJ 1\n<max_cycles> <latency>\n<镜像文本>`，
  把返回值打印到 **stdout**，把 `CPU2026 cycles=N` 打印到 **stderr**。

⚠️ 因此 RTL 里**不能有 `$display`**：它会污染 OJ 模式的标准输出，导致
`compare_output` 判定失败（`report-stage1.md` 里记录过这个坑）。调试只能用
`make run ... LOG=run.log`（LOG 会把仿真输出落到文件，同时终端仍显示）。

`oj_io.py` / `testcase.py` 用与 OJ **完全相同的协议**生成输入并比对输出，所以
本地 `make test` 通过 ≈ OJ 通过。perf 的 IPC 计算方式在 `testcase.py:51`：
读 `testcases/perf_*/metrics.json` 里预先统计好的 `dynamic_instructions`，
除以仿真器 stderr 报告的周期数，最后对所有 perf 用例取几何平均。

### 3.4 综合与时序：`synth.py` / `fakeram.py` / `synth_report.py` / `timing.py` / `timing.tcl`

这一组是"把你的 RTL 变成真实电路指标"的流水线，你只需要知道输入输出：

1. `synth.py`：先用 Yosys 把 RTL 展开（elaborate），认识 `student_top`；
2. `fakeram.py`：扫描所有 `sram_fakeram` 实例，按 DEPTH/WIDTH 生成
   具体 SRAM 包装模块和 FakeRAM 的 `.lib`（面积按 0.0419904 µm²/bit 估算，
   时序按拟合公式），**SRAM 面积因此会计入总面积**；
3. Yosys `synth` + `abc` 把设计映射到 ASAP7 标准单元。`opt` 模式展平层次、
   跨模块优化；`diagnose` 模式保留层次，方便看每个模块占多少面积；
4. `timing.py` + `timing.tcl`：OpenSTA 读 `.lib` 和门级网表，先按
   `CLOCK_PERIOD_NS`（默认 2.0 ns）做约束，再用**二分搜索**找最小可行周期，
   `estimated_fmax_mhz = 1000 / 最小周期`；
5. `synth_report.py` 汇总 `report.txt` / `report.json` / `area.json` /
   `timing.json`，输出总面积（组合/时序/SRAM 分开）、估算频率、最差建立
   裕量（slack）和关键路径。

### 3.5 `Dockerfile` + `packaging/appimage/`

构建课程工具链镜像/AppImage 的维护脚本（Yosys 0.63、Verilator 5.020、
ASAP7 7.5T RVT TT 库、OpenSTA）。日常开发**不需要碰**：下载课程提供的
`cpu2026-tools-x86_64.AppImage` 放根目录即可。

### 3.6 `docs/axi4-lite.md` 与 `docs/sram.md`

两份必读协议文档：
- `axi4-lite.md`：5 通道定义、valid/ready 握手黄金法则、内存布局（256 MiB，
  未加载区域清零）、SLVERR/DECERR 触发条件、退出协议；
- `sram.md`：`sram_fakeram` 参数范围、端口、单端口同步读写语义
  （读数据下一拍有效、无全局复位、地址越界会 `$fatal`）。

### 3.7 `testcases/`（submodule）

每个用例通常有：`program.data`（十六进制文本机器码，仿真器的实际输入）、
`program.dump`（反汇编）、`.c` 源码、`expected.txt`（标准答案），perf 用例
还有 `metrics.json`（动态指令数）。`correctness_*` 用于正确性，
`perf_*` 用于 IPC。

---

## 4. 你的设计 `verilog/` 逐个文件精讲

先看模块连接关系：

```
                       student_top
     +--------------------------------------------------------------+
     |  fetch_req(valid,pc)              refill_req(valid,addr)      |
     |   +-----------+   fetch_inst   +--------------------------+  |
     |   |  icache   |<---------------|          core            |  |
     |   | 1024x32   |--------------->|  FETCH -> EXEC -> MEM    |  |
     |   +-----+-----+  fetch_resp    |        -> HALT           |  |
     |         | refill               +------------+-------------+  |
     |         |                                   | data_req     |
     |         v                                   v              |
     |      (mux: refill_valid ? refill_addr : data_addr)          |
     |                  +-------------+   AXI4-Lite (AR/R, AW/W/B)  |
     |                  | axi_mem_if  |<=========================>外部内存
     |                  +------+------+                            |
     |                         | resp_valid 广播给 icache 和 core   |
     +--------------------------------------------------------------+
```

### 4.1 `filelist.f`：源文件清单（顺序有讲究）

列出所有 RTL 文件，**路径相对 `verilog/`**。两条硬性规则：

1. `rv32_defs.sv` 必须放第一个。因为它只有 `` `define`` 宏，
   `build.py` / `synth.py` 按文件顺序预处理，宏对后面的文件生效。
2. 顶层模块必须叫 `student_top`。

当前顺序：`rv32_defs → alu → regfile → decoder → core → icache → axi_mem_if
→ student_top`（被依赖的放前面，其实 RTL 不要求，但宏文件必须第一）。

> 为什么不直接用 `include` 或 SystemVerilog package？见
> `report-stage1.md` §2.4：Yosys 0.63 不支持 package，而 Verilator 不搜索源
> 文件所在目录，无法 `include` 同目录头文件，所以只能"宏文件排第一"。

### 4.2 `rv32_defs.sv`：全局编码表

把五组编码集中定义成宏，避免 `decoder` 产生、`alu`/`core` 消费时对不上：

| 宏组 | 含义 | 类似你模拟器里的 |
| --- | --- | --- |
| `ALU_ADD..ALU_REMU`（5 bit） | 18 种 ALU 操作 | `ALU.h` 里的 op 枚举 / decoder 输出 |
| `A_REG/A_PC/A_ZERO` | ALU A 口来源：rs1 / PC / 0 | 操作数选择逻辑 |
| `B_REG/B_IMM` | ALU B 口来源：rs2 / 立即数 | 同上 |
| `WB_ALU/WB_MEM/WB_PC4` | 写回数据来源 | 你 CDB 上的结果来源选择 |
| `SZ_BYTE/SZ_HALF/SZ_WORD` | 访存宽度 | LSQ 里的访存类型 |

> 你模拟器里 decoder 每周期算出一组控制信号直接传给各单元；这里同一组
> 信号就是这些宏编码，走的是组合逻辑连线。

### 4.3 `student_top.sv`：顶层与"微型仲裁器"

职责只有三件：

1. **定义课程要求的 AXI4-Lite 端口**（名称、位宽、方向都不能改，OJ 靠它对接）。
2. **共享一个 AXI 引擎**：设计里只有一套 AXI 接口，I-Cache 回填读和 core 的
   数据读写都要用。`student_top.sv:82-87` 用一个 mux 选择地址来源：
   ```systemverilog
   assign mem_req_addr = refill_valid ? refill_addr : data_req_addr;
   ```
   之所以不需要真正的仲裁器：**同一时刻只可能有一个来源有效**——
   I-Cache 回填只在 core 的 `ST_FETCH` 状态发起，数据访存只在 `ST_MEM` 状态
   发起，二者互斥（见 `report-stage1.md` §2.2）。
3. **广播响应**：`mem_resp_valid/rdata` 同时接给 icache 和 core，谁在等谁采样。
   这可以类比成你模拟器里的 CDB（广播总线），只是现在只有一条指令在飞，
   不存在竞争。

> 这是理解"顺序单发射设计为什么简单"的关键：省掉了仲裁、消歧、端口冲突。

### 4.4 `axi_mem_if.sv`：AXI4-Lite 主机适配器

把复杂的 5 通道协议封装成 `req_valid/we/addr/wdata/wstrb → resp_valid/rdata`
的简单事务接口。内部是 5 状态 FSM（`axi_mem_if.sv:65-71`）：

| 状态 | 行为 |
| --- | --- |
| `ST_IDLE` | 等 `req_valid`，锁存地址/写数据/掩码 |
| `ST_RD_ADDR` | 拉高 `arvalid`，等 `arready` |
| `ST_RD_DATA` | 拉高 `rready`，等 `rvalid`；握手当拍 `resp_valid=1` |
| `ST_WR_ADDR` | 同时驱动 AW 和 W，用 `aw_done`/`w_done` 分别记录谁先握手 |
| `ST_WR_RESP` | 拉高 `bready`，等 `bvalid`；握手当拍 `resp_valid=1` |

设计纪律（`axi4-lite.md` §3 的黄金法则）：

- `arvalid/awvalid/wvalid` **只由状态驱动，绝不组合依赖 ready**（否则可能
  产生组合环或死锁）；
- 地址/数据在发出后保持不变直到握手完成；
- 一次只处理一笔事务，不需要并发乱序。

类比你的模拟器：这就是 `DMEM.h` 里"硬件延迟返回"接口的硬件化版本——把
"发出请求 → 等待 → 拿到数据/收到写确认"变成了有握手信号的 FSM。

### 4.5 `icache.sv`：直接映射 I-Cache（你的模拟器里没有的结构）

结构：1024 行（`INDEX_BITS=10`）、每行 1 个 32 位字 + 20 位 tag + 1 位 valid。

| 地址位 | 用途 |
| --- | --- |
| `pc[1:0]` | 字内偏移（固定为 0） |
| `pc[11:2]` | index，选 1024 行之一 |
| `pc[31:12]` | tag |

- data 数组（32 bit）与 tag 数组（20 bit）用 `sram_fakeram` 实现，
  同步读延迟 1 周期；
- `valid` 位是触发器阵列（`logic valid[1024]`），复位清零——因为 SRAM 没有
  复位值（`docs/sram.md` §3.5）；
- `ST_IDLE`：收到 `fetch_valid` 就把 index 发给两块 SRAM；
- `ST_LOOKUP`：下一拍比较 `valid[index] && tag_rdata == req_tag`：
  - **命中**：组合输出 `fetch_resp_valid` 和 `data_rdata`，回 IDLE；
  - **缺失**：拉高 `refill_valid` 走 AXI 读内存，进 `ST_REFILL`；
- `ST_REFILL`：等 `refill_resp_valid`，把数据写回 data SRAM、tag 写回 tag
  SRAM、置 valid，同时把返回的指令**旁路**给 core（省掉再读一次 SRAM 的一拍）。

命中路径 **2 拍**，缺失约 **2 + 10 拍**（AXI 延迟）。`report-stage1.md` §5.3
的数据：pi 从 5472 万周期降到 1732 万周期，加速 3.16 倍。这是你第一次见到
"Cache 不是必需逻辑，而是性能结构"。

### 4.6 `core.sv`：顺序执行内核（当前设计的灵魂）

这是你模拟器 `simulator.cpp` 主循环的"硬件版本"，但简单得多。内部有：

**(1) 4 状态 FSM（`core.sv:48`）**

| 状态 | 做什么 | 出口 |
| --- | --- | --- |
| `ST_FETCH` | 拉高 `fetch_valid`，等 `fetch_resp_valid`（与 icache 的 2 拍/回填配合） | 指令进 `instr_q`，转 `ST_EXEC` |
| `ST_EXEC` | 组合译码、读寄存器、算 ALU、算 `next_pc` | ALU/分支/跳转：写回并回 `ST_FETCH`；load/store：PC+4 转 `ST_MEM`；非法指令转 `ST_HALT` |
| `ST_MEM` | 发起读/写，等 `data_resp_valid` | load 写回 rd；退出 store 转 `ST_HALT`；其余回 `ST_FETCH` |
| `ST_HALT` | 停机 | — |

对比你的 Tomasulo 模拟器：你有 fetch / issue / exec / write-broadcast / commit
五个**并行**阶段，每条指令占用 ROB 一个槽位；这里所有阶段被压缩成串行的
状态跳转，**ROB/RAT/保留站/CDB 全部不存在**，因为同一时刻只有一条指令。

**(2) 分支与跳转（`core.sv:129-148`）**
分支条件直接看 `instr_q[14:12]`（funct3）做 6 种比较；`next_pc` 三选一：

```systemverilog
is_jalr              ? ((rdata1 + imm) & ~32'b1) :   // JALR 清最低位
(is_jal || br_taken) ? (pc + imm) :                   // JAL/JAL 型偏移
                       (pc + 32'd4);                  // 顺序
```

因为你模拟器学过：分支在 EXEC 拍就算出方向和目标，顺序设计里**不需要分支
预测、不需要冲刷/回滚**；而真实流水线/乱序 CPU 必须做分支预测，这正是
课程要求里 "实现分支预测并统计准确率" 的由来。

**(3) 访存打包与解包（`core.sv:150-189`）**
- 写：根据宽度把 `rs2` 放到正确的字节通道，生成 `wstrb`
  （`SB` 用 `4'b0001 << addr[1:0]`，`SH` 用 `4'b0011/1100`，`SW` 用 `4'hf`）；
- 读：用 `data_resp_rdata[8*addr[1:0] +: 8]` 选出字节/半字，再按
  `mem_unsigned` 决定零扩展还是符号扩展。
- 测试程序保证自然对齐，所以不需要处理跨字访存。

**(4) 写回（`core.sv:208-223`）**
写回信号是组合产生的，但真正写进 `regfile` 发生在时钟沿：

- `ST_EXEC` 且非 load/store/非法：`rf_we=1`，数据来自 ALU 或 `pc+4`（JAL/JALR）；
- `ST_MEM` 且 load 响应有效：`rf_we=1`，数据来自内存。

因为"写回在指令边界发生，且下一条指令要等几十个取指周期"，**天然没有 RAW
相关，不需要前递网络**——这是顺序实现的最大红利。

**(5) 退出协议（`core.sv:191-193`）**
```systemverilog
assign halt_store = is_store && (mem_addr == 32'h8000_0000) && (mem_wstrb == 4'hf);
```
它不特判、不走捷径，而是把这次 store 当普通写发给 AXI，等写响应后进
`ST_HALT`；仿真器在写响应握手瞬间结束仿真。**和旧模拟器的 `li a0,255`
协议完全不同，这是最容易踩的坑之一。**

### 4.7 `decoder.sv`：译码器（纯组合）

输入 32 位指令，输出：寄存器地址、`reg_we`、`wb_sel`、`alu_op`、
`a_sel/b_sel`、`imm`、`is_branch/is_jal/is_jalr/is_load/is_store`、
`mem_size`、`mem_unsigned`、`illegal`。

**立即数拼装（`decoder.sv:54-73`）** 是 RISC-V 译码最容易错的地方，五种
格式的位拼接务必和规范对照：

| 类型 | 指令 | 拼接 |
| --- | --- | --- |
| I | OP-IMM/LOAD/JALR | `instr[31:20]` 符号扩展 |
| S | STORE | `instr[31:25] \| instr[11:7]` 符号扩展 |
| B | BRANCH | `instr[31] \| instr[7] \| instr[30:25] \| instr[11:8] \| 0` |
| U | LUI/AUIPC | `instr[31:12] << 12` |
| J | JAL | `instr[31] \| instr[19:12] \| instr[20] \| instr[30:21] \| 0` |

**控制信号生成（`decoder.sv:76-214`）** 按 opcode 分派，要点：

- 一开始就把所有输出赋默认值，保证组合逻辑无锁存器（latch）；
- `illegal`：课程不要求的 `CSR*/FENCE/ECALL/EBREAK`、非法 funct3/funct7
  组合都会被标记，core 收到后停机以便定位问题；
- M 扩展靠 `funct7 == 7'b0000001` 识别，funct3 对应 8 条乘除指令；
- `SLTI/SLTIU` 复用 `ALU_SLT/ALU_SLTU`（立即数经 `b_sel` 进 ALU）。

对比你模拟器里的 `decoder.h`：概念几乎一模一样，只是输出从 C++ 结构体变成
了一束 wire；另外你当时可能把 `lui/auipc` 当成特化指令处理，这里统一成
"选择 A/B 操作数 + ALU_ADD"。

### 4.8 `alu.sv`：组合运算单元

覆盖 RV32I 全部整数运算 + M 扩展，全部在一个周期内组合完成。三个注意点：

**(1) 乘法高位** 要 64 位乘积：
```systemverilog
prod_ss = a_s * b_s;        // MULH   有符号 x 有符号
prod_su = a_s * b_u;        // MULHSU 有符号 x 无符号
prod_uu = {32'b0,a} * {32'b0,b};  // MULHU  无符号 x 无符号
y = prod_xx[63:32];
```
MUL 只取低 32 位，有无符号一致，直接 `a * b`。

**(2) 除法边界语义** 必须显式实现，不能依赖主机 `/` `%`（`alu.sv:47-60`）：
| 情况 | DIV | REM |
| --- | --- | --- |
| 除零 | -1 (`0xffffffff`) | 被除数 |
| `INT_MIN / -1` | `INT_MIN` | 0 |
| 正常 | 向零截断 | 同号于被除数 |

这正是 RISC-V 规范与 C++ 宿主行为不一致的地方（你在模拟器里应该处理过）。

**(3) 已知缺陷**：行为级 `/` `%` 在综合时会展开成一个**巨大的组合除法器**，
成为关键路径，把频率压到 47 MHz；也是面积大头（`report-stage1.md`：ALU
单独占 1794 µm²，约 33%）。后续必须换成**多周期串行除法器**（像你看过的
移位-相减除法），把路径切短。

### 4.9 `regfile.sv`：32x32 架构寄存器堆

- 两个组合读端口（`assign rdata = regs[raddr]`），一个同步写端口；
- `regs` 数组只存 x1..x31，x0 通过读端口旁路恒 0、写端口忽略；
- **注意**：这只是"架构寄存器堆"。你 Tomasulo 模拟器里的 RAT（逻辑寄存器
  → 物理寄存器）+ 物理寄存器堆在这里还不存在；顺序设计写回即生效，所以
  用不到。

### 4.10 各模块与你模拟器的对应总表

| 你的 C++ 模拟器 | 本仓库现状 | 差异说明 |
| --- | --- | --- |
| `simulator.cpp` 主循环 | `core.sv` FSM | 从"一周期并行调用所有模块"变成"逐状态串行推进" |
| `IF_IS.h`（取指+发射） | `core.sv` 的 `ST_FETCH` + `icache.sv` | 取指要等 2 拍/回填；没有发射队列，取到即执行 |
| `decoder.h` | `decoder.sv` | 概念相同，输出改为控制线束 |
| `ALU.h` | `alu.sv` | 组合 ALU；无多周期除法；无执行延迟建模 |
| `BU.h` | `core.sv` 分支比较逻辑 | 分支在 EXEC 组合判断 |
| `RegFile.h` | `regfile.sv` | 只有架构寄存器堆，无物理寄存器堆 |
| `RAT.h` | **不存在** | 顺序执行不需要重命名 |
| `ROB.h` | **不存在** | 顺序执行按程序序完成，天然按序提交 |
| `ArithRS.h` / `BranchRS.h` | **不存在** | 没有乱序发射 |
| `LSQ.h` | **不存在** | load/store 直接走 AXI；`core.sv` 的 `ST_MEM` 是雏形 |
| `CDB.h` | **不存在**（最接近的是 `student_top` 响应广播） | 单指令在飞，无广播需求 |
| `DMEM.h`（延迟返回） | `axi_mem_if.sv` + `sim.cpp` 内存从机 | 延迟由仿真从机 `--latency` 模拟 |
| `converter.h`/`utils.h` | `rv32_defs.sv` | 宏定义代替工具函数 |

一句话总结：**你已经写过的乱序结构，在硬件阶段要重新实现一遍，而且还要
面对时序、面积、握手这些软件模拟器里没有的约束。**

---

## 5. 一次完整执行的时序走查

以 I-Cache 命中为例，一条普通 ALU 指令经历 3 拍：

```
拍 1  ST_FETCH : core 拉高 fetch_valid/pc；icache ST_IDLE 接到请求，发 SRAM 读
拍 2  ST_FETCH : icache ST_LOOKUP，比较 tag 命中，组合输出 fetch_resp_valid/inst
      （时钟沿：core 采样指令进 instr_q，转 ST_EXEC）
拍 3  ST_EXEC  : decoder 组合译码；读 regfile；ALU 算出结果；next_pc 就绪
      （时钟沿：regfile 写入 rd；pc <= next_pc；回 ST_FETCH）
```

**load 指令**多一段：`ST_EXEC` 时 PC+4 并进 `ST_MEM`；`data_req_valid` 发出后
AXI 走 `ST_RD_ADDR → ST_RD_DATA`，10 拍后 `data_resp_valid` 回来，在该拍写
`rd` 并回 `ST_FETCH`。**store 到 `0x80000000`** 则在写响应握手时触发 `halt_store`，
core 进 `ST_HALT`，testbench 同时结束仿真。

**I-Cache 缺失**：`ST_LOOKUP` 发现 miss → `ST_REFILL` 向 AXI 发读请求 →
约 10 拍后数据回来，写 SRAM/tag/valid 并把指令直接旁路给 core。

---

## 6. 当前成果、课程要求与差距

**已达成**（`docs/report-stage1.md`）：
- 完整 RV32IM（含 M 扩展、全部 Load/Store）；19/19 correctness 通过；
- 面积 5444 µm²（组合 2565 / 时序 643 / SRAM 2236），满足阶段 1 的 9000 µm²；
- `correctness_pi` 加 I-Cache 后从 5472 万降到 1732 万周期。

**未达标**：
| 课程要求 | 现状 | 差距 |
| --- | --- | --- |
| 乱序执行 + 按序提交（ROB） | 顺序执行 | 需要重命名 + ROB + 发射队列 |
| 分支预测 + 准确率统计 | 无（顺序不需要） | 需要 BTB/BHT 等 |
| IPC ≥ 0.60（阶段 1） | **0.138** | 主因：数据访存无 Cache，每次 load/store 付 10 拍 |
| 频率 ≥ 300 MHz | **47 MHz** | 主因：行为级组合除法器 |
| 参数化（发射宽度/ROB/PRF/RS/Cache） | 仅 I-Cache 行数参数化 | 后续逐项参数化 |

---

## 7. 下一阶段的改造路线（正好用上你的 Tomasulo 经验）

按依赖顺序，建议这样演进：

1. **流水线化**：把 `core.sv` 的 FETCH/EXEC/MEM 拆成 IF/ID/EX/MEM/WB 五级，
   加前递网络解决 RAW；同时把 `alu.sv` 的 `/` `%` 换成多周期串行除法器。
   → 直接提高频率，并让 IPC 从"3 拍/指令"往 1 靠。
2. **D-Cache**：照抄/扩展 `icache.sv`，用 `sram_fakeram` 搭数据 Cache
   （写回或写直达 + 写分配，参数化容量/相联度）。这是 IPC 0.6 的关键。
3. **分支预测**：加 BTB + 2-bit 饱和计数器/BHT，统计预测准确率；预测失败
   冲刷流水线。
4. **乱序改造**：这一步就是你模拟器的硬件版——
   - RAT：逻辑寄存器 → 物理寄存器/ROB 槽位；
   - 物理寄存器堆（PRF）：替代/扩展 `regfile.sv`；
   - ROB：按序提交、异常恢复；
   - 发射队列/保留站（ArithRS/BranchRS 等）+ CDB 广播唤醒；
   - LSQ：load/store 乱序执行但按序访存、store-to-load forwarding。
5. **参数化**：发射宽度、ROB 深度、PRF 大小、RS 深度、Cache 配置全部做成
   `parameter`，跑敏感度分析写进报告。

每完成一步，用 `make test` 保正确性、`make perf` 看 IPC、`make synth
MODE=diagnose` 定位面积热点、`make synth MODE=opt` 拿最终指标。

---

## 8. 常用命令速查

```sh
git submodule update --init --recursive     # 第一次必须先拉测试用例

make build                                  # Verilator 编译 build/sim
make test                                   # 全部 correctness
make test Case=correctness_pi MAX_CYCLES=200000000
make run PROGRAM=testcases/correctness_add_to_100/program.data EXPECTED=5050 WAVE=trace.vcd LOG=run.log
make perf                                   # IPC 表 + 几何平均
make synth MODE=diagnose                    # 各模块面积定位
make synth MODE=opt                         # 最终面积/频率
make                                        # 生成 OJ 提交产物 ./code
```

调试原则（课程明确建议）：**不要对着波形调，打印日志比波形强**；但 RTL 里
不能留 `$display`（会污染 OJ stdout），用 `make run ... LOG=run.log`。

---

## 9. 术语对照速查

| 硬件/RTL 术语 | 你熟悉的等价概念 |
| --- | --- |
| `always_ff @(posedge clk)` | 周期末统一 `commit/update` 所有模块状态 |
| `always_comb` | `eval()`：输入的纯函数 |
| `<=` 非阻塞赋值 | 先算 `new_state` 再统一覆盖，天然满足旧/新状态 |
| `valid/ready` 握手 | 请求-响应"双方同意才算成功" |
| 组合逻辑关键路径 | 决定了时钟周期（频率）的最长计算链 |
| 综合 | 把行为描述摊成真实门电路，得到面积/频率 |
| I-Cache / D-Cache | 你模拟器里一直"零延迟"的指令/数据内存的缓存 |
| SRAM 同步读 | `DMEM.h` 的延迟返回，只是延迟固定为 1 拍 |
| AXI4-Lite | 你模拟器里内存接口的工业协议版本 |
| ROB/RAT/RS/CDB/LSQ | 你已经实现过、硬件里即将重写的结构 |
