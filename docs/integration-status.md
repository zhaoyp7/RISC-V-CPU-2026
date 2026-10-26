# 集成状态（P1 完成，P2 进入性能优化）

## 最新实验：64B读缓存暂不采用（2026-10-26）

分支feat/ipc-lsu-read-cache，功能37e3b1d；默认缓存关闭，main仍f4a0555。
ROB32+64B缓存：W2/W1 IPC0.654101/0.582267，diagnose23800.891µm²/329.47MHz；
较ba7f0a3 IPC+5.292%，频率−16.248%，IPC×频率−11.816%，不升级默认。
四配置各19/19、run_allALLPASS、plain/stats输入答案周期一致，24源码/7库/约束和实际尺寸已核验。
128B/256B仅IPC0.664876/0.671951，ROB16+64B0.580314，均19/19，无PPA。
首版W2 queens触发已有FIFO槽年龄残留bug，37e3b1d修复并有原版失败回归；默认关闭但含修复的RTL没有单独PPA，不能沿用旧频率。
下一步应隔离store排空地址→LSU读结果→CDB/PRF长链，再评估查找/选择寄存化；尚未实现。
本次连续执行授权到07:30未达成，约01:27后执行长间隔，09:52恢复检查，原因未确认；恢复后只做已有结果核验与记录。
无opt/合main/推送；详见[缓存实验](experiments/lsu-read-cache.md)。以下为历史检查点。


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

## 频率流水化分支（`feat/freq-alupipe`，2026-10-23，未合并）

- 分支 HEAD `fa8920f`，只改 `verilog/backend_ooo.sv`；未合入 `main`。
- lane1 和 lane0 非访存都改为“IQ 选择 → a0/a1 缓冲 → PRF/ALU”两级；
  load/store 仍直连 LSU，避免旧 `feat/pipeline-iq` 的访存所有权死锁。
- PRF 从 4 读口扩到 6 读口。
- 验证：W2 19/19、W1 19/19、`run_all` ALL PASS。
- W2 IPC 0.6084（C2 0.6311，-3.6%）；W1 IPC 0.5759（C2 0.5940，-3.1%）。
- diagnose：21,092.6 µm² / 67.91 MHz；opt：**20,306.7 µm² / 72.73 MHz**。
- 相对 C2 opt（19,759.4 / 55.47）：面积 +2.8%，Fmax +31.1%，IPC -3.6%，
  `IPC × Fmax` +26.4%。
- 关键路径仍在 `ROB → backend`，终点为 ALU 结果寄存器；下一步可试
  squash 结果捕获路径或 MIQ，不要先做 D-Cache。

## P2 当前结果（RTL `a95a938`，2026-10-22）

- **W=1 correctness：19/19 PASS**；**W=2 correctness：19/19 PASS**（`MAX_CYCLES=50,000,000`）。
- 单元测试：`sh test/run_all.sh` → **ALL PASS**（frontend W=1/W=2 已适配
  双 bank I$ 和 wake mask；LSU、mem_subsystem、backend 三套 P2 测试已适配
  并加入 `run_all.sh`）。
- 2026-10-22 本机独立复核：W=2 19/19；perf 0.5507；synth opt
  24,288.346 µm² / 56.08 MHz，与队友记录一致。
- `tools/config_gen.py --check`：up to date（默认值已切到 P2 双发射配置）。
- perf（官方 OoO filelist，W=2）：P2 基线 IPC geomean **0.5507**；W=1 为
  0.5017。2026-10-22 加入 store 地址预填后，W=2 IPC 提升到 **0.6380**。
  2026-10-23 默认 LSQ 提高到 32（`116cbb8`），W=2 IPC 进一步提升到
  **0.7295**（qsort 0.5100、rsort 0.8622、vvadd 1.1447）；W=1 复测
  19/19 PASS、IPC **0.6336**。LSQ 16/32/64 的扫描显示 32 已饱和。
- synth（ASAP7，2 ns 目标）：P2 基线 opt **24,288.346 µm² / 56.08 MHz**；
  diagnose 25,025.438 µm² / 53.93 MHz。LSQ8 的 opt 为
  **24,468.759 µm² / 56.72 MHz**。LSQ32 的 diagnose 为 28,444.463 µm² /
  54.27 MHz。当前默认 C2（`1e99cc8`）opt **19,759.4 µm² / 55.47 MHz**
  （diagnose 20,262.8 µm² / 53.44 MHz），IPC 0.6311；距 18k 还差 1.76k。
  tournament gshare（`9666237`）IPC 0.7563，但面积 29,896.7 µm²，
  保留在实验分支。
- **未达到课程阶段门槛**：阶段 1 需要 9,000 µm²、IPC 0.6000、300 MHz；
  IPC 已过 0.6，但面积/频率仍差很远；阶段 2 的 18,000 µm² 也未满足。
- 2026-10-22 修复 ROB16 恢复竞态（`ab00273`）：恢复拍停止提交，避免
  rename 装载快照时丢失 ROB crat/free 更新。ROB16 配置现已 19/19 PASS。
- 参数扫描：C2（ROB16/PRF48/LSQ16/1KB I$/BTB32/BHT128）IPC 0.6311，
  diagnose 20,262.8 µm² / 53.44 MHz；C3（RS4/512B I$/BTB16/BHT64）
  IPC 0.5917，预计面积接近 18k。面积与 IPC 仍无法同时满足阶段 2。
- 双发射、双 bank 取指、双 CDB、流水化 load/store、store-to-load forwarding、
  取指侧 BPU 预测均已接入；D-Cache 原型因阻塞式 miss 反而降低 IPC，已回退。

### P2 关键改动

1. 前端改为双 bank I-Cache（pc/pc+4 各一个 refill 口），fetch 请求 FIFO
   解耦取指与 rename；取指侧 BPU 预测消除 taken 分支的一拍气泡。
2. IQ 支持每拍两条发射；第二 ALU、两条 CDB；wake 改为 PRF 掩码，支持
   同拍多条完成。
3. load/store 改为流水化：多笔在途 load、按序响应；store 流水 drain；
   同地址整字 store-to-load forwarding；store 在 issue 时发送给 LSQ。
4. mem_subsystem/axi_mem_if 支持多笔在途读、流水写和 I$ 双 refill 客户。
5. 分支解析改为 issue 当拍组合发送 `br_update`，ROB redirect 也改为组合
   输出，缩短恢复路径。

### 下一步策略（2026-10-22）

**先频率/面积/分支预测，D-Cache 暂缓。**

- 当前 IPC 0.5507，距离阶段 1 只差约 9%；但面积 24.3k（阶段 1 ≤9k、
  阶段 2 ≤18k）和频率 56.08 MHz（≥300 MHz）差得更远。只把 IPC 提到 0.6
  不会改变 85 分，因为门槛是全有或全无。
- P2 的 4KB 阻塞式写直达 D-Cache 原型 IPC 只有 0.1543，已回退；直接重做
  风险高，且会增加面积、拖慢 ROB→backend 关键路径。
- 优先顺序：
  1. 性能计数器/停顿分类（branch/I$/D$/IQ/ROB/LSU/CDB/divider）；
  2. 频率流水化：ROB recovery、IQ select/wakeup、ALU 乘法器、
     I$ tag/BPU 路径；
  3. 面积参数收缩：ROB/PRF/IQ/LSQ/I$/BTB/BHT；
  4. 分支预测：gshare 保存预测时 GHR 快照 + RAS；
  5. D-Cache 仅在计数器证明 load stall 主导且面积预算允许时再做，
     采用小型、非阻塞、写直达 + store buffer 的形态。

### 复现命令

```sh
python3 tools/config_gen.py --check
make build JOBS=4
make test MAX_CYCLES=50000000          # 本机约 45 s
make perf MAX_CYCLES=50000000
make synth MODE=diagnose               # 本机约 716 s
make synth MODE=opt                    # 本机约 25 min
# W=1 档：默认是 W=2，用 +define+CPU_ISSUE_WIDTH=1 的 wrapper
sh test/run_all.sh
```

---

# P1 集成状态（2026-10-18）

## 最终结果：P1 PASS

- **W=1 correctness：19/19 PASS**（`MAX_CYCLES=50,000,000`）
- **W=2 smoke：7/7 PASS**（add_to_100、expr、gcd、naive、manyarguments、
  multiarray、bulgarian）
- 全部单元测试 PASS；官方 `sh test/run_all.sh --build` → **ALL PASS**
- tag：`p1-ooo`（功能集成）、`p1-ooo-official`（官方 filelist 切换）
- **官方 `verilog/filelist.f` 已切换到 OoO 顶层**；官方
  `make test MAX_CYCLES=50000000` → **19/19 PASS**；官方 filelist 的
  W=2 smoke → **7/7 PASS**。

### W=1 记录（cycles）

| case | cycles |
| --- | ---: |
| correctness_add_to_100 | 2,401 |
| correctness_expr | 2,002 |
| correctness_gcd | 1,464 |
| correctness_naive | 849 |
| correctness_manyarguments | 860 |
| correctness_multiarray | 9,483 |
| correctness_bulgarian | 1,450,991 |
| correctness_hanoi | 26,010 |
| correctness_lvalue2 | 904 |
| correctness_magic | 3,170,417 |
| correctness_pi | 21,204,137 |
| correctness_qsort | 4,667,870 |
| correctness_queens | 1,891,253 |
| correctness_statement_test | 4,495 |
| correctness_superloop | 1,059,467 |
| correctness_tak | 9,446,589 |
| correctness_array_test1/2 | 1,867 / 2,193 |
| correctness_basicopt1 | 761,342 |

### W=2 smoke 记录

add_to_100 2,407；expr 1,877；gcd 1,458；naive 837；manyarguments 863；
multiarray 9,511；bulgarian 1,448,579。全部 PASS。

## 复现命令

```sh
# W=1 全量 correctness
make build FILELIST=test/integration/filelist.f BUILD=build/ooo JOBS=4
python3 scripts/testcase.py --build build/ooo --kind correctness \
    --max-cycles 50000000 --latency 10

# W=2 smoke（需要带 define 的 Verilator wrapper，见 docs 记录）
make build FILELIST=test/integration/filelist.f BUILD=build/ooo_w2 \
    VERILATOR=/path/to/verilator_w2.sh JOBS=4
python3 scripts/testcase.py --build build/ooo_w2 \
    --case correctness_add_to_100 --max-cycles 50000000 --latency 10
```

W=2 wrapper 的内容：

```sh
#!/bin/sh
exec <repo>/cpu2026-tools-x86_64.AppImage exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+CPU_ISSUE_WIDTH=2 "$@"' sh "$@"
```

## P0/P1 交付

- P0：`tools/unit/build.py`、divider 边界修复、`mem_subsystem` v1、
  RV32IM 黄金模型/`trace_diff`、接口复核、`p0-baseline` tag。
- P1 后端：`prf.sv`、`cdb.sv`、`issue_queue.sv`、`lsu.sv`、`lsq.sv`、
  `backend_ooo.sv`、`stub_front_ooo.sv`，含 W=1/2 单测。
- 集成：`verilog/student_top_ooo.sv`（模块名 `student_top`，现为官方
  顶层）、`verilog/filelist.f`（官方 OoO filelist）、
  `test/integration/filelist.f`（历史 test-only filelist）。

## 集成期间定位并修复的问题

1. **ROB 恢复丢失在飞 RAT**：`rename` 恢复时只装载 `crat`，丢失 branch
   自身及更老在飞 uop 的 rd 映射。`rob.sv` 新增 `recover_rat`，按程序序
   从 `crat` 重放 branch 及更老表项。
2. **同拍 completion / recovery 竞态**：ROB 的 `recover_busy_mask` 采到了
   CDB/complete 置 done 前的状态，把刚完成的 tag 重新标 busy。`rob.sv`
   增加 `done_now_mask`；`rename.sv` 恢复时排除本拍 wake tag。
3. **前端 BPU 预测未驱动 PC**：预测 taken 时仍顺序取 fall-through。
   `frontend_ooo.sv` 用寄存一拍的 `bpu_redirect_q` 重定向 PC 并 flush
   I-Cache，同时避免 `bpu_redirect → flush → resp_valid` 组合环。
4. **ready/valid 组合环**：`backend_ready → ren_ready → dispatch.valid →
   iq/lsu ready → backend_ready` 会振荡。`backend_ooo.sv` 增加 dispatch
   skid buffer；IQ 用寄存后的 `in_alloc_mask` 计容量，LSQ 用 `alloc_fire`
   控制真正分配。
5. **skid 中的 stale ready**：skid 停住期间 producer 的 CDB 已过，保存的
   `src_ready` 不会更新。skid 在 hold 期间用 CDB wake 更新 ready 位，并在
   捕获新组时做同拍旁路。
6. **squash 边界不一致**：IQ/LSQ/skid/LSU 原来用 `rob_idx` 模 32 的半窗口，
   ROB 用 age；两者在回绕边界不一致，导致旧 store/load 残留。统一改为
   32-bit dispatch seq：ROB squash 点映射到 `squash_seq`，后端按
   `seq > squash_seq` 清理。
7. **squash 后已发射结果仍广播**：ALU/divider/branch-complete/store-complete
   按 seq 过滤；divider 在跑的 uop 用 discard 标记。
8. **load 被误 squash 后永久占住 LSU**：请求尚未真正发出时被 squash，
   `load_active/load_inflight` 永远不清。`lsu.sv` 在请求未启动时直接取消；
   已在途的读响应丢弃。

## P1 性能与综合（官方 OoO filelist）

### perf（`make perf MAX_CYCLES=50000000`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 46,505 | 0.1497 |
| perf_multiply | 21,722 | 64,422 | 0.3372 |
| perf_qsort | 139,900 | 862,789 | 0.1621 |
| perf_rsort | 195,719 | 1,105,270 | 0.1771 |
| perf_towers | 5,278 | 55,429 | 0.0952 |
| perf_vvadd | 4,524 | 26,869 | 0.1684 |
| **GEOMEAN** |  |  | **0.1689** |

说明：P1 的目标是功能打通，不是性能门禁；0.1689 是当前 OoO 实现的真实
IPC，主要受 branch/I-Cache 停顿和单发射后端限制。P2 再针对 IPC 做优化。

### 综合（ASAP7 / 2 ns 目标）

| mode | total area (µm²) | comb (µm²) | seq (µm²) | SRAM (µm²) | Fmax | min period | WNS vs 2 ns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| diagnose | 17,383.665 | 10,569.232 | 4,578.528 | 2,235.905 | 63.53 MHz | 15.7412 ns | -13.7406 ns |
| opt | 17,204.622 | 10,394.855 | 4,573.863 | 2,235.905 | 64.48 MHz | 15.5098 ns | -13.5088 ns |

- 关键路径（diagnose）：`u_core/u_rob` → `u_backend`。
- `opt` 相比 `diagnose`：面积减少 179.043 µm²，Fmax 提高 0.95 MHz。
- 2 ns（500 MHz）目标未达到；当前 Fmax 约 64 MHz。P1 只要求综合可跑通，
  时序优化留到 P2/P3。
- 综合修复：`lsq.sv` 各组合块使用独立循环变量，避免 Yosys 对复用 `i`
  推断 latch；`core_ooo.sv` 删除未使用的 `pc_out` 空连接。

## 后续

1. 官方 filelist 已切换；下一步跑 `make perf` / `make synth`，记录真实
   IPC/面积/频率（P1 尚未做性能门禁）。
2. P2：W=2 双发射后端、D-Cache、mem_subsystem 三方仲裁。
3. 保留基线 `core.sv`/`icache.sv`/`student_top.sv` 作为回滚点。
