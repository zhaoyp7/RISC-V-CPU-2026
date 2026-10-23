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
