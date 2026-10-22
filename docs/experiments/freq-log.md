# 频率实验记录

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

## 当前决策

- `feat/freq-recovery` 保留为 WIP 分支（commit `63a06cf`），不合并到 `main`。
- `main` 包含 `36e4302` 的 complete FIFO 修复；默认 IPC 恢复为 **0.6380**，
  W=2 19/19、`run_all` ALL PASS。
- 四次频率实验：
  - squash 两级化：Fmax +4.0%，IPC -1.8%，不达标；
  - CDB 打一拍：Fmax +3.2%，IPC -4.4%，不达标；
  - complete FIFO 修复：正确性收益，保留；
  - IQ/PRF 分开：Fmax **+29.8%**，但 6 个 case 死锁，需要 replay 重构，
    不合并。
- IQ/PRF 分开是唯一一个 Fmax 收益超过 20% 的实验，证明方向正确；下一步
  应设计 **issue replay / 非阻塞 issue queue**，而不是继续加局部旁路。

## 停止后的候选方向

1. **先修 complete FIFO / ROB squash 竞态**：这是 CDB 实验暴露出的正确性
   隐患，也可能影响现有设计在更激进时序下的稳定性。
2. **分支预测**：qsort/median 误预测仍是 IPC 的主要损失，带 GHR 快照的
   gshare + RAS 是低风险 IPC 方向。
3. **接受当前性能，转向报告/参数化展示**：当前 W=2 IPC 0.638、W=1 0.5688，
   功能全绿；若频率无法突破，继续投入的性价比需要重新评估。
4. **D-Cache 仍暂缓**：计数器显示 load 阻塞已不是主要矛盾，且面积/频率
   代价高。
