# 两人分工方案（参数化乱序 CPU · v2）

> **前提**：甲、乙两人水平相近，都完整写过 C++ Tomasulo RV32I 模拟器
> （`RISCV_CPU-simulator`：IF_IS / decoder / RAT / ROB / RegFile / ArithRS /
> BranchRS / LSQ / ALU / BU / CDB / DMEM），但都没有 RTL/硬件经验。
>
> **修正说明（v2）**：重读 README-ZH「微架构要求」后，本方案的阶段划分修正为
> **乱序执行 + 按序提交 + 参数化（发射宽度/ROB/PRF/保留站深度/Cache 容量与
> 相联度）+ 分支预测从第一次集成起就是底线**。旧版里"P1 先做顺序流水线、
> P3 再乱序、P4 才多发射、最坏交顺序 CPU"全部作废；多发射 bundle 从 P0 起
> 数组化，每个阶段验收都跑 `ISSUE_WIDTH=1` 与 `2` 两档。
>
> **当前起点**：顺序基线（`docs/report-stage1.md`：IPC 0.138、约 47 MHz、
> 面积 5444 µm²）仅作为集成前 main 保活与调试参照；`divider.sv`（多周期）与
> `test/divider_test/` 已完成；环境见 `docs/environment.md`。
>
> **课程评分阶段**（性能门禁，功能要求无条件）：
> | 课程阶段 | 面积上限 | IPC 几何平均 | 频率 | 累计分 |
> | --- | ---: | ---: | ---: | ---: |
> | 阶段 1 | 9,000 µm² | 0.6000 | 300 MHz | 90 |
> | 阶段 2 | 18,000 µm² | 0.8450 | 300 MHz | 95 |
> | 阶段 3 | 36,000 µm² | 1.0985 | 300 MHz | 100 |

---

## 0. 核心机制：接口隔离 + 架构底线

### 0.1 五条协作机制

| 机制 | 做法 |
| --- | --- |
| **M1 接缝少而稳** | 两人之间只定义一组 **数组化 bundle**（第 2 节），其余都是内部实现 |
| **M2 文件单写者** | 每个 `.sv` 只有一个主人；改对方文件必须先提需求 |
| **M3 Stub 独立测试** | 每人给对方写桩模块；不依赖对方代码就能编译、跑单元测试 |
| **M4 逐边替换集成** | 先真前段+桩后段，再桩前段+真后段，最后全真；一次只换一边 |
| **M5 接口变更协议** | 改 `docs/interface.md` → 双方确认 → 同一次 commit 同步改两侧 stub+RTL |

### 0.2 三个不可降级的架构要求（README 原文）

1. **乱序执行 + 按序提交**（Tomasulo + ROB）：从 P1 第一次集成起就生效，
   不存在顺序交付版本；
2. **参数化**（五个点名参数，见 §0.3）：从 P0 落地，每个阶段用参数切换
   跑验收，P4 汇总敏感度矩阵；
3. **分支预测**：P1 就有 BTB + 2-bit BHT，P2/P3 升级 gshare/RAS。

其它底线：`main` 永远绿（`make test MAX_CYCLES=200000000`）；开发在 feature
分支；每阶段打 tag；`scripts/`、`Makefile`、`config.mk` 不改；`filelist.f`
只由甲维护。

### 0.3 参数化契约

| 参数 | 默认（bring-up） | 验收覆盖 | 归属 |
| --- | --- | --- | --- |
| `CPU_ISSUE_WIDTH` | 1 | 1 / 2（有余力 3） | 甲（接口）、乙（执行端口） |
| `CPU_ROB_DEPTH` | 32 | 32 / 64 / 128 | 甲 |
| `CPU_PRF_SIZE` | 64 | 64 / 96 / 128 | 乙（PRF）、甲（重命名） |
| `CPU_RS_DEPTH` | 8 | 8 / 16 / 32 | 乙 |
| `CPU_ICACHE_*` / `CPU_DCACHE_*` | 直接映射 | 1/2 路、不同容量/行宽 | 甲（I$）、乙（D$） |

`verilog/cpu_config.sv`（甲维护，`` `ifndef`` 保护）提供默认值；
`tools/config_gen.py` 按命令行重新生成它。**换参数 = 重新生成 + 重编译，
不允许改 RTL 源码。**

---

## 1. 人员分工总表

| | **甲：前端 & 提交线** | **乙：执行 & 存储线** |
| --- | --- | --- |
| 一句话 | 取指/预测/重命名，并把乱序执行的指令按程序序"确认掉" | 把收到的 uop 乱序执行完，并管理结果广播与访存状态 |
| 对应模拟器模块 | `IF_IS` + `decoder` + `RAT` + `ROB` + BPU | `RegFile(PRF)` + `ArithRS/BranchRS` + `ALU/BU` + `CDB` + `LSQ/DMEM` |
| 文件所有权 | `frontend_ooo.sv`、`if_stage.sv`、`icache.sv`、`bpu.sv`、`decoder.sv`、`rename.sv`、`rob.sv`、`commit.sv` | `backend_ooo.sv`、`alu.sv`、`divider.sv`（已完成）、`prf.sv`、`issue_queue.sv`、`cdb.sv`、`lsu.sv`、`lsq.sv`、`dcache.sv`、`mem_subsystem.sv`、`axi_mem_if.sv` |
| 共享文件 | `rv32_defs.sv`、`cpu_config.sv`（甲维护、乙确认）、`docs/interface.md`（共同）、`filelist.f`（甲） | 同左 |
| 常驻公共事务 | `tools/config_gen.py`（参数生成）、`filelist.f`、AI/决策记录 | 黄金模型与 `trace_diff.py`、综合热点与 perf 记录表 |

**为什么这样分**：甲拿"控制复杂度"（预测恢复、重命名、精确提交），乙拿
"数据通路复杂度"（唤醒选择、前递、访存消歧、Cache 时序）；两边都能靠 stub
独立推进。现有 `divider.sv` 已验证通过，乙可直接进入后端模块。

---

## 2. 接缝（Seams）：数组化的八条总线（P0 冻结）

所有 bundle 用**扁平总线 + `` `define`` 字段切片 + `[W-1:0]` 打包数组**
（Yosys 0.63 不支持 struct/package，见 `docs/report-stage1.md` §2.4）。
位宽由参数推导：`ROB_TAG_W = $clog2(CPU_ROB_DEPTH)`、
`PRF_IDX_W = $clog2(CPU_PRF_SIZE)`。

```
core.sv（薄封装，只连线）
 ├── frontend_ooo.sv（甲：icache/decoder/bpu/rename/rob/commit）
 │        ── dispatch[W] ──▶ backend_ooo.sv（乙：prf/iq/cdb/alu/divider/lsu/lsq）
 │        ◀── cdb[R] ──────
 │        ◀── complete[W] ──
 │        ── commit[W] ────▶（store 释放 / 物理寄存器释放）
 │        ◀── br_update ────（EX 分支解析结果，供 BPU 更新）
 │        ── squash ──────▶（丢弃错误路径的后端在飞 uop）
 │   if_refill 端口                    data_mem 端口
 └── mem_subsystem.sv（乙：axi_mem_if + 仲裁 + D-Cache）
```

| Bundle | 方向 | 字段 | 备注 |
| --- | --- | --- | --- |
| `dispatch[W]` | 甲→乙 | `valid, pc, inst, 控制位, imm, dest_tag, src1_tag, src1_ready, src2_tag, src2_ready, lsq_id, rob_idx` | 等价于你模拟器 rename→RS 的入队包 |
| `cdb[R]` | 乙→甲+乙内部 | `valid, tag, value, exception` | 广播唤醒 RS + 通知 ROB |
| `complete[W]` | 乙→甲 | `valid, tag, exception` | 与 cdb 可合并 |
| `commit[W]` | 甲→乙 | `valid, tag, is_store, lsq_id` | store 提交时写内存 |
| `br_update` | 乙→甲 | `valid, pc, taken, target, is_jalr, tag` | EX 解析结果；`tag` 供甲在 ROB 中精确定位 |
| `squash` | 甲→乙 | `valid, rob_idx` | 保留该序号及更老，丢弃更年轻的在飞 uop |
| `if_refill` | 甲→乙 | 请求 `valid, addr`；响应 `valid, rdata` | I-Cache 缺失回填 |
| `data_mem` | 乙→mem_subsystem | 请求 `valid, we, addr, wdata, wstrb`；响应 `valid, rdata` | load/store |

约定：x0 固定映射到零 tag、永远 ready；`W` 默认 1，P1 起验收跑 W=1/2；
`R`（CDB 条数）先 1，P2 视双发射结果决定是否升 2。

---

## 3. 文件所有权与红线（P0 一次性搭好）

| 文件 | 主人 | 说明 |
| --- | --- | --- |
| `student_top.sv` | 冻结（P0 后改动需双方同意） | AXI 端口 + 例化 `core` |
| `core.sv` | **轮值**（§6.2） | 薄封装：frontend + backend + mem_subsystem，只允许连线 |
| `rv32_defs.sv` / `cpu_config.sv` | 甲维护、乙确认 | 编码与参数 |
| `frontend_ooo.sv` 及子模块 | 甲 | 内部拆为 `if_stage/icache/decoder/bpu/rename/rob/commit` |
| `backend_ooo.sv` 及子模块 | 乙 | 内部拆为 `prf/issue_queue/cdb/alu/divider/lsu/lsq` |
| `mem_subsystem.sv` | 乙 | axi_mem_if + 仲裁 + D-Cache |
| `tools/unit/stub_*.sv`、`*_tb.cpp`、`test/` | 各自 | **绝不进 `filelist.f`** |
| `docs/interface.md` | 共同 | 每次接口变更走 M5 |

**红线**：不改对方文件；禁止层次引用；接口变更必须双确认；stub/TB 不进
`filelist.f`；不在 `main` 上直接开发。

---

## 4. 独立开发机制

### 4.1 Stub 清单（P1 起就要用，不再是后期工具）

- 乙写 `stub_front_ooo.sv`：按脚本发 `dispatch[W]`、收 `cdb/complete`、
  发 `commit`、可脚本化 `br_update`——供乙独立测 PRF/IQ/CDB/LSQ；
- 甲写 `stub_exec.sv`：收 `dispatch[W]`，随机延迟后回 `cdb[R]/complete[W]`，
  可伪造异常、可拒绝提交——供甲独立测 rename/ROB/恢复；
- 双方共用 `stub_mem.sv`（乙维护）：模拟 `mem_subsystem` 响应。

### 4.2 单元测试

`tools/unit/build.py --top <mod> --tb <file> --sources ...` 直接调用
Verilator（参考 `test/divider_test/run.sh`），支持 `-D` 参数覆盖：
每个测试至少覆盖复位、正常流、边界（满/空/停顿/冲刷/恢复/异常）。

### 4.3 逐边替换集成（每阶段 1 次）

1. 真前端 + `stub_exec`：验证取指/重命名/提交流；
2. `stub_front_ooo` + 真后端：验证发射/唤醒/执行/访存；
3. 全真 + `mem_subsystem`：小用例 → 全量；
4. `make perf` + `make synth`，记录数据，打 tag。

---

## 5. 阶段工作包（WP）

> 人日为估算值，用于对账。依赖栏"仅接口"= 开发期不需要对方代码。

### P0（约 1 周）：热身与地基

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A0.1 | 甲 | `decoder.sv` 穷举单测（控制位 + 立即数 + illegal） | 无 | 单测 | 1 |
| A0.2 | 甲 | `pc_unit.sv` + 单测（redirect > stall > advance） | 无 | 单测 | 1 |
| A0.3 | 甲 | `bpu.sv` 原型（BTB + 2-bit BHT，参数化） | 无 | 与 C++ 模型对拍 | 1.5 |
| A0.4 | 甲 | `cpu_config.sv` + `tools/config_gen.py` + `docs/interface.md`（§2 八条总线）+ tag/分支 | 无 | 双方 review | 2 |
| A0.5 | 甲 | `core.sv` 薄封装骨架（空壳可编译） | 仅接口 | `make build` | 0.5 |
| B0.1 | 乙 | `tools/unit/build.py` 单元测试脚手架 | 无 | 能编译任意模块 | 1 |
| B0.2 | 乙 | `divider.sv` 复验 + 接口固化（done 当拍结果有效） | 无 | `test/divider_test` | 0.5 |
| B0.3 | 乙 | `mem_subsystem.sv` v1（两客户、owner 路由） | 无 | 单测 | 1.5 |
| B0.4 | 乙 | 黄金解释器 + `trace_diff.py` | 无 | 对基线跑通 | 1.5 |
| B0.5 | 乙 | 参数与接口评审 | 无 | 双方签字 | 0.5 |
| 集成 | 双方 | 空壳对拍 + tag `p0-baseline` | — | `make build` | 0.5 |

### P1（约 3 周）：乱序核心 bring-up（没有顺序阶段）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A1.1 | 甲 | `icache.sv` 流水线化（每拍可接收 + W 条预留 + epoch 冲刷） | 无 | 吞吐/回填/重定向单测 | 2 |
| A1.2 | 甲 | `frontend_ooo.sv`：取指/译码/BPU/redirect | 仅接口 | `stub_exec` | 3 |
| A1.3 | 甲 | `rename.sv`（重命名表/提交表/空闲列表/x0/W 路规则） | 仅接口 | `stub_exec` | 3 |
| A1.4 | 甲 | `rob.sv` + `commit.sv`（按序提交、精确恢复、异常） | 仅接口 | 分支连错/异常单测 | 4 |
| A1.5 | 甲 | 乱序前端单测（含恢复一致性） | 仅接口 | 自己 | 2 |
| B1.1 | 乙 | `prf.sv`（参数 `CPU_PRF_SIZE`，2W 读口） | 无 | 单测 | 2 |
| B1.2 | 乙 | `issue_queue.sv`（参数深度，唤醒/选择/W 路发射） | 仅接口 | `stub_front_ooo` | 3.5 |
| B1.3 | 乙 | `cdb.sv`（先 1 条，仲裁 + 重试） | 无 | 单测 | 1.5 |
| B1.4 | 乙 | ALU/divider 接入执行端口 | 仅接口 | 单测 | 1.5 |
| B1.5 | 乙 | `lsu.sv`/`lsq.sv` v1（保守消歧，commit 释放 store） | 仅接口 | 单测 | 3.5 |
| B1.6 | 乙 | 乱序后端单测（死锁/满反压/乱序证据） | 仅接口 | 自己 | 2 |
| 集成 | 双方 | 逐边替换 + 小/中用例 + trace_diff + 综合冒烟 | — | `make test` | 4 |

**P1 验收**：OoO 版本在 main 全绿；**W=1 小/中用例全过、W=2 smoke 过**；
有乱序执行证据（后发独立指令先完成）；参数切换只改 `cpu_config.sv`；
tag `p1-ooo`。

### P2（约 2.5 周）：双发射全速 + D-Cache + 预测升级（课程阶段 1）

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A2.1 | 甲 | 2 宽取指/重命名/提交（映射表双写、空闲列表双分配） | 仅接口 | 成对提交/部分冲刷单测 | 5 |
| A2.2 | 甲 | BPU 升级（gshare）+ 统计 | 无 | 对拍 + 准确率 | 2.5 |
| A2.3 | 甲 | 性能实验与参数档记录（W=1/2 × ROB=32/64） | — | `docs/perf-log.md` | 1 |
| B2.1 | 乙 | 双路 select + 第二 ALU/执行端口 | 仅接口 | 单测 | 2.5 |
| B2.2 | 乙 | CDB 仲裁增强（可升 `R=2`） | 无 | 单测 | 1.5 |
| B2.3 | 乙 | `dcache.sv`（参数容量/相联度/行宽，写直达 + 写缓冲） | 无 | 迷你 AXI 从机对拍 | 4 |
| B2.4 | 乙 | `mem_subsystem` 仲裁升级 + 统计 | 仅接口（对甲不变） | 单测 | 1.5 |
| 集成 | 双方 | W=1/2 各跑全量 + perf + synth + tag | — | 见下 | 3 |

**P2 验收**：**W=1 与 W=2 都 19/19**；IPC ≥ 0.6；面积 ≤ 9000 µm²；
频率 ≥ 300 MHz；tag `p2-stage1`。

### P3（约 2.5 周）：性能到课程阶段 2

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A3.1 | 甲 | 恢复路径压力测试（连续 mispredict + ROB 满 + 异常） | 仅接口 | 压力用例 | 3 |
| A3.2 | 甲 | 宽度/ROB/PRF 按瓶颈调整 + BPU 提准确率（gshare/RAS） | 无 | 参数档 + 准确率 | 3 |
| A3.3 | 甲 | 前端参数扫描（W/ROB/BPU） | — | 数据入档 | 2 |
| B3.1 | 乙 | `lsq.sv` 完整版：乱序 load、地址消歧、store-to-load 转发 | 仅接口 | 单测 + 压力用例 | 4 |
| B3.2 | 乙 | 执行端口/乘法器流水化、访存端口扩展 | 仅接口 | 单测 | 2.5 |
| B3.3 | 乙 | D-Cache 参数化升级（2 路/行宽/写回） | 无 | 单测 + 综合 | 2 |
| B3.4 | 乙 | 后端参数扫描（PRF/RS/Cache） | — | 数据入档 | 1.5 |
| 集成 | 双方 | 全量 W=1/2 + perf + synth + tag | — | 见下 | 3 |

**P3 验收**：IPC ≥ 0.845；面积 ≤ 18000 µm²；频率 ≥ 300 MHz；
tag `p3-stage2`。

### P4（约 2.5 周）：课程阶段 3 + 参数汇总 + 报告

| WP | 主人 | 内容 | 依赖 | 独立验证 | 人日 |
| --- | --- | --- | --- | --- | ---: |
| A4.1 | 甲 | 继续加宽（W=3/更深 ROB/BPU 强化）满足 IPC | 仅接口 | 参数档 | 4 |
| A4.2 | 甲 | 参数敏感度矩阵（W/ROB/BPU 部分） | — | 数据表 | 2 |
| A4.3 | 甲 | 报告（取指/预测/重命名/ROB/恢复）+ CR + OJ | — | 完稿 | 4 |
| B4.1 | 乙 | 后端性能调优（端口/PRF/RS/Cache 容量）满足 IPC | 仅接口 | 参数档 | 4 |
| B4.2 | 乙 | 参数敏感度矩阵（PRF/RS/Cache/端口部分） | — | 数据表 | 2 |
| B4.3 | 乙 | 报告（PRF/IQ/CDB/LSQ/Cache/除法器）+ CR + OJ | — | 完稿 | 4 |
| 集成 | 双方 | 全量 + perf + synth + `make code` 复现 | — | 见下 | 2 |

**P4 验收**：IPC ≥ 1.0985；面积 ≤ 36000 µm²；频率 ≥ 300 MHz
（冲 400/500 加分）；报告完稿；tag `p4-final`。

---

## 6. 均分核算与轮值

### 6.1 人日核算（估算）

| 阶段 | 甲 | 乙 | 差值 |
| --- | ---: | ---: | ---: |
| P0 | 6 | 5 | +1（甲多） |
| P1 | 16 | 16 | 0 |
| P2 | 11.5 | 12 | +0.5（乙多） |
| P3 | 11 | 11.5 | +0.5（乙多） |
| P4 | 10 | 10 | 0 |
| **合计** | **54.5** | **54.5** | **0** |

补偿规则：某阶段差 > 1.5 人日时，多的一方把下一阶段的公共事务（`tools/`
脚本、perf 记录、黄金模型维护、报告章节、参数扫描配置）转给少的一方。

### 6.2 集成窗口与轮值

- 每阶段末尾 **1 次集成窗口（2~3 天）**；只有此时允许碰 `core.sv`（薄封装）；
- 主集成人轮值：P1 甲、P2 乙、P3 甲、P4 乙；另一人负责对拍与数据记录；
- 窗口流程：逐边替换 → 小用例 → 全量（W=1/2）→ perf/synth → tag →
  更新 `docs/interface.md` + `docs/perf-log.md`；
- 每阶段末各写半页 `docs/journal-*.md`，用于对账与 CR 证明贡献。

---

## 7. 公共工作与验收

- **性能记录** `docs/perf-log.md`：日期 / commit / 参数配置 / IPC / 面积 /
  频率；每个集成窗口 + 每组参数扫描一行。
- **参数敏感度**：每阶段都要记录本阶段相关参数的两档以上数据（不是 P4 才
  开始）；P4 汇总成矩阵。
- **验证命令**：

```sh
tools/config_gen.py --issue-width 2 --rob 64 --prf 96 --rs 16
make test MAX_CYCLES=200000000     # W=1/2 都要全绿
make perf MAX_CYCLES=200000000
make synth MODE=diagnose           # 面积热点
make synth MODE=opt                # 面积/频率门禁
make code                          # OJ 产物（干净环境复现）
```

---

## 8. 风险与降级（只降性能旋钮，不降架构）

| 风险 | 症状 | 对策 | 负责人 |
| --- | --- | --- | --- |
| 接口反复变更 | 两边来回改 bundle | M5；P0 一次定全八条总线，只允许加宽/加深 | 两人 |
| 集成地狱 | 集成窗口超时 | 逐边替换；stub 测试必须提前全绿 | 轮值集成人 |
| 频率塌方 | 唤醒/选择/转发路径长 | select 流水化；除法器多周期；diagnose 定位 | 乙 |
| 死锁 | ROB/RS/LSQ 满互相等待 | 满信号保持反压；压力用例 | 甲 |
| 恢复污染 | 预测错后状态被改坏 | 提交才写架构态；trace_diff 逐条比对 | 甲 |
| 面积超限 | 超阶段上限 | 缩 ROB/PRF/RS；Cache 先直接映射（参数保留） | 乙 |
| 进度落后 | 集成窗口一拖再拖 | 按下面顺序降"旋钮" | 两人 |

**降级顺序**（架构三项 OoO/按序提交/参数化 + BPU 永远不能删）：

1. 放弃频率加分（400/500），保 300 MHz；
2. Cache 相联度/行宽降到最小（参数保留，配置为直接映射）；
3. LSQ 消歧保守化（load 等更老 store 地址）、执行端口减到最少；
4. ROB/PRF/RS 缩到最小值（仍满足参数化）；
5. 最后手段：提交 `W=1` 运行的配置（**参数与 RTL 仍支持 W=2**），并保留
   所有 OoO/参数化/BPU 结构——绝不交顺序 CPU。

---

## 9. 一页速查

| 阶段 | 甲（前端/提交） | 乙（执行/存储） | 接缝 | 联合验收 |
| --- | --- | --- | --- | --- |
| P0 | decoder/pc_unit/BPU 原型 + 参数与接口冻结 | 测试脚手架 + divider 复验 + mem_subsystem v1 + 黄金模型 | interface.md（八条总线） | 双方签字、tag p0-baseline |
| P1 | I$ 流水线、rename、ROB/commit、恢复 | PRF、IQ、CDB、执行端口、LSQ v1 | dispatch/cdb/complete/commit | W=1 全过 + W=2 smoke、乱序证据 |
| P2 | 2 宽 rename/commit、gshare | 双路 select、第二 ALU、D$、仲裁 | 同上（W=2 生效） | 19/19 @W=1/2、IPC ≥ 0.6、≤ 9000 µm²、300 MHz |
| P3 | 恢复压力、BPU 准确率、参数扫描 | LSQ 完整、端口/乘法器、Cache 相联 | 同上 | IPC ≥ 0.845、≤ 18000 µm² |
| P4 | 加宽/ROB、参数矩阵、报告 | 后端调优、参数矩阵、报告 | 同上 | IPC ≥ 1.0985、≤ 36000 µm²、报告/CR |

**记住**：两人 90% 的时间只跟自己的 stub 和单元测试打交道；`core.sv` 只在
集成窗口连线；接口只允许"加宽/加深"，不允许改字段含义；**乱序、多发射、
参数化是全程底线，不是某个阶段的任务**。
