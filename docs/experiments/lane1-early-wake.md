# ALU1受限提前唤醒（2026-10-25）

## 基线与范围

基于8cbb580 / ipc-lane1-select-20261025，分支feat/ipc-lane1-early-wake。
直接基线W2/W1 IPC 0.5327630834296588/0.4998402582161382；
diagnose 20,555.951840 µm² /403.308389 MHz，报告build/synth/lane1_select_candidate/。
main仍f4a0555，默认仿真器与diagnose/opt报告保持主线基线，不属于本轮候选。

目标是减少普通ALU依赖链的等待；仅在后接a1缓冲的第二通道使用同拍CDB唤醒。
lane0、load/store、store地址预填仍只使用寄存ready，六口PRF仍无同拍数据旁路。
先测机会，再做独立实验；只跑diagnose，不自动opt、合main或推送。

## 修改前统计

input-only EARLY1按每拍真实IQ表项、已寄存ALU1资格与实际CDB计算提前就绪集合，
排除lane0已预选槽和squash年轻项，按(seq, slot)排序。
统计最老候选恰需本拍wake、且ALU1缓冲可接收的周期。此时即使原lane1有其他候选，
新策略也可能改选更老的被唤醒项；这些次数不能直接折算为节省周期。

| benchmark | 提前wake候选获胜且可接收 | 占总周期 | 其中原lane1无offer | 两路均无offer |
| --- | ---: | ---: | ---: | ---: |
| median | 1 | 0.006% | 1 | 1 |
| multiply | 4,267 | 17.957% | 876 | 131 |
| qsort | 25,910 | 6.828% | 25,350 | 16,994 |
| rsort | 88,256 | 25.325% | 86,161 | 34,636 |
| towers | 514 | 4.314% | 364 | 108 |
| vvadd | 301 | 4.727% | 154 | 153 |

原始数据build/lane1_early_probe/，普通/统计版六项答案、输入、周期相同，IPC仍0.532763083430。
原策略实际提前接收次数逐例为0，24个功能输入hash匹配直接基线报告。
qsort共有25,911次候选提前wake机会，其中1次缓冲不可接收；表中只列可接收次数。

## 时序与数据正确性

IQ增加默认关闭的LANE1_EARLY_WAKE，只有IW2、LANE1_ALU_ONLY通道使用。
lane1候选源ready由寄存ready或本拍实际CDB tag命中提供，lane0/pre-fill候选保持原样。
两通道不重复选择同槽，仍按年龄关系选择并在输出末端按seq取消。

本拍CDB在接收沿写PRF，同一沿把消费者uop放进a1；消费者下一拍才从PRF读数并执行。
没有将新选指令的操作数在CDB广播当拍直接送进ALU，也没有让load/store提前读旧PRF。
反压时表项保留，沿后ready位正常锁存；dispatch与wake同拍的原旁路继续保留。

新增IQ独立参考按通道分别计算ready：lane0寄存，lane1允许实际wake。
包含单/双源、两条CDB、同tag唤醒两源、反压、取消边界和load不得提前发射的专项。
后端增加受控load响应后普通ALU消费数据测试，检查一/双源值、恰好一次结果，
以及消费者在生产者广播后两个时钟沿返回。W1/W2专项580/606项已通过。

## 完整验证、性能与决定

qsort→hanoi→queens依次通过；W1/W2官方correctness各19/19通过。
新增提前wake四档IQ独立参考共1,245,951项零失败，原五档通用和四档ALU1受限矩阵也通过。
两档后端580/606项通过；完整run_all ALL PASS，配置检查通过。
一次diagnose完成，结构检查0 problems，24个功能输入hash与源码/归档/统计结果一致。
LOCAL_STATS构建通过，无新增IMPLICIT/UNDRIVEN/LATCH，保留既有两条packed树UNOPTFLAT假依赖提示。

| benchmark | 基线W2 cycles | 本轮W2 cycles | 本轮W2 IPC | W2 IPC变化 | 本轮W1 cycles |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 18,135 | 18,135 | 0.383843 | +0.000% | 18,926 |
| perf_multiply | 23,762 | 23,182 | 0.937020 | +2.502% | 29,417 |
| perf_qsort | 379,442 | 375,647 | 0.372424 | +1.010% | 390,079 |
| perf_rsort | 348,500 | 319,869 | 0.611872 | +8.951% | 325,046 |
| perf_towers | 11,914 | 11,893 | 0.443790 | +0.177% | 12,497 |
| perf_vvadd | 6,368 | 6,368 | 0.710427 | +0.000% | 6,537 |
| **GEOMEAN** | | | **0.543730** | **+2.058%** | |

W1 IPC 0.507784231121264，较直接基线提升1.589%。
latency=10、MAX_CYCLES=50,000,000，使用官方make perf答案检查。

| 指标 | 直接基线 | 提前wake试验 | 变化 |
| --- | ---: | ---: | ---: |
| W2 IPC | 0.532763083430 | 0.543729862637 | +2.058% |
| W1 IPC | 0.499840258216 | 0.507784231121 | +1.589% |
| diagnose面积 µm² | 20,555.951840 | 20,569.059260 | +13.107420 / +0.064% |
| diagnose频率 MHz | 403.308389 | 383.377012 | -4.942% |
| 最小周期 ns | 2.479492188 | 2.608398438 | +0.128906250 |
| 2 ns目标WNS ns | -0.478914 | -0.608323 | -0.129409 |

W2 IPC×Fmax **-2.985%**。
虽然rsort IPC+8.951%、两档geomean均有改善，但频率代价超过W2收益，因此不作为工作版本保留。
试验完整提交保存在ipc-lane1-early-wake-trial-20261025；工作分支随后恢复8cbb580的功能RTL与原IQ测试矩阵。
保留统计工具与load依赖数据回归，恢复版该消费者应在生产者广播后三个时钟沿返回。
直接基线仍为W2/W1 IPC0.532763/0.499840、diagnose20,555.952 µm² /403.31 MHz；未合main。

新首条路径为ROB取消→LSU结果有效→CDB→IQ提前wake/选择→后端接收寄存器。
端点u_core/u_rob/_59955_/QN→u_backend/_23606_/D，D端约2.553 ns。
报告中进入LSU约0.537 ns，CDB约1.086 ns，IQ约1.483 ns，回到后端约2.278 ns。
它验证了实际CDB资格仍会把ROB取消路径接到IQ选择，即使只对ALU1开启、没有PRF同拍数据旁路。
不能因“访存不提前发射”就认为这条跨模块控制路径已被切断。

后续若继续提前唤醒，优先研究不依赖全局取消/CDB仲裁长链的安全lookahead资格或缩短依赖链，
必须证明广播确实写PRF和取消/仲裁反压一致；不要直接对lane0和访存恢复同拍wake。
本轮不追加第二次综合或opt，不合main、不推送。综合13:27:58→13:35:07，约7分09秒。

## 普通/统计版与实际提前接收

六项答案、输入、周期逐项相同，提交数等于软件指令数；分类之和、load所有权互斥和EARLY1包含关系均通过。

| benchmark | 实际提前接收 | 其中两个源都等待本拍wake |
| --- | ---: | ---: |
| perf_median | 1 | 0 |
| perf_multiply | 4,266 | 0 |
| perf_qsort | 25,602 | 1 |
| perf_rsort | 82,375 | 1 |
| perf_towers | 545 | 0 |
| perf_vvadd | 301 | 0 |

原始候选统计build/lane1_early_stats/，另归档候选statistics/；这些是接收事件，不等于节省周期。

## 复现与归档

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lane1_early_w2
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lane1_early_w2 SIM="$REPO_ROOT/build/lane1_early_w2/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lane1_early_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lane1_early_w1 SIM="$REPO_ROOT/build/lane1_early_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/lane1_early_candidate
```

普通仿真器build/lane1_early_w{1,2}/sim；候选报告、源码、仿真器、日志build/synth/lane1_early_candidate/。
修改前统计build/lane1_early_probe/，日志/tmp/lane1-early-*.log。
默认main报告及仿真器、直接基线lane1_select_candidate/保持原样。

复现试验需要先检出trial标签；当前工作分支已恢复原功能RTL，不能用其源码运行试验报告的hash核对。

```sh
python3 tools/perf_stats/collect.py --plain-sim build/lane1_early_w2/sim --reference-report build/synth/lane1_early_candidate/diagnose/report.json --out build/lane1_early_stats
```

## 恢复后复核

功能RTL及原IQ测试文件逐字节恢复8cbb580；当前24个功能输入hash全部匹配403.31 MHz报告。
恢复版新增load→ALU回归W1/W2仍580/606项通过，确认一/双源读取新PRF数据、恰好一次结果、广播后三个沿完成。
恢复没有引入新功能RTL，完整correctness/perf/run_all沿用同源8cbb580的已验证记录，不再重复综合。
trial标签和build/synth/lane1_early_candidate/仍保留383.38 MHz试验，两个版本不混用。
