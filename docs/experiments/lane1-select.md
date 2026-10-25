# ALU1按执行能力选择候选（2026-10-25）

## 基线和目标

分支feat/ipc-lane1-select，基于f21ac1f（ROB单槽接收候选，尚未合main）。
直接基线W2/W1 IPC 0.5284625454164975/0.4988444806718703，
diagnose 20,535.904340 µm² / 401.253918 MHz。
基线完整报告build/synth/rob_single_slot_candidate/，仿真器build/rob_single_slot_w{1,2}/sim。
main仍为f4a0555；其456.12 MHz opt不能用作本轮候选频率。

本轮优先回收已有ALU1的发射机会，不改变配置、增加执行单元或增加流水级。
先测原选择策略下的真实替代候选，再做一次独立修改；通过两档正确性/单元回归后，
以实测IPC、同模式频率和面积判断保留，综合只运行diagnose。

## 原选择策略下的机会统计

input-only LANE1监视器扫描存活且源已寄存就绪的完整候选，排除lane0预选槽（即使其被反压）。
若原lane1所选类型不受后端支持，再检查是否有普通写回ALU候选且a1缓冲可接收。
替代候选必须reg_we、非访存/分支/跳转/DIV/REM且非illegal，与后端j_lane_ok相同。
没有将同拍CDB唤醒加入候选，也不将计数直接折算为可节省周期。

| benchmark | 原lane1不支持 | 存在替代且ALU1可接收 | 占总周期 |
| --- | ---: | ---: | ---: |
| median | 3,954 | 807 | 4.406% |
| multiply | 873 | 187 | 0.785% |
| qsort | 44,059 | 22,649 | 5.930% |
| rsort | 24,589 | 3,843 | 1.093% |
| towers | 2,237 | 526 | 4.367% |
| vvadd | 1,243 | 498 | 7.739% |

原始数据build/lane1_select_probe/；六项普通/统计版答案、输入、周期相同，原功能源码hash与f21ac1f报告一致。
所有计数分类和load阶段互斥检查通过，W2 IPC仍0.5284625454164975。

## 修改与协议

IQ增加默认关闭的LANE1_ALU_ONLY参数，仅后端IW2实例启用；通用IQ原策略保留。
分配时寄存每槽lane1_eligible分类位，避免在发射路径从完整uop重新解码类型。
lane0仍选最老完整就绪项或store地址预填；lane1从完整就绪且自身支持的候选中排除lane0，
使用现有成对年龄关系选最老项。相同seq时物理槽较小者优先。

通道分别握手；lane0即使不被接收，也不能被lane1重复选中；未被选中的访存/分支等继续留在IQ。
registered wake、地址预填保留、late squash、分配/复用年龄关系、PRF读与执行流水级均保持既有协议。
只对IW2的第二通道启用限制；IW1及默认关闭模式沿用原行为。

## 验证与结果

qsort→hanoi→queens依次通过；W1/W2官方完整正确性各19/19通过，后端两档专项通过。
IQ原五档独立选择参考共1,468,560项、新增四档受限端口参考共1,245,047项，均零失败。
原有行为矩阵保留；完整run_all已ALL PASS，配置检查与LOCAL_STATS构建通过。
无新增IMPLICIT/UNDRIVEN/LATCH，保留既有IQ packed树两条UNOPTFLAT假依赖提示。
一次diagnose已完成，24个功能输入hash与当前源码和统计结果一致，结构检查0 problems。

首次IQ构建曾在Verilator结束时出现一次内部线程池报错（attempted to destroy locked Thread Pool）；
已生成的同一测试二进制重跑通过，随后完整IQ矩阵从头重跑全部通过。保留原始日志，不将工具错误当作RTL失败或通过。

| benchmark | 单槽基线W2 cycles | 本轮W2 cycles | 本轮W2 IPC | W2 IPC变化 | 本轮W1 cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 18,317 | 18,135 | 0.383843 | +1.004% | 18,926 |
| perf_multiply | 23,807 | 23,762 | 0.914149 | +0.189% | 29,588 |
| perf_qsort | 381,916 | 379,442 | 0.368699 | +0.652% | 392,603 |
| perf_rsort | 351,569 | 348,500 | 0.561604 | +0.881% | 352,697 |
| perf_towers | 12,046 | 11,914 | 0.443008 | +1.108% | 12,506 |
| perf_vvadd | 6,435 | 6,368 | 0.710427 | +1.052% | 6,537 |
| **GEOMEAN** | | | **0.532763** | **+0.814%** | |

W1 IPC 0.499840258216138，相对基线0.4988444806718703提升0.200%。
所有perf使用latency=10、MAX_CYCLES=50,000,000和官方make perf答案检查。

| 指标 | 单槽接收基线 | 本轮候选 | 变化 |
| --- | ---: | ---: | ---: |
| W2 IPC | 0.528462545416 | 0.532763083430 | +0.814% |
| W1 IPC | 0.498844480672 | 0.499840258216 | +0.200% |
| diagnose面积 µm² | 20,535.904340 | 20,555.951840 | +20.047500 / +0.098% |
| diagnose频率 MHz | 401.253918 | 403.308389 | +0.512% |
| 最小周期 ns | 2.492187500 | 2.479492188 | -0.012695312 |
| 2 ns目标WNS ns | -0.491852 | -0.478914 | +0.012938 |

诊断IPC×Fmax提升1.330%，保留独立候选，标签ipc-lane1-select-20261025。
相对main的诊断模式，累计W2 IPC+2.041%、频率+0.236%、面积+0.248%、IPC×Fmax+2.282%。
没有候选opt数据；两轮候选均尚未合main或推送。

首条时序变为a0_src1_tag[0]寄存器→PRF读→ALU0→alu_value_q[29]寄存器，D端到达2.419 ns。
门级端点为u_backend/_23665_/QN→u_backend/_23777_/D；通过mapped.v的反相器连接核对源tag和结果位。
ROB→CDB→ROB仍是相邻路径，报告中D端约2.384 ns。没有根据少量路径推断具体ALU运算种类。
频率约0.5%的改善是本次网表实测趋势，不能单凭它推断新选择逻辑缩短了ALU数据路径。

## 候选统计复核

六项普通/LOCAL_STATS版答案、输入hash及周期逐项相同，提交数等于指令数；
排他分类和LOAD_HEAD阶段互斥检查全部通过。候选LANE1.unsupported逐例为0。

| benchmark | ALU1实际发射次数 | 跳过原不支持候选后实际发射 |
| --- | ---: | ---: |
| perf_median | 2,073 | 629 |
| perf_multiply | 8,357 | 240 |
| perf_qsort | 63,730 | 17,499 |
| perf_rsort | 26,291 | 3,329 |
| perf_towers | 1,052 | 382 |
| perf_vvadd | 1,438 | 366 |

后列按候选运行当拍状态重新计算原策略：排除lane0后最老的完整就绪项不受支持，
而新策略确实选中并接收了普通ALU。不能把这些次数或与基线发射数之差直接当作节省周期。
原始统计build/lane1_select_stats/；连同源码、仿真器、全部日志复制到build/synth/lane1_select_candidate/。
实际综合13:08:02→13:15:06，约7分04秒；本轮仅一次diagnose。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lane1_select_w2
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lane1_select_w2 SIM="$REPO_ROOT/build/lane1_select_w2/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lane1_select_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lane1_select_w1 SIM="$REPO_ROOT/build/lane1_select_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/lane1_select_candidate
```

使用独立build和综合输出；默认main报告及仿真器保留，不跑opt、不合main、不推送。

候选统计复现（需要当前RTL普通/统计两版，省略--skip-build会重建统计版）：

```sh
python3 tools/perf_stats/collect.py --plain-sim build/lane1_select_w2/sim --reference-report build/synth/lane1_select_candidate/diagnose/report.json --out build/lane1_select_stats
```
