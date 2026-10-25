# ROB单槽接收与前端部分出队（2026-10-25）

## 基线与接收机会

用户授权在主线统计之后继续下一步。分支feat/ipc-rob-single-slot，基于f4a0555，
功能RTL同ba7ceb6。baseline diagnose 20,505.023900 µm² / 402.357564 MHz，
opt 19,808.712260 µm² / 456.124722 MHz，W2/W1 IPC0.522108164152558/0.4988444806718703。
基线两模式完整报告与仿真器在build/synth/rob_single_slot_baseline/。

先以独立input-only ADMISSION监视器复测原RTL，六项普通/统计版答案及周期完全一致。
只统计ROB剩一槽、backend允许且非恢复/redirect、存在可分配物理tag的机会：

| benchmark | 自然单条 | FQ有至少两条 | 双条且当拍无提交 |
| --- | ---: | ---: | ---: |
| median | 146 | 2,912 | 2,268 |
| multiply | 84 | 1,404 | 1,176 |
| qsort | 2,635 | 70,827 | 54,905 |
| rsort | 0 | 101,432 | 77,806 |
| towers | 0 | 1,991 | 1,562 |
| vvadd | 99 | 982 | 295 |

因此只按当前自然单条请求放宽ready不能覆盖大多数机会，需要允许FQ输出队首的一条并保留其后缀。
这些是容量/请求状态计数，并不等于可以回收的周期或保证的IPC增益。
原始数据和当时监视器快照在build/rob_single_slot_probe/，功能源码hash与基线一致。

## 改动与不变量

ROB新增in_capacity[W]，由寄存count给出低位连续可接收mask；in_ready只表示非恢复/redirect且至少有一槽。
实际lane接收为in_valid && in_ready && in_capacity。n_valid、分配写和alloc_rob_idx均按容量过滤。
容量不借当拍commit释放，满队列即使当拍提交也等到下一拍复用。

core将容量送到frontend.decode_capacity。前端pop_n是FQ现有条数与容量的较小前缀；
dec_valid和真正清除/前进的槽位均按pop_n处理，pop_credit只统计实际被rename接收的条数。
关键修正是原来清槽循环按fq_count的判断改为pop_n，避免弹出一条却清掉两条有效位。
第二条uop和预测快照保持在FIFO，下一次从它开始；无额外搬移或新寄存级。

rename接口及其tag、RAT、LSQ pointer逻辑不改，输入已经是正确前缀；ROB、rename和dispatch共享实际接收mask。
容量只依赖寄存count，不依赖ren_fire，避免ready由已门控valid反向计算产生组合环。
W1的容量/握手退化为原单槽协议。外部顶层接口、配置、filelist、Makefile及综合脚本不改。

## 验证

新增ROB容量边界：仅剩一槽时只收lane0、满队列同拍commit不借空间、释放沿后绕回复用。
独立有序队列参考按旧占用的剩余容量限定接收前缀，逐拍比对容量与提交/恢复。
W1/W2为28,094/28,038项通过。保留全部重复tag与回绕测试。

前端增加容量0/1/2切换、rename反压、保留第二条PC/非零taken预测快照、先单后双及部分消费后的redirect。
W1/W2专项293/325项通过。完整run_all为ALL PASS（完整矩阵运行时前端324项，之后强化非零预测专项325项）。
qsort→hanoi→queens依次通过，W1/W2 correctness各19/19，配置与LOCAL_STATS lint通过。
无新增IMPLICIT/UNDRIVEN/LATCH，保留IQ树既有两条UNOPTFLAT假依赖提示。

两档perf已测，W2 IPC **0.5284625454164975**，较主线+1.217%；W1仍0.4988444806718703，六项周期相同。
一次diagnose已完成，24个输入hash一致，结构检查0 problems。以下与同模式基线比较；候选没有opt数据。

## 复现与归档

本轮使用独立build及SYNTH_OUT，默认main仿真器与两模式报告保持原样。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/rob_single_slot_w2
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/rob_single_slot_w2 SIM="$REPO_ROOT/build/rob_single_slot_w2/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/rob_single_slot_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/rob_single_slot_w1 SIM="$REPO_ROOT/build/rob_single_slot_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/rob_single_slot_candidate
```

候选归档build/synth/rob_single_slot_candidate/，日志/tmp/rob-single-slot-*.log。
功能RTL稳定期间综合顺序运行；本轮不运行opt、不合main、不推送。

## 实测、复核与保留决定

| 指标 | main基线diagnose | 单槽候选diagnose |
| --- | ---: | ---: |
| 面积 µm² | 20,505.023900 | 20,535.904340 |
| Fmax MHz | 402.357564 | 401.253918 |
| 最小周期 ns | 2.485351562 | 2.492187500 |
| 2 ns目标WNS ns | -0.484783 | -0.491852 |
| W2 IPC | 0.522108164153 | 0.528462545416 |
| W1 IPC | 0.498844480672 | 0.498844480672 |

IPC+1.217%，频率-0.274%，面积+30.880 µm²（+0.151%）。
诊断IPC×Fmax+0.939%。保留为独立IPC候选，标签ipc-rob-single-slot-20261025；不合main、不跑opt。
这是小幅改进，median略慢；不能把单槽机会数或实际接收次数直接折算成节省周期。

| benchmark | main cycles | 候选cycles | 候选IPC | IPC变化 |
| --- | ---: | ---: | ---: | ---: |
| perf_median | 18,311 | 18,317 | 0.3800 | -0.033% |
| perf_multiply | 23,816 | 23,807 | 0.9124 | +0.038% |
| perf_qsort | 385,836 | 381,916 | 0.3663 | +1.026% |
| perf_rsort | 363,001 | 351,569 | 0.5567 | +3.252% |
| perf_towers | 12,134 | 12,046 | 0.4382 | +0.731% |
| perf_vvadd | 6,585 | 6,435 | 0.7030 | +2.331% |
| **GEOMEAN** | | | **0.5285** | **+1.217%** |

W1全部19项正确性和6项perf周期与主线逐项相同。主线opt456.12 MHz仍只适用于旧RTL，不能作为候选opt值。

## 候选统计验证

普通/LOCAL_STATS候选六项答案、输入和周期相同，提交数与指令数相等；所有排他分类和阶段互斥检查通过。
参考报告指定候选自己的diagnose，24个功能源码hash一致。原始数据build/rob_single_slot_stats/，另复制到候选statistics/。

| benchmark | 实际单槽接收 | 其中当拍无提交 |
| --- | ---: | ---: |
| perf_median | 2,069 | 321 |
| perf_multiply | 680 | 130 |
| perf_qsort | 28,061 | 13,185 |
| perf_rsort | 23,026 | 17,416 |
| perf_towers | 624 | 238 |
| perf_vvadd | 2,072 | 1,130 |

基线count=15时in_ready恒低，单槽实际接收为0；候选统计确认新路径实际工作且不依赖当拍提交。
原ROB.rob_full_cycles仍统计剩余不足W槽的物理状态，候选里不能再称其全部为入口阻塞；新容量阈值是满16项。
fetch仍由backend_ready && rob_in_ready门控，因此本轮包含仅剩一槽时允许按原FQ/RQ规则发fetch的效果；
不将全部收益孤立归因于某个计数事件。首条时序仍经过ROB→LSU→CDB→ROB，D端到达约2.432 ns。

复现候选统计：

```sh
python3 tools/perf_stats/collect.py --plain-sim build/rob_single_slot_w2/sim --reference-report build/synth/rob_single_slot_candidate/diagnose/report.json --out build/rob_single_slot_stats
```
