# CDB 唤醒与 IQ 选择隔拍（频率优先实验，2026-10-23）

## 目标与基线

用户已允许为了尽快提高频率，暂时放宽 IPC 和面积限制。当前阶段以正确性为
硬约束，以频率为首要筛选指标，IPC / 面积继续如实测量；不再把 IPC 0.60
或面积 18k 作为本轮候选的硬性淘汰线。

实验分支 `feat/freq-registered-wake`，基于 `bc795ae` / tag
`alu-shared-mul-20261023`。main 保持该已完成 opt 的检查点：
W2 IPC 0.6084、W1 IPC 0.5759；diagnose 18,603.442 µm² / 99.38 MHz；
opt 17,895.831 µm² / 115.12 MHz。

按用户要求，本轮只做功能、perf 和 diagnose，不运行 opt；待积累到阶段
检查点再统一运行一次 opt。候选暂不合入 main，避免把未测 opt 的结果与
main 的旧报告混淆。

## 改动与时序依据

原关键路径包括 `CDB → IQ select → PRF/bypass → LSU/LSQ`。

- IQ 的普通 issue 和 store address-only prefill 都只按寄存的 src ready
  选择，不再使用本拍 CDB 的组合 tag_hit。
- CDB 本拍在时钟沿写 PRF、更新 IQ ready；下一拍选择时 PRF 数据已落地。
- 删除 backend 六个操作数读口的当前拍 CDB 数据旁路，直接读 PRF。
- a0/a1 在选择后还会再缓冲一拍；寄存后的 ready 已保证所需操作数可读。
- dispatch、skid、IQ 入队的同拍 wake 匹配仍保留，避免漏掉唯一一次广播。
- store address-only 继续留在 IQ，full store 才删除；load/store 继续保持
  IQ→LSU 握手，不进入 a0/a1，不改变访存请求所有权和程序顺序。

两项 RTL 改动配套验证；不能只移除操作数旁路却保留同拍 wake→select。
代价是依赖指令可能多等一拍，预期 IPC 会下降，是否保留取决于实测频率收益。

## 验证

- IQ 新增唤醒当拍不可弹出、store 地址与数据分步唤醒/预填、squash 优先、
  双 CDB 同拍唤醒测试；W1/R1、W2/R1、W2/R2 分别 61 / 60 / 64 项通过。
- backend W1/W2 分别 445 / 449 项通过。
- qsort、hanoi、queens 逐个通过后，标准 W1/W2 全量各 19/19 PASS。
- 默认构建与 IQ/backend 测试未出现 IMPLICIT / UNDRIVEN 警告。
- 首次 run_all 在未修改的 ALU 算术测试处遇到 Verilator 内部错误
  `attempted to destroy locked Thread Pool`。同一二进制串行重跑通过；随后
  将纯组合 ALU 测试设为显式单线程 context，并串行重跑完整 suite。
- 显式单线程 ALU context 下的完整 suite 重跑：**ALL PASS**。

## perf（latency=10，MAX_CYCLES=50,000,000）

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 16,368 | 0.4253 | 16,980 | 0.4100 |
| perf_multiply | 21,722 | 22,771 | 0.9539 | 28,548 | 0.7609 |
| perf_qsort | 139,900 | 341,290 | 0.4099 | 349,447 | 0.4003 |
| perf_rsort | 195,719 | 330,683 | 0.5919 | 326,568 | 0.5993 |
| perf_towers | 5,278 | 11,404 | 0.4628 | 11,495 | 0.4592 |
| perf_vvadd | 4,524 | 5,841 | 0.7745 | 5,796 | 0.7805 |
| **GEOMEAN** | | | **0.5727** | | **0.5471** |

W2 IPC 相对 0.6084 约 -5.9%，W1 相对 0.5759 约 -5.0%。

## 综合

| 版本 | W2 / W1 IPC | diagnose 面积 / MHz | opt 面积 / MHz |
| --- | ---: | ---: | ---: |
| main `bc795ae` | 0.6084 / 0.5759 | 18,603.442 / 99.38 | 17,895.831 / 115.12 |
| 隔拍唤醒候选 | 0.5727 / 0.5471 | **18,542.177 / 107.56** | **未运行** |

原 main 报告和仿真器已备份到 `build/synth/registered_wake_baseline/`。
`build/synth/opt/` 仍是 main 的旧结果，不得当作本轮候选 opt。
本轮 diagnose 使用标准 `make synth MODE=diagnose`，输出在
`build/synth/diagnose/report.txt`。

## 后续决策

diagnose 与完整 suite 已结束，报告输入 SHA-256 与候选 RTL 一致。
同模式 Fmax +8.2%，面积 -61.265 µm²（-0.3%），W2 IPC -5.9%；
`IPC×Fmax` 约 +1.9%，不能把小幅吞吐趋势收益夸大为已接近 300 MHz。

保留为后续分级起点，tag `freq-registered-wake-20261023`，提交在独立分支，未合入 main、未推送。
没有运行 opt；main 仍保留上一版已完成 opt 的 `bc795ae`。

候选关键路径：`ROB → IQ → PRF → LSU/LSQ`，CDB 已不在第一条关键路径中。
累计到达时间：IQ 入口 0.602 ns、出口 3.015 ns，PRF 出口 3.348 ns，
LSQ 入口 3.986 ns、出口 8.505 ns，LSU 终点 9.240 ns；
最小周期 9.2969 ns。下一轮需要继续缩短 IQ / LSQ 段，而不是仅调整
唤醒旁路。用户已允许 IPC / 面积暂时越线，后续可以评估更深的选择、读口或
访存分级，但必须先设计请求所有权 / retry，避免旧 load-store 死锁。
继续尊重降低 opt 频率的要求，不追加 opt。

后续 load 查询分级实验保留了本轮诊断副本，位于
`build/synth/load_query_baseline/diagnose_report.txt`、`diagnose_report.json`。
默认 diagnose 目录会被新实验更新，历史结果以此副本和本页检查点为准。
