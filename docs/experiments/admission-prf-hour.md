# Rename admission fix and PRF sweep

## 派发接收修复与PRF缩减（2026-10-26，保留PRF64）

faa8c87修复core_ooo只看ren_ready、不看rename_ready的错误派发；tag不足时下游不再接收未分配指令。
旧W1/W2各72checks6fails，新各72checks0fails；新回归已加入run_all。
PRF56 hanoi从50M超时恢复为8863周期PASS，56两档各19/19。

| 当前配置（ROB32/IQ8/LSQ16/D$64B） | W2 IPC | W1 IPC | diagnose面积 µm² | 频率 MHz | 较ba7f吞吐 | 较ba7f单位面积吞吐 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 修复/PRF64 | 0.668276 | 0.590333 | 23,875.147 | 375.37 | +2.644% | -1.533% |
| 修复/PRF56 | 0.667723 | 0.590420 | 23,775.303 | 367.29 | +0.352% | -3.327% |

64四组各19/19、56两档各19/19并复用同源默认两档；完整run_allALLPASS。
两组plain/stats输入、答案、周期一致；24生产输入/7库/工具约束/实际综合容量与五档仿真容量（含实际PRF存储字数）核验。
相对ba7f仅cpu_config、LSU、core三个生产输入改变；每组一次有效diagnose，中断产物单独保留，不计有效PPA。
PRF56仅省99.844µm²（0.418%），频率下降2.152%、吞吐较PRF64下降2.233%，不采用。
TAG_PRESSURE：64六perf无tag不足；56仅rsort有7315拍tag_wait，其中5835拍free1/bundle2等待。
PRF52仅W2 IPC .661974、19/19，无PPA；PRF48完整回归18/19，statement_test期望50实得61，不采用也不报告完整IPC/PPA。
32B缓存仅三smoke+六perf IPC .659243（比64B低1.352%），未跑完整19项与PPA，不列完整核心表。
PRF48波形对照首个退休分歧index317，PC0xD4后的控制流不同；根因待查，证据位于build/cache_admission_prf_sweep_20261026/statement-diagnosis/。

内存事件：两综合重叠触发WSL严重内存压力，按用户暂停停止；恢复后严格一项综合持锁/tmp/riscv_cpu_synthesis.lock，其他仿真/构建可并行并监控内存。
两次完成的diagnose均已当场给出当前优化/ba7f基线/main同模式表。默认容量及main不改，无opt/合main/推送。
详见[派发修复与本轮结果](experiments/admission-prf-hour.md)。


Production source checkpoint: faa8c87. Archives: build/synth/cache_admission_fix_64/ and cache_admission_fix_56/.

The user paused the one-hour goal during WSL memory pressure and explicitly resumed it. Paused time is excluded. Existing completed builds/smokes/perf were reused only after matching24 source hashes and real PRF dimensions; interrupted complete correctness was restarted.

The PRF48 control-flow divergence remains unresolved. Do not claim all smaller PRFs work or merge them. Next investigation should inspect source tags, PRF operand values and recovery RAT around branch0xD4. The current corrected64 and56 configurations passed their stated full regressions.
