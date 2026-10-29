# ROB恢复掩码与存活判定固定槽位化（2026-10-25）

## 结果与决定

基于dca7d77的恢复RAT树，分支feat/area-rob-recovery-masks；保留独立检查点area-rob-recovery-masks-20261025。

| 版本（ROB32/PRF64/IQ8/LSQ16） | W2 IPC | diagnose面积 µm² | 频率 MHz |
| --- | ---: | ---: | ---: |
| 恢复RAT树dca7d77 | 0.607639 | 23,281.158 | 376.47 |
| 固定槽恢复网络 | 0.607639 | 22,878.356 | 375.23 |

全核面积减少402.801660 µm²（1.730%），频率下降0.330%，IPC不变，单位面积吞吐改善1.425%。
未完全满足最初的频率不降目标；以当前压面积方向，接受这次小幅频率代价，保留独立候选，未升级默认或合main。
四组各19/19且全部正确性/perf周期不变，完整run_all ALL PASS；ROB完整随机W1/W2 131698/131696零失败。
普通/统计版六项输入、答案、周期和全部计数器与dca7d77相同；一次有效diagnose约12.63分钟，没有opt。

## 实验依据

基于dca7d77的恢复RAT树；分支feat/area-rob-recovery-masks，宏ROB32/PRF64/IQ8/CDB2/LSQ16。
原掩码仍按head旋转读取所有ROB字段，并动态写free/busy；LSQ指针也以程序序循环覆盖。
基线全核23,281.157960 µm²/376.470588 MHz，ROB5,232.733 µm²；恢复掩码独占806.289 µm²。
面积锥包含共享逻辑，不可相加，也不能把独占面积全部视作可回收资源。

## 改写

每个物理槽计算(slot-head)环形年龄，产生recovery_keep与recovery_live；RAT、掩码、LSQ指针和flush共用。
free/busy按常量物理tag分别归约committed/live/pending匹配；非写回项仍占其完成tag，tag0固定不释放且不busy。
保留原busy_mask_c & ~done_now_mask，确保同拍CDB/complete不产生错误busy，包含重复tag的接口测试语义。
LSQ指针选最年轻存活访存项，以(wrapped,slot)排序平衡树选原始id，再统一执行加一/回绕；无存活访存项取0。
flush直接清除不满足keep的物理槽，保留分支及更老项。没有新增流水级、状态阵列、容量或执行资源。

## 验证依据

新增run_recovery_mask_boundaries，独立参考仍是程序序deque，遍历32个head、branch在0/15/31、满窗口、非写回tag、
高位已提交tag63、同拍完成、LSQ指针回绕与空访存前缀；先在原RTL通过W1/W2 131698/131696，再对候选通过同样检查。
完整随机50,000拍，未用RTL物理槽排序或树结构构造参考。当前候选ROB单测无新增锁存/环/隐式网警告；
新增LSQ根节点wrapped未被使用的UNUSEDSIGNAL提示，不影响功能。

## 测量口径

保持默认cpu_config、Makefile/config.mk/scripts/filelist及SRAM不变。与同容量、同模式的dca7d77比较。
验收目标：正确性和全部测试/perf周期相同，面积下降且守住376.47 MHz；实际结果写入最终记录。
默认16项只作兼容性/IPC回归，不借用旧默认16的400MHz PPA。
独立归档build/synth/rob_recovery_masks/，保护已有报告与main默认归档；仅一次diagnose，不自动opt/合main/推送。

## 实际面积来源与时序

| 区域 | 原逻辑锥 µm² | 新逻辑锥 µm² | 原独占 µm² | 新独占 µm² |
| --- | ---: | ---: | ---: | ---: |
| 恢复free/busy掩码 | 1340.879 | 1115.443 | 806.289 | 602.460 |
| 恢复LSQ指针 | 585.810 | 427.821 | 123.463 | 26.915 |
| 其余状态更新 | 1853.031 | 1765.419 | 1258.444 | 1178.895 |

锥之间共享，不可相加。ROB总面积5,232.733→4,808.892 µm²，减少423.841；全核净减少402.802，
因为未改RTL的其他模块也出现映射变化（例如IQ+53.071、LSU-23.095、rename-11.139 µm²）。
ROB时序面积减少0.2916 µm²，恢复掩码接收寄存器127→126，为常量位被优化；没有新增状态或流水。
面积分析工具补充处理零输入tie单元输出，基线重跑结果与原归档一致；不因常量输出停止追踪。

首条仍穿过ROB→backend/LSU/CDB→ROB/rename准入→frontend/I$，D端到达2.625 ns（原2.616），最小周期2.665039 ns。
小幅频率下降是真实同模式报告差异，不宣称本轮提高Fmax。后续面积候选仍有完成匹配的D×D年龄矩阵和旋转分支查找。
用户询问IPC后，下一步先做load路径分段测量和数据局部性分析；外部响应和load-use链是重点，不自动扩窗口或重做阻塞缓存。
当前qsort/rsort队首load等待48.5%/49.3%，其中已发请求等内存35.2%/41.0%；ROB满/单槽1.5%/1.8%，
这些统计包含关系明确，不相加或直接折算可节省周期。

## 最终核验与归档

24候选输入hash与工作树、报告、归档、统计一致，仅verilog/rob.sv较dca7d77不同；其余23项相同。
7库hash、工具版本、SRAM、时序参数、SDC和ABC约束匹配，Yosys实际展开32/64/8/16及五份仿真器容量核验通过。
ROB32 W2/W1 IPC0.607638658854/0.549105278548；默认16两档0.538262837589/0.504222699251，默认16没有本RTL的PPA。
main仍f4a0555；默认build/sim、build/synth/diagnose与opt保留旧main产物，不覆盖、不复用。
归档build/synth/rob_recovery_masks/：基线/候选inputs、configuration、所有wrapper、四组测试/perf、普通/统计结果、
基线与候选ROB日志、unit-all、源报告与新旧逻辑锥、comparison/verification及复现驱动。
配置忽略规则另有提交afd4914；本轮无opt/合main/推送，用户持续自主工作/Git授权保持。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose SYNTH_OUT=build/synth/rob_recovery_masks \
  YOSYS="$REPO_ROOT/build/synth/rob_recovery_masks/yosys.py"
python3 tools/perf_stats/collect.py --skip-build \
  --plain-sim build/synth/rob_recovery_masks/w2/sim --stats-sim build/synth/rob_recovery_masks/stats/sim \
  --reference-report build/synth/rob_recovery_masks/diagnose/report.json --out build/synth/rob_recovery_masks/statistics
```

REPO_ROOT为仓库绝对路径；重跑应另设归档保护已测报告。
