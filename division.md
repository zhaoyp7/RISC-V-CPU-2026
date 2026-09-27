# 两人分工方案（接口隔离版）

> **前提**：甲、乙两人水平相近，都完整写过 C++ Tomasulo RV32I 模拟器
> （`RISCV_CPU-simulator`：IF_IS / decoder / RAT / ROB / RegFile / ArithRS /
> BranchRS / LSQ / ALU / BU / CDB / DMEM），但都没有 RTL/硬件经验。
>
> **当前起点**：仓库里有一个通过全部 19 个 `correctness_*` 的**顺序基线**
> （`docs/report-stage1.md`：IPC 0.138、约 47 MHz、面积 5444 µm²）。
>
> **课程评分阶段**：
> | 课程阶段 | 面积上限 | IPC 几何平均 | 频率 | 累计分 |
> | --- | ---: | ---: | ---: | ---: |
> | 阶段 1 | 9,000 µm² | 0.6000 | 300 MHz | 90 |
> | 阶段 2 | 18,000 µm² | 0.8450 | 300 MHz | 95 |
> | 阶段 3 | 36,000 µm² | 1.0985 | 300 MHz | 100 |
>
> **配套阅读**：`explanation.md`、`docs/baseline-plan.md`、
> `docs/report-stage1.md`、`docs/axi4-lite.md`、`docs/sram.md`。

---

## 0. 本方案的核心：让两人几乎只依赖接口

要达到"大部分工作互不依赖、只需要约定接口"，靠五条机制，本文档全部围绕它们展开：

| 机制 | 做法 |
| --- | --- |
| **M1 接缝少而稳** | 两人之间只定义 **3~5 个 bundle**（见第 2 节），其余全部是各自的内部实现 |
| **M2 文件单写者** | 每个 `.sv` 只有一个主人；改对方的文件必须先提需求，不能直接动手 |
| **M3 Stub 独立测试** | 每人都给对方写一个"桩模块"，不依赖对方代码就能编译、跑自己的单元测试 |
| **M4 逐边替换集成** | 集成时先真实前段+桩后段，再真实后段，最后全真实；一次只换一边 |
| **M5 接口变更协议** | 接口任何改动都要：改 `docs/interface.md` → 双方确认 → 同一次 commit 同步改两侧 stub + RTL |

再加上两条底线：

- **`main` 永远绿**（`make test MAX_CYCLES=200000000` 全过）；开发在各自 feature 分支。
- **每个阶段打 tag 作为可交付回退点**，正确性（85 分）永远优先于性能（15 分）。

> ⚠️ `scripts/`、`Makefile`、`config.mk` 是课程框架，**不要修改**。自己的脚本放
> 新建的 `tools/` 目录。`verilog/filelist.f` 只由甲维护。

---

## 1. 人员分工总表

| | **甲：前端 & 提交线** | **乙：执行 & 存储线** |
| --- | --- | --- |
| 一句话 | 把正确的指令/微指令送到后端，并按程序序把它们"确认掉" | 把收到的微指令乱序执行完，并把结果和访存状态管理好 |
| 对应模拟器模块 | `IF_IS` + `decoder` + `RAT` + `ROB` + BPU | `RegFile(PRF)` + `ArithRS/BranchRS` + `ALU/BU` + `CDB` + `LSQ/DMEM` |
| 文件所有权（全程） | `frontend*.sv`、`if_stage.sv`、`decoder.sv`、`icache.sv`、`bpu.sv`、`rename.sv`、`rob.sv`、`commit.sv` | `backend*.sv`、`alu.sv`、`divider.sv`、`regfile.sv`→`prf.sv`、`issue_queue.sv`、`cdb.sv`、`lsu.sv`、`lsq.sv`、`dcache.sv`、`mem_subsystem.sv`、`axi_mem_if.sv` |
| 共享文件 | `rv32_defs.sv`、`cpu_config.sv`（甲维护、乙确认）；`docs/interface.md`（共同） | 同左 |
| 只读复用 | 乙可以实例化 `decoder.sv` 做测试，但**不改** | 甲可以实例化 `alu.sv` 做测试，但**不改** |
| 常驻公共事务 | `filelist.f`、`tools/` 脚本仓库、AI 交互与决策记录 | 黄金模型（C++ 对拍）、综合面积热点分析、perf 记录表 |

**为什么这样分**：甲拿"控制复杂度"（预测恢复、重命名、精确提交），乙拿
"数据通路复杂度"（唤醒选择、前递、访存消歧、Cache 时序）。两边都能独立推进，
且都能用自己的 stub 测。

---

## 2. 接缝（Seams）：两人之间只有这些东西

所有 bundle 都用**扁平总线 + `define 字段位置** 表示（不用 SystemVerilog
interface/struct，因为 Yosys 0.63 支持不佳，见 `docs/report-stage1.md` §2.4）。
每个字段的含义与位宽冻结在 `docs/interface.md`，P0 完成初稿。

### 2.1 P1（顺序流水线）的接缝

```
core.sv（薄封装，只连线）
 ├── frontend.sv（甲） ── fetch_packet ──▶ backend.sv（乙）
 │    内含 icache                  ◀──── backend_ready
 │     ◀───────────── redirect ───────────  （EX 分支解析）
 │   refill 端口                            data 端口
 └── mem_subsystem.sv（乙，内含 axi_mem_if）
```

| Bundle | 方向 | 字段（含 valid） | 产生/消费 |
| --- | --- | --- | --- |
| `fetch_packet` | 甲→乙 | `valid, pc[31:0], inst[31:0], 译码控制位 + rs1/rs2/rd/imm` | 前端送下一条已译码指令 |
| `backend_ready` | 乙→甲 | `ready`（反压，后端停顿/忙时拉低） | 乙控制取指节奏 |
| `redirect` | 乙→甲 | `valid, target_pc[31:0], flush` | EX 分支解析后冲刷错误路径 |
| `if_refill` | 甲→乙 | 请求：`valid, addr`；响应：`valid, rdata` | I-Cache 缺失走 mem_subsystem |
| `data_mem` | 乙→mem_subsystem | 请求：`valid, we, addr, wdata, wstrb`；响应：`valid, rdata` | load/store 访存 |

> 设计要点：**译码放在前端**（`decoder.sv` 甲所有），所以 P1→P3 的接缝可以
> 平滑升级成 P3 的 `dispatch`（P3 只是再挂上重命名 tag）。后端不需要自己的
> 第二份译码器。

### 2.2 P2 新增的接缝

| Bundle | 方向 | 字段 | 说明 |
| --- | --- | --- | --- |
| `br_update` | 乙→甲 | `valid, pc, taken, target, is_jalr` | EX 解析结果，供 BPU 更新 |
| `if_refill` / `data_mem` | 不变 | 不变 | mem_subsystem 内部从"互斥 mux"升级为带 D-Cache 和仲裁器，**接缝不变** |

### 2.3 P3（乱序）的接缝（Tomasulo 的经典四条总线）

```
frontend_ooo.sv（甲：fetch/decode/rename/ROB/commit/BPU）
     ── dispatch ─────────▶ backend_ooo.sv（乙：PRF/IssueQueue/CDB/ALU/divider/LSU/LSQ）
     ◀── cdb ──────────────
     ◀── complete ─────────
     ── commit ───────────▶（store 释放 / 物理寄存器释放通知）
```

| Bundle | 方向 | 字段 | 备注 |
| --- | --- | --- | --- |
| `dispatch` | 甲→乙 | `valid, pc, inst, 控制位, imm, dest_tag, src1_tag, src1_ready, src2_tag, src2_ready` | 等价于你模拟器 rename→RS 的入队包 |
| `cdb` | 乙→甲+乙内部 | `valid, tag, value, exception` | 广播同时唤醒 RS 和通知 ROB |
| `complete` | 乙→甲 | `valid, tag, exception` | 若 cdb 已带 exception 可合并 |
| `commit` | 甲→乙 | `valid, tag, is_store, lsq_id` | 通知 LSQ 把 store 写出去 |

位宽约定（P0 定）：`ROB_TAG_W = $clog2(ROB_DEPTH)`、
`PRF_IDX_W = $clog2(PRF_SIZE)`；x0 在重命名时固定映射到零 tag/零值，不占物理寄存器。

### 2.4 P4 的接缝：只加宽，不加线

`dispatch[2]`、`commit[2]`、`cdb[2]`（或按功能分两条）；字段不变。
**这是最关键的收益：P1→P4 接缝始终是同一组字段，只是位宽/条数变化，
接口变更成本极低。**

---

## 3. 文件所有权与骨架（P0 一次性搭好）

P0 把现有 `core.sv` 重构为**薄封装**，后面所有阶段两人都不需要再碰它：
封装里只允许 `assign` 连线和模块例化，**不允许任何逻辑**。

| 文件 | 主人 | 说明 |
| --- | --- | --- |
| `student_top.sv` | 冻结（P0 后再改需双方同意） | 只保留 AXI 端口 + 例化 core |
| `core.sv` | **轮值**（见第 6 节） | 薄封装：frontend + backend + mem_subsystem |
| `rv32_defs.sv` / `cpu_config.sv` | 甲维护、乙确认 | 编码与参数（ROB/PRF/RS 深度等） |
| `filelist.f` | 甲 | 新文件登记 |
| `frontend.sv` / `frontend_ooo.sv` | 甲 | 内部再分为 `if_stage/decoder/icache/bpu/rename/rob/commit` |
| `backend.sv` / `backend_ooo.sv` | 乙 | 内部再分为 `alu/divider/prf/issue_queue/cdb/lsu` |
| `mem_subsystem.sv` | 乙 | axi_mem_if + 仲裁 + D-Cache |
| `tools/unit/stub_*.sv` | 各自 | **绝不进 `filelist.f`**，只用于单元测试 |
| `tools/unit/*_tb.cpp` | 各自 | 每人维护自己模块的测试台 |

**红线（违反即回退）**：

1. 不改对方的文件；需要改动时在 `docs/interface.md` 或聊天里描述需求。
2. 禁止层次引用（如 `u_backend.some_signal`）；模块只见端口。
3. 接口变更必须走 M5 协议；禁止单方面改字段含义/位宽。
4. stub 与单元测试文件不得出现在 `verilog/filelist.f`（否则 OJ 综合会炸）。
5. 不在 `main` 上直接开发；合并前必须跑全量回归。

---

## 4. 独立开发机制：Stub + 单元测试 + 逐边集成

### 4.1 每人一套 stub

- 甲写 `stub_backend.sv`：接收 `fetch_packet`，永远 `ready`，分支按脚本返回
  `redirect`，转发 `if_refill`/`data_mem` 到 mem_subsystem。
- 乙写 `stub_frontend.sv`：按文件/内存里的指令序列产生 `fetch_packet`，
  可按脚本拉低 `backend_ready` 或产生分支让后端真实解析。
- 乙写 `stub_exec.sv`（P3 用）：接收 `dispatch`，自动在随机延迟后发 `cdb`+
  `complete`，用于甲独立测 ROB/重命名。
- 甲写 `stub_front_ooo.sv`（P3 用）：按脚本发 `dispatch`、收 `cdb/complete`、
  发 `commit`，用于乙独立测发射/唤醒/CDB。

### 4.2 单元测试怎么搭

`tools/unit/build.sh MODULE=frontend` 直接调用 Verilator（**不用 `scripts/`**）：

```sh
verilator --cc --exe --build --assert -Wall -Wno-fatal \
  --top-module frontend -Mdir build/unit/frontend \
  scripts/ram/sram_fakeram.sv verilog/rv32_defs.sv verilog/cpu_config.sv \
  verilog/icache.sv verilog/decoder.sv verilog/frontend.sv \
  tools/unit/stub_backend.sv tools/unit/frontend_tb.cpp \
  -CFLAGS -std=c++17 -o build/unit/frontend/tb
```

每个单元测试至少覆盖：复位行为、正常流、边界（满/空/停顿/冲刷/重定向）。

### 4.3 逐边替换的集成流程（每个阶段只做 1 次）

1. 真前段 + 桩后段：验证取指流/指令包正确；
2. 桩前段 + 真后段：验证执行/写回/访存正确；
3. 真前段 + 真后段 + 真 mem_subsystem：跑全量；
4. `make perf` + `make synth`，记录数据，打 tag。

任何一步失败，回到自己那一侧修，**不跨文件改对方代码**。

---

## 5. 阶段工作包（WP）：每人每阶段做什么

> 人日为估算值，用于检查均分；每个 WP 的依赖栏如果写"仅接口"，就表示
> 开发期不需要对方任何代码。

### P0：骨架与工具（约 3 天/人）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A0.1 | 甲 | 拆分 `core.sv` 为薄封装 + 空的 `frontend/backend/mem_subsystem` 壳；`cpu_config.sv`；tag `p0-baseline` | 无 | `make build` 通过 | 2 |
| A0.2 | 甲 | `docs/interface.md` 初稿（第 2 节全部 bundle） | 无 | 双方 review | 1 |
| B0.1 | 乙 | `tools/unit/build.sh` + Verilator 单元测试骨架 | 无 | 能编译空模块 | 1.5 |
| B0.2 | 乙 | 黄金模型：老 C++ 模拟器输出 `(pc, rd, wdata)` 提交轨迹 | 无 | 对基线跑通 | 1.5 |

### P1：顺序流水线 + 串行除法器（约 8 天/人）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A1.1 | 甲 | `frontend.sv`：PC、取指对 I-Cache 握手、IF/ID、`redirect`/冲刷、`backend_ready` 反压 | 仅接口 | stub_backend 单元测试：指令流与重定向 | 3 |
| A1.2 | 甲 | `decoder.sv` 适配流水线（控制位随指令走） | 无 | 译码单测（复用你写过的 decoder_test 思路） | 1 |
| A1.3 | 甲 | I-Cache 包进 frontend，refill 端口接 mem_subsystem | 仅接口 | 取指流单测 + miss 回填 | 1.5 |
| A1.4 | 甲 | 前端单元测试（含冲刷/停顿边界） | 仅接口 | 自己 | 1.5 |
| B1.1 | 乙 | `backend.sv`：ID/EX/MEM/WB、regfile、前递、load-use 停顿、分支解析产生 `redirect` | 仅接口 | stub_frontend 单测：喂指令查写回 | 4 |
| B1.2 | 乙 | `divider.sv`：移位-相减串行除法（约 34 拍），边界语义照抄 `alu.sv:47-60` | 无 | 单测：除零/`INT_MIN/-1`/随机对拍 | 2.5 |
| B1.3 | 乙 | `mem_subsystem.sv`：axi_mem_if + 互斥 mux（保持现有行为） | 无 | 单测：请求-响应 | 1 |
| B1.4 | 乙 | 后端单元测试（前递/停顿/分支边界） | 仅接口 | 自己 | 1 |
| 集成 | 双方 | 逐边替换 + 全量回归 + 综合 | — | `make test/perf/synth` | 1.5 |

**P1 验收**：`make test` 19/19；频率 ≥ 300 MHz；tag `p1-pipeline`。

### P2：D-Cache + 分支预测（约 8 天/人，对应课程阶段 1）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A2.1 | 甲 | `bpu.sv`：BTB + 2-bit BHT（gshare 有余力再上） | 无 | 用 C++ 参考模型随机分支流对拍 | 3.5 |
| A2.2 | 甲 | 预测接入前端 + 错误路径冲刷 + `br_update` 接收 | 仅接口 | stub_backend 单测 | 1.5 |
| A2.3 | 甲 | 分支统计（`ifdef LOCAL_TRACE` 打印，OJ 不打印） | 无 | 人工核对 | 1 |
| B2.1 | 乙 | `dcache.sv`：直接映射 + 写直达 + 写缓冲 | 无 | `tools/unit` 里接迷你 AXI 从机对拍 | 4 |
| B2.2 | 乙 | mem_subsystem 升级：I$/D$ 仲裁、写缓冲排空 | 仅接口（对甲不变） | 单测 | 1.5 |
| B2.3 | 乙 | Cache 命中率统计 + AXI 请求统计 | 无 | 人工核对 | 1 |
| 集成 | 双方 | 逐边替换 + 全量回归 + 性能实验（4 种配置对比） | — | `make test/perf/synth` | 1.5 |

**P2 验收**：IPC ≥ 0.6；面积 ≤ 9000 µm²；频率 ≥ 300 MHz；tag `p2-stage1`。

### P3：乱序核心（单发射，约 12 天/人，对应课程阶段 2）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A3.1 | 甲 | `rename.sv`：RAT + 空闲列表 + x0 特判 | 仅接口 | `stub_exec` 完成/乱序完成场景 | 3 |
| A3.2 | 甲 | `rob.sv` + `commit.sv`：分配/完成/按序提交/精确恢复 | 仅接口 | 分支连错 + 异常流单测 | 4 |
| A3.3 | 甲 | `frontend_ooo.sv` 组装 + `dispatch` 生成 + `cdb` 接收 | 仅接口 | stub_exec 单测 | 2 |
| A3.4 | 甲 | 前端乱序单元测试 | 仅接口 | 自己 | 2 |
| B3.1 | 乙 | `prf.sv`：物理寄存器堆（多读 1 写，x0 特判） | 无 | 单测 | 2 |
| B3.2 | 乙 | `issue_queue.sv` + 唤醒/选择（age 优先，选择可流水化） | 仅接口 | `stub_front_ooo` 乱序发射场景 | 3.5 |
| B3.3 | 乙 | `cdb.sv` 单总线广播仲裁 | 无 | 单测 | 1.5 |
| B3.4 | 乙 | `lsu.sv`/`lsq.sv` v1：地址就绪执行、保守消歧（load 等所有更老 store） | 仅接口（commit 释放） | 单测 | 3 |
| B3.5 | 乙 | 后端乱序单元测试（死锁/满反压/唤醒） | 仅接口 | 自己 | 2 |
| 集成 | 双方 | 逐边替换 + 压力用例 + 对拍 + 全量 + 综合 | — | `make test/perf/synth` | 2 |

**P3 验收**：IPC ≥ 0.845；面积 ≤ 18000 µm²；频率 ≥ 300 MHz；tag `p3-stage2`。

### P4：多发射 + LSQ 完整版 + 参数化 + 报告（约 13 天/人，对应课程阶段 3）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A4.1 | 甲 | 2 宽前端：取 2 条/拍（I-Cache 双 bank 或双字行）、双路 rename/commit | 接口 v2（数组化） | 单测：成对提交/部分冲刷 | 5 |
| A4.2 | 甲 | BPU 增强（gshare / RAS） | 无 | 对拍 | 2 |
| A4.3 | 甲 | 集成 + 综合时序/面积迭代（前端侧热点） | 轮值 | `make synth` | 2 |
| B4.1 | 乙 | 第二执行端口 + 发射队列双路 select + 第二 ALU | 接口 v2 | 单测 | 3 |
| B4.2 | 乙 | LSQ 完整版：地址消歧 + store-to-load 转发 | 仅接口 | 单测 + 压力用例 | 3.5 |
| B4.3 | 乙 | D-Cache 参数化（容量/相联度/行宽）+ 除法器流水化（若面积允许） | 无 | 单测 + 综合 | 2.5 |
| B4.4 | 乙 | 集成 + 综合时序/面积迭代（后端侧热点） | 轮值 | `make synth` | 2 |
| 共同 | 双方 | 参数扫描（见 §7）+ 报告 + CR 准备 | — | 数据表 | 4 |

**P4 验收**：IPC ≥ 1.0985；面积 ≤ 36000 µm²；频率 ≥ 300 MHz；报告完稿；
tag `p4-final`。

---

## 6. 均分核算与轮值机制

### 6.1 人日核算（估算）

| 阶段 | 甲 | 乙 | 差值 |
| --- | ---: | ---: | ---: |
| P0 | 3 | 3 | 0 |
| P1 | 8.5 | 10 | +1.5（乙多） |
| P2 | 7.5 | 8 | +0.5（乙多） |
| P3 | 13 | 14 | +1（乙多） |
| P4 | 13 | 15 | +2（乙多） |
| **合计** | **45** | **50** | **+5（乙多约 10%）** |

补偿规则（写进日程，强制执行）：

1. 每个阶段结束后对一次账；某阶段差 > 1.5 人日时，多的一方把**下一阶段
   的公共事务**（`tools/` 脚本、perf 记录表、黄金模型、报告章节、参数扫描
   配置）转给少的一方。
2. P2 的"性能实验"（4 种配置对比）与 P4 的"参数扫描"默认由甲主导执行、
   乙点评；P1/P3 综合热点分析由乙主导、甲点评。
3. 集成轮值：P1 甲当主集成人、P2 乙、P3 甲、P4 乙；主集成人负责在集成窗口
   里连 `core.sv` 的线（薄封装，改动很小），另一人负责跑对拍与记录。
4. 每阶段末两人各写半页 `docs/journal-*.md`：我做了什么、接口改了什么、
   下一步。既用于对账，也用于 CR 时证明个人贡献。

### 6.2 集成窗口

每个阶段只在末尾开 **1 次集成窗口（1.5~2 天）**，期间才允许碰 `core.sv`：
上午逐边替换（§4.3），下午全量回归 + perf + synth + 打 tag + 更新
`docs/interface.md`。其余时间两人各在自己的 feature 分支上工作。

---

## 7. 公共工作与验收

- **性能记录**（乙的黄金模型脚本 + 两人轮流填）：`docs/perf-log.md`
  五列 = 日期 / commit / 配置 / IPC / 面积 / 频率；每个集成窗口各一行。
- **参数敏感度实验**（P4，课程报告硬性要求）：
  {发射宽度 1/2} × {ROB 32/64/128} × {PRF 64/96} × {RS 8/16/32} ×
  {D-Cache 容量/相联度}；甲负责前端相关参数（宽度/ROB/BPU），乙负责后端
  相关参数（PRF/RS/Cache/除法器），结果合并成同一张表。
- **验证命令**（每个集成窗口都跑）：

```sh
make test MAX_CYCLES=200000000     # 正确性，main 必须全绿
make perf MAX_CYCLES=200000000     # IPC 几何平均
make synth MODE=diagnose           # 面积热点定位
make synth MODE=opt                # 最终面积/频率
make code                          # OJ 产物 ./code（提交前在干净环境验证）
```

---

## 8. 风险与降级

| 风险 | 症状 | 对策 | 负责人 |
| --- | --- | --- | --- |
| 接口反复变更 | 两边来回改 bundle | M5 协议；P0 一次把字段定全；P4 只加宽 | 两人 |
| 集成地狱 | 集成窗口超时 | 逐边替换；stub 单元测试必须提前全绿 | 轮值集成人 |
| 频率塌方 | 唤醒/发射选择路径过长 | 选择信号流水化；除法器多周期；diagnose 定位 | 乙 |
| 死锁 | ROB/RS/LSQ 满互相等待 | 满信号反压；压力用例；断言 | 甲 |
| 恢复污染 | 预测错后状态被改坏 | 只提交才写架构态；对拍工具逐条比对 | 甲 |
| 面积超限 | 超阶段上限 | 缩 ROB/PRF/RS；Cache 先直接映射；共享端口 | 乙 |
| 进度落后 | 集成窗口一拖再拖 | 按下表降级，保留正确性 | 两人 |

**降级顺序（从下往上砍，永远保住 tag 回退版本）**：

1. 放弃频率加分（400/500 MHz），保 300 MHz；
2. 放弃多发射（P4 的宽度 2），保单发射乱序（阶段 2 指标）；
3. 放弃 LSQ 高级消歧，load 等所有老 store；
4. 放弃动态分支预测，静态 + BTB；
5. 最坏：交付 P2 的顺序流水线 + D-Cache + 预测（正确性 85 分 + 阶段 1）。

---

## 9. 一页速查

| 阶段 | 甲（前端/提交） | 乙（执行/存储） | 接缝 | 联合验收 |
| --- | --- | --- | --- | --- |
| P0 | 薄封装骨架 + 接口初稿 | 单元测试设施 + 黄金模型 | interface.md v1 | 基线 tag、接口确认 |
| P1 | frontend（PC/译码/冲刷/反压） | backend（前递/停顿）+ 串行除法 + mem_subsystem | fetch_packet / redirect / ready / refill / data | 19/19 + 300 MHz |
| P2 | BPU + 恢复 + 统计 | D-Cache + 仲裁 + 写缓冲 | br_update | IPC ≥ 0.6、面积 ≤ 9000 |
| P3 | rename + ROB + 提交 + 恢复 | PRF + IQ + CDB + LSQ v1 | dispatch / cdb / complete / commit | IPC ≥ 0.845、面积 ≤ 18000 |
| P4 | 2 宽前端 + BPU 增强 | 双发射口 + LSQ 完整 + Cache 参数化 | 同 P3，数组化加宽 | IPC ≥ 1.0985、面积 ≤ 36000、报告 |

**记住**：两人 90% 的时间只跟自己的 stub 和单元测试打交道；`core.sv` 只在
集成窗口连线；接口字段只在 P0 和 P4 两次集中变更；每个 tag 都是可交付版本。
