# IQ 双候选平衡选择树（2026-10-23）

## 基线与范围

分支 `feat/freq-iq-select-tree`，基于 `5c2b07c` / `freq-lsq-snapshot-20261023`。
基线 W2/W1 IPC 0.5274 / 0.5059，diagnose 20,093.751 µm² / 190.80 MHz。
第一条路径为 ROB squash_seq → IQ → backend a1 捕获；IQ 段约4.1764 ns，
占5.2412 ns周期约80%。用户允许 IPC/面积暂时越线，本轮仍以正确性和频率为主。
只运行一次 diagnose，不追加 opt；main 保持 `bc795ae`，候选独立保存。

本轮只调整 `issue_queue.sv` 的组合候选选择及 seq 输出，不增加寄存器或拍数，
不改变已寄存的 ready/CDB 唤醒、dispatch、store 预填、按 lane 握手或 squash。

## 选择结构与语义

旧结构对每个 lane 扫描 D 项，串行更新 best_seq/best_idx；lane1 还需要等待
lane0 决定 chosen 后再次扫描。新结构使用平衡树同时归约三种摘要：

- 完整 ready 候选的第一名 `first` 和第二名 `second`；
- 仅地址就绪且尚未预填的 store 的最老候选 `prefill`。

每个节点先比较左右第一名；第二名必为“胜方第二名”和“败方第一名”中较老者。
两种胜负情况的第二名比较并行计算，再由第一名比较选择，避免 lane0 选完后
重新扫描整队列。候选仅携带 valid、seq 和 slot，不携带整条 uop。

| lane0 选择 | lane1 选择 |
| --- | --- |
| 最老完整候选 | 完整候选第二名 |
| 更老的 store 地址预填 | 完整候选第一名 |

lane0 在完整第一名和 prefill 第一名之间比较；完整/预填集合互斥，lane1 不可能
重复选择 lane0。树的左右子树分别覆盖低/高物理 slot，等 seq 时左侧优先；
最终完整/预填二选一同时比较 slot，保持旧扫描的低 slot 优先规则。

输出 seq 直接沿候选树传递，省去获胜 slot 再读取 seq 数组的选择层；uop 仍
由获胜 slot 读取。D 非2的幂时补无效叶；IW=1/2 使用树，IW>2 保留通用原扫描。
ready 不参与选择，未接收的 lane 留在 IQ；预填握手只标记 addr_sent，不删除 store。
CDB 本拍只更新源 ready，下一拍选择；squash 的年轻项仍在选择前屏蔽。

综合工具不能可靠解析 unpacked struct 数组字段，最终使用扁平41位候选：
valid[40]、seq[39:8]、slot[7:0]。Yosys `proc; opt; check -assert` 检查0问题；
不把仿真通过当作综合可用的证明。

## 专项验证

旧 IQ 行为测试 W1/R1、W2/R1、W2/R2：61 / 60 / 64 项通过。
新测试使用独立 slot scoreboard：将可用项按 `(seq, slot)` 排序，再按原语义逐
lane 选择；逐拍比较 valid、预填标志、seq、整条 uop、count/free_count 和 ready。
参考模型不使用选择树，不读取 RTL 内部信号。

| W / CDB / IW / D | 周期 | 检查数 | 结果 |
| --- | ---: | ---: | --- |
| 2 / 2 / 1 / 8 | 40,007 | 226,857 | PASS |
| 1 / 1 / 2 / 8 | 40,007 | 297,813 | PASS |
| 2 / 2 / 2 / 8 | 40,007 | 307,779 | PASS |
| 2 / 2 / 2 / 6 | 40,007 | 301,319 | PASS |
| 2 / 2 / 2 / 16 | 40,007 | 332,349 | PASS |

新对拍共200,035周期、1,466,117项检查，覆盖独立 lane 反压、store 预填不重复、
源分步唤醒、dispatch-wake 旁路、同拍 squash/dispatch、边界年龄保留、相同 seq、
高位 seq 和物理槽位复用。旧 IQ fixture 也改用单线程 VerilatedContext，避免无须
并行的测试创建大量仿真线程。所有配置接入原有 `test/issue_queue_test/run.sh`。

qsort/hanoi/queens 已逐个 PASS；W1/W2 全量各19/19 PASS，全部正确性周期与基线
逐项相同。perf 两档六个 benchmark 周期和 IPC 均与基线逐项相同。
完整 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh`：ALL PASS；backend W1/W2
445 / 449 项、LSU W1/W2 172 / 255 项均通过。默认构建无 IMPLICIT / UNDRIVEN /
UNOPTFLAT / LATCH 警告；本轮唯一一次 diagnose 已完成，24个输入 hash 与 RTL 一致。

基线报告与仿真器已归档在 `build/synth/iq_tree_baseline/`；本轮输出将位于
`build/synth/diagnose/`。`build/synth/opt/` 仍是 main 的旧结果。

## perf

latency=10，MAX_CYCLES=50,000,000。两档六个 benchmark 周期均与 `5c2b07c` 相同。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,827 | 0.3905 | 18,439 | 0.3775 |
| perf_multiply | 21,722 | 23,161 | 0.9379 | 28,938 | 0.7506 |
| perf_qsort | 139,900 | 375,975 | 0.3721 | 383,141 | 0.3651 |
| perf_rsort | 195,719 | 362,998 | 0.5392 | 355,734 | 0.5502 |
| perf_towers | 5,278 | 12,379 | 0.4264 | 12,411 | 0.4253 |
| perf_vvadd | 4,524 | 6,584 | 0.6871 | 6,536 | 0.6922 |
| **GEOMEAN** | | | **0.5274** | | **0.5059** |

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/issue_queue_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/iq_tree_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/iq_tree_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper 只添加 `+define+CPU_ISSUE_WIDTH=1`，不改默认配置，创建方法见本地
`prompt.md`。日志为 `/tmp/iq-tree-{w1,w2}-test.log`、`/tmp/iq-tree-{w1,w2}-perf.log`、
`/tmp/iq-tree-unit.log`、`/tmp/iq-tree-diagnose.log`；生成物不随 Git 提交。

## diagnose 与保留决定

| 指标 | LSQ 快照 `5c2b07c` | IQ 双候选树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 20,093.751 | **20,057.360** |
| diagnose Fmax MHz | 190.80 | **197.11** |
| 最小周期 ns | 5.2412 | **5.0732** |
| 2 ns 目标下 WNS ns | -3.2402 | **-3.0727** |
| opt | 未运行 | **未运行** |

同模式 Fmax **+3.31%**，总面积 **-36.392 µm²（-0.18%）**；IPC 不变，
`IPC×Fmax` 约 +3.31%。收益较小，仍未达到200 MHz，但没有增加流水延迟或
测得 IPC 代价、面积也略降，因此保留独立检查点 `freq-iq-tree-20261023`。
未合入 main、未推送；只跑一次 diagnose，不追加 opt。

IQ 自身面积 1,916.949 → **1,851.354 µm²（-3.42%）**；总寄存器面积仍为
5,409.880 µm²，SRAM仍为1,160.951 µm²，组合面积13,486.529 µm²。
不同模块的映射/缓冲也有小幅变化，不能把 IQ 面积减少直接当作整核减少。

本轮报告在 `build/synth/diagnose/{report.txt,report.json,timing.rpt}`，基线报告和
仿真器在 `build/synth/iq_tree_baseline/`。`build/synth/opt/` 仍为 main `bc795ae`
旧结果，不能作为本候选 opt。

## 新瓶颈与下一步

报告前5条关键路径均为 `ROB → backend → LSU 查询级捕获`，不经过 IQ、PRF
或 LSQ。第一条：`u_core/u_rob/_57513_/QN → u_backend/u_lsu/_36249_/D`。
映射终点对应 `q_seq[13]`（另一路对应 `q_seq[15]`）；进入 LSU 的第一个单元
输入为 `squash_seq[15]`。累计到达时间为 LSU 入口 **0.5900 ns**、捕获端
**5.0170 ns**，LSU 段约 **4.4270 ns**，占5.0732 ns周期约87%。

结合 q_seq 的写入条件，下一轮应针对等待 load 表的最老选择与 q 捕获门控：
`lsu.sv` 仍线性扫描16项 lp_valid/lp_seq，逐项比较最老 seq，再用选中 id
读取元数据；squash 过滤也进入该选择链。可先改成平衡最老选择，并直接传递
获胜 seq，保持 q/r 中 id 排除、晚就绪老 load 的预留容量、阻塞重试及 squash
语义。还需按时序报告区分选择与 q_accept 门控代价，不能把整个4.43 ns都归为
年龄比较，也不因新第一条路径不经过 IQ 就断言其余路径都已有充足余量。

本轮到此结束，不继续叠加 LSU 改动，不追加第二次综合。
