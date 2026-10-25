# 频率实验记录

> 最新独立实验见实验 18：diagnose 279.78 MHz，W2 IPC 0.5274，未跑 opt、未合入 main。

> 最新主线结果见末尾实验 8：本地 main 为 17,895.8 µm² / 115.12 MHz（opt），
> W2 IPC 0.6084；前面各实验的“未合并”描述保留为当时的历史状态。

> 所有数字来自本仓库 `make perf` / `make synth MODE=diagnose`。
> 实验分支不合并，除非同时满足：功能全绿、Fmax 明显提升、IPC 损失可接受。

## 基线（`main`，tag `p2-perf-prefill`）

| 指标 | 数值 |
| --- | ---: |
| W=2 IPC | 0.6380 |
| diagnose 面积 | 25,134.9 µm² |
| diagnose Fmax | 53.96 MHz |
| opt 面积 / Fmax | 24,468.759 µm² / 56.72 MHz |
| diagnose 关键路径 | `u_rob/squash_rob_idx → u_backend → u_lsu → u_cdb → u_iq` |

## 实验 1：squash 两级化（`feat/freq-recovery`）

改动：

- `backend_ooo` 增加 `sq_pending` / `squash_seq_q`；
- 第 1 拍只做 `rob_seq[squash_rob_idx]` 查找并冻结 issue/CDB/complete；
- 第 2 拍用寄存后的 `squash_seq` 清理 IQ/LSU/LSQ。

| 指标 | 基线 | 实验 1 |
| --- | ---: | ---: |
| diagnose Fmax | 53.96 MHz | 54.99 MHz（+1.9%） |
| diagnose 面积 | 25,134.9 µm² | 25,051.7 µm² |
| W=2 IPC | 0.6380 | 0.6263（-1.8%） |
| 关键路径 | ROB → backend | backend 内部 `squash_seq_q → u_lsu → u_cdb` |

结论：路径确实从 ROB 移入 backend，但 Fmax 只 +1.9%，不值得单独保留。

## 实验 2：LSU discard 寄存化

在实验 1 基础上，让 `load_result_valid` / `md_resp_keep` 只依赖已寄存的
`rq_discard` / `md_discard`，不再组合比较 `squash_seq`。

| 指标 | 基线 | 实验 2 |
| --- | ---: | ---: |
| diagnose Fmax | 53.96 MHz | 56.10 MHz（+4.0%） |
| diagnose 面积 | 25,134.9 µm² | 25,024.9 µm² |
| W=2 IPC | 0.6380 | 0.6263（-1.8%） |
| 关键路径 | ROB → backend | `u_lsu → u_cdb → u_backend` |

结论：仍低于 20% 的保留阈值；整条 `feat/freq-recovery` 分支不合并。

## 实验 3：CDB 仲裁输出打一拍（CDB 回滚，FIFO 修复保留）

改动：在 `backend_ooo` 把 `u_cdb` 的 `cdb_out` 寄存后再广播，试图切断
`u_lsu → u_cdb → u_backend` 的组合路径。

第一次结果为 **perf_qsort 死锁**，trace 定位到：

- ROB 头部 branch：`PC=0x000000b0, dest=23, resolved=1, done=0`
- `[CF_PUSH] tag=23` 之后只有 `[CF_POP]`，没有 `[COMPLETE]`
- 同一拍一个正确路径 branch 压入 complete FIFO，另一个 branch 触发
  squash；squash 循环用**旧表项**的 `cf_seq` 把同一个 slot 标成
  `discard=1`，覆盖了新 push 的 discard
- 下一拍这个正确 complete 被静默丢弃，ROB 头部永远不 done

修复（`36e4302`，已合入 `main`）：

- complete FIFO 的 push 移到 squash 循环之后；同一拍 push 与 squash 落到
  同一 slot 时，push 的新表项 discard 最后写入、以新 `cf_seq` 为准。

修复后的 CDB 实验：

| 指标 | 基线 | CDB 打一拍 + FIFO 修复 |
| --- | ---: | ---: |
| W=2 IPC | 0.6380 | 0.6097（-4.4%） |
| diagnose Fmax | 53.96 MHz | 55.68 MHz（+3.2%） |
| diagnose 面积 | 25,134.9 µm² | 25,048.1 µm² |
| 关键路径 | ROB → backend | 仍是 ROB → backend |

结论：**CDB 打一拍只换来 +3.2% Fmax，却损失 4.4% IPC，不保留**。
complete FIFO 的 same-cycle push/squash 修复是独立正确性收益，已合入
`main`；CDB 寄存器改动已回滚。

## 实验 4：IQ select / PRF read 分开（WIP，未合并）

改动：在 IQ 和 backend EX 之间加一组 issue 寄存器，IQ 的 `out_ready`
改为“寄存器可接收”，执行资源 ready 只控制寄存器排空。

结果：

- W=2 correctness：**13/19**，qsort/hanoi 等 6 个 case 死锁
- perf_median/multiply 正常
- diagnose Fmax：**70.04 MHz（+29.8%）**
- diagnose 面积：25,532.2 µm²（+397.3）
- 关键路径起点仍为 ROB，但路径长度从 18.19 ns 降到 14.28 ns

死锁原因：

- issue 寄存器把 load 提出 IQ 后，如果它被 LSQ 中更老 store 的未知地址阻塞，
  就占住 lane0；
- 更老 store 的 address-only prefill / 完整 issue 也走 lane0；
- 形成循环等待。
- 尝试了 store prefill bypass + full store bypass + complete FIFO push，
  仍无法覆盖所有 load-store 依赖，qsort 继续死锁。

结论：**这版不合并**。+29.8% Fmax 证明“IQ/PRF 分开”方向有效，但需要
真正的 **issue replay / 非阻塞 issue queue**，而不是继续加旁路。WIP 分支
`feat/pipeline-iq`（commit `9a7f9ff`）保留作设计参考。

后续又试了 Phase 1：skid store 地址预填队列 + PRF 第 5 读口
（WIP `6971acd`），qsort/hanoi/queens 仍死锁。说明阻塞 store 的 src1
依赖链本身也被卡住，仅预填地址不够；需要 `docs/plan/replay.md` 的
Phase 2 retain-entry IQ/replay。

Phase 2（WIP `c12ac89`）进一步让 LSQ 在 skid 捕获时分配表项，并直接从
skid 捕获 store 做预填，仍然无法解开 qsort/hanoi/queens 死锁。结论：
issue 所有权、skid/IQ 反压、LSQ 分配时机和 load/store 内存序需要一起
重写，局部补丁不可行；按时间盒停止，`feat/pipeline-iq` 不合并。

## 实验 5：lane1 ALU 发射流水化（`feat/freq-alupipe`，保留检查点）

2026-10-23，基于 `main` 的 C2 面积档（ROB16/PRF48/LSQ16/1KB I$）。

改动：

- 在 IQ lane1 与 PRF/ALU1 之间增加一个 a1 缓冲；
- IQ 选中 lane1 后先写入缓冲，下一拍才做 PRF 读 + ALU1；
- lane0 和 load/store 完全保持原路径，不进入流水级；
- lane1 结果仍经原有 `alu1_valid_q` / CDB 写回。

| 指标 | C2 基线 | 实验 5 |
| --- | ---: | ---: |
| W=2 IPC | 0.6311 | **0.6252（-0.9%）** |
| diagnose 面积 | 20,262.8 µm² | 20,518.3 µm² |
| diagnose Fmax | 53.44 MHz | **59.26 MHz（+10.9%）** |
| W=2 correctness | 19/19 | 19/19 |
| qsort/hanoi/queens | PASS | 逐个 PASS，无死锁 |

结论：**保留**。面积只增加约 255 µm²，Fmax +10.9%，IPC 损失很小。
新关键路径从 lane1 移到 **lane0 的 PRF→ALU0**，说明下一步应流水化
lane0 非访存路径。检查点 commit：`0621c83`。

## 实验 6：lane0 非访存流水化（当前分支，未合并 `main`）

改动：

- lane0 的**非访存** uop（ALU、branch、jal/jalr、div、非法指令）进入 a0
  缓冲，下一拍做 PRF 读 + ALU/分支/div start；
- **load/store 仍然从 IQ 直接进 LSU**，不进入流水级，避免之前
  `feat/pipeline-iq` 的 load/store 所有权死锁；
- PRF 读口从 4 个扩到 6 个（lane0 直连 + a0 + a1）；
- 非访存指令的 complete 仍在 IQ 选中时压入 complete FIFO；分支的
  `br_update` 在 a0 执行时产生，ROB 提交会等待 `resolved`；
- a0/a1 都按 seq squash，并在同一拍支持“排空旧项 + 接收新项”。

| 指标 | C2 基线 | 实验 6 |
| --- | ---: | ---: |
| W=2 IPC | 0.6311 | **0.6084（-3.6%）** |
| W=1 IPC | 0.5940 | **0.5759（-3.1%）** |
| W=2 correctness | 19/19 | 19/19 |
| W=1 correctness | 19/19 | 19/19 |
| `run_all` | ALL PASS | ALL PASS |
| diagnose 面积 | 20,262.8 µm² | 21,092.6 µm² |
| diagnose Fmax | 53.44 MHz | **67.91 MHz（+27.1%）** |
| **opt 面积** | **19,759.4 µm²** | **20,306.7 µm²（+2.8%）** |
| **opt Fmax** | **55.47 MHz** | **72.73 MHz（+31.1%）** |
| 关键路径 | ROB → backend → ALU1 | 仍 ROB → backend → ALU 结果寄存器 |

`IPC × Fmax` 从 **35.0** 提升到 **44.2（+26.4%）**。这是目前唯一同时
通过 W1/W2/`run_all` 且 Fmax 收益超过 20% 的频率改动。

调试过程：

- qsort 第一次超时，ROB head 卡在 `pc=0x4` 的 `auipc`；
- trace 显示指令在 t=53 被 lane1 弹出，但 `a1_issue_ready` 永远为 0；
- 根因有两个：
  1. `a1_issue_ready` 漏了显式声明，被 Verilator 隐式建网；
  2. 实际逻辑还连着旧的 `alu1_issue_ready`，而后者已无驱动。
- 补声明并统一信号名后 qsort/hanoi/queens/全量 19 项全部通过。
- 教训：综合/仿真前检查 `IMPLICIT`、`UNUSEDSIGNAL`；新增流水控制信号
  必须显式声明并确认只使用一个名字。

当前状态：分支 `feat/freq-alupipe`，HEAD `fa8920f`（RTL 改动只在
`verilog/backend_ooo.sv`），**尚未合并到 `main`**。`main` 仍是 C2 面积档
（`94eac37`）。回滚到实验前：`git switch main` 或 branch 上的 `0621c83`
（保留 lane1 版）/ `94eac37`（C2）。

## 实验 6 后的历史决策

- `main`：C2 面积档，opt 19,759.4 µm² / 55.47 MHz，IPC 0.6311；保持可交付。
- `feat/freq-alupipe`：频率优化版，opt 20,306.7 µm² / 72.73 MHz，IPC 0.6084；
  **未合并**，等下一 agent/用户决定是否接受面积换频率。
- `feat/freq-recovery`、`feat/pipeline-iq`、`feat/gshare-snapshot` 保留为
  实验分支，不合并。
- 下一步优先级：
  1. 若接受面积换频率：把 `feat/freq-alupipe` 合入 `main`，再补 opt 后文档；
  2. 若继续频率：先试“a0/a1 结果捕获不再由 squash 组合门控”，把 squash
     从 ALU 结果使能路径上移走；再考虑两级 squash；
  3. 若继续面积：当前 20.3k opt，距 18k 还差 2.3k，需砍 LSQ/ROB/BPU/I$
     或做结构优化，不要只扫参数；
  4. MIQ/独立 memory issue queue 仍留到频率流水化稳定之后。
- D-Cache 继续暂缓。

## 停止后的候选方向

1. **先做 opt 后的合并决策**：频率版已全绿，但面积 +547 µm²、IPC -3.6%。
2. **squash→ALU 结果使能路径**：当前关键路径起点仍是 ROB；可试让 a0/a1
   照常执行，只在结果捕获处用 seq 门控，缩短控制路径。
3. **分支预测**：qsort/median 误预测仍是 IPC 主要损失；带 GHR 快照的
   gshare + RAS 是低风险 IPC 方向，但会增加面积。
4. **D-Cache 仍暂缓**：load 阻塞不是当前主要矛盾，面积/频率代价高。

## 实验 7：关闭 OoO ALU 的冗余组合除法（已验收）

基线 `b6c009c` 已快进合入本地 `main`，本轮在独立分支验证后纳入本地 main，
保存 tag `freq-alu-no-comb-div-20261023`，未推送远端。

| 指标 | 非访存流水基线 | 本轮 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.6084 / 0.5759 | 0.6084 / 0.5759 |
| diagnose 面积 / MHz | 21,092.6 / 67.91 | 19,777.0 / 99.38 |
| opt 面积 / MHz | 20,306.7 / 72.73 | **18,955.7 / 115.80** |
| W2 / W1 correctness | 各 19/19 | 各 19/19，周期数逐项相同 |
| run_all | ALL PASS | ALL PASS |

原 ALU 内 `/`、`%` 仍被综合，虽然 OoO 的 DIV/REM 已走独立串行 divider。
增加默认开启的 `ENABLE_DIV`，只在两个后端 ALU 关闭，消除这段冗余组合电路。
展开后 ALU 的 `$div` / `$mod` 均为 0。

opt 相对流水基线：面积 -6.7%，Fmax +59.2%，IPC 不变。
本轮保留；下一轮按新关键路径研究访存发射/LSQ 消歧，不叠加未经设计的旁路。
详细记录：[alu-no-comb-div.md](alu-no-comb-div.md)。

## 实验 8：ALU 乘法器共享（已验收）

分支 `feat/alu-shared-mul` 基于 `3b3e467`（RTL `21fba79`），只改变组合乘法
表达式，MUL/MULH/MULHSU/MULHU 共享无符号乘积和高位修正，不增加流水拍数。

| 指标 | 原乘法表达式 | 共享乘法 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.6084 / 0.5759 | 0.6084 / 0.5759 |
| diagnose 面积 / MHz | 19,777.030 / 99.38 | 18,603.442 / 99.38 |
| opt 面积 / MHz | 18,955.695 / 115.80 | **17,895.831 / 115.12** |
| W1 / W2 correctness | 各 19/19 | 各 19/19，周期数相同 |
| run_all | ALL PASS | ALL PASS，新增 ALU 对拍 713,728 项 |

opt 面积 -5.6%，Fmax -0.6%，保留并合入本地 main，tag `alu-shared-mul-20261023`，
未推送。面积低于 18k，但 IPC / 300 MHz 未达阶段 2。本轮只跑一次 opt；
后续小改动先用 diagnose 筛选，积累到阶段检查点再跑 opt。
详见 [alu-shared-mul.md](alu-shared-mul.md)。

## 实验 9：CDB 唤醒 / IQ 选择隔拍（独立检查点）

用户明确允许频率优先，IPC / 面积暂时越线；不沿用 IPC ≥0.60 的旧候选门槛。
基线 main `bc795ae`，分支 `feat/freq-registered-wake`，tag `freq-registered-wake-20261023`。

- IQ 只按已寄存 ready 选择；CDB 数据先写 PRF，下一拍才选择消费者。
- 移除六个操作数读口的当前拍 CDB 数据旁路，保留入队 / skid 的 wake 匹配。
- store 地址预填仍留在 IQ，完整 store 才删除，访存请求所有权不变。
- W1/W2 各 19/19、IQ/backend 测试 PASS、完整 run_all 重跑 ALL PASS。

| 指标 | main 基线 | 隔拍唤醒候选 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.6084 / 0.5759 | 0.5727 / 0.5471 |
| diagnose 面积 / MHz | 18,603.442 / 99.38 | **18,542.177 / 107.56** |
| opt 面积 / MHz | 17,895.831 / 115.12 | **未运行** |

同模式 Fmax +8.2%，W2 IPC -5.9%，面积 -0.3%；`IPC×Fmax` 约
+1.9%。新路径 `ROB → IQ → PRF → LSU/LSQ`，已移除 CDB，但 IQ
和 LSQ 仍长。保留为后续结构分级的独立起点，未合入 main，未推送。
本轮没有跑 opt，继续遵守“diagnose 筛选、阶段检查点才 opt”的要求。
详见 [registered-wake.md](registered-wake.md)。

## 实验 10：load 等待表 / 查询寄存器（独立检查点）

分支 `feat/freq-load-query-pipe`，基于 `819ddd1`，tag `freq-load-query-pipe-20261023`。
按 LSQ id 为 load 预留等待槽位，按 seq 选择进入查询寄存器；消歧阻塞保留
表项重试，store 保持独立入口。分离 AGU / 查询，同时为在途响应预留结果槽。

| 指标 | 隔拍唤醒 | load 查询分级 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5727 / 0.5471 | **0.5419 / 0.5205** |
| diagnose 面积 / MHz | 18,542.177 / 107.56 | **19,706.842 / 156.31** |
| opt | 未运行 | **未运行** |

W1/W2 各 19/19、完整 run_all ALL PASS；LSU W1/LSQ8 144 项、W2/LSQ16
227 项通过，覆盖晚就绪老 load、预填、部分写、三阶段 squash、请求反压和
12 笔 load / 8 个结果槽的 CDB 反压场景。

同模式 Fmax +45.3%，面积 +6.3%，W2 IPC -5.4%，`IPC×Fmax` 约
+37.5%。按用户频率优先授权保留，未合入 main、未推送；本轮不跑 opt。
新第一条关键路径 `ROB → LSU → LSQ → LSU`，LSQ 段约 4.6 ns，后续继续
按报告分级。详见 [load-query-pipe.md](load-query-pipe.md)。

## 实验 11：LSQ 匹配快照 / 平衡选择树（独立检查点）

分支 `feat/freq-lsq-snapshot`，基于 `eb36c43`，tag `freq-lsq-snapshot-20261023`。
LSQ 并行匹配后保存 seq/data/full 与匹配位，下一拍平衡树选择最年轻同字
store。LSU r 级同步保存 load 元数据，q/r 两级都从等待表选择集合中排除。
store 释放复用不影响快照；阻塞释放响应留表重试，反压保持，squash 支持同拍替换。

| 指标 | load 查询分级 | LSQ 匹配快照 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5419 / 0.5205 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 19,706.842 / 156.31 | **20,093.751 / 190.80** |
| opt | 未运行 | **未运行** |

W1/W2 各 19/19、run_all ALL PASS；直接 LSQ 151/207、LSU 172/255 项通过。
Fmax +22.1%、面积 +2.0%、W2 IPC -2.7%，`IPC×Fmax` 约 +18.8%。未达期望
200 MHz，保留为独立检查点，未合入 main、未推送；只跑一次 diagnose，无 opt。
24 个输入 hash 与 RTL 一致，基线报告与仿真器在 `build/synth/lsq_snapshot_baseline/`。

新路径 `ROB → IQ → backend a1 捕获`，IQ 约 4.18 ns（周期约80%）。下一阶段
优先把双 lane 串行最老选择改为平衡候选选择，保留 store 预填、lane 排除、
未握手留队和 squash 语义。详见 [lsq-query-snapshot.md](lsq-query-snapshot.md)。

## 实验 12：IQ 双候选平衡选择树（独立检查点）

分支 `feat/freq-iq-select-tree`，基于 `5c2b07c`，tag `freq-iq-tree-20261023`。
平衡树同时求完整 ready 前两名及最老 store 预填候选，两个 lane 直接选择；
省去 lane1 依赖 lane0 后重新扫描及 seq 按 id 再读取。保持拍数、唤醒和握手语义。

| 指标 | LSQ 匹配快照 | IQ 双候选树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 20,093.751 / 190.80 | **20,057.360 / 197.11** |
| opt | 未运行 | **未运行** |

两档19/19、run_all ALL PASS，全部 correctness/perf 周期与基线相同。
新独立 IQ scoreboard 5档200,035周期、1,466,117检查通过，原185检查仍通过。
Fmax +3.31%、面积 -0.18%、IPC不变，收益虽小但无测得 IPC 代价，保留独立
检查点；未合入 main、未推送，只跑一次 diagnose、无 opt。24个输入 hash 一致。

新路径 ROB → LSU 查询级 q_seq 捕获，LSU 段约4.43 ns（周期约87%）。下一轮
优先优化16项等待 load 最老选择及捕获门控，不继续叠加 IQ 流水拍数。基线报告
与仿真器为 `build/synth/iq_tree_baseline/`，详见 [iq-select-tree.md](iq-select-tree.md)。

## 实验 13：LSU 等待 load 平衡最老选择（独立检查点）

分支 `feat/freq-lsu-select-tree`，基于 `a239510`，tag `freq-lsu-tree-20261023`。
等待表最老选择改为平衡树，保持候选过滤、q/r排除和同龄低id优先；获胜seq
直接进入q_seq，不增加拍数或寄存器，不改请求所有权、重试、容量与恢复语义。

| 指标 | IQ 双候选树 | LSU 最老选择树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 20,057.360 / 197.11 | **19,980.042 / 232.04** |
| opt | 未运行 | **未运行** |

W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期与基线相同。
LSU 292/483项通过，覆盖置换物理槽位、逆龄入队、同龄、批量squash、反压及
无重复执行。Fmax+17.72%、面积-0.39%、IPC不变，超过200 MHz诊断目标，保留
独立检查点，未合入main、未推送；一次diagnose，无opt。24个输入hash与RTL一致。

新瓶颈为LSQ已提交store选择→AXI写请求捕获，LSQ段约4.11 ns；出口确认是
`drain_addr[29]`。下一阶段针对store drain线性最老选择，保持提交/发送顺序和
sent FIFO/B响应对应。基线报告/仿真器为 `build/synth/lsu_tree_baseline/`，详见
[lsu-select-tree.md](lsu-select-tree.md)。

## 实验 14：LSQ 已提交 store 平衡选择（独立检查点）

`feat/freq-store-select-tree`，基于`6ae6be2`，tag `freq-store-tree-20261023`。
store drain线性扫描改为平衡树，保持committed/unsent筛选、同龄低id优先，
不增加拍数，不改sent FIFO及写响应释放。

| 指标 | LSU 最老选择树 | store 排空选择树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 19,980.042 / 232.04 | **19,952.559 / 240.60** |
| opt | 未运行 | **未运行** |

W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期与基线相同。
LSQ专项637/1173/1173项通过，覆盖双提交、反压、多笔在途、B响应当拍复用及
sent FIFO回绕。Fmax+3.69%、面积-0.14%、IPC不变，保留独立检查点；一次diagnose，
无opt，未合入main、未推送。24个输入hash一致，基线为`build/synth/store_tree_baseline/`。

新路径为squash→LSU/CDB→ROB提交→LSQ分配ready→前端第二路I-cache地址端。
下一轮优先研究ready反压传播与弹性缓冲，避免把终点误认为SRAM自身访问延迟。
详见 [store-select-tree.md](store-select-tree.md)。

## 实验 15：双槽 dispatch 弹性缓冲（独立检查点）

`feat/freq-dispatch-buffer`，基于`d81cacb`，tag `freq-dispatch-buffer-20261023`。
backend_ready只由尾槽占用决定，切断IQ/LSQ ready组合回传；前槽同拍排空与接收，
后槽吸收停顿，两槽保存wake，squash清两槽。

| 指标 | store选择树 | 双槽dispatch缓冲 |
| --- | ---: | ---: |
| W2 / W1 IPC（四位） | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 19,952.559 / 240.60 | **20,103.272 / 251.29** |
| opt | 已取消，无有效结果 | **未运行** |

W1/W2各19/19、run_all ALL PASS；backend增强测试各502项通过。两档perf_qsort
少55/47周期，其余相同；频率+4.44%、面积+0.76%，保留独立检查点。24个输入
hash一致。本轮用户明确不opt，已中断此前d81cacb的opt（130）；未合main、未推送。

新路径ROB→IQ→PRF→LSU地址生成→LSQ fill捕获，原前端ready链移出第一条路径。
下一轮按新报告检查访存发射和squash门控，不把load/store直接放入旧a0/a1。
基线为`build/synth/dispatch_buffer_baseline/`，详见
[dispatch-buffer.md](dispatch-buffer.md)。

## 实验 16：IQ 末端 squash 过滤（独立检查点）

`feat/freq-iq-late-squash`，基于`c74d4e2`，tag `freq-iq-late-squash-20261023`。
先预选再取消年轻项valid，payload不经squash；IQ弹出/预填也受过滤后valid控制。
原参考模型仍先过滤再排序，验证有效输出等价。

| 指标 | 双槽dispatch | IQ末端squash |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 20,103.272 / 251.29 | **20,162.350 / 261.69** |
| opt | 未运行 | **未运行** |

W1/W2各19/19、run_all ALL PASS；全部correctness/perf周期与基线相同。
IQ增强对拍1,466,671项、原185项通过，backend各502项通过。Fmax+4.14%、面积+0.29%，
保留独立检查点；一次diagnose，未跑opt、未合main、未推送；24个输入hash一致。
新路径是ROB分支类型→BPU同拍训练旁路→预测方向→第二路取指/I-cache地址。
下一轮优先仅寄存BPU训练入口，保持分支恢复即时处理。详见
[iq-late-squash.md](iq-late-squash.md)。

## 实验 17：BPU 训练入口寄存（独立实验，小收益）

`feat/freq-bpu-training-pipe`，基于`43b84ac`，tag `freq-bpu-training-20261023`。
只寄存frontend BPU训练字段，BPU同拍旁路保留；ROB解析/redirect/squash不延迟。

| 指标 | IQ末端squash | BPU训练寄存 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 20,162.350 / 261.69 | **20,170.865 / 263.10** |
| opt | 未运行 | **未运行** |

W1/W2各19/19、run_all ALL PASS，新增训练测试35/39项、backend各502项通过，
全部correctness/perf周期与基线相同。24个输入hash一致。Fmax仅+0.54%、面积+0.04%，
保留独立实验起点供组合验证，不作为单独合main的充分依据；一次diagnose，无opt、
未合main、未推送。基线报告/仿真器为`build/synth/bpu_training_baseline/`。

BPU路径移出首位，新路径经LSU/CDB、ROB提交、LSQ alloc_ready到skid_drain和
backend disp_seq[31]捕获。下一轮先分析解析/结果资源耦合与seq使能，保持
IQ/LSQ/ROB年龄一致。详见 [bpu-training-pipe.md](bpu-training-pipe.md)。

## 实验 18：dispatch 接收时预分配年龄（2026-10-24检查点）

`feat/freq-dispatch-seq`，基于`b80df1d`，tag `freq-dispatch-seq-20261024`。
next-free seq在缓冲接收时递增，前后槽保存seq，IQ/LSQ用前槽seq，ROB映射仍下发
时建立；squash后保留年龄空洞而不回退。n_push与原下发统计n_disp分开。

| 指标 | BPU训练寄存 | dispatch年龄预分配 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 / MHz | 20,170.865 / 263.10 | **20,231.241 / 279.78** |
| opt | 未运行 | **未运行** |

两档19/19、最终run_all ALL PASS，全部correctness/perf周期相同，backend539/541项
通过，LOCAL_STATS lint通过。Fmax+6.34%、面积+0.30%，24个输入hash一致。前一项
diagnose早期中断以修正统计口径，仅采用重启后一次完成结果；无opt、未合main、未推送。

新路径经ROB redirect、cache0响应valid、cache1接收/ready到I-cache地址；下一轮
优先研究前端响应缓冲和配对容量，保持即时redirect和预测快照对应。基线为
`build/synth/dispatch_seq_baseline/`，详见 [dispatch-seq.md](dispatch-seq.md)。

## 实验 19：前端独立响应队列（2026-10-24，小收益）

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
保持表项复用与访存所有权，重新测量分配停顿代价。详见 [前端响应队列实验](frontend-response-queues.md)。

## 实验 20：LSQ 分配使用寄存占用（2026-10-24）

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
详见 [LSQ寄存占用实验](lsq-registered-alloc.md)。

## 实验 21：LSU 地址分组进位（收益不足，已回退）

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
详见 [地址分组进位实验](lsu-address-prefix.md)。

## 实验 22：接收数量寄存＋地址进位组合（小收益）

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
详见 [组合实验](seq-count-pipe.md)。

## 实验 23：I-cache SRAM 地址预选择（诊断300.03 MHz）

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
详见 [地址预选择实验](icache-read-address.md)。

## 实验 24：I-cache本地预读trial（单项小收益）

`feat/freq-icache-local-read`，提交4dc81b2 / `freq-icache-local-read-trial-20261024`。
lookup_room触发本地SRAM读，真正accept_fetch才建立有效s1；空读不产生指令/refill，
s1停顿、pending重放、flush和写条件不变。索引4/10各10万拍随机，19259/71513次
响应对拍通过；W1/W2各19/19、run_all ALL PASS，全部correctness/perf周期与基线相同。

diagnose **20,437.519 / 300.29 MHz**，仅频率+0.088%、面积+0.001%。CE路径移出首位，
decode FIFO指令写入成为瓶颈；保存中间trial供后续组合，不单独作为采用依据。
一次diagnose、24个输入hash一致，无opt。完整归档`build/synth/icache_local_read_trial/`。
详见 [本地预读trial](icache-local-read.md)。

## 实验 25：本地预读＋响应容量解耦（322.42 MHz）

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
详见 [响应容量组合](frontend-response-capacity.md)。


## 实验 26：IQ源tag随候选树传递（局部改善，全核回退）

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
详见[IQ tag树试验](iq-tag-tree.md)。

## 实验 27：四轮1，branch update数据提前输出

valid保持原br_issue，PC/tag/目标等直接输出，避免握手门控tag再进入ROB匹配。
W1/W2各19/19、run_all ALL PASS，两档perf周期相同；一次diagnose24个hash匹配。
20,430.433 µm² / 322.52 MHz，频率+0.0315%、面积-0.05585%，仅作为组合中间对照。
下一轮加入IQ tag树验证组合。完整归档`build/synth/freq_r1_branch_payload/`，无opt。

## 实验 28：四轮2，branch payload＋IQ tag树

第一轮上加入6637367的IQ tag树。W1/W2各19/19、run_all ALL PASS，两档perf周期相同。
一次diagnose24个hash匹配，20,426.671 µm² / 340.77 MHz，较本批次起点频率+5.69%、面积-0.074%。
保留组合，tag freq-r2-iq-combined-20261024，无opt。首条IQ→PRF→AGU→LSQ仍为2.875 ns到达。
第三轮继续缩短IQ年龄选择，详见四轮记录。归档`build/synth/freq_r2_iq_combined/`。

## 实验 29：四轮3，IQ年龄关系寄存

分配时对槽位保存完整32位seq的成对年龄关系，发射按更老候选集合选第一/第二名。
边界随机矩阵1,468,560项通过，W1/W2各19/19、run_all ALL PASS，IPC周期相同。
一次diagnose24个hash匹配、结构检查0 problems：20,505.024 µm² / 402.36 MHz。
相对第二轮频率+18.07%、面积+78.35 µm²，保留freq-r3-age-matrix-20261024，无opt。
新瓶颈ROB取消→LSU结果valid→CDB→ROB完成搜索。第四轮优化CDB并消除packed树UNOPTFLAT假依赖。

## 实验 30：四轮4，并行CDB组合回退

并行有效源前缀授权并拆分IQ节点；精确轮转参考四档69,797项通过，IQ1,468,560项通过。
W1/W2各19/19、run_all ALL PASS、LOCAL_STATS lint通过；correctness/perf周期相同。
一次diagnose24个hash一致：20,482.585 µm² / 385.25 MHz。较第三轮频率-4.25%、面积-22.44 µm²，
组合不保留，trial标签freq-r4-cdb-parallel-trial-20261024。CDB段0.370→0.379 ns，未获得门级改善。
最终选择ba7ceb6的402.36 MHz RTL，较起点频率+24.79%、面积+0.309%，IPC0.5221/0.4988不变。
四轮结束，保留新测试，精确恢复第三轮的RTL/报告/仿真器；无opt、未合main、未推送。

## 实验 31：ROB完成固定槽位匹配（局部改善，单项小收益回退）

固定物理槽并行匹配，保持最年轻同tag命中优先，直接one-hot写done/exception；done_now_mask直接用命中广播tag。
原RTL和trial的ROB新增边界随机均28,024/27,978项通过；W1/W2各19/19、run_all ALL PASS，全部周期相同。
一次diagnose、24个hash一致，20,487.732 µm² / 404.26 MHz，较402.36版频率+0.474%、面积-0.084%。
按既定小收益准则回退，保存freq-rob-completion-match-trial-20261024及新测试，无opt/合main/推送。
已有网表附加OpenSTA显示ROB→CDB→ROB到达2.4252→2.0403 ns，但ALU路径2.4104→2.4138 ns形成瓶颈。
后续先核查ALU运算路径，再考虑与此trial组合；当前精确恢复402.36 MHz检查点，详见ROB完成匹配实验。

## 实验 32：402 MHz检查点同源opt验收

用户授权单次opt，RTL同ba7ceb6，未采用ROB完成匹配trial。24个源码输入、7个库hash与全部时序约束一致。
diagnose 20,505.024 µm² / 402.36 MHz，opt **19,808.712 µm² / 456.12 MHz**，面积-3.40%、频率+13.36%。
最小周期2.48535→2.19238 ns，2 ns目标WNS -0.484783→-0.191631 ns；结构0 problems。
实际约7分20秒，唯一一次opt，无新增RTL；沿用W1/W2各19/19、run_all及IPC0.5221/0.4988验证。
标签freq-age-matrix-opt-20261024，完整归档build/synth/iq_age_matrix_opt_checkpoint/。未合main、未推送。
详见同源opt对比记录。

## 实验 33：ROB单槽接收（IPC小幅改善，保留候选）

基于f4a0555，新增寄存占用容量mask，前端按可接受前缀出队，ROB只分配实际前缀，不借当拍提交空间。
W1/W2各19/19、run_all ALL PASS，ROB28,094/28,038、前端293/325项通过，W1周期不变。
W2 IPC0.5221→0.5285（+1.217%）；diagnose20,535.904 µm² /401.25 MHz，较基线面积+0.151%、频率-0.274%。
IPC×Fmax+0.939%，保留ipc-rob-single-slot-20261025独立候选，不合main、不跑opt。
单槽实际接收qsort28,061/rsort23,026次，候选普通/统计版周期相同，详见rob-single-slot.md。

## 实验 34：ALU1按执行能力选候选（保留）

基于f21ac1f的单槽候选，入队寄存ALU1资格位，lane1跳过其不支持的类型，按原年龄关系选最老普通ALU。
不增加执行单元/流水级，不改lane0和registered wake；两档19/19、run_all ALL PASS，新增四档IQ参考1,245,047项通过。
W2/W1 IPC0.532763/0.499840，较上轮+0.814%/+0.200%；一次diagnose20,555.952 µm² /403.31 MHz，
频率+0.512%、面积+0.098%、IPC×Fmax+1.330%，保留ipc-lane1-select-20261025。
普通/统计版六项周期相同、24个源码hash一致，qsort实际绕过不支持项发射17,499次。
首条路径a0源tag→PRF→ALU0→结果寄存器2.419 ns，后续IPC方向仍需核对load依赖等待与唤醒，不能直接加深流水。
本轮无opt、未合main、未推送，报告归档build/synth/lane1_select_candidate/。
详见[ALU1选择实验](lane1-select.md)。

## 实验 35：ALU1受限提前wake（回退）

基于8cbb580，只有普通ALU1允许CDB当拍唤醒并进入a1，下一拍读PRF；lane0/访存仍寄存ready。
两档19/19、run_all ALL PASS，新增IQ四档1,245,951项、后端580/606项通过，普通/统计版周期相同。
W2/W1 IPC0.543730/0.507784，较403.31版+2.058%/+1.589%；一次diagnose20,569.059 µm² /383.38 MHz。
频率-4.942%、面积+0.064%、W2 IPC×Fmax-2.985%，不采纳，保留trial标签并恢复8cbb580功能RTL。
ROB取消→LSU→CDB→IQ→后端接收的2.553 ns新路径表明，即使只提前ALU1，仍会接回全局控制链。
后续不能直接扩大同拍wake范围；先证明独立lookahead资格、实际写PRF与取消/仲裁一致，或转向其他瓶颈。
完整归档build/synth/lane1_early_candidate/，24个源码hash匹配，无opt/合main/推送。
详见[提前wake试验](lane1-early-wake.md)。
