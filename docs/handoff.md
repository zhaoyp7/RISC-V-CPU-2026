# RISC-V CPU 2026 — 协作者交接（P2 功能完成，性能优化中）

## 当前检查点：固定槽分支查找（393.39 MHz，保留IPC）

固定物理槽匹配分支，保留最年轻同tag语义；预测payload先形成，最后限定有效恢复动作。
ROB32/PRF64/IQ8/LSQ16：W2/W1 IPC0.621226/0.558328，diagnose22,903.492 µm²/393.39 MHz。
较007bd09：频率+6.877%，面积+0.166%，全部正确性/perf周期与统计计数器不变；保留独立检查点。
四组各19/19，新增ROB边界先在原版通过，再在候选141970/141968零失败；最终单任务run_all ALL PASS。
两次Verilator编译线程池内部故障及统计等待超时日志均保留；单测CPU_UNIT_JOBS=1重跑通过，未改生产工具/约束。
24输入仅ROB改变，7库/工具约束及实际容量核验，一次diag约9.92分钟；默认16不复用旧PPA。
一小时相对ce32682累计W2 IPC+2.236%、W1+1.680%、Fmax+4.841%、面积+0.110%、W2 IPC×Fmax+7.185%。
无opt/合main/推送；归档build/synth/rob_branch_match/，详见[ROB分支查找](experiments/rob-branch-match.md)。
本次一小时迭代窗口已结束，工具故障的必要收尾验证已补齐；停止追加新实验。

## 当前检查点：load响应直通（IPC改善，频率下降）

空结果FIFO时，存活内存响应直通CDB；反压则入预留队列，旧队首优先，保留squash与前递语义。
ROB32/PRF64/IQ8/LSQ16：W2/W1 IPC0.621226/0.558328，diagnose22,865.599 µm²/368.08 MHz。
较ce32682：IPC+2.236%/+1.680%、频率-1.905%、面积-0.056%；W2 IPC×Fmax仅+0.288%，保留独立IPC候选，未升级默认。
四组各19/19，普通/统计周期相同、全部守恒核验；最终run_all ALL PASS，LSU四档63803/63994/64274/64274通过。
backend观测改沿前采样后，候选与原LSU均586/612通过；初次漏记失败日志保留，完整回归已从头重跑。
24输入仅LSU改变、7库/工具约束与实际容量核对；一次diag，无opt/合main/推送，默认16不复用旧PPA。
下一轮按当前关键链改写ROB分支查找/资格控制，争取减少旋转选择并保留本轮IPC。
归档build/synth/load_response_bypass/，详见[load响应直通](experiments/load-response-bypass.md)。

## 当前检查点：固定槽恢复网络（面积改善，频率略降）

恢复掩码/LSQ指针/flush共用固定槽存活判定，分支feat/area-rob-recovery-masks，基于dca7d77。
ROB32/PRF64/IQ8/LSQ16：W2/W1 IPC0.607639/0.549105，diagnose22,878.356 µm²/375.23 MHz。
面积-402.802 µm²（-1.730%），频率-0.330%，单位面积吞吐+1.425%；频率不降目标未完全满足，接受小幅代价保留独立候选。
四组各19/19且全部周期相同，run_all ALL PASS；新增恢复掩码边界先在原版通过，完整随机131698/131696零失败。
普通/统计六项全部计数器同dca7d77，24输入/7库/工具约束与实际容量核验通过；一次diag约12.63分钟，无opt。
恢复掩码独占806→602、LSQ指针123→27 µm²；ROB少423.841，全核净少402.802，逻辑锥不可相加。
首条仍ROB→LSU/CDB→准入→前端I$，D端2.625 ns；默认参数与main不改，不复用默认16旧PPA。
用户继续自主工作及Git授权保持；下一步按新统计分解load延迟，再选IPC改动；完成年龄矩阵压缩仍是面积候选。
归档build/synth/rob_recovery_masks/，详见[恢复掩码实验](experiments/rob-recovery-masks.md)。

## 当前检查点：恢复RAT选择树（面积小幅下降，继续推进）

分支feat/area-rob-recovery-rat，基于9747662；宏ROB32/PRF64/IQ8/LSQ16，默认参数不改。
面积23,281.158 µm²/376.47 MHz，较9747662减少148.483（-0.634%），频率和IPC不变；保留独立检查点area-rob-rat-tree-20261025。
W2/W1 IPC0.607639/0.549105；四组（32/默认16 × W1/W2）各19/19，所有测试/perf周期同基线。
新增完整recover_rat独立参考先在原版通过，W1/W2完整随机115666/115664零失败，run_all ALL PASS。
普通/统计版全部计数器同基线，24候选输入（只ROB变）/7库/工具与约束核对；一次有效diagnose，无opt。
RAT锥1839→1646、独占1322→1191 µm²；全核实际只降148，不把锥面积当可回收总量。
首条仍为ROB取消→LSU/CDB→分支资格→ROB/rename准入→前端I$，D端2.616 ns。
用户已授权连续后续优化及自主Git，不逐轮等待；接下来研究恢复掩码/存活判定固定槽位化，默认/main及旧报告保留。
归档build/synth/rob_rat_tree/，详见[恢复RAT实验](experiments/rob-rat-tree.md)。

## 最新完成：ROB32固定槽匹配trial（未全面达标）

分支feat/freq-rob32-match，基于5394ea0，迁移52d7c72的完成搜索/one-hot更新，保留当前单槽准入。
宏参数ROB32/PRF64/IQ8/LSQ16，默认配置文件仍ROB16/PRF48，main未改。
W2/W1 IPC0.607639/0.549105；diagnose23,429.641 µm²/376.47 MHz。
较原32：频率+7.243%、面积+23.007 µm²（+0.098%）；较旧16：IPC×Fmax+6.248%、面积+13.891%。
面积不增和380 MHz目标均未完全达到，只保留独立trial，不升级默认或合main；不自动新RTL或opt。
四组（32/默认16 × W1/W2）各19/19，全部正确性/perf周期同各自基线；完整run_all ALL PASS。
ROB完整随机W1/W2检查108050/108048通过；普通/统计版全部计数器同原32基线。
24个候选输入hash（仅ROB改变）、7库、工具及全部时序/ABC约束核对一致，实际容量确认32/64/8/16。
当前首条为ROB取消→LSU→CDB ready→分支资格→ROB/rename准入→前端I$，D端2.616 ns，原恢复busy路径不再首位。
下一步优先拆解ROB表项与恢复网络面积；若继续频率则应针对新前端准入链，不能重复旧瓶颈定位。
默认参数本轮仅功能/IPC验证，没有本RTL的默认16项PPA，不能复用旧400 MHz；默认build/sim及main报告仍是旧main归档。
一次diagnose，无opt/合main/推送；归档build/synth/rob32_fixed_match/，详见[ROB32固定匹配](experiments/rob32-fixed-match.md)。

## 最新完成：三组窗口PPA对照（默认不改）

功能RTL仍1d142db，分支feat/ipc-uncontended-wake；只新增参数覆盖工具、测试和文档。
三组均完成W2 diagnose、W1/W2各19/19和两档perf，最终run_all ALL PASS（含LSQ32新矩阵）。
W2普通/统计版周期一致；24个源码hash、显式宏配置、7个库hash、工具与时序/ABC约束已核对。

| 配置 ROB/PRF/IQ/LSQ | W2 IPC | W1 IPC | diagnose面积 µm² | MHz | W2 IPC×Fmax变化 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 原参数16/48/8/16 | 0.538263 | 0.504223 | 20,571.946 | 400.00 | — |
| 第一组：ROB32+PRF64（32/64/8/16） | 0.607639 | 0.549105 | 23,406.633 | 351.05 | -0.927% |
| 第二组：再加LSQ32（32/64/8/32） | 0.620532 | 0.558531 | 27,459.844 | 356.67 | +2.796% |
| 第三组：再加IQ16（32/64/16/32） | 0.639400 | 0.567505 | 29,817.241 | 347.71 | +3.260% |

当前已测IPC×Fmax最好为第三组：再加IQ16，较400 MHz原参数候选+3.260%，面积+44.941%。
第一组净吞吐未改善；扩大容量的IPC收益不能直接当作整核收益，三组均未设为默认。
三组瓶颈是squash索引→LSU取消→CDB tag→ROB完成搜索/恢复busy掩码；下一步优先评估32项ROB的该控制链，
旧固定槽位匹配52d7c72可作参考，但尚未移植或验证。不自动追加新RTL或opt。
本轮3次完整有效diagnose，另有首组宏未生效时主动中止的尝试，无report，独立保留。
默认build/sim与默认diagnose/opt仍为main归档；main仍f4a0555，未合并或推送。
归档build/synth/ipc_{rob32_prf64,rob32_lsq32,window32}/，复现必须保留宏manifest及wrapper。
详见[窗口PPA实验](experiments/ipc-window-ppa.md)和[前置容量测量](experiments/ipc-sensitivity.md)。

## 当前工作分支：无争用计算结果提示（独立IPC候选）

分支feat/ipc-uncontended-wake，标签ipc-uncontended-wake-20261025，基于6b341e3（功能同8cbb580）。
只有一个compute结果且R>=2时直接提示其tag，保证compute+至多一个load均获准；不经过CDB仲裁或当拍取消。
W2/W1 IPC **0.538263/0.504223**，较403.31版+1.032%/+0.877%。
diagnose **20,571.946 µm² /400.00 MHz**，面积+0.078%、频率-0.820%、诊断IPC×Fmax **+0.204%**。
仅作独立IPC组合候选，整体收益很小；403.31 MHz检查点继续保留，不据此合main或opt。
两档19/19、run_all重跑ALL PASS，后端586/612、IQ新增四档1,245,917、CDB69,833项通过。
普通/统计版答案和周期一致，24个源码及7个库hash核对一致，所有安全提示实际获准写回，missing_grant为0。
首条路径为PRF→ALU0→结果寄存器2.444 ns；qsort/rsort实际提前接收23,210/40,983次。
首次工具错误导致初次diag中断无report，保留interrupted目录；独立重启后完成一次diag。
仿真器build/uncontended_wake_w{1,2}/sim，报告/源码/统计build/synth/uncontended_wake_candidate/。
main仍f4a0555，默认main报告/仿真器及403.31版归档不改；本轮无opt、未合main、未推送。
详见[无争用提示实验](experiments/uncontended-wake.md)。

## 前一轮：ALU1提前唤醒试验（2026-10-25，不采纳）

标签ipc-lane1-early-wake-trial-20261025保留试验；工作分支feat/ipc-lane1-early-wake恢复8cbb580功能RTL。
W2 IPC0.532763→0.543730（+2.058%），W1 .499840→.507784（+1.589%）。
一次diagnose20,569.059 µm² /383.38 MHz，较403.31版面积+0.064%、频率-4.942%，W2 IPC×Fmax-2.985%，因此回退。
W1/W2各19/19、run_all ALL PASS，新增四档IQ参考1,245,951项通过，后端580/606项通过；
普通/统计版答案和周期一致，24个源码hash及7个库hash匹配。qsort/rsort实际提前接收25,602/82,375次。
新瓶颈ROB取消→LSU结果valid→CDB→IQ提前wake/选择→后端寄存器，D端2.553 ns。
试验源码、仿真器、报告和统计归档build/synth/lane1_early_candidate/，不覆盖默认main或403.31版报告。
恢复后仍采用W2/W1 IPC0.532763/0.499840、diagnose20,555.952 µm² /403.31 MHz的候选；main仍f4a0555。
恢复后24个输入hash与403.31报告匹配，新增后端回归580/606项通过；完整测试沿用同源8cbb580记录。
本轮无opt、未合main、未推送。详见[提前唤醒试验](experiments/lane1-early-wake.md)。

## 选定候选：ALU1候选选择（未合main）

分支feat/ipc-lane1-select，标签ipc-lane1-select-20261025，基于f21ac1f的ROB单槽接收候选。
lane0保持原年龄优先；lane1在剩余的普通ALU候选中选最老项，资格入队时寄存。
两档正确性各19/19、run_all ALL PASS，新增四档IQ独立参考1,245,047项零失败。

| 指标 | 上轮单槽候选 | 本轮候选 | 变化 |
| --- | ---: | ---: | ---: |
| W2 IPC | 0.528463 | 0.532763 | +0.814% |
| W1 IPC | 0.498844 | 0.499840 | +0.200% |
| diagnose面积 µm² | 20,535.904 | 20,555.952 | +0.098% |
| diagnose频率 MHz | 401.25 | 403.31 | +0.512% |

诊断IPC×Fmax+1.330%，保留独立候选。相对main累计W2 IPC+2.041%、诊断IPC×Fmax+2.282%。
普通/统计版六项答案、周期一致，24个源码hash匹配；qsort实际绕过不支持项发射17,499次。
首条时序已转为a0源tag→PRF→ALU0→结果寄存器，D端2.419 ns，ROB控制链仍相邻。
候选仿真器build/lane1_select_w{1,2}/sim，报告和统计build/synth/lane1_select_candidate/。
本轮仅一次diagnose，无opt、未合main、未推送；main的456.12 MHz opt仍适用于原主线。
详见[ALU1候选选择实验](experiments/lane1-select.md)。

## 前一候选：ROB单槽接收（未合main）

分支`feat/ipc-rob-single-slot`，标签`ipc-rob-single-slot-20261025`，基于f4a0555。
候选W2 IPC **0.5285**（主线0.5221，+1.217%），W1 **0.4988**且19项正确性/6项perf周期逐项相同。
候选diagnose **20,535.904 µm² / 401.25 MHz**；同模式主线20,505.024 /402.36，面积+0.151%、频率-0.274%。
诊断IPC×Fmax+0.939%，作为独立IPC候选保留；W1/W2各19/19、run_all ALL PASS、24个输入hash匹配。
ROB边界28,094/28,038、前端非零预测快照专项293/325项通过，配置及LOCAL_STATS lint通过。
ROB按寄存count给出in_capacity前缀，前端按容量输出/弹出前缀并保留后缀；不借当拍commit空间，无新增流水拍数。
候选普通/统计版六项周期相同，单槽实际接收qsort28,061/rsort23,026次，其中无同拍提交13,185/17,416次。
main仍保留f4a0555的功能RTL（同ba7ceb6），默认build/sim及diagnose/opt是主线基线，不对应候选。
候选仿真器build/rob_single_slot_w{1,2}/sim，报告/源码/统计在build/synth/rob_single_slot_candidate/。
本轮无opt、未合main、未推送。详见[ROB单槽实验](experiments/rob-single-slot.md)。

## main基线检查点：opt 456.12 MHz / 19,808.71 µm²

main基线检查点`main-freq-age-matrix-20261025`。
测量检查点仍为`freq-age-matrix-opt-20261024`，源码与ba7ceb6相同。
本次用户授权的一次opt已完成；RTL与ba7ceb6完全一致，ROB固定槽位匹配trial仍回退。

| 指标 | diagnose | opt | 变化 |
| --- | ---: | ---: | ---: |
| 面积 µm² | 20,505.024 | 19,808.712 | -3.40% |
| Fmax MHz | 402.36 | 456.12 | +13.36% |
| 最小周期 ns | 2.48535 | 2.19238 | -0.29297 |
| 2 ns目标WNS ns | -0.484783 | -0.191631 | +0.293152 |

24个源码输入（含顺序）、7个库文件、工具版本、SRAM模型及全部时序约束一致。
结构检查0 problems，实际约7分20秒；没有追加第二次opt或重跑diagnose。
RTL未改，沿用已通过的W1/W2各19/19、run_all ALL PASS；IPC仍为0.5221/0.4988。
默认diagnose与opt分别为上述两列，完整归档`build/synth/iq_age_matrix_opt_checkpoint/`。
已按用户授权将本地main从bc795ae快进到b848264，无冲突；随后仅更新合并记录。
原main回滚标签`main-before-freq-age-matrix-20261025`保留bc795ae，未推送远端。
合并后验证树与已测分支一致，diagnose/opt的24个源码hash均匹配，沿用既有测试，不重复综合。
详见[opt同源对比及合并记录](experiments/iq-age-matrix-opt.md)。

## 当前IPC统计已刷新（2026-10-25）

主线六项perf的普通/LOCAL_STATS版答案、输入、周期逐项相同，IPC0.5221；功能RTL未改。
qsort/rsort的ROB入口容量不足42.83%/57.41%，队首load未完成51.12%/55.37%，
其中已发请求等返回37.90%/48.56%。仅剩一槽的容量状态占21.36%/29.43%，不等于保证能回收的周期。
当前活跃load执行级消歧阻塞0～1.24%周期；本拍wake机会1.35%～17.80%，不能直接折算IPC增益。
下一步先评估单槽接收机会与load关键依赖链/有效窗口，不沿用2026-10-22的旧瓶颈结论。
复现tools/perf_stats/collect.py，原始数据build/perf_stats_20261025/results.json，
详见[当前main统计](experiments/main-stats-20261025.md)。阶段合计、互斥及软件提交数检查均通过。

## 最新检查点：ALU 乘法器共享（2026-10-23）

本地 `main` 已纳入乘法器共享，检查点 tag `alu-shared-mul-20261023`，未推送远端。
上一版 RTL `21fba79` 保留在 `freq-alu-no-comb-div-20261023`，原 C2 与非访存
流水版分别保留为 `c2-area-baseline-20261023`、`freq-alupipe-baseline-20261023`。

| 版本 | W2 IPC | diagnose 面积 / MHz | opt 面积 / MHz |
| --- | ---: | ---: | ---: |
| 原 C2 `94eac37` | 0.6311 | 20,262.8 / 53.44 | 19,759.4 / 55.47 |
| 非访存流水 `b6c009c` | 0.6084 | 21,092.6 / 67.91 | 20,306.7 / 72.73 |
| 移除组合除法 `21fba79` | 0.6084 | 19,777.0 / 99.38 | 18,955.7 / 115.80 |
| 共享乘法器 | **0.6084** | **18,603.4 / 99.38** | **17,895.8 / 115.12** |

本轮 opt 面积 -5.6%，Fmax -0.6%，IPC 不变；以约 0.6% 的频率下降
换取约 1,059.9 µm² 的面积减少。面积低于 18k 约 104.2 µm²，但课程阶段 2
的 IPC 0.845 和 300 MHz 仍未达到，不能称为阶段通过。

W1/W2 correctness 各 19/19、`run_all` ALL PASS；六个 perf 周期数及两档全部
正确性周期数与前一版逐项相同。W1 IPC 0.5759。新增 ALU 独立参考对拍共
713,728 项，覆盖 `ENABLE_DIV=0/1`，已接入 `run_all`。

改动仅为 ALU 组合乘法共享及测试，不增加流水拍数、不改参数或访存路径。
后续先研究 `ROB → LSU → CDB → IQ → PRF → LSU/LSQ` 长路径；不要直接把
load/store 放入旧的 a0/a1 缓冲。优先做分析和方案设计，单次实验保持可回滚。
**验证策略：平时用 diagnose 筛选，积累到阶段检查点再跑 opt，避免频繁运行
约半小时的 opt；同一时间只运行一项综合。** 本轮已完成，不追加 opt。

详细结果和复现见 [乘法共享实验](experiments/alu-shared-mul.md)。
以下各节保留此前配置和实验的历史记录，旧的“未合并/待决策”描述以本节为准。

> 这是**已跟踪**的协作文档，`git pull` 即可获得。
> 本地完整版 `prompt.md` 被 `.gitignore` 忽略，不会随 git 同步；本文件是
> 给协作者/新 agent 的入口。
>
> 仓库根目录 = 本文件所在目录（包含 `verilog/`、`Makefile`、`README-ZH.md`）。
> 所有命令默认在仓库根目录执行。

---

## 0. 拉取后第一件事

```sh
git switch main
git pull --ff-only
git submodule update --init --recursive
git log --oneline -5
```

如果 `testcases/` 是空的，说明 submodule 没初始化：

```sh
git submodule set-url testcases \
  https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026-Testcases.git
git submodule update --init --recursive
```

然后验证环境：

```sh
python3 tools/config_gen.py --check
make build JOBS=4
make test MAX_CYCLES=50000000
```

### 唯一不随 git 拉取的东西

`cpu2026-tools-x86_64.AppImage` 被 `.gitignore` 忽略（课程工具包，约 37 MB），
不在仓库里。如果合作者电脑上还没有：

1. 从旧电脑复制到本仓库根目录，或按 `README-ZH.md` 的方案 B/C 使用 Docker/
   原生工具链；
2. `chmod +x cpu2026-tools-x86_64.AppImage`；
3. 如果 FUSE 不可用（WSL/容器）：`export APPIMAGE_EXTRACT_AND_RUN=1`。

除此之外，RTL、测试、文档、`docs/handoff.md` 都已经在 git 中，拉取即可。
`build/`、`build/synth/` 是本地产物，不需要复制，重新构建即可。

---

## 1. 当前状态（2026-10-23）

- 分支：`main`
- P1 功能 tag：`p1-ooo-final`（`0d6e07f`）
- P2 RTL 提交：`a95a938`（双发射 + 双取指 + 流水访存）
- 性能检查点 tag：`p2-perf-prefill`（store 地址预填 + ROB recovery 修复 +
  LOCAL_STATS；2026-10-22 推送）
- 当前 `main`：以 `git log -1 --oneline` 为准
- 官方 `verilog/filelist.f` 使用 OoO 顶层 `student_top_ooo.sv`
  （模块名仍是 `student_top`）
- 基线 `core.sv`/`icache.sv`/`student_top.sv` 保留但不在 filelist

### 已验证

- 官方 W=1 correctness：**19/19 PASS**
- 官方 W=2 correctness：**19/19 PASS**（`MAX_CYCLES=50,000,000`）
- `sh test/run_all.sh`：**ALL PASS**
- `test/lsu_test`、`test/mem_subsystem_test`、`test/backend_test` 已适配
  P2 端口并加入 `run_all.sh`
- `python3 tools/config_gen.py --check`：up to date
- 当前课程分数估算：仍约 **85/100**（性能/面积/频率未达阶段门槛）

### 当前性能/面积（W=2）

| 指标 | 当前值 | 阶段 1 门槛 | 阶段 2 门槛 |
| --- | ---: | ---: | ---: |
| IPC GEOMEAN | **0.6311**（C2 面积档，`1e99cc8`） | ≥ 0.6000 | ≥ 0.8450 |
| 面积（opt） | **19,759.4 µm²**（C2；diag 20,262.8） | ≤ 9,000 µm² | ≤ 18,000 µm² |
| 频率（opt） | **55.47 MHz**（C2；diag 53.44） | ≥ 300 MHz | ≥ 300 MHz |

P2 基线 `a95a938` 的 IPC 为 0.5507；`a56cca6` 加入 store 地址预填后
提升到 0.6380。2026-10-23 曾用 LSQ32 把 IPC 推到 0.7295，但面积涨到
28.4k；随后按“频率/面积优先”切回 **C2 面积档**（`1e99cc8`，ROB16/
PRF48/LSQ16/1KB I$），W=2 IPC **0.6311**、diagnose 20.26k。
tournament gshare + GHR 快照（`9666237`）在 LSQ32 上把 IPC 推到 0.7563，
但面积 +1.45k，保留在 `feat/gshare-snapshot` 分支，未入默认。
W=1 档 C2 为 19/19 PASS、IPC 0.5940。perf 明细、参数敏感度和 synth
breakdown 见 `docs/perf-log.md` 与 `docs/integration-status.md`。

2026-10-22 还修复了 ROB16 的恢复竞态（`ab00273`），C2 依赖该修复。
C2 的完整参数/复现命令/注意事项见 `docs/configs/c2-area.md`。

### 频率流水化分支（未合并）

分支 `feat/freq-alupipe`（HEAD `fa8920f`）在 C2 参数上把非访存发射流水化：

- lane1：IQ → a1 缓冲 → PRF/ALU1；
- lane0：非访存 IQ → a0 缓冲 → PRF/ALU/分支/div；load/store 仍直连 LSU；
- PRF 扩为 6 读口，避免 a0/a1 同时执行时读口冲突。

| 指标 | C2 `main` | 频率分支 |
| --- | ---: | ---: |
| W2 IPC | 0.6311 | **0.6084** |
| W1 IPC | 0.5940 | **0.5759** |
| diagnose 面积 / Fmax | 20,262.8 / 53.44 | 21,092.6 / **67.91** |
| opt 面积 / Fmax | 19,759.4 / 55.47 | **20,306.7 / 72.73** |
| correctness | W2/W1 19/19 | W2/W1 19/19 |
| `run_all` | ALL PASS | ALL PASS |

相对 C2 opt：面积 +2.8%，Fmax +31.1%，IPC -3.6%，`IPC × Fmax` +26.4%。
分支**尚未合并**；若接受面积换频率，再合入 `main`。回滚点：
`main` 的 `94eac37`，或本分支的 `0621c83`（仅 lane1 版本）。

---

## 2. 当前架构

`verilog/cpu_config.sv` 默认：

| 参数 | 当前值 |
| --- | ---: |
| `CPU_ISSUE_WIDTH` | 2 |
| `CPU_ROB_DEPTH` | 16 |
| `CPU_PRF_SIZE` | 48 |
| `CPU_RS_DEPTH` | 8 |
| `CPU_CDB_NUM` | 2 |
| `CPU_LSQ_DEPTH` | 16 |
| I-Cache | 双 bank，每 bank 1 KB 直接映射，1 字/行 |
| BTB / BHT | 32 项 / 128 项 2-bit（单 BPU 双读口） |
| D-Cache | **未实现**（原型已验证不适合当前阻塞式方案，已回退） |

### 已实现

- RV32IM；乱序发射/乱序完成/按序提交
- 精确分支恢复、RAT replay、ROB 恢复、统一 32-bit dispatch seq squash
- 双 bank I-Cache、fetch FIFO、取指侧 BPU 预测（消除 taken 气泡）
- 双发射 IQ、第二 ALU、两条 CDB、wake 掩码（同拍多条完成）
- PRF/IQ/CDB/ALU/多周期 divider/LSU/LSQ
- 流水化 load/store、多笔在途 load、按序响应、store-to-load forwarding
- `mem_subsystem` + `axi_mem_if` 多笔在途读/流水写、I$ 双 refill 客户

### 关键限制

1. 取指仍限制吞吐：每 bank 每拍一条，分支误预测恢复约 6–7 拍
2. 无低延迟 D-Cache：towers 等 pointer chasing 直接暴露 10 拍内存延迟
3. BPU 仍是 BTB + 2-bit BHT；gshare/RAS 未接入
4. 关键路径仍是 `ROB → backend`；`main` C2 opt 55.47 MHz / 19.76k，
   频率分支 opt 72.73 MHz / 20.31k，阶段 1/2 的面积/频率门槛均未达
5. 双发射只在 ALU lane 生效；mem/div/branch 仍单端口
6. 频率分支已验证“非访存 IQ/PRF 分开”可行，但 load/store 仍直连 LSU；
   独立 memory issue queue（MIQ）尚未实现

---

## 3. 下一步：先频率/面积/分支预测，D-Cache 暂缓

2026-10-22 决策：**不要先做 D-Cache**。当前课程门槛是全有或全无：

| 指标 | `main` C2 | 频率分支 | 阶段 1 | 阶段 2 |
| --- | ---: | ---: | ---: | ---: |
| IPC | 0.6311 | 0.6084 | ≥ 0.6000 | ≥ 0.8450 |
| 面积（opt） | 19,759 µm² | 20,307 µm² | ≤ 9,000 | ≤ 18,000 |
| 频率（opt） | 55.47 MHz | 72.73 MHz | ≥ 300 | ≥ 300 |

IPC 已过阶段 1，但面积/频率差得更远；只把 IPC 提到 0.6 不会改变 85 分。
D-Cache 会增加面积、可能拖慢 ROB→backend 关键路径，而且 P2 的 4KB
阻塞式写直达原型已经测到 IPC 0.1543，不能直接重做。

建议优先级：

1. **先决定频率分支是否合入**：`feat/freq-alupipe` 已全绿，Fmax +31%，
   但面积 +0.55k、IPC -3.6%；接受后合入 `main` 再跑 opt 文档。
2. **频率继续（最高优先）**：关键路径仍是 ROB→backend，终点在 ALU
   结果寄存器。先试把 a0/a1 的结果捕获从 squash 组合使能路径上移走，
   再考虑两级 squash / MIQ；不要重复“把 load/store 放进流水级”的旧死锁。
3. **面积**：当前频率版 20.3k opt，距 18k 还差约 2.3k；需要 LSQ/ROB/BPU/
   I$ 的结构性缩减，单纯扫参数会把 IPC 压到 0.60 以下。
4. **分支预测**：gshare 必须保存预测时 GHR 快照；分支 `feat/gshare-snapshot`
   已有实现（LSQ32 上 IPC 0.7563，但面积 29.9k），未入默认。
5. **D-Cache 仅在计数器和面积预算允许时再做**：小型、非阻塞、
   写直达 + store buffer、带 MSHR/hit-under-miss；不要重复阻塞式 4KB。
6. **LSQ 增强**：store-to-load forwarding、non-blocking load、地址消歧。

路线判断：阶段 1 的 9k 面积非常激进；如果频率/面积压不下去，优先评估
阶段 2（面积 18k 更近，但 IPC 要 0.845），不要为了一个 IPC 指标盲目加
D-Cache。`main` 已打 tag `p2-dual-issue`，没有 `p2-stage1`。

---

## 4. 常用命令

```sh
# 默认 W=2
make build JOBS=4
make test MAX_CYCLES=50000000
REPO_ROOT="$(git rev-parse --show-toplevel)"
make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
make synth MODE=diagnose
make synth MODE=opt

# 单测
sh test/run_all.sh --build
sh test/lsu_test/run.sh
sh test/backend_test/run.sh
sh test/issue_queue_test/run.sh
sh test/rob_test/run.sh --quick
ROB_W=2 sh test/rob_test/run.sh --quick
sh test/rename_test/run.sh --quick
RENAME_W=2 sh test/rename_test/run.sh --quick
```

### W=1 构建（默认已是 W=2）

`cpu_config.sv` 默认 W=2，直接 `make build` 即可。W=1 用带
`CPU_ISSUE_WIDTH=1` 的 wrapper：

```sh
export REPO_ROOT="$(git rev-parse --show-toplevel)"

cat > /tmp/opencode/verilator_w1.sh <<'EOF'
#!/bin/sh
exec "${REPO_ROOT:?export REPO_ROOT}/cpu2026-tools-x86_64.AppImage" exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+CPU_ISSUE_WIDTH=1 "$@"' sh "$@"
EOF
chmod +x /tmp/opencode/verilator_w1.sh

make build FILELIST=verilog/filelist.f BUILD=build/w1 \
  VERILATOR=/tmp/opencode/verilator_w1.sh JOBS=4
```

W=1/W=2 的 correctness 都由队友记录为 19/19；本机独立复核了 W=2 19/19。

---

## 5. 硬性约束 / 坑

1. 不改 `scripts/`、`Makefile`、`config.mk`；参数用
   `python3 tools/config_gen.py` 生成，不手改 `cpu_config.sv`。
2. `verilog/filelist.f` 顺序：`rv32_defs.sv`、`cpu_config.sv`、`if_defs.sv`
   必须在前；顶层模块名必须是 `student_top`。
3. 不要再把基线 `student_top.sv` 加进 filelist（与 `student_top_ooo.sv`
   模块重名）。
4. 正常构建不能有 `$display`（污染 OJ stdout）；调试用
   `` `ifdef LOCAL_TRACE ``。
5. 不要向 `upstream` 模板仓库开 PR；只在个人 fork 上提交。
6. 不要提交 `build/`、VCD、日志、AppImage、`prompt.md`。
7. 没有跑过 perf/synth 就不要声称 IPC/面积/频率或“阶段通过”。

### P1 已修复、不要回归

- ROB：`recover_rat` 重放、`done_now_mask` 同拍 completion/recovery
- rename：恢复时排除同拍 wake
- frontend：BPU taken 寄存一拍重定向，断开 `flush → resp_valid` 环
- backend：dispatch skid、`skid_drain` 门控、skid stale-ready 更新、
  skid squash、统一 32-bit dispatch seq
- LSU：未启动请求的 squashed load 清理
- LSQ：组合块独立循环变量，避免 Yosys latch
- `core_ooo.sv`：`pc_out` 空连接已删除，不要加回

### 综合

- `make synth MODE=diagnose`：面积 breakdown
- `make synth MODE=opt`：最终面积/频率
- 报告在 `build/synth/<mode>/report.txt`
- `docs/perf-log.md` 已记录 P1/P2 perf、面积、频率和参数敏感度

---

## 6. 推荐阅读

1. `docs/integration-status.md`：P1/P2 结果、perf/synth 数据、下一步策略
2. `docs/plan/pipeline.md`：系统性流水化设计草案（当前/目标流水级、验收、风险）
3. `docs/plan/replay.md`：IQ/PRF 分开后的 replay / store 地址预填设计
4. `docs/experiments/freq-log.md`：频率实验记录（成功/失败/回滚原因）
5. `docs/plan/division.md`：P2/P3 工作包和验收标准
6. `docs/interface.md`：八条总线冻结接口
7. `README-ZH.md`：课程评分、工具链、命令

一句话：**P2 功能已全绿（W=2 双发射/双取指/流水访存，IPC 0.5507）；
下一步先做频率流水化、面积收缩和带 GHR 快照的 gshare/RAS，D-Cache 暂缓。**
