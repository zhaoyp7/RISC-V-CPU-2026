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

## 实验 3：CDB 仲裁输出打一拍（已回滚）

改动：在 `backend_ooo` 把 `u_cdb` 的 `cdb_out` 寄存后再广播，试图切断
`u_lsu → u_cdb → u_backend` 的组合路径。

结果：

- W=2 correctness：19/19 PASS
- perf_median/multiply 正常
- **perf_qsort 死锁**，50M cycles 超时

死锁定位：

- ROB 头部是一个 branch：`PC=0x000000b0, dest=23, resolved=1, done=0`
- trace 显示 `[CF_PUSH] tag=23` 之后只有 `[CF_POP]`，没有 `[COMPLETE]`
- 也就是 complete FIFO 项被弹出，但没有广播到 ROB；ROB 头部永远等
  `complete`
- 这说明 CDB 打一拍改变了完成/恢复时序，暴露了 complete FIFO 与 ROB
  squash 之间更深层的竞态；不是简单的频率优化

决策：**回滚 CDB 改动，删除 `feat/freq-cdb` 分支**。不再在同一层继续
堆寄存器。

## 当前决策

- `feat/freq-recovery` 保留为 WIP 分支（commit `63a06cf`），不合并到 `main`。
- 两次频率实验：
  - squash 两级化：Fmax +4.0%，IPC -1.8%，不达标；
  - CDB 打一拍：qsort 死锁，回滚。
- 按要求触发停止条件（连续实验 Fmax 提升 <20%），下一步需要重新选方向，
  不再盲目继续频率流水化。

## 停止后的候选方向

1. **先修 complete FIFO / ROB squash 竞态**：这是 CDB 实验暴露出的正确性
   隐患，也可能影响现有设计在更激进时序下的稳定性。
2. **分支预测**：qsort/median 误预测仍是 IPC 的主要损失，带 GHR 快照的
   gshare + RAS 是低风险 IPC 方向。
3. **接受当前性能，转向报告/参数化展示**：当前 W=2 IPC 0.638、W=1 0.5688，
   功能全绿；若频率无法突破，继续投入的性价比需要重新评估。
4. **D-Cache 仍暂缓**：计数器显示 load 阻塞已不是主要矛盾，且面积/频率
   代价高。
