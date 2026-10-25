# 无争用计算结果的独立唤醒提示（2026-10-25）

## 基线与范围

分支feat/ipc-uncontended-wake，基于6b341e3，功能RTL与8cbb580相同。
直接基线W2/W1 IPC0.5327630834296588/0.4998402582161382，
diagnose20,555.951840 µm² /403.308389 MHz，报告build/synth/lane1_select_candidate/。
前一轮实际CDB提前wake试验因频率降至383.38 MHz而回退，不叠加它的组合选择资格。
main仍f4a0555，默认报告/仿真器保留；本轮只用diagnose，不opt、合main或推送。

## 先证明准入，再统计机会

后端CDB固定四源：ALU0、ALU1、LSU、divider，LSU每拍至多提供一个结果。
当三个计算结果缓冲恰好一个有效、且R>=2时，全部有效源至多两个，CDB必然接收该计算结果，
与轮转位置、当拍LSU是否有结果以及squash无关。R<2或多个计算结果有效时关闭提示。
compute valid/tag来自寄存器，提示不读取CDB ready/valid、LSU valid或当拍squash。

这只加速无争用计算结果的消费者；load结果仍以实际CDB更新持久ready，隔拍选择。
取消由IQ末端和a1接收处原seq检查负责；本拍提示不会把ready永久设为1，实际广播仍负责状态更新。
计算结果本来就会广播，包括当拍被取消路径上的结果；更年轻消费者由相同seq规则清除。

修改前input-only SAFE_WAKE监视器独立计算资格与最老可用普通ALU1候选，排除lane0和年轻取消项。
每个提示同时检查实际CDB compute_ready，六项benchmark的missing_grant全为0；
普通/统计版输入、答案、周期一致，基线IPC0.532763083430，24个源码hash匹配。

| benchmark | 安全提示周期 | 可提前选择且a1可接收 | 占总周期 |
| --- | ---: | ---: | ---: |
| median | 2,117 | 1 | 0.006% |
| multiply | 8,472 | 319 | 1.342% |
| qsort | 81,453 | 23,166 | 6.105% |
| rsort | 104,919 | 59,309 | 17.018% |
| towers | 1,344 | 170 | 1.427% |
| vvadd | 1,973 | 2 | 0.031% |

原始数据build/uncontended_wake_probe/；机会次数不是可节省周期，也不等于IPC增益。

## 修改与数据协议

后端通过三个compute valid恰好one-hot生成iq_lookahead_valid，tag按这三个valid作掩码或。
IQ增加默认关闭的LANE1_LOOKAHEAD及单tag提示端口；只在LANE1_ALU_ONLY的第二通道候选中使用。
lane0、访存、地址预填仍按寄存ready选择，实际CDB的wake与dispatch旁路完整保留。
提示沿把普通ALU消费者写入a1，同沿生产者由实际CDB写PRF；下一拍消费者才读PRF并执行。
不增加流水级、不增加PRF数据旁路、不改变仲裁优先级，不绕过资源反压或年轻取消。

## 验证进展

CDB穷举所有rotation/mask，并追加单compute在R>=2时必获准的契约检查；
W1/R1、W2/R2、W1/R2、W2/R1四档共69,833项零失败，已接入run_all。
IQ独立scoreboard按实际提示而非任意本拍CDB计算lane1 ready，四档新增1,245,917项零失败。
原五档通用和四档ALU1受限矩阵共2,713,607项继续通过。
提示专项包含单/双源、同tag双源、两个不同CDB但只有一个提示、无提示不得提前、load不得提前、
独立反压、wake同拍取消/保留、年龄边界、槽位复用和40,000随机周期。

后端load→ALU→ALU链覆盖一/双源数据和每项恰好一个结果：
load广播后第一个消费者仍三个沿返回；唯一compute结果的后继消费者两个沿返回。
W1/W2专项586/612项零失败。

qsort→hanoi→queens依次通过；W1/W2官方correctness各19/19通过。
两档perf已完成，LOCAL_STATS构建通过，无新增IMPLICIT/UNDRIVEN/LATCH，
保留既有两条IQ packed树UNOPTFLAT假依赖提示。完整run_all重跑已ALL PASS，配置检查通过；
独立重启的diagnose已完成，结构检查0 problems，24个输入hash与当前源码、归档和统计匹配。

| benchmark | 基线W2 cycles | 本轮W2 cycles | 本轮W2 IPC | W2 IPC变化 | 本轮W1 cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 18,135 | 18,135 | 0.383843 | +0.000% | 18,926 |
| perf_multiply | 23,762 | 23,664 | 0.917934 | +0.414% | 29,509 |
| perf_qsort | 379,442 | 376,184 | 0.371892 | +0.866% | 390,370 |
| perf_rsort | 348,500 | 332,466 | 0.588689 | +4.823% | 337,569 |
| perf_towers | 11,914 | 11,893 | 0.443790 | +0.177% | 12,504 |
| perf_vvadd | 6,368 | 6,368 | 0.710427 | +0.000% | 6,537 |
| **GEOMEAN** | | | **0.538263** | **+1.032%** | |

W1 IPC 0.504222699250847，较直接基线提升0.877%。
latency=10、MAX_CYCLES=50,000,000，使用官方make perf答案检查。

| 指标 | 403.31 MHz直接基线 | 无争用提示候选 | 变化 |
| --- | ---: | ---: | ---: |
| W2 IPC | 0.532763083430 | 0.538262837589 | +1.032% |
| W1 IPC | 0.499840258216 | 0.504222699251 | +0.877% |
| diagnose面积 µm² | 20,555.951840 | 20,571.946100 | +15.994260 / +0.078% |
| diagnose频率 MHz | 403.308389 | 400.000000 | -0.820% |
| 最小周期 ns | 2.479492188 | 2.500000000 | +0.020507812 |
| 2 ns目标WNS ns | -0.478914 | -0.499917 | -0.021003 |

诊断W2 IPC×Fmax **+0.204%**，只属于很小的趋势收益，不作为明显整体加速的结论。
保留为独立IPC组合候选，标签ipc-uncontended-wake-20261025；403.31 MHz回滚检查点8cbb580继续保留。
不据此合main或启动opt；没有把main的456.12 MHz opt数值当作候选结果。

首条路径恢复为后端源tag寄存器→PRF读→ALU0→后端结果寄存器，D端约2.444 ns。
端点u_backend/_23500_/QN→u_backend/_23612_/D；进入PRF约0.075 ns、ALU0约0.551 ns、回到后端约2.392 ns。
上一轮ROB取消→LSU→CDB→IQ的首位路径没有在本轮首条时序中重现。
代码中提示资格及payload仅依赖compute结果寄存器，不引用当拍CDB/LSU/squash；
IQ持久ready仍由实际CDB更新，末端取消保留原路径。

## 实际提示与普通/统计版复核

普通/LOCAL_STATS六项答案、输入、周期完全相同，提交数等于软件指令数；
所有排他分类、load阶段互斥及SAFE_WAKE包含关系检查通过。missing_grant逐例为0。

| benchmark | 安全提示周期 | 实际提前接收 |
| --- | ---: | ---: |
| perf_median | 2,117 | 1 |
| perf_multiply | 7,838 | 417 |
| perf_qsort | 80,024 | 23,210 |
| perf_rsort | 84,446 | 40,983 |
| perf_towers | 1,313 | 158 |
| perf_vvadd | 1,973 | 2 |

前列是安全资格，不保证每拍有消费者；后列是实际接收事件，也不直接等于节省周期。
原始候选统计build/uncontended_wake_stats/，已复制到候选statistics/。
一/双源数据链专项及完整测试共同核对：提示对应实际CDB写PRF，a1下一拍读数；并未提前直接读取旧PRF。
本轮一次完整diagnose，另有一次随工具错误中断的尝试；两者目录和日志独立保留。

## 复现与归档

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/uncontended_wake_w2
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/uncontended_wake_w2 SIM="$REPO_ROOT/build/uncontended_wake_w2/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/uncontended_wake_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/uncontended_wake_w1 SIM="$REPO_ROOT/build/uncontended_wake_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/uncontended_wake_candidate
```

仿真器build/uncontended_wake_w{1,2}/sim，候选源码、报告、仿真器及日志build/synth/uncontended_wake_candidate/。
基线与前一轮trial的全部文件保留，不使用默认main的opt值代表候选。

## 工具重试记录

首次完整run_all在通用IQ选择W2/R2/IW1测试构建末尾遇到Verilator内部线程池错误
attempted to destroy locked Thread Pool。相同测试二进制重跑通过；随后完整suite从头重跑。
原始日志保留，不将构建工具内部错误计作RTL通过或失败。
进一步检查确认，验证脚本在单元构建退出时也中断了综合子进程；没有产生report.json。
首次未完成产物移至build/synth/uncontended_wake_interrupted/，原日志完整保留。
同一RTL的diagnose改为独立进程重启，完整suite独立重跑；不将首次中断计作完成的测量。

候选统计复现（重建统计版；只有确认两份二进制同源时才可--skip-build）：

```sh
python3 tools/perf_stats/collect.py --plain-sim build/uncontended_wake_w2/sim --reference-report build/synth/uncontended_wake_candidate/diagnose/report.json --out build/uncontended_wake_stats
```
