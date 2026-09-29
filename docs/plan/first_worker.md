# 甲的工作手册（前端 & 提交线）

> **修正说明（v2，重读 README-ZH 后重写）**
>
> README-ZH「微架构要求」是无条件的：**乱序执行 + 按序提交 + 参数化**（发射
> 宽度 / ROB Depth / PRF Size / 保留站或发射队列深度 / Cache 容量与相联度）；
> 分支预测属于扣分项（未实现 → 60%+10%）。因此旧版 `docs/plan/first_worker.md` 里：
>
> 1. ~~P1 顺序流水线 → P3 乱序~~ → **OoO + 按序提交从第一次集成起就是唯一
>    架构**，没有"顺序阶段"；
> 2. ~~P4 才多发射~~ → `dispatch/commit` 等 bundle 从 P0 起按 `ISSUE_WIDTH`
>    **数组化**，P1 起的每个阶段验收跑 `ISSUE_WIDTH=1` 与 `2` 两档；
> 3. ~~参数化后置~~ → `cpu_config.sv` 从 P0 存在，每阶段记录敏感度；
> 4. ~~最坏交顺序 CPU~~ → 降级只降性能旋钮（宽度/深度/Cache），**不降架构**；
> 5. 分支预测从 P1 就接入（BTB + 2-bit BHT），P2/P3 再升级 gshare/RAS。
>
> 完整分工对象是乙（执行 & 存储线）；`docs/plan/division.md` 旧阶段划分冲突处以本文档
> 为准（division.md 待同步）。

---

## 0. 交付定义与参数化契约

最终交付：**参数化的乱序、多发射 RV32IM 处理器**，AXI4-Lite 顶层
`student_top`，按序提交 + 分支预测，可综合，面积/频率达标。

### 0.1 五个必须参数化到位的参数（README 点名）

| 参数（宏/parameter） | 默认（bring-up） | 验收至少覆盖 | 你这边的影响面 |
| --- | --- | --- | --- |
| `CPU_ISSUE_WIDTH` | 1 | 1 / 2（有余力 3） | 取指宽度、重命名、dispatch、ROB 提交、空闲列表 |
| `CPU_ROB_DEPTH` | 32 | 32 / 64 / 128 | ROB、tag 位宽、恢复成本 |
| `CPU_PRF_SIZE` | 64 | 64 / 96 / 128 | 重命名表、空闲列表（与乙的 PRF 对应） |
| `CPU_RS_DEPTH` | 8 | 8 / 16 / 32 | 只影响反压接口（乙实现） |
| `CPU_ICACHE_*` / `CPU_DCACHE_*` | 直接映射 | 1/2 路、不同行数 | I-Cache 参数化（D$ 归乙） |

### 0.2 现有资产（本仓库当前状态）

- `docs/environment.md`：环境已配好（AppImage + 本地 Verilator 回落，
  `tools/yosys-wrap.sh` 处理中文路径）。
- `verilog/decoder.sv`、`icache.sv`：你的文件；`icache.sv` 当前是 2 拍/条的
  串行 FSM，**必须改造成每拍可接收的流水线**（多发射要求每拍出 W 条）。
- `verilog/core.sv` 等：单周期顺序基线，仅用于集成前 main 保活与调试参照，
  **不是交付路线**。
- `verilog/divider.sv`：乙已完成（多周期，`test/divider_test` 通过）。
- `test/decoder_test/`：W1 已完成并推送（commit `8b910be`）；后续单测按
  `test/<module>_test/` 同样结构新建。
- `docs/interface.md`：待你起草（P0 W2），冻结前需双方 review。

### 0.3 三条自我保护原则

1. **不碰乙的文件**：`backend*.sv`、`alu.sv`、`divider.sv`、`prf.sv`、
   `issue_queue.sv`、`cdb.sv`、`lsu.sv`、`lsq.sv`、`dcache.sv`、
   `mem_subsystem.sv`、`axi_mem_if.sv`。
2. **不碰课程框架**：`scripts/`、`Makefile`、`config.mk`。
3. **stub / TB 不进 `filelist.f`**；`filelist.f` 由你维护，新文件登记后立刻
   `make build` 验证 main 保绿。

---

## 1. P0（约 1 周）：地基（接口优先）

顺序：**W1（已完成）→ W2 参数与接口 → W3 pc_unit → W4 bpu → W5 骨架收尾**。
理由：参数（所有模块的位宽来源）和八条总线是后续一切的契约；接口草案先发给
乙 review，review 期间并行做 W3/W4，避免 P1 返工。W5 需要双方签字后收尾。

### W1（1 天，已完成）`decoder.sv` 全量单测

- 已完成并推送：commit `8b910be`，测试在 `test/decoder_test/`
  （`decoder_tb.cpp` + `run.sh` + `README.md`；穷举 131,072 组编码 +
  立即数边界 + 20 万随机 + 3,112 条真实指令，`checked=334224 fails=0`）；
- 后续所有模块单测都按同样结构放在 `test/<module>_test/`。

### W2（1.5 天）参数化与接口冻结（先做）

**Step 1**：`verilog/cpu_config.sv`（放 `rv32_defs.sv` 之后），所有参数加
`` `ifndef`` 保护以便 `-D` 覆盖：

```systemverilog
`ifndef CPU_ISSUE_WIDTH
  `define CPU_ISSUE_WIDTH 1
`endif
`ifndef CPU_ROB_DEPTH
  `define CPU_ROB_DEPTH 32
`endif
// ... PRF / RS / ICACHE / DCACHE
```

**Step 2**：`tools/config_gen.py`（你维护）按命令行生成 `cpu_config.sv`，
让"换参数"= 重新生成 + 重编译，**不改任何 RTL**。

**Step 3**：`docs/interface.md` v1，全部 bundle **数组化**（用扁平总线 +
`` `define`` 字段切片，Yosys 0.63 不支持 struct/package）：
`dispatch[W]`、`commit[W]`、`cdb[R]`、`complete[W]`、`br_update`、
`squash`、`if_refill`、`data_mem`；位宽由参数推导
（`ROB_TAG_W = $clog2(CPU_ROB_DEPTH)`）。
同时把 W3/W4 要用的语义写清：

- `br_update`：EX 解析的真实方向/目标 + `tag`，每条分支/跳转都发（不只预测失败时）；
  甲据此更新 BPU，并用 `tag` 在 ROB 中定位该分支，与保存的预测比较，自行产生
  内部重定向（EX 拍末有效、下一拍 PC 已切换，优先级高于 stall/顺序推进）；
- 数组化字段的切片位置（`` `define``）与 x0 约定（零 tag、永远 ready）。

**Step 4**：把接口草案发给乙 review；按 M5 协议，冻结后任何改动都要
"改文档 → 双方确认 → 同一次 commit 同步两侧 stub/RTL"。

### W3（1 天）`pc_unit.sv`：PC 与重定向（接口冻结后做）

```systemverilog
module pc_unit (
  input  logic        clk, reset,
  input  logic        advance,        // 下游接收，pc <= pc+4
  input  logic        stall,
  input  logic        redirect_valid,
  input  logic [31:0] redirect_pc,
  output logic [31:0] pc
);
```

优先级 `redirect > stall > advance`（与 W2 文档一致）；单测在
`test/pc_unit_test/`，覆盖复位、连续推进、停顿、同拍 redirect、同拍
stall+redirect、`pc+4` 溢出、10 万拍随机对拍。这是多发射/乱序恢复的基础。

### W4（1.5 天）`bpu.sv` 原型（P1 就要用，不是 P2 彩蛋）

- BTB（直接映射 `{valid, tag, target}`）+ 2-bit BHT；参数
  `BTB_INDEX_BITS/BHT_INDEX_BITS`（默认值接入 `cpu_config.sv`）；
- 接口：`fetch_pc → predict_taken/predict_target`，`br_update`（来自乙的
  EX 解析，语义见 W2 冻结的 `docs/interface.md`）更新；同拍读写冲突要有旁路；
- 单测在 `test/bpu_test/`：用 C++ 参考模型对拍循环/交替分支流，记录准确率、
  冷启动与别名冲突表现；
- 目标 P1 就接上（先 BTB+BHT），P2/P3 升级 gshare/RAS。

### W5（0.5 天）骨架、签字与收尾

- `verilog/core.sv` 薄封装骨架（只例化 frontend/backend/mem_subsystem 并
  连线，空壳可编译，即 `docs/plan/division.md` 的 A0.5）；
- 和乙逐条 review `docs/interface.md`，双方签字冻结（M5）；
- 打 tag、开分支：

```sh
git tag p0-baseline && git push origin p0-baseline
git checkout -b p1-front
```

**P0 验收**：decoder 单测全过（已完成）；`cpu_config.sv` + `config_gen.py`
可用；接口文档双方签字；pc_unit/BPU 原型可独立仿真；空壳 `make build` 通过；
tag 已推。

---

## 2. P1（约 3 周）：乱序前端与按序提交 bring-up（没有顺序阶段）

目标：与乙的 OoO 后端拼成可跑程序的 OoO CPU。调试时 `ISSUE_WIDTH=1`，但
RTL 全部写成宽度通用；门禁要求 **W=1 全过、W=2 smoke 过**。

### Step P1-1（0.5 天）对齐接口

逐条确认：`dispatch[W]` 字段、`cdb[R]`、`complete[W]`、`commit[W]`、
`backend_ready` 语义（ROB/空闲列表/发射队列任一满）、恢复协议（甲前端内部冲刷 +
`dispatch.rob_idx` / `squash` 清理后端）；x0 不重命名、永远 ready。

### Step P1-2（2 天）改造 `icache.sv` 为流水线（关键）

- 2 级流水：每拍接收新 PC（stage A）→ 下一拍比较输出（stage B），
  命中吞吐 1 条/拍；为多发射预留每拍出 W 条（双 bank 或按块取）；
- 缺失暂停 + refill 回填旁路；重定向给在途请求打 epoch 标记并丢弃；
- 测试：连续取指吞吐、miss 回填、redirect 与在途请求冲突。

### Step P1-3（2 天）`frontend_ooo.sv`：取指/译码/预测

- `icache` + `pc_unit` + `decoder` + `bpu` 组装；
- `ISSUE_WIDTH` 组取指（先 W=1 调通，结构支持 W）；
- 预测失败/非预测跳转：收到乙的 `br_update` 后与保存的预测比较，自行冲刷前端，
  并向乙发 `squash(rob_idx)` 丢弃后端里的错误路径 uop；
- `backend_ready` 反压时保持状态。

### Step P1-4（2 天）`rename.sv`（RAT + 空闲列表）

- 重命名表（推测态）+ 提交表（架构态）；dispatch 最多 W 条；
- 每条分配 `dest_preg`，`old_preg` 存进 ROB，提交时释放；
- `src_ready`：映射项不在飞行中即就绪；x0 特判；
- 空闲列表/ROB 满反压前端。**W 条同拍分配/释放的重名与冲突规则要写清**
  （两条同时写同一目的寄存器、读同一旧映射）。

### Step P1-5（2 天）`rob.sv` + `commit.sv`（按序提交 + 精确恢复）

- ROB 表项：`valid, pc, rd, dest_preg, old_preg, is_store, lsq_id, done,
  exception`；每拍最多提交 W 条（W=1 时逐条）；
- 提交：更新提交表、释放 `old_preg`、向乙发 `commit`（store 在此时写内存）、
  非法指令提交时停机；
- **恢复**：分支失败时把提交表拷回重命名表、重建空闲列表、冲刷 ROB，并向乙发
  `squash` 清理后端在飞 uop；连续两次失败是最好用的一致性测试；
- 分支/跳转必须**收到 `br_update` 后才允许提交**（保证预测失败先于提交被检出，
  这是精确恢复的前提）；
- 接收乙的 `complete`/`cdb` 置 done。

### Step P1-6（1 天）单元测试（`stub_exec.sv`）

- 接收 `dispatch`/`squash`/`commit`（被冲刷的 uop 不再回应），随机延迟发
  `cdb`/`complete`、可伪造异常；按脚本拉低 `backend_ready` 测反压；覆盖乱序
  完成按序提交、ROB 满、分支失败恢复、异常、x0、W 条提交边界。

### Step P1-7（集成窗口 2 天，和乙一起）

- 逐边替换；先 5 个小用例（`add_to_100`、`expr`、`gcd`、`naive`、
  `manyarguments`），再扩大；
- W=1 全绿、W=2 smoke 全绿；`trace_diff.py` 对拍；
- `make synth` 能出结果；打 tag `p1-ooo`。

**P1 验收**：OoO 版本在 main 全绿；W=1 小/中用例全过、W=2 smoke 过；
参数切换只改 `cpu_config.sv`；能观察到乱序完成但寄存器结果按序正确。

---

## 3. P2（约 2.5 周）：双发射全速 + 预测升级（课程阶段 1）

目标：**IPC ≥ 0.6 + 面积 ≤ 9000 µm² + 频率 ≥ 300 MHz，W=1/2 全部 19/19**。

- **2 宽重命名/提交**：映射表双写、空闲列表一次分配/回收 2 个、
  两条同写同一目的寄存器的年龄处理；
- **取指 2 条/拍**：I-Cache 双 bank 或按 2 字块取，处理跨行/重定向；
- **BPU 升级**：BTB + 2-bit BHT → gshare（或局部历史）；
  接收乙的 `br_update`，预测错误时冲刷 ROB 中分支之后的表项；
- **统计**：分支数/失败数/类型（`ifdef LOCAL_TRACE`）；
- **集成窗口**：W=1 与 W=2 各跑全量 19/19 + perf + synth；
  `(W=1,2)×(ROB=32,64)` 敏感度数据入档；tag `p2-stage1`。

---

## 4. P3（约 2.5 周）：性能到课程阶段 2

目标：**IPC ≥ 0.845 + 面积 ≤ 18000 µm²**。

- 恢复路径压力测试（连续 mispredict、异常、ROB 满同时发生）；
- 提交宽度、ROB 深度、PRF 大小按瓶颈调整（参数扫描，不改 RTL）；
- BPU 继续提准确率（gshare/RAS，函数调用多的用例看收益）；
- 和乙的 LSQ 完整版联调：load 乱序执行后，分支恢复/异常时的访存一致性；
- 参数扫描：`W/ROB/PRF` 至少各两档；集成窗口 tag `p3-stage2`。

---

## 5. P4（约 2.5 周）：课程阶段 3 + 参数汇总 + 报告

目标：**IPC ≥ 1.0985 + 面积 ≤ 36000 µm² + 频率 ≥ 300（冲 400/500 加分）**。

- 按瓶颈加宽（W=3 / 更多执行端口 / 更深 ROB）或加高预测准确率；
- **参数敏感度汇总矩阵**（README 硬性要求）：你负责 `W/ROB/BPU` 部分，
  乙负责 `PRF/RS/Cache/端口`，合并成一张表；
- 报告章节（你）：取指与分支预测、重命名/ROB 结构与恢复、精确提交、
  前端关键路径与面积；整理设计决策与 AI 交互记录（CR 要查）；
- CR 准备：两人互讲对方模块；`make code` 在干净环境复现；tag `p4-final`。

---

## 6. 每个阶段的固定动作

| 时点 | 动作 |
| --- | --- |
| 阶段开始 | 对齐接口 → 更新 `docs/interface.md` → 更新 stub |
| 开发中 | 只在自己的 feature 分支；每模块先过 `test/<module>_test/run.sh`；参数改完先跑冒烟 |
| 合并前 | `test/*/run.sh` 全 PASS + `make test` 全绿（W=1/2） |
| 集成窗口 | 逐边替换 → 小用例 → 全量 → perf/synth → tag → 更新 `docs/perf-log.md` |
| 阶段结束 | `docs/journal-甲.md` 半页；和乙对人日账 |

常用命令：

```sh
tools/config_gen.py --issue-width 2 --rob 64 --prf 96 --rs 16
make build JOBS=8
make test MAX_CYCLES=200000000
make perf MAX_CYCLES=200000000 SIM="$PWD/build/sim"
make synth MODE=diagnose
make synth MODE=opt
git tag p1-ooo && git push origin p1-ooo
```

---

## 7. 坑清单（前端/提交专属）

1. **I-Cache 吞吐**：不改流水线每 2 拍才 1 条，多发射直接没戏；
2. **内部重定向时序**：由 `br_update` 与保存的预测比较产生；同拍有效、下一拍 PC 已切换；必须优先于 stall/顺序推进；
3. **冲刷边界**：EX 解析分支时 IF/ID 各有年轻指令；你清 IF/ID，乙清 ID/EX，
   写进接口文档；
4. **恢复一致性**：RAT/空闲列表/ROB 三者同步恢复；连续两次失败必测；
5. **x0**：不分配、不写、永远 ready；
6. **参数只改配置**：宽度数组用 `generate`，别手写复制；
7. **ROB 满反压**：满信号必须保持，不能脉冲式丢一拍；
8. **组合逻辑默认值** + **always_ff 全复位**（valid/busy/指针/计数器）；
9. **`$display` 只在 `ifdef LOCAL_TRACE`**，否则 OJ stdout 被污染；
10. **Yosys 0.63**：不支持 package/struct 端口，扁平总线 + 宏；
    `unique case` 建议带 default；
11. **本机路径含中文**：`make synth` 靠 `tools/yosys-wrap.sh`，别删
    `config.mk` 里那行；`test/`、`tools/` 不进 `filelist.f`；
12. **不要对着波形调**：先用 `trace_diff.py` + `LOCAL_TRACE` 日志。

---

## 8. 第一个月节奏

| 时间 | 你做什么 |
| --- | --- |
| 第 1 天 | W1 decoder 全量单测（已完成） |
| 第 2 天 | W2 cpu_config + config_gen；接口草案发乙 |
| 第 3 天 | W2 interface.md 定稿并发乙 review |
| 第 4 天 | W3 pc_unit + 单测 |
| 第 5~6 天 | W4 bpu 原型 + 单测 |
| 第 7 天 | W5 空壳 + 双方签字 + tag p0-baseline / 开 p1-front |
| 第 2~4 周 | P1：I-Cache 流水线、rename/ROB/commit、与乙集成（W=1 全过、W=2 smoke） |
| 第 5~7 周 | P2：双发射全速 + gshare；19/19 @W=1,2；阶段 1 指标 |
| 第 8~10 周 | P3：恢复压力 + 参数扫描；阶段 2 指标 |
| 第 11~13 周 | P4：阶段 3 + 报告；DDL 前留缓冲 |

> 记住：**每个阶段的验收都包含"W=1 与 W=2 都能跑"和"参数只改配置"**，
> 乱序/多发射/参数化不是某个阶段的任务，而是全程的底线。
