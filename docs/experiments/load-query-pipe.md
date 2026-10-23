# load 等待表与查询寄存器（2026-10-23，频率优先）

## 基线与范围

分支 `feat/freq-load-query-pipe`，基于 `819ddd1`（隔拍唤醒）。
基线 W2/W1 IPC 0.5727 / 0.5471，diagnose 18,542.177 µm² / 107.56 MHz；
基线自身未跑 opt。main 仍为 `bc795ae`，其 115.12 MHz 来自 opt，不能与
本轮 diagnose 直接比较。用户允许 IPC / 面积暂时越线，本轮不跑 opt。

## 实现与请求归属

完整设计见 [访存查询分级](../plan/memory-query-pipeline.md)。
本轮仅修改 `lsu.sv`，增加按 LSQ id 预留的 load 等待槽位，以及查询寄存器：

```text
IQ / PRF / AGU -> load 等待表 -> 按 seq 选择 -> 查询寄存器 -> LSQ 查询 / 请求
store ---------> LSQ 地址预填 / 数据填入 ------------------> 提交后写内存
```

- load 接收后等待表持有请求，内存握手或本地结果成功入队后才删除。
- 查询副本所在 id 不会被再次选中；消歧阻塞释放查询级，保留表项重试。
- LSQ id 提供容量预留，年轻 load 不能挤占晚就绪老 load 的位置；等待表按
  程序 seq 选择，store 可以独立填 LSQ，避免旧 load-store 循环等待。
- q 级使用捕获的地址、tag、seq、id、size、unsigned、illegal，MD/RQ 不再
  依赖本拍 IQ 输入字段。squash 清待执行年轻项，并按原机制丢弃在途响应。
- 在途请求与结果 FIFO 合计预留 LDQ_DEPTH 个槽，CDB 暂停时也不覆盖结果。
- LSQ 内部匹配与最年轻 store 选择本轮仍为组合；本轮先切 AGU 与查询。

## 测试

旧 LSU 测试把 issue_ready 等同于执行完成，现改为验证“接收入等待表后，
阻塞时不发请求，条件满足后自动继续且不重复发射”；未放宽数据、顺序和
squash 的验收。

- LSU W1/LSQ8：144 项 PASS；W2/LSQ16：227 项 PASS。
- 多条年轻 load 阻塞时，晚就绪老 load 仍能进入并返回，store 预填 / 数据
  填入均推进，年轻 load 正确前递完成且无额外读请求。
- 内存反压地址稳定；查询前、等待 ready 时、请求已发后的 squash 均覆盖。
- signed/unsigned 字节前递及非法 load 元数据正确。
- 12 笔 load、8 个结果槽，CDB 停顿后恢复，全部数据正确且无重复、无覆盖。
- backend W1/W2：445 / 449 项 PASS；qsort/hanoi/queens 逐个 PASS。
- 标准 W1/W2 correctness：各 19/19 PASS。
- `sh test/run_all.sh`：ALL PASS。
- 默认构建及 LSU/backend 测试无 IMPLICIT / UNDRIVEN 警告。

## perf（latency=10，MAX_CYCLES=50,000,000）

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,340 | 0.4014 | 17,952 | 0.3878 |
| perf_multiply | 21,722 | 23,031 | 0.9432 | 28,808 | 0.7540 |
| perf_qsort | 139,900 | 364,107 | 0.3842 | 371,952 | 0.3761 |
| perf_rsort | 195,719 | 351,473 | 0.5569 | 340,185 | 0.5753 |
| perf_towers | 5,278 | 12,054 | 0.4379 | 12,084 | 0.4368 |
| perf_vvadd | 4,524 | 6,336 | 0.7140 | 6,289 | 0.7194 |
| **GEOMEAN** | | | **0.5419** | | **0.5205** |

相比隔拍唤醒基线，W2 IPC 约 -5.4%，W1 约 -4.9%；按用户授权先记录代价，
不以旧 IPC / 面积门槛直接淘汰。

## 综合与决定

| 版本 | W2 / W1 IPC | diagnose 面积 / MHz | opt |
| --- | ---: | ---: | --- |
| 隔拍唤醒 `819ddd1` | 0.5727 / 0.5471 | 18,542.177 / 107.56 | 未运行 |
| load 查询分级候选 | 0.5419 / 0.5205 | **19,706.842 / 156.31** | **未运行** |

原诊断报告与仿真器保留于 `build/synth/load_query_baseline/`；本轮输出为
`build/synth/diagnose/`。报告输入 SHA-256 与本轮 RTL 已核对一致。

同模式 Fmax +45.3%，面积 +1,164.665 µm²（+6.3%），W2 IPC -5.4%；
`IPC×Fmax` 约 +37.5%。保留为新频率检查点 `freq-load-query-pipe-20261023`，
未合入 main、未推送。最小周期 6.3975 ns，2 ns 目标下 WNS
-4.3965 ns；已超过 150 MHz 诊断阶段目标。

第一条关键路径：`ROB → LSU → LSQ → LSU`，不再经过 IQ/PRF。
累计到达时间：LSU 入口 0.590 ns、LSQ 入口 1.100 ns、出口 5.695 ns、
LSU 终点 6.337 ns。LSQ 段约 4.6 ns，下一轮可继续切分其匹配 / 前递选择。

本轮仅一项候选、一次 diagnose，没有追加 opt。
`build/synth/opt/` 仍为 main 的旧结果，不能当作本候选的 opt；不追加 opt。
