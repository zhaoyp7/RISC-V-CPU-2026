# Pipeline 重构计划

> 状态：设计草案，先不修改 RTL。
> 基线：`main`（含 complete FIFO 修复 `36e4302`），tag `p2-perf-prefill`。
> 目标：先到 100–150 MHz，再评估是否继续冲 300 MHz；全过程保持 W=1/W=2
> 功能全绿，IPC 不低于 0.60。

---

## 0. 先澄清：当前已经有流水线

当前设计不是“无流水线”，而是**粗粒度流水线**：

```text
PC/BPU → I$ s1 → I$ s2 → 响应/译码 FIFO → rename → ROB 分配
       → backend skid → IQ → PRF 读 + ALU/LSU → 结果缓冲 → CDB → ROB 提交
```

问题不是“没有寄存器”，而是**某些级之间的组合逻辑太长**。例如一个周期内可能同时完成：

- IQ 候选选择、最老 ready 选择、uop mux；
- PRF 4 个读口；
- ALU 32×32 乘法/分支比较；
- LSU 的 LSQ 地址消歧；
- CDB 4 源仲裁、2 lane 输出；
- PRF 写、IQ 唤醒、ROB 完成；
- ROB 32 项 tag 搜索和恢复掩码。

所以 `pipeline.md` 讨论的是：**如何把现有的长组合段继续切成更短的流水级**，而不是从零加流水线。

---

## 1. 当前基线

| 指标 | 数值 |
| --- | ---: |
| W=2 IPC | **0.6380** |
| W=1 IPC | **0.5688** |
| W=2 correctness | 19/19 PASS |
| W=1 correctness | 19/19 PASS |
| `run_all` | ALL PASS |
| opt 面积 | **24,468.759 µm²** |
| opt Fmax | **56.72 MHz** |
| opt 最小周期 | **17.6318 ns** |
| diagnose 面积/Fmax | ~25,134.9 µm² / 53.96 MHz |
| 当前关键路径 | `u_rob/squash_rob_idx → u_backend → u_lsu → u_cdb → u_iq` |

已做过的频率实验：

| 实验 | Fmax | IPC | 结论 |
| --- | ---: | ---: | --- |
| squash 两级化 | 54.99 MHz (+1.9%) | 0.6263 (-1.8%) | 不保留 |
| squash + LSU discard 寄存 | 56.10 MHz (+4.0%) | 0.6263 (-1.8%) | 不保留 |
| CDB 输出打一拍 | 55.68 MHz (+3.2%) | 0.6097 (-4.4%) | CDB 回滚，FIFO 修复保留 |

经验：**只切一段只会把关键路径起点往后挪，总延迟下降有限。必须按关键路径连续切多级。**

---

## 2. 目标与约束

### 2.1 阶段目标

| 阶段 | 目标频率 | 单级预算 | 说明 |
| --- | ---: | ---: | --- |
| Phase A | 100–150 MHz | 6.7–10 ns | 先证明流水化方向有效 |
| Phase B | 200–300 MHz | 3.3–5 ns | 需要更深的流水和更好的预测 |

300 MHz 对应 3.33 ns/级。当前 17.63 ns，需要沿关键路径至少切 **5–6 段**，不是一次改动。

### 2.2 硬约束

1. W=1 / W=2 correctness 都保持 19/19；
2. `sh test/run_all.sh` ALL PASS；
3. IPC 不低于 **0.60**；
4. 面积不明显恶化（目标不超过当前 opt 的 ~10%）；
5. 参数化保持：W/ROB/PRF/RS/LSQ/I$/BTB/BHT 仍可配置；
6. 每个实验单独分支，可回滚。

---

## 3. 当前流水级与组合段

### 3.1 前端

```text
pc_q / BPU 组合预测
    │
I$ s1：请求寄存器 → tag/data SRAM 读
    │
I$ s2：tag 比较、hit、响应
    │
请求 FIFO（rq，深度 4）
    │
译码 FIFO（fq，深度 8）+ decoder
    │
rename（RAT / free list / busy mask）
```

当前问题：

- BPU 查询、I$ tag 比较、`fetch_ready`、FIFO 空间判断之间有组合耦合；
- redirect/flush 要清 I$ 在途、rq、fq；
- `fetch_ready` 依赖 `s2_accept`、`buf_valid`、`pending_valid` 等。

### 3.2 rename / dispatch / ROB

```text
rename 组合：读 RAT、分配 free tag、更新 busy/free
    │
ROB 分配 + backend skid
    │
IQ / LSU 分配
```

当前问题：

- ROB 32 项 tag 搜索、`recover_rat` 重放、free/busy mask 在一个周期组合完成；
- `squash_rob_idx → backend rob_seq 查找 → seq 比较` 跨模块；
- `in_ready/backend_ready/ren_ready` 之间有 skid 解耦，但仍有组合依赖。

### 3.3 后端 issue / execute

```text
IQ select（8 项、2 lane）
    │
PRF 4 读口 + CDB 同拍 bypass
    │
ALU0 / ALU1 / divider / 分支比较 / LSU 地址生成与消歧
    │
结果缓冲 alu_valid_q / alu1_valid_q / div_valid_q / lsu result queue
```

当前问题：

- IQ select、PRF 读、ALU、LSU 查询在同一拍；
- CDB 同拍 bypass 使唤醒、读口、执行耦合；
- load 结果 → CDB → IQ 唤醒也在同一拍。

### 3.4 CDB / writeback

```text
ALU/load/div 结果源
    │
CDB 仲裁（4 源、2 lane，组合）
    │
PRF 写 / IQ 唤醒 / ROB 完成 / rename wake_mask
```

当前问题：

- 仲裁、广播、写回、唤醒都是一拍组合；
- 这是当前长路径的一部分。

### 3.5 LSU / LSQ

```text
地址生成
    │
LSQ 8 项地址消歧（老 store 地址未知/同地址/部分写）
    │
load 请求 / store complete / forwarding
    │
load 响应 → 结果队列 → CDB
```

当前问题：

- 8 项 LSQ 查询、forwarding、load issue 同拍；
- load 响应到 CDB 再到 IQ 也是一条长链；
- store drain / write response / commit 释放都在 LSQ 内组合。

---

## 4. 目标流水线草案

下面是 **Phase A（100–150 MHz）** 的草案；Phase B 可能继续拆分。

| 级 | 名称 | 主要逻辑 | 新增寄存器 | 风险 |
| --- | --- | --- | --- | --- |
| IF1 | PC/BPU | PC 选择、BPU 查询、redirect | PC、预测信息 | 预测错误恢复 |
| IF2 | I$ tag/data | SRAM 读、tag 比较 | tag/data、PC | 双 bank 配对 |
| IF3 | align/decode FIFO | hit 选择、对齐、FIFO 写 | 指令、预测 | FIFO 反压 |
| ID | rename | RAT 读、free list、busy | RAT/free/busy | 恢复一致性 |
| DIS | ROB/IQ/LSQ 分配 | ROB entry、IQ/LSQ alloc | entry/valid | 满反压 |
| IQ1 | select | 候选 mask、最老 ready | selected uop/idx | squash/replay |
| IQ2 | PRF read | 4 读口、操作数选择 | src1/src2 | 唤醒时序 |
| EX | execute | ALU、分支、AGU、div start | 结果、异常 | 乘法器延迟 |
| MEM | LSU/LSQ | 地址消歧、forwarding、内存请求 | load/store 元数据 | load 延迟 |
| WB1 | CDB select | 结果源选择、仲裁 | CDB winner | 源保持 |
| WB2 | CDB broadcast | PRF 写、IQ wake、ROB complete | 无/流水寄存器 | 同拍多写 |
| CM | commit | ROB 按序提交 | 架构状态 | 精确异常 |

说明：

- `IQ1/IQ2` 分开后，issue 到 execute 增加 1 拍；需要处理“选中后源才 ready”和“选中后被 squash”。
- `WB1/WB2` 分开后，load-use 和 ALU 依赖延迟增加 1 拍；需要更好的唤醒/旁路。
- `MEM` 级需要把 LSQ 消歧和内存请求拆开，load 结果可能多 1–2 拍。
- 分支恢复从 6–7 拍可能变成 9–12 拍，必须配合更好的 BPU。

---

## 5. 横切设计问题

### 5.1 valid/ready 与 skid

每一级都要有明确的 valid/ready；跨级反压要用 skid 或 FIFO，不能在组合路径上形成环。

### 5.2 唤醒与旁路

流水化后，CDB 唤醒和 PRF 读的时序会变化：

- 如果 IQ2 读 PRF 时源还没写回，需要 replay 或额外 bypass；
- 同拍 CDB 旁路可能消失，需要“前一拍 CDB 结果”旁路；
- 建议保留一个 **wakeup/replay** 机制，而不是强行全组合旁路。

### 5.3 squash / 精确恢复

每个流水级都要携带 `seq` 或 epoch：

- 分支解析后，按 seq 清年轻项；
- 已在 EX/MEM/WB 的年轻结果要丢弃；
- ROB 恢复快照要与 rename 的 free list/busy 一致；
- complete FIFO、load result queue、store queue 都要按 seq 清理。

### 5.4 分支预测

流水越深，误预测惩罚越大。建议：

- 先做带预测时 GHR 快照的 gshare；
- 加 RAS；
- 目标把 qsort/median 的误预测率从 17–22% 降下来；
- 否则频率提高会被 IPC 下降抵消。

### 5.5 LSU / 访存顺序

- LSQ 查询要跨流水级，需要保存 issue 时的地址/seq；
- store-to-load forwarding 要处理“store 数据晚到”；
- load 结果队列和 CDB 之间要有明确握手；
- 不要让 squash 清错已经提交的 store。

### 5.6 参数化

所有新流水级必须同时支持：

- W=1 / W=2；
- ROB 16/32/64；
- PRF 48/64/96；
- RS/LSQ 4/8/16；
- I$ 1KB/2KB per bank；
- BTB/BHT 不同容量。

---

## 6. 实施顺序（建议）

> 每步单独分支、单独 commit、单独测；不通过就回滚。

### Step 0：准备

- 本文档 review；
- 补充 `docs/experiments/freq-log.md`；
- 确认 `main` 全绿、opt 基线。

### Step 1：IQ1 / IQ2 分开

- 先只拆 IQ select 和 PRF read；
- 保留 EX 和 CDB 不变；
- 观察 Fmax 和 IPC。
- 已做的 WIP 实验见 `docs/plan/replay.md`：Fmax +29.8%，但会因
  load/store issue 死锁；正式实现必须先做 store 地址预填 + retain-entry
  IQ/replay。
- 2026-10-23 进展（`feat/freq-alupipe`）：先做了**只流水化非访存**的
  a0/a1 缓冲，load/store 保持 IQ→LSU 直连；C2 opt 55.47→72.73 MHz
  （+31.1%），面积 19.76k→20.31k（+2.8%），W2 IPC 0.6311→0.6084。
  该版本 W2/W1 19/19、`run_all` ALL PASS，但尚未合并；下一步是处理
  squash→ALU 结果捕获路径，或设计独立 MIQ。不要直接把 load/store 放入
  流水级。

2026-10-23 后续进展：非访存流水化已合入本地 `main`；进一步关闭两个
OoO ALU 中未使用的组合除法，diagnose 达到 19,777.0 µm² / 99.38 MHz，
opt **18,955.7 µm² / 115.80 MHz**，W2 IPC 保持 0.6084，W1/W2 19/19、
`run_all` ALL PASS。该改动没有增加流水拍数。关键路径已转为访存 issue/LSQ
消歧，应重新按报告排序后续实验，不机械沿用下面的旧步骤顺序。
详见 `docs/experiments/alu-no-comb-div.md`。

### Step 2：WB1 / WB2 分开

- CDB 仲裁与广播分开；
- 处理 wakeup/bypass；
- 这是之前 CDB 实验的“正确版本”，需要先有 FIFO 修复。

### Step 3：ROB recovery / checkpoint

- 先做 recovery 两级；
- 如果仍不够，再考虑 checkpoint；
- 与 rename 的 free list/busy 一起验证。

### Step 4：LSU / LSQ

- 地址生成、消歧、内存请求、响应分开；
- 保持 store-to-load forwarding 和 squash 正确。

### Step 5：I$ / BPU

- I$ 三级；
- 更早的 BPU 查询；
- fetch queue 加深。

### Step 6：ALU 乘法器

- 如果乘法器成为关键路径，再做 2 级流水；
- 不要在 recovery/LSU 路径没解决前先做。

---

## 7. 验收标准

每个实验必须同时满足：

1. W=2 19/19 PASS；
2. W=1 19/19 PASS；
3. `run_all` ALL PASS；
4. IPC ≥ 0.60；
5. diagnose Fmax 至少 +20%（相对当前 53.96 MHz）；
6. 关键路径确实换了一段，而不是只换起点；
7. 面积不明显恶化。

不满足：回滚，不叠加。

---

## 8. 验证矩阵

### 单元测试

- `issue_queue_test`
- `backend_test`
- `rob_test` W=1/W=2
- `rename_test` W=1/W=2
- `lsu_test`
- `lsq` 相关测试
- `frontend_test` W=1/W=2
- `icache_pipe_test`
- `bpu_test` / `bpu_gshare_test`
- `core_skeleton_test`

### 集成/压力

- W=1/W=2 19/19；
- 连续 mispredict + ROB 满；
- load-use + store-to-load forwarding；
- IQ/ROB/LSQ 满反压；
- squash 发生在 EX/MEM/WB 各级；
- 异常/非法指令；
- 参数矩阵：ROB16/32、PRF48/64、LSQ8/16、I$1KB/2KB。

### 性能/综合

```sh
make perf MAX_CYCLES=50000000
make synth MODE=diagnose
make synth MODE=opt        # 阶段节点再跑
```

---

## 9. 风险与停止条件

| 风险 | 应对 |
| --- | --- |
| IPC 掉到 0.60 以下 | 回滚该实验，先做分支预测 |
| 连续 2–3 次 Fmax 提升 <20% | 停止频率主线，转 P3 文档/交付 |
| squash/complete 竞态 | 先修正确性，再加流水 |
| 面积超 26k | 暂停流水，先做参数/结构面积优化 |
| 验证时间不够 | 只保留已验证的级，其他回滚 |

---

## 10. 待决策

1. Phase A 目标定 100 MHz 还是 150 MHz？
2. ROB recovery 用“重放”还是 checkpoint？
3. IQ1/IQ2 先做，还是 WB1/WB2 先做？
4. 是否保留双发射/双 I$，还是先降面积？
5. 时间盒：频率主线最多投入几天？
6. 是否在流水化前先做 gshare（降低分支惩罚）？

---

## 11. 与 P3/P4 的关系

- P3 是课程阶段 2 的性能目标（IPC 0.845、面积 18k、300 MHz）；
- 本文档是 P3 的**技术实现路径**，不是 P3 报告；
- P4 再汇总参数矩阵、报告和最终数据；
- 当前先做 pipeline 设计，不开始写 P3 报告。

## 12. 当前面积检查点与验证策略（2026-10-23）

`alu-shared-mul-20261023` 通过组合乘法共享，在 W2 IPC 0.6084 不变的情况下，
opt 达到 **17,895.8 µm² / 115.12 MHz**。W1/W2 各 19/19、`run_all` ALL PASS，
ALU 独立对拍 713,728 项通过。面积低于 18k 约 104.2 µm²，后续流水寄存器
和队列需考虑这一面积余量；目前仍未达到课程阶段 2。

用户要求避免频繁运行约半小时的 opt：小改动先做功能 / perf / diagnose，
积累到阶段检查点再运行 opt，同一时间只运行一项综合。本轮结束后不追加 opt。
下一步先分析 opt 的访存长路径和请求所有权，不直接开始 MIQ 或 LSU 流水化。

## 13. 频率优先阶段与隔拍唤醒（2026-10-23）

用户最新授权：为了尽快提高频率，可暂时放宽 IPC 和面积范围。因此本阶段
正确性仍是硬约束，IPC 0.60、18k 面积及此前的面积增幅限制不作为实验淘汰线；
所有代价必须记录，不能据此声称达到课程门槛。低频率运行 opt 的策略不变。

`feat/freq-registered-wake` / `freq-registered-wake-20261023` 切断同拍 CDB→IQ 选择和执行端
操作数旁路：diagnose 99.38→107.56 MHz（+8.2%），面积
18,603.442→18,542.177 µm²，W2 IPC 0.6084→0.5727，W1 IPC 0.5759→0.5471。
W1/W2 各 19/19、完整单测 ALL PASS。此候选未合入 main、未跑 opt。

新的主要组合段为 IQ 约 2.4 ns、LSQ 约 4.5 ns。下一轮可按报告拆分选择、
PRF 读或访存查询；在访存分级前必须先定义请求所有权、重试和 squash，
不能把被旧 store 阻塞的 load 留在唯一 lane0 缓冲里。保留 main `bc795ae`
及独立检查点作回滚，不追加零散 opt。

## 14. load 查询分级检查点（2026-10-23）

`feat/freq-load-query-pipe` / `freq-load-query-pipe-20261023` 基于隔拍唤醒，加入按 LSQ id
预留容量的待执行 load 表及查询寄存器。store 仍由 IQ 直填 LSQ，阻塞 load
留表重试，晚就绪老 load 不会被年轻请求挤占入口。

W1/W2 各 19/19、完整单测 ALL PASS；W2 / W1 IPC 0.5419 / 0.5205。
diagnose **19,706.842 µm² / 156.31 MHz**，相对 `819ddd1` Fmax +45.3%，
面积 +6.3%；未跑 opt，未合入 main。本轮已经超过 150 MHz 诊断目标。

第一条路径不再经过 IQ/PRF；LSQ 的匹配和最年轻 store 选择仍占约 4.6 ns。
下一阶段针对 LSQ 查询内部继续分级，并检查全局 squash 对查询级的组合门控。
具体所有权、容量和恢复不变量见 `docs/plan/memory-query-pipeline.md`。


## 15. LSQ 匹配快照检查点（2026-10-23）

`feat/freq-lsq-snapshot` / `freq-lsq-snapshot-20261023` 基于 `eb36c43`，在 LSQ
并行比较与平衡 youngest-store 选择之间保存完整快照，LSU r 级同步保存 load
元数据。store 槽位释放复用、反压和 flush 同拍替换均有专项测试覆盖。

W1/W2 各 19/19、run_all ALL PASS；IPC 0.5274 / 0.5059，diagnose
**20,093.751 µm² / 190.80 MHz**。相对基线 Fmax +22.1%、面积 +2.0%、W2
IPC -2.7%，`IPC×Fmax` 约 +18.8%。未到期望 200 MHz，保留独立检查点；
未跑 opt、未合入 main、未推送，不把旧 main opt 当作本候选结果。

关键路径已转到 `ROB → IQ → backend a1 捕获`，IQ 内部约4.18 ns，占周期约80%。
下一阶段优先优化 IQ 最老候选/双 lane 排除的串行选择结构，再按报告评估
squash 控制分级，暂不继续给 LSQ 增级。完整测量见
[LSQ 快照实验](../experiments/lsq-query-snapshot.md)。


## 16. IQ 双候选平衡树检查点（2026-10-23）

`feat/freq-iq-select-tree` / `freq-iq-tree-20261023` 基于 `5c2b07c`，只调整组合
选择，平衡树同时给出完整候选前两名和最老 store 预填；seq 直接沿树传递。
W1/W2各19/19、run_all ALL PASS，全部 correctness/perf 周期与基线相同。
新IQ对拍5档200,035周期、1,466,117检查通过。

diagnose **20,057.360 µm² / 197.11 MHz**，相对基线频率+3.31%、面积-0.18%，
IPC仍0.5274/0.5059。虽未达到200 MHz，但无测得IPC代价，保留独立检查点；
未跑opt、未合入main、未推送。新第一条路径不经过IQ/PRF/LSQ，转到
ROB → LSU q_seq 捕获，LSU段约4.43 ns。下一轮优先检查16项load等待表的
线性最老选择及q捕获门控，保持预留容量、q/r排除、重试和squash不变量。
详见 [IQ 选择树实验](../experiments/iq-select-tree.md)。


## 17. LSU 等待 load 平衡选择检查点（2026-10-23）

`feat/freq-lsu-select-tree` / `freq-lsu-tree-20261023` 基于 `a239510`，将等待表最老
选择改为平衡树，并直接传递seq；不增加拍数，保留q/r排除、预留容量、重试与squash。
W1/W2各19/19、run_all ALL PASS；LSU专项292/483项通过，全部correctness/perf
周期与基线相同，IPC仍0.5274/0.5059。

diagnose **19,980.042 µm² / 232.04 MHz**，频率+17.72%、面积-0.39%、IPC不变，
已过200 MHz诊断阶段目标。未跑opt、未合入main、未推送。新瓶颈为LSQ已提交
store选择→AXI写请求捕获，LSQ段约4.11 ns。下一轮先优化store drain的16项
线性最老选择，保持提交后发送、按序、反压与sent FIFO/B响应释放语义。
详见 [LSU 选择树实验](../experiments/lsu-select-tree.md)。

## 18. store 排空平衡选择检查点（2026-10-23）

`feat/freq-store-select-tree` / `freq-store-tree-20261023` 基于`6ae6be2`，只改
LSQ已提交store的组合最老选择，不增加拍数，保留sent FIFO和写响应释放。
W1/W2各19/19、run_all ALL PASS，LSQ专项637/1173/1173项通过；全部correctness/
perf周期不变，IPC仍0.5274/0.5059。diagnose **19,952.559 µm² / 240.60 MHz**，
频率+3.69%、面积-0.14%；未跑opt、未合入main、未推送。

新第一条路径跨越squash、LSU结果有效、CDB ready、ROB提交、LSQ分配ready，
最后沿backend_ready/前端响应接收到达第二路I-cache地址端。下一阶段优先研究
用弹性缓冲及寄存容量/ready切断反压链，保留dispatch资源预留、分配与恢复一致性。
详见 [store选择树实验](../experiments/store-select-tree.md)。

## 19. 双槽 dispatch 弹性缓冲检查点（2026-10-23）

`feat/freq-dispatch-buffer` / `freq-dispatch-buffer-20261023` 基于`d81cacb`，
backend_ready改为仅依赖tail_valid，增加后槽保存整组输入与唤醒；两槽同拍恢复
按squash清理，seq仍在前槽进入IQ/LSQ时建立。满缓冲不借用当拍排空容量接收，
无停顿时仍可每拍接收一组。

W1/W2各19/19、run_all ALL PASS，backend各502项通过。IPC四位0.5274/0.5059，
两档perf_qsort少55/47周期；diagnose **20,103.272 µm² / 251.29 MHz**，频率+4.44%、
面积+0.76%。用户明确暂不opt，已取消先前opt；未合main、未推送。
新最长路径为ROB→IQ→PRF→LSU地址→LSQ fill捕获，下一轮优先检查访存发射及
squash门控位置，确保load/store所有权、重试和预填推进能力。
详见 [dispatch缓冲实验](../experiments/dispatch-buffer.md)。

## 20. IQ 末端取消检查点（2026-10-23）

`feat/freq-iq-late-squash` / `freq-iq-late-squash-20261023` 基于`c74d4e2`。
利用年轻项为年龄排序后缀的性质，先预选、再按squash过滤valid，payload不受取消
控制；IQ和backend只按过滤后valid写状态。无新增流水拍数。
W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期不变；IQ增强1,466,671项、
原185项通过。diagnose **20,162.350 µm² / 261.69 MHz**，频率+4.14%、面积+0.29%，
IPC仍0.5274/0.5059。未跑opt、未合main、未推送。

新瓶颈经过LSU/CDB、ROB br_update_uncond、BPU同拍训练旁路到I-cache地址端。
下一轮优先只给BPU训练入口寄存整组字段，保留redirect/squash即时处理，验证
连续/同索引训练与预测快照配对，不延迟整条恢复总线。
详见 [IQ末端过滤实验](../experiments/iq-late-squash.md)。

## 21. BPU 训练入口寄存实验（2026-10-23，小收益）

`feat/freq-bpu-training-pipe` / `freq-bpu-training-20261023` 基于`43b84ac`。
只延迟预测器训练一拍，完整捕获valid/PC/taken/target/is_uncond，保持分支恢复即时。
W1/W2各19/19、run_all ALL PASS，新训练测试35/39项通过；全部correctness/perf
周期不变，IPC仍0.5274/0.5059。diagnose **20,170.865 µm² / 263.10 MHz**，
仅频率+0.54%、面积+0.04%；保留独立实验起点，不据此单独合main，不追加opt。

新路径由squash经LSU/CDB、ROB提交和LSQ ready到disp_seq[31]捕获，说明两条路径
原本接近上限。下一轮先分析分支解析与结果接收的耦合、序号分配/递增使能，
保持两个dispatch槽及IQ/LSQ/ROB的seq一致；不能只延迟计数器。
详见 [BPU训练寄存实验](../experiments/bpu-training-pipe.md)。

## 22. dispatch 年龄预分配检查点（2026-10-24）

`feat/freq-dispatch-seq` / `freq-dispatch-seq-20261024` 基于`b80df1d`。序号在缓冲
接收时分配并随两槽保存，进入IQ/LSQ用保存年龄，ROB映射仍在实际下发时建立；
squash允许年龄空洞，保持比较次序和恢复一致。
W1/W2各19/19、最终run_all ALL PASS，backend539/541项通过，全部correctness/perf
周期不变。diagnose **20,231.241 µm² / 279.78 MHz**，频率+6.34%、面积+0.30%，
IPC仍0.5274/0.5059。n_push/n_disp统计分开，LOCAL_STATS lint通过；无opt、未合main、未推送。

新瓶颈为redirect经cache0响应valid到cache1接收/ready及地址端。下一轮优先研究
独立响应缓冲，保留请求FIFO use2/预测快照、响应顺序、反压及redirect清理；
不直接延迟redirect本身。详见 [年龄预分配实验](../experiments/dispatch-seq.md)。

## 23. 前端独立响应队列实验（2026-10-24，小收益）

`feat/freq-frontend-response-queues` / `freq-frontend-response-20261024`，基于`d309093`。
两路I-cache各加两槽响应队列，ready只依赖本路寄存占用；请求FIFO的use2与预测快照
保持配对，redirect同时清所有前端队列。修复rename未出队时错误借用decode空间。
W1/W2各19/19、run_all ALL PASS，增强前端测试281/284项通过；恢复旧容量算法的
临时源文件在同一W2测试中失败38项，确认修复有必要。

diagnose **20,397.453 µm² / 284.44 MHz**，频率+1.67%、面积+0.82%；W2/W1 IPC
为0.5196/0.4990，下降1.49%/1.37%，W2 `IPC×Fmax`仅+0.16%。保留为后续组合
实验的独立起点，不据此单独合main。一次diagnose、24个输入hash一致，无opt、
未合main、未推送；基线为`build/synth/frontend_response_baseline/`。

原跨cache路径退出首位，新路径为ROB squash索引→LSU/CDB→分支tag→ROB提交LSQ id
→LSQ alloc_ready→IQ捕获。下一轮优先评估LSQ对当拍提交释放空间的组合依赖，
保持表项复用与访存所有权，重新测量分配停顿代价。详见 [前端响应队列实验](../experiments/frontend-response-queues.md)。

## 24. LSQ 分配寄存占用检查点（2026-10-24）

`feat/freq-lsq-registered-alloc` / `freq-lsq-registered-alloc-20261024`，基于`1706178`。
LSQ alloc_ready只依据寄存valid和组内重复id，load提交/B响应释放沿后才复用；
整组原子分配、查询快照、store提交/发送/响应所有权不变。增强LSQ测试
677/1229/1242项通过，W1/W2各19/19、run_all ALL PASS。

选定组合版保留前端响应队列：diagnose **20,389.871 µm² / 290.50 MHz**，
IPC 0.5195/0.4989。相对上一轮频率+2.13%、面积-0.037%、W2 `IPC×Fmax`约+2.10%。
同时完成移除队列但保留容量修复的对照：20,261.932 / 262.23 MHz，IPC 0.5272/0.5057，
同样通过两档全量及run_all。组合版W2 `IPC×Fmax`比对照高9.15%，故保留响应队列。
两版各一次diagnose、24个输入hash一致；默认RTL/仿真器/报告已恢复为组合版。

原ROB提交→LSQ ready→IQ路径退出首位，新路径为IQ源tag选择→PRF→LSU地址加法
→LSQ fill捕获；累计到达1.759/2.087/3.220/3.382 ns。下一轮优先研究地址进位结构，
保持访存所有权和拍数。无opt、未合main、未推送；基线为
`build/synth/lsq_registered_alloc_baseline/`，两个候选分别归档在
`lsq_registered_alloc_buffered/`和`lsq_registered_alloc_direct/`。
详见 [LSQ寄存占用实验](../experiments/lsq-registered-alloc.md)。

## 25. LSU 地址分组进位实验（2026-10-24，已回退）

`feat/freq-lsu-address-prefix`，基于`5c921b7`；候选`bf08056` /
`freq-lsu-address-prefix-trial-20261024`。LSU地址改为4位局部双候选和＋三级分组
进位，保持模2^32结果、访存所有权和拍数。

W1/W2各19/19，全部correctness/perf周期相同；最终候选run_all ALL PASS。
每档4231组操作数经真实load/store端口对拍，含全位进位边界、回绕、负偏移和
随机数、两拍反压稳定；63757/63948项通过。一轮早期run_all遇到Verilator线程池
内部错误250，重跑完整矩阵通过。一次diagnose、24个输入hash一致，无opt。

diagnose **20,442.024 µm² / 290.83 MHz**，相对基线仅+0.114%频率、+0.256%面积，
最小周期3.4424→3.4385 ns。地址路径退出首位，另一ROB/LSU/CDB/分支tag/ROB ready
控制链到dispatch有效位及backend捕获成为最长链，限制整体收益。

决定回退RTL，保留trial代码与新增测试；当前仍选定**20,389.871 / 290.50 MHz**。
默认RTL、仿真器和报告已恢复且24个hash核对一致，回退后完整run_all也ALL PASS。
候选归档为
`build/synth/lsu_address_prefix_trial/`，基线为`lsu_address_prefix_baseline/`。
后续同时评估数据与控制路径；未合main、未推送，评审tag为
`freq-lsu-address-review-20261024`。
详见 [地址分组进位实验](../experiments/lsu-address-prefix.md)。

## 26. 接收数量寄存与地址进位组合（2026-10-24）

`feat/freq-seq-count-pipe` / `freq-seq-count-pipe-20261024`，基于`a050c13`。
将输入接收数量寄存为seq_pending，disp_seq+seq_pending提前准备本拍组首，保持
每组年龄数值不变；同时重用已验证的地址分组进位，处理两条相近瓶颈。
W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期相同，IPC0.5195/0.4989；
增强backend566/592项、LSU63757/63948项通过，LOCAL_STATS lint通过。

diagnose **20,441.659 µm² / 293.07 MHz**，相对基线频率+0.887%、面积+0.254%。
收益仍小，保存独立中间检查点供后续组合，不据此单独合main；一次diagnose，
24个输入hash一致，无opt、未合main、未推送。候选归档`build/synth/seq_count_pipe_candidate/`，
基线为`seq_count_pipe_baseline/`。

年龄与地址加法退出首位，新路径经ROB redirect、cache1 ready、frontend fetch_fire
到cache0 SRAM地址，累计2.647/2.868/3.096/3.312 ns。下一轮优先评估读地址预选择，
保持所有使能访问和refill/flush语义。
详见 [组合实验](../experiments/seq-count-pipe.md)。

## 27. I-cache SRAM 地址预选择检查点（2026-10-24）

`feat/freq-icache-read-address` / `freq-icache-read-address-20261024`，基于`fd07456`。
按lookup_room提前选读地址，REFILL按寄存state提前选地址；保持全部使能访问的
地址/次数、read_en、写使能和状态更新不变，未使能地址可变化。
W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期相同，IPC0.5195/0.4989。
索引4/10各10万拍随机矩阵、19247/71501次响应对拍通过；新定向覆盖停顿重读、
pending重放不得额外回填，以及flush与回填同拍不得写入。LOCAL_STATS lint通过。

diagnose **20,437.314 µm² / 300.03 MHz**，频率+2.373%、面积-0.021%、IPC无损，保留
独立检查点；相对290.50 MHz原基线，两阶段组合频率+3.282%、面积+0.233%。
一次diagnose、24个输入hash一致，无opt、未合main、未推送。300.03只是诊断值，
尚无opt最终验收和充分裕量，不视为课程阶段通过。

SRAM地址路径退出首位，新路径为ROB in_ready→rename in_ready→fetch_fire→cache0
read_en→SRAM CE，累计2.578/2.820/3.047/3.232 ns。下一轮优先研究读使能本地化
或受控请求缓冲，独立验证s1/s2、pending与flush配对。基线在
`build/synth/icache_read_address_baseline/`，完整候选在`icache_read_address_candidate/`。
详见 [地址预选择实验](../experiments/icache-read-address.md)。

## 28. I-cache本地预读trial（2026-10-24）

`feat/freq-icache-local-read`，提交4dc81b2 / `freq-icache-local-read-trial-20261024`。
lookup_room触发本地SRAM读，真正accept_fetch才建立有效s1；空读不产生指令/refill，
s1停顿、pending重放、flush和写条件不变。索引4/10各10万拍随机，19259/71513次
响应对拍通过；W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期与基线相同。

diagnose **20,437.519 / 300.29 MHz**，仅频率+0.088%、面积+0.001%。CE路径移出首位，
decode FIFO指令写入成为瓶颈；保存中间trial供后续组合，不单独作为采用依据。
一次diagnose、24个输入hash一致，无opt。完整归档`build/synth/icache_local_read_trial/`。
详见 [本地预读trial](../experiments/icache-local-read.md)。

## 29. 前端响应容量解耦检查点（2026-10-24）

`feat/freq-frontend-response-capacity` / `freq-frontend-response-capacity-20261024`，基于4dc81b2。
响应入队只看寄存fq_count空闲，不借当拍出队空间，且不等待backend ready；新请求与
rename消费仍用原握手。新增停backend后缓冲并按序消费原4条响应测试，前端293/297项通过。
W1/W2各19/19、run_all ALL PASS；backend566/592、LSU63757/63948项，LOCAL_STATS lint通过。

diagnose **20,441.849 µm² / 322.42 MHz**，IPC **0.5221 / 0.4988**。
相对本地预读trial：频率+7.368%、面积+0.021%、W2 IPC+0.509%、W2 `IPC×Fmax`约+7.91%。
相对300.03 MHz正式检查点：频率+7.462%、面积+0.022%、W2 `IPC×Fmax`约+8.01%；
W1 IPC仅下降0.006%。保留组合，形成约22.42 MHz初步诊断余量，未做opt最终验收。

前端链退出首位，新路径IQ源tag→PRF→LSU地址→LSQ fill，累计1.759/2.088/2.879/3.042 ns。
下一轮优先研究IQ选择输出与PRF地址形成，保持访存所有权和实际握手。
当前完整候选在`build/synth/frontend_response_capacity_candidate/`，基线在
`frontend_response_capacity_baseline/`，默认报告与24个RTL输入hash一致。
两版各一次diagnose，顺序运行；无opt、未合main、未推送。
详见 [响应容量组合](../experiments/frontend-response-capacity.md)。


## 30. IQ tag树trial已回退（2026-10-24）

`6637367` / `freq-iq-tag-tree-trial-20261024`，基于e9390ce。
两个源tag随first/second/prefill候选树传递，直接提供输出tag，减少slot动态索引后的
二次选择；不增加流水拍数，最老优先、wake、预填、late squash和独立lane反压不变。
IQ独立scoreboard五档共1,466,671项零失败，原三档行为回归通过；W1/W2各19/19、
run_all ALL PASS、LOCAL_STATS lint通过，两档全部correctness/perf周期与基线相同。

diagnose **20,431.512 µm² / 318.90 MHz**，IPC0.5221/0.4988。相对322.42版，频率
-1.090%、面积-0.051%，不采用。一次diagnose、24个hash一致，无opt、未合main、未推送。
补做现有网表OpenSTA查询，IQ→PRF→地址→LSQ累计1.603/1.920/2.712/2.875 ns，
局部比基线改善约0.167 ns；全核首位改为ROB squash→LSU load result valid→CDB ready
→branch update tag→ROB commit free→rename，整体频率反而下降。

已恢复e9390ce的RTL、默认报告和W2仿真器，24个hash匹配，保留322.42 MHz基线。
trial网表/源码/仿真器/日志及附加时序在`build/synth/iq_tag_tree_candidate/`，
原基线在`iq_tag_tree_baseline/`。下一轮优先检查branch update payload与valid能否
解耦，再独立验证与tag树组合；不得省略分支取消、CDB反压和提交回归。
详见[IQ tag树试验](../experiments/iq-tag-tree.md)。
