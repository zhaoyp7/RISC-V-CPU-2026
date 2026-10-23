# LSU 等待 load 的平衡最老选择（2026-10-23）

## 基线与范围

分支 `feat/freq-lsu-select-tree`，基于 `a239510` / `freq-iq-tree-20261023`。
基线 W2/W1 IPC 0.5274 / 0.5059，diagnose 20,057.360 µm² / 197.11 MHz。
基线前5条关键路径均为 ROB squash → LSU 查询级 q_seq 捕获，LSU 段约4.427 ns，
占5.0732 ns周期约87%。用户允许 IPC/面积暂时越线，正确性和频率仍为本轮重点。

本轮只修改 `lsu.sv` 的等待表最老选择与 q_seq 的数据来源，不增加寄存器或拍数。
只运行一次 diagnose，不追加 opt；候选独立保存，不合入 main、不推送。

## 实现与语义

旧结构逐项扫描 `CPU_LSQ_DEPTH` 个槽位，串行更新 best_seq/id，选出 id 后再
读取对应 seq。新结构对每个槽位独立形成候选，按平衡树归约最老 valid/seq/id：
默认16项为4层，8项为3层。无效补叶不参与选择，相等 seq 时左子树优先；
左侧物理 id 较低，因此保持旧扫描的低 id 优先规则。

候选有效条件仍为 lp_valid，排除 q/r 已持有的 id，并过滤本拍被 squash 的年龄。
根节点直接提供获胜 seq 给 q_seq，其他元数据仍按获胜 id 读取。q_accept/r_accept、
LSQ 快照、store 通道、结果容量预留与流水结构均保持原有逻辑。

等待表始终拥有 load，只有实际内存请求握手或本地结果成功入队才删除所有者；
查询阻塞继续留表重试。老 load 的预留容量、q/r 排除、反压时请求稳定和 squash
均不改变。平衡树仅减少组合选择层次，不改变候选集合或选择优先级。

## 专项验证

LSU W1/LSQ8 **292项 PASS**、W2/LSQ16 **483项 PASS**（原172/255项保留）。
新加3轮外部接口检查，不读取 RTL 内部信号：

1. 按置换 `(5*age+3)%depth` 分配物理 id，填满表；先用两笔请求占住 r/q，
   其余 load 按反向年龄入队。内存反压后放行，逐项检查请求按年龄排列，
   返回数据/tag正确，每笔仅一次。
2. 相同场景在放行前 squash 年轻一半，检查边界和旧请求全部保留、年轻请求
   不发内存请求或 CDB，完成后队列可排空。
3. 所有 seq 相同，检查 r/q 已持有项排除后，其余按物理 id 升序发射；使用
   seq 高位，避免仅低位比较恰好通过。

原有晚就绪老 load、未知/partial store 重试、内存/CDB反压、混合宽度前递、
各阶段 squash 与槽位复用测试仍通过。新测试检查额外16拍，确认没有尾部重复
结果。Yosys `proc; opt; check -assert` 检查0问题；默认构建未见 IMPLICIT /
UNDRIVEN / UNOPTFLAT / LATCH 警告。

qsort/hanoi/queens 已逐个 PASS；W1/W2 全量各19/19 PASS，全部周期与基线相同。
完整 `APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh`：ALL PASS；backend W1/W2
445 / 449项通过。两档perf周期与基线相同，IPC 0.5274 / 0.5059。
本轮唯一一次diagnose已完成，24个输入文件SHA-256均与当前RTL一致。
基线报告与仿真器已归档在 `build/synth/lsu_tree_baseline/`，本轮输出将写入
`build/synth/diagnose/`；`build/synth/opt/` 仍为 main `bc795ae` 的旧结果。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsu_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lsu_tree_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/lsu_tree_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper 仅添加 `+define+CPU_ISSUE_WIDTH=1`，不改默认配置，创建方法见本地
`prompt.md`。日志为 `/tmp/lsu-tree-{w1,w2}-test.log`、`/tmp/lsu-tree-{w1,w2}-perf.log`、
`/tmp/lsu-tree-unit.log`、`/tmp/lsu-tree-diagnose.log`；生成物不随 Git 提交。

## perf

latency=10，MAX_CYCLES=50,000,000。两档全部 correctness 和六个 perf 周期与基线相同。

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

| 指标 | IQ 双候选树 `a239510` | LSU 最老选择树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 20,057.360 | **19,980.042** |
| diagnose Fmax MHz | 197.11 | **232.04** |
| 最小周期 ns | 5.0732 | **4.3096** |
| 2 ns 目标下 WNS ns | -3.0727 | **-2.3093** |
| opt | 未运行 | **未运行** |

同模式频率 **+17.72%**、面积 **-77.318 µm²（-0.39%）**；IPC 不变，
`IPC×Fmax` 约 +17.72%。已超过200 MHz诊断阶段目标，保留独立检查点
`freq-lsu-tree-20261023`。未合入main、未推送，本轮仅一次diagnose，无opt。

面积为组合13,409.211、寄存器5,409.880、SRAM1,160.951 µm²；后两项与基线
相同，符合不新增流水寄存器的范围。LSU自身（不含LSQ）为1,814.802 µm²，
较基线减少约70.9 µm²；含LSQ为4,452.805 µm²。不同模块的映射/缓冲有小幅
变化，总面积变化应以整核报告为准。

报告在 `build/synth/diagnose/{report.txt,report.json,timing.rpt}`，基线报告与仿真器
为 `build/synth/lsu_tree_baseline/`。`build/synth/opt/` 仍为main `bc795ae`旧结果，
不能作为本候选opt。

## 新瓶颈与下一步

报告前5条关键路径已转为 **LSQ已提交store选择 → 写地址输出 → AXI写请求捕获**，
不经过本轮load等待选择或IQ/PRF。第一条为
`u_backend/u_lsu/u_lsq/_51963_/QN → u_mem/u_axi/_8206_/D`。
网表确认LSQ出口为 `drain_addr[29]`，进入AXI的对应端口为 `wr_addr[29]`。

累计到达时间：起点QN **0.06739 ns**、LSQ出口 **4.1810 ns**、AXI捕获端
**4.2540 ns**。LSQ段约 **4.1136 ns**，占4.3096 ns周期约95%；AXI段约0.073 ns。
这定位到store排空通路，不能将其误认为此前已拆级的load查询通路。

`lsq.sv` 的store drain仍线性扫描16项，选 `valid && is_store && committed && !sent`
的最老seq，再按id读取地址/数据/掩码。下一阶段优先将这一路改为平衡最老选择，
先不增加流水拍数；必须保持只发送已提交store、按序发送、内存反压及sent FIFO
与B响应释放的对应关系，重点测试物理槽位复用与多笔在途store。

本轮到此结束，不追加opt，也不继续叠加store路径改动。
