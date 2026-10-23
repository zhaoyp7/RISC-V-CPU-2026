# LSQ 匹配快照与平衡选择树（2026-10-23）

## 基线与验收

独立分支 `feat/freq-lsq-snapshot`，基于 load 查询分级检查点 `eb36c43`。
基线 W2 / W1 IPC 0.5419 / 0.5205，diagnose 19,706.842 µm² / 156.31 MHz。
基线第一条路径 `ROB → LSU → LSQ → LSU`，LSQ 查询约占 4.6 ns。
本轮目标为正确性全绿并提高诊断频率，期望接近 200 MHz；未测量前不承诺。
用户允许 IPC / 面积暂时越线，本轮仅运行一次 diagnose，不追加 opt。

## 实现

```text
load 等待表 → q 地址/元数据 → LSQ 并行比较 → 匹配快照 + r 元数据
                                               ↓
                       内存请求/本地结果 ← 平衡选择最年轻的同字 store
store → LSQ 预填/完整填入 → 提交/写完成/释放（与查询独立）
```

- 第一级独立比较每个 store 的年龄和字地址，保存匹配位、未知地址归约、
  完整写标志，以及每个候选的 seq 和数据。
- 第二级使用平衡树选择 seq 最大的匹配 store；seq 相同时保留低 slot 优先。
  更老 store 地址未知时阻塞；最年轻匹配 store 非整字写也阻塞。
- 数据、seq、完整写标志与匹配位同时保存，避免只保存 slot id 后读取已释放
  或复用槽位的内容。store 完成或槽位复用不会改变被反压的响应。
- LSQ 增加请求 ready、响应 valid/ready 和显式 query_flush。
  新请求与旧响应消费/flush 同拍发生时，新快照优先。
- LSU 的 r 级保存对应 load 的 id、seq、tag、地址、size、unsigned、illegal。
  MD/RQ 与内存端只使用 r 级元数据；q 级可同时准备下一条查询。
- 等待表排除 q/r 中的 id，直到内存握手或本地结果成功入队才删除所有者。
  未知/partial 阻塞时释放响应并保留所有者重试，store 始终独立推进。
- 反压时同时保持快照和 r 元数据；squash 分别取消年轻 q/r。
  被 squash 的 r 与可保留的 q 同拍替换时，新快照与新 r 一起保留。
- 继续使用在途请求加结果数的容量预留，防止 CDB 停顿造成结果覆盖。
- LOCAL_STATS 的 LSQ 查询分类改为统计实际消费且未 flush 的快照，避免把
  下一条请求与上一条响应混计。

## 验证与结果

- 直接 LSQ：深度 8 / 16 分别 151 / 207 项通过，覆盖年龄筛选与乱序物理
  slot、未知/partial 保守重试、反压稳定、消费/flush 与捕获同拍、释放复用。
- LSU：W1/LSQ8 与 W2/LSQ16 分别 172 / 255 项通过；新加连续混合访问宽度、
  offset、signedness、tag 的前递，验证 q/r 不串线。
- qsort、hanoi、queens 已逐个 PASS；W1/W2 官方全量各 19/19 PASS。
- 完整 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh`：ALL PASS；backend
  W1/W2 445 / 449 项通过。构建无 IMPLICIT / UNDRIVEN / UNOPTFLAT / LATCH 警告。
- W2 / W1 IPC 为 0.5274 / 0.5059，分别比基线下降约 2.7% / 2.8%。
- 本轮唯一一次 diagnose 已完成，报告的 24 个输入文件 SHA-256 均与当前 RTL 一致。
- 原报告与仿真器归档在 `build/synth/lsq_snapshot_baseline/`。
- 本候选尚无 opt 结果，未合入 main、未推送。

## perf

latency=10，MAX_CYCLES=50,000,000；W1/W2 各 19/19，完整 run_all ALL PASS。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,827 | 0.3905 | 18,439 | 0.3775 |
| perf_multiply | 21,722 | 23,161 | 0.9379 | 28,938 | 0.7506 |
| perf_qsort | 139,900 | 375,975 | 0.3721 | 383,141 | 0.3651 |
| perf_rsort | 195,719 | 362,998 | 0.5392 | 355,734 | 0.5502 |
| perf_towers | 5,278 | 12,379 | 0.4264 | 12,411 | 0.4253 |
| perf_vvadd | 4,524 | 6,584 | 0.6871 | 6,536 | 0.6922 |
| **GEOMEAN** | | | **0.5274** | | **0.5059** |

## diagnose 与保留决定

| 指标 | load 查询分级 `eb36c43` | LSQ 匹配快照 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5419 / 0.5205 | 0.5274 / 0.5059 |
| diagnose 面积 µm² | 19,706.842 | **20,093.751** |
| diagnose Fmax MHz | 156.31 | **190.80** |
| 最小周期 ns | 6.3975 | **5.2412** |
| 2 ns 目标下 WNS ns | -4.3965 | **-3.2402** |
| opt | 未运行 | **未运行** |

同模式 Fmax **+22.1%**、面积 **+386.909 µm²（+2.0%）**；W2 IPC -2.7%，
`IPC×Fmax` 约 **+18.8%**。未达到原先期望的 200 MHz，但通过正确性和频率
收益验收，保留独立检查点 `freq-lsq-snapshot-20261023`，不合入 main、不推送。

面积：组合 13,522.921、寄存器 5,409.880、SRAM 1,160.951 µm²。
LSQ 2,638.003 µm²（总面积 13.13%），相对基线 LSQ 增加约 396.0 µm²；
LSU 含 LSQ 为 4,523.722 µm²（22.51%），PRF 12.51%、IQ 9.54%、ROB
13.00%、前端含 BPU/I$ 24.27%。父子模块占比有重叠，不能相加。

报告：`build/synth/diagnose/{report.txt,report.json,timing.rpt}`；上一版与仿真器
为 `build/synth/lsq_snapshot_baseline/`。`build/synth/opt/` 仍是 main `bc795ae`
的旧结果，不能称为本候选的 opt。后续仍按阶段检查点安排 opt。

## 新瓶颈与下一步

第一条路径已经不经过 LSU/LSQ/PRF：

```text
ROB squash_seq → IQ squash 比较 → 双 lane 最老候选选择 / out_seq
              → backend lane1 squash 门控 → a1_uop_q 捕获
```

报告前三条路径均从 `u_core/u_rob/_56759_/QN` 出发，终点为 backend 的
`_19897_ / _19898_ / _19899_`。第一条终点反相输出对应 `a1_uop_q[107]`。
映射网表中 IQ 第一个单元输入为 `squash_seq[29]`，出口为 `out_seq[55]`。
累计到达：IQ 入口 **0.6066 ns**、出口 **4.7830 ns**、捕获端 **5.1960 ns**。
IQ 内部约 **4.1764 ns**，占 5.2412 ns 周期约 **80%**。

下一阶段优先优化 IQ，而非继续给 LSQ 增级：把逐项比较最老候选、再排除
lane0 重新选 lane1 的串行结构改为平衡候选选择，尽量一次求出两个 lane
需要的候选。必须保留 lane0 store 地址预填、lane1 排除 lane0、各 lane 独立
ready/未接收保留和 squash 同拍不发年轻项的语义。先改选择结构再测 diagnose；
如仍由 squash 控制主导，再评估取消/恢复控制分级。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lsq_snapshot_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/lsq_snapshot_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper 仅添加 `+define+CPU_ISSUE_WIDTH=1`，不修改默认配置；创建方法见
本地 `prompt.md` 的 W1 构建说明。结果日志为 `/tmp/lsq-snapshot-{w1,w2}-test.log`、
`/tmp/lsq-snapshot-{w1,w2}-perf.log`、`/tmp/lsq-snapshot-unit.log` 和
`/tmp/lsq-snapshot-diagnose.log`；日志和 build 产物不随 Git 提交。
