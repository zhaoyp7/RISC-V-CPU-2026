# 频率实验记录

> 最新独立频率候选见实验 9：diagnose 107.56 MHz，W2 IPC 0.5727，未跑 opt、未合入 main。

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
