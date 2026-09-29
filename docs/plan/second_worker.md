# 乙的工作手册（执行 & 存储线）

> **修正说明（v2，重读 README-ZH 后重写）**
>
> README-ZH「微架构要求」是无条件的：**乱序执行 + 按序提交 + 参数化**（发射
> 宽度 / ROB Depth / PRF Size / 保留站或发射队列深度 / Cache 容量与相联度）；
> 「缺陷情况（未实现分支预测 / 主要功能缺陷）60%+10%」说明**分支预测**也必须
> 有。因此旧版 `docs/plan/second_worker.md` 里这些全部作废：
>
> 1. ~~P1 先做顺序流水线、P3 再乱序~~ → **OoO 从第一次集成起就是唯一架构**，
>    不存在"顺序版本"这一交付阶段；
> 2. ~~P4 才加多发射~~ → bundle 从 P0 起就按 `ISSUE_WIDTH` **数组化**，
>    P1 起每个阶段的验收都要跑 `ISSUE_WIDTH=1` 和 `2` 两档；
> 3. ~~参数化到后期再说~~ → 参数从 P0 落地，每阶段记录敏感度，P4 只是汇总；
> 4. ~~最坏交顺序 CPU~~ → 降级只降"性能旋钮"（宽度/深度/Cache 大小），
>    **不降架构**；
> 5. 分支预测同样是必需功能，从 P1 起就接入简单预测器，不能等到最后。
>
> 完整分工对象仍是甲（前端 & 提交线）；`docs/plan/division.md` 的旧阶段划分冲突处，
> **以本文档为准**（division.md 待同步）。

---

## 0. 交付定义与参数化契约

最终交付：**参数化的乱序、多发射 RV32IM 处理器**，AXI4-Lite 顶层 `student_top`，
按序提交、分支预测、可综合、面积/频率达标。

### 0.1 五个必须参数化到位的参数（README 点名）

| 参数（宏/parameter） | 默认（bring-up） | 验收至少覆盖 | 影响面 |
| --- | --- | --- | --- |
| `CPU_ISSUE_WIDTH` | 1 | 1 / 2（有余力 3） | 取指、重命名、dispatch、发射队列、提交、执行端口数 |
| `CPU_ROB_DEPTH` | 32 | 32 / 64 / 128 | ROB、tag 位宽、恢复成本 |
| `CPU_PRF_SIZE` | 64 | 64 / 96 / 128 | 物理寄存器堆、空闲列表、读口数 |
| `CPU_RS_DEPTH` | 8 | 8 / 16 / 32 | 发射队列、唤醒/选择、满反压 |
| `CPU_ICACHE_*` / `CPU_DCACHE_*`（容量/相联度/行宽） | 直接映射 | 1/2 路、不同行数 | 取指带宽、访存命中率、面积 |

实现约定：`verilog/cpu_config.sv`（甲维护）用 `` `define`` 提供默认值并加
`` `ifndef`` 保护，这样 Verilator 可以用 `-D` 覆盖；全量构建/综合用
`tools/config_gen.py --issue-width N --rob M --prf P --rs Q --dcache ...` 重新
生成 `cpu_config.sv`（不改 `scripts/`），再跑 `make build/test/perf/synth`。
**任何参数切换都不允许改 RTL 源码。**

### 0.2 现有资产（本仓库当前状态）

- `verilog/divider.sv`：多周期串行除法器，已通过 `test/divider_test/`
  （100k 随机 fails=0；有符号除零由 `alu.sv` 兜底）；接口 `start/busy/done`，
  **`done` 当拍商/余数有效**。
- `verilog/naive_divider.sv`：组合参考模型，**只用于对拍，不进 `filelist.f`**。
- `docs/environment.md`：环境已配好（AppImage + 本地 Verilator 回落，
  `tools/yosys-wrap.sh` 处理中文路径）。
- `verilog/core.sv` 等：单周期顺序基线，仅作为**集成前的 main 保活版本**与
  调试参照；不是交付路线。

### 0.3 三条自我保护原则

1. **不碰甲的文件**：`frontend*.sv`、`if_stage.sv`、`decoder.sv`、`icache.sv`、
   `bpu.sv`、`rename.sv`、`rob.sv`、`commit.sv`、`cpu_config.sv`、`filelist.f`。
2. **不碰课程框架**：`scripts/`、`Makefile`、`config.mk`。
3. **你的 stub / TB / 参考模型不进 `verilog/filelist.f`**。只有被
   `student_top` 真正例化的设计文件才登记（甲维护，你报文件名）。

---

## 1. P0（约 1 周）：热身地基（独立任务优先）

先做 W1/W2，找到手感，再和甲对齐接口。

### W1（1 天）单元测试脚手架 `tools/unit/build.py`

- 参考现成的 `test/divider_test/run.sh`：`verilator --cc --exe --build
  -Wall -Wno-fatal --top-module <mod> -Mdir build/... <sources> <tb.cpp>`；
- 支持 `-DCPU_ISSUE_WIDTH=...` 等宏透传，**所有 stubs 只在此编译，不进 filelist**；
- 目标：任意模块一条命令编译 + 运行（后续每个模块都靠它）。

### W2（0.5 天）`divider.sv` 收尾（已完成大部分）

- 用 `sh test/divider_test/run.sh` 复验（含 `--no-boundary` 语义）；
- 和甲确认 `alu.sv` 里 `b==0`、`INT_MIN/-1` 分支优先于 divider 结果；
- 把接口与时序（`start/busy/done`、done 当拍结果有效）写进 `docs/interface.md`；
- P1 例化后请甲登记进 `filelist.f`。

### W3（1 天）`mem_subsystem.sv` v1（两客户）

包住 `axi_mem_if`，对外提供 I-Cache 回填 + 数据访存两个客户口，锁存 owner、
响应按 owner 路由；P2 再加入 D-Cache 和真正的仲裁。接口冻结进
`docs/interface.md`（对甲保持 `if_refill` 字段不变）。

### W4（1.5 天）黄金模型 + 轨迹对拍

- `tools/golden/`：顺序 RV32IM 解释器（读 `.data`、新退出协议 store 到
  `0x80000000`），逐条输出提交轨迹 `%08x %0d %08x`；
- `tools/trace_diff.py`：比对黄金模型 vs RTL 的 `LOCAL_TRACE` 轨迹；
- 这是后面所有模块级/系统级调试的第一工具。

### W5（0.5 天）参数与接口评审

和甲逐条过 `docs/interface.md`：`dispatch[W]`、`commit[W]`、`cdb[R]`、
`complete`、`br_update` 的**数组宽度与位宽**；确认所有 tag/索引位宽由参数
推导（`ROB_TAG_W = $clog2(CPU_ROB_DEPTH)` 等）。

**P0 验收**：`tools/unit/build.py` 能用；divider 复验通过；mem_subsystem、
黄金模型可用；参数表与数组化接口双方签字；`git tag p0-baseline`。

---

## 2. P1（约 3 周）：OoO 后端 bring-up（没有顺序阶段）

目标：把**乱序执行后端**和甲的前端/提交拼成一台能跑程序的 OoO CPU，
参数化结构全部就位。bring-up 调试时把 `ISSUE_WIDTH` 设 1，但 RTL 用 generate
写成宽度通用；门禁要求 **W=1 全过、W=2 smoke 过**。

### Step P1-1（0.5 天）冻结四条总线（含数组化）

`docs/interface.md` 定死：`dispatch[W]`（uop + dest_tag + src tags/ready +
`lsq_id`）、`cdb[R]`（tag/value/exception）、`complete[W]`、`commit[W]`。
约定 x0 恒映射到零 tag、永远 ready。

### Step P1-2（1.5 天）`prf.sv`（参数 `CPU_PRF_SIZE`）

- `2*W` 个组合读口、`R` 个写口（CDB 写）；读口索引由 rename 给出的物理号；
- 写冲突/旁路规则写清；综合若读口 mux 太长，再加一拍"select→读"。

### Step P1-3（2 天）`issue_queue.sv`（参数 `CPU_RS_DEPTH`，按端口分布）

- 表项：`valid, busy1, tag1, busy2, tag2, uop, age`；
- 唤醒：所有 CDB 结果与 tag 比较清 busy；选择：每拍选 `W` 条最老的 ready；
- 发射时读 PRF 送执行单元；满时反压 dispatch；
- 除法器等非流水单元占用表项直到 `done`。

### Step P1-4（1 天）`cdb.sv`（参数 `CPU_CDB_NUM`，先 1 条）

- 来源：ALU（每拍 W 条）、除法 `done`、load 数据；单总线时按优先级仲裁，
  未获胜者锁存重试；
- 广播 tag+value 同时写 PRF、唤醒 IQ；异常经 `complete` 通知 ROB。

### Step P1-5（1.5 天）执行单元与 `lsu.sv`/`lsq.sv` v1

- ALU 复用现有 `alu.sv`（接 `divider.sv`）；W 路端口先各配一个 ALU；
- LSQ v1：dispatch 按序分配 `lsq_id`；地址就绪即可算；load 等所有更老 store
  地址已知（先保守），store 等 `commit` 释放后写 D-Cache；
- 访存走 `mem_subsystem`（此时可先无 D-Cache，直接走 AXI，P2 加）。

### Step P1-6（2 天）单元测试（`stub_front_ooo.sv`）

用甲的前端 stub 构造：长依赖链、乱序完成但按序提交、ROB/RS/LSQ 满反压、
除法长延迟、连续分支失败后恢复、x0。**必须有一条测试证明"确实乱序执行"**
（如后发的独立指令先完成），不是只看结果。

### Step P1-7（集成窗口 2 天，和甲一起）

- 逐边替换（前端 stub ↔ 真前端），全真后跑 `make test`：
  先 5 个小用例（`add_to_100`、`expr`、`gcd`、`naive`、`manyarguments`），
  再逐渐扩大；
- `make test MAX_CYCLES=200000000` 在 `ISSUE_WIDTH=1` 下全绿，`ISSUE_WIDTH=2`
  至少 smoke 用例全绿；
- 用 `trace_diff.py` 逐条对拍；`make synth` 能出面积（不要求达标）；
- 打 tag `p1-ooo`。

**P1 验收**：main 上 `core.sv` 已切成 OoO 版本且全绿；W=1 小/中用例全过、
W=2 smoke 过；参数只改 `cpu_config.sv`+重编译即可切换；有乱序执行证据。

---

## 3. P2（约 2.5 周）：多发射全速 + D-Cache（课程阶段 1）

目标：**W=2 全量正确性 + IPC ≥ 0.6 + 面积 ≤ 9000 µm² + 频率 ≥ 300 MHz**。

### Step P2-1（2 天）双发射打通

- IQ 每拍选 2 条（两条 age 最老 ready）；第二 ALU/分支单元；
- 读口冲突、同拍除法器竞争、双结果 CDB 仲裁（或把 `CPU_CDB_NUM` 提到 2）；
- rename/dispatch/commit 已是数组结构，这里只调参数 + 修时序。

### Step P2-2（2 天）`dcache.sv`（参数容量/相联度/行宽）

- 先直接映射 + 写直达 + 写缓冲，行宽参数化；load miss 回填；
- store→load 同地址旁路；缺失且写缓冲非空先排空（保守正确）；
- 命中率、AXI 事务数统计（`ifdef LOCAL_TRACE`）。

### Step P2-3（1 天）`mem_subsystem` 升级为仲裁器

I$ 回填 / D$ 读 / D$ 写缓冲三方仲裁、owner 路由；对甲的 `if_refill` 接口不变。

### Step P2-4（1 天）统计与联调

- 分支准确率（甲的）、Cache 命中率（你的）、stall 分解；填 `docs/perf-log.md`；
- 和甲联调预测失败 + D$ miss 同时发生的边界。

### Step P2-5（集成窗口 2 天）

```sh
tools/config_gen.py --issue-width 2 --rob 64 --prf 96 --rs 16
make test MAX_CYCLES=200000000        # 19/19，W=2
tools/config_gen.py --issue-width 1 --rob 64 --prf 96 --rs 16
make test MAX_CYCLES=200000000        # 19/19，W=1
make synth MODE=diagnose              # 面积热点
make synth MODE=opt                   # ≤ 9000 µm²，≥ 300 MHz
```

- 参数敏感度第一版：`(W=1,2) × (ROB=32,64)` 四组 perf 数据入档；
- 打 tag `p2-stage1`。

---

## 4. P3（约 2.5 周）：性能到课程阶段 2

目标：**IPC ≥ 0.845 + 面积 ≤ 18000 µm²**。

- **LSQ 完整版**：load 乱序执行（等更老 store 地址）、地址 CAM 消歧、
  store-to-load forwarding；
- **执行端口扩展**：按瓶颈加第二个访存端口/乘法器流水化；IQ 深度加大；
- **Cache 参数化升级**：2 路组相联、行宽 4 字、写回策略（若面积允许）；
- **参数扫描**：PRF/RS/Cache 三组至少各两档，记录 IPC/面积/频率；
- 集成窗口跑全量 W=1/W=2 + perf + synth，tag `p3-stage2`。

---

## 5. P4（约 2.5 周）：课程阶段 3 + 参数汇总 + 报告

目标：**IPC ≥ 1.0985 + 面积 ≤ 36000 µm² + 频率 ≥ 300（冲 400/500 加分）**。

- 根据 P3 瓶颈继续加宽（第三执行端口 / W=3）与加大 ROB/PRF/IQ；
- 参数敏感度**汇总矩阵**（README 硬性要求）：宽度、PRF、ROB、RS、Cache
  配置；你负责 PRF/RS/Cache/执行端口，甲负责 W/ROB/BPU，合并成一张表；
- 报告章节（你）：PRF/发射队列/唤醒/CDB 设计权衡、LSQ 与访存顺序、
  D-Cache 设计与参数影响、除法器多周期权衡、后端关键路径；
- CR 准备：两人互讲对方模块；整理 AI 交互与设计决策记录；
- 打 tag `p4-final`，`make code` 产物在干净环境复现。

---

## 6. 每个阶段的固定动作

| 时点 | 动作 |
| --- | --- |
| 阶段开始 | 对齐接口 → 更新 `docs/interface.md` → 更新 stub |
| 开发中 | 只在自己的 feature 分支；每模块先过 `tools/unit`；每改一个参数跑一次冒烟 |
| 合并前 | `tools/unit/run.sh` 全 PASS + `make test` 全绿（W=1/2） |
| 集成窗口 | 逐边替换 → 小用例 → 全量 → perf/synth → tag → 更新 `docs/perf-log.md` |
| 阶段结束 | `docs/journal-乙.md` 半页；和甲对人日账 |

常用命令：

```sh
tools/config_gen.py --issue-width 2 --rob 64 --prf 96 --rs 16
make build JOBS=8
make test MAX_CYCLES=200000000
make perf MAX_CYCLES=200000000 SIM="$PWD/build/sim"
make synth MODE=diagnose
make synth MODE=opt
sh test/divider_test/run.sh --quick
```

---

## 7. 坑清单（后端专属）

1. **参数只改配置不改 RTL**：数组宽度用 `generate`/循环，别手写 1 路再复制；
2. **唤醒/选择路径过长**：选择可流水化（select 拍 + 发射拍），别先优化再说；
3. **x0**：不分配物理寄存器、读恒 0、ready 恒 1；
4. **CDB 竞争**：未获胜结果必须锁存重试，不能丢；
5. **访存顺序**：store 只在 commit 释放后写内存；load 消歧先保守再激进；
6. **ROB/RS/LSQ 满**：反压必须保持，不能脉冲式丢一拍；
7. **参数切换后的位宽**：`$clog2` 推导 tag 宽度，注意 `PRF_SIZE`/`ROB_DEPTH`
   非 2 的幂时取整；
8. **`$display` 只在 `ifdef LOCAL_TRACE`**，否则污染 OJ stdout；
9. **Yosys 0.63 不支持 package/struct 端口**：扁平总线 + 宏；`unique case`
   建议带 default；
10. **本机路径含中文**：`make synth` 依赖 `tools/yosys-wrap.sh`，别删
    `config.mk` 里那行；`test/`、`tools/` 不进 `filelist.f`；
11. **不要对着波形调**：先 `trace_diff.py` + `LOCAL_TRACE` 日志。

---

## 8. 第一个月节奏

| 时间 | 你做什么 |
| --- | --- |
| 第 1 天 | W1 测试脚手架 + W2 divider 复验 |
| 第 2 天 | W3 mem_subsystem v1 |
| 第 3~4 天 | W4 黄金模型 + trace_diff |
| 第 5 天 | W5 参数与接口评审；P0 收尾 |
| 第 2~4 周 | P1：PRF/IQ/CDB/ALU/LSU + stub 测试 + 与甲集成（W=1 全过、W=2 smoke） |
| 第 5~7 周 | P2：双发射全速 + D-Cache + 仲裁；19/19 @W=1,2；阶段 1 指标 |
| 第 8~10 周 | P3：LSQ 完整 + 参数扫描；阶段 2 指标 |
| 第 11~13 周 | P4：阶段 3 + 报告；DDL 前留缓冲 |

> 记住：**每个阶段的验收都包含"W=1 与 W=2 都能跑"和"参数只改配置"**，
> 乱序/多发射/参数化不是某个阶段的任务，而是全程的底线。
