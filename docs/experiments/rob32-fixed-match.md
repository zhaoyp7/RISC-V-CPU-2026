# ROB32固定槽完成匹配：频率改善，面积目标未达（2026-10-25）

## 结果与决定

基于5394ea0创建feat/freq-rob32-match，迁移52d7c72的固定槽位匹配结构，只修改ROB完成搜索和写回路径。
W2实验参数ROB32/PRF64/IQ8/CDB2/LSQ16；默认cpu_config仍ROB16/PRF48，不扩IQ/LSQ。
验收目标为面积不超过原ROB32的23,406.633440 µm²、频率至少380 MHz，保持所有测试与perf周期不变。

| 配置与版本 | W2 IPC | diagnose面积 µm² | 频率 MHz | 相对旧ROB16的IPC×Fmax |
| --- | ---: | ---: | ---: | ---: |
| 旧ROB16/PRF48，1d142db | 0.538263 | 20,571.946 | 400.00 | — |
| 原ROB32/PRF64，5394ea0宏覆盖 | 0.607639 | 23,406.633 | 351.05 | -0.927% |
| 本轮ROB32固定槽匹配trial | 0.607639 | 23,429.641 | 376.47 | +6.248% |

相对原ROB32，频率+7.243%，面积+23.007240 µm²（+0.098%），IPC相同。
相对旧ROB16参考，IPC×Fmax+6.248%，面积仍+2857.695 µm²（+13.891%）。
频率目标还差3.53 MHz，面积不增目标也未达到；不将“基本持平”当作面积下降或完整验收通过。
**只保留独立trial检查点，不升级默认配置、不合main、不运行opt。** 本轮到此停止，不追加小补丁或第二次综合。

该结果比直接增大LSQ/IQ的组合有更好的吞吐/面积取舍，但仍未解决面积偏大的问题。
下一步应直接针对ROB表项与恢复网络做面积拆解，再选择能减少实际资源的结构改写，避免继续扩大容量。
若延续频率优化，需要另外处理新的前端准入链；不能把旧完成搜索继续当作首要瓶颈。

## 面积拆分

| ROB模块（含commit子模块） | 旧ROB16 | 原ROB32 | 本轮ROB32 |
| --- | ---: | ---: | ---: |
| 面积 µm² | 2,705.392 | 5,322.006 | 5,381.216 |
| 时序单元 µm² | 593.989 | 1,052.384 | 1,052.384 |
| 组合逻辑 µm² | 2,111.403 | 4,269.622 | 4,328.831 |

本轮没有删除表项字段或减少存储容量，ROB本身面积约增加59.209 µm²。
总面积只增加23.007 µm²，是其他模块映射变化共同作用的结果，不代表ROB变小。
完整面积为组合16,054.286、时序6,214.404、SRAM1,160.951 µm²；与原ROB32的时序和SRAM面积相同。

## 改动与语义

逐物理槽比较valid/dest_tag，以寄存head推导环形先后关系，选择最年轻同tag命中；保持原扫描的最后命中规则。
one-hot资格直接写固定槽位done/exception，广播valid在写入处门控。
恢复done_now_mask在命中时直接索引广播tag，避免编码槽号后再次读取dest_tag。
无命中、tag0、同拍多源异常、分配最后写优先级、分支恢复和提交语义均保留。
不新增流水级或额外寄存阵列，现有单槽准入count<DEPTH与in_capacity前缀保持不变。
未迁移旧trial的其他RTL/文档，保留当前单槽in_ready条件；生产输入只有verilog/rob.sv改变，另23个保持一致。

## 功能与周期验证

- ROB独立有序队列参考，W1/W2完整50,000拍随机及定向检查108,050/108,048项零失败。
- 覆盖全部32个head位置、重复tag跨回绕、无效广播、年轻项被取消、再次匹配、异常和恢复边界。
- ROB32的W1/W2与默认ROB16的W1/W2四组，均依次qsort→hanoi→queens后通过官方19/19。
- 四组全部19项正确性与6项perf周期都与各自基线逐项相同；ROB32 W2/W1 IPC0.607638658854/0.549105278548。
- 当前RTL默认16项的W2/W1 IPC仍0.538262837589/0.504222699251；只作功能/IPC兼容性结论，没有给这份RTL的默认16项复用旧PPA。
- 最终sh test/run_all.sh ALL PASS，包含上一轮LSQ32矩阵；无新增IMPLICIT/UNDRIVEN/LATCH。
- ROB32普通/统计版输入、答案、周期一致；全部模块计数器逐项等于原ROB32统计基线，所有排他分类与SAFE_WAKE检查通过。

stats collector新增--stats-sim（要求--skip-build），用独立统计目录复用预构建仿真器，避免覆盖旧统计基线。
通过本轮真实采集验证该入口；默认CLI行为不变。

## 当前首条关键路径

原首条是ROB取消→LSU结果资格→CDB tag→ROB完成搜索/恢复busy寄存器，D端2.793 ns。
本轮首条为ROB取消→LSU结果资格→CDB ready→ALU分支更新资格→ROB准入→rename就绪→前端I$捕获，D端2.616 ns。
关键边界到达：squash索引0.083 ns、LSU squash_seq 0.594 ns、load_result_valid 1.098 ns、
CDB src_ready[0] 1.371 ns、br_update_valid 1.565 ns、ROB in_ready 1.934 ns、rename in_ready 2.230 ns、
I$ fetch_valid 2.421 ns、最终D端2.616 ns。它已经转为前端准入控制链，不能继续用旧路径定位描述当前瓶颈。
端点u_core/u_rob/_121418_/QN→u_core/u_front/u_icache0/_4811_/D；最小周期2.65625 ns，2 ns WNS约-0.6560 ns。
仅凭当前全局首条不能精确量化ROB完成搜索自身缩短了多少；旧16项试验的0.385 ns不冒充本轮32项数据。

## 综合、来源和归档

一次完整make synth MODE=diagnose，实际约9.40分钟，无中断/重试，无opt。
24个候选源码hash与报告/归档/统计一致，比较基线仅ROB变化；7个库hash、工具版本、SRAM、ABC约束及SDC均相同。
独立Yosys wrapper把宏定义写在实际脚本首行；完整展开确认ROB32/PRF64/IQ8/LSQ16，五份C++仿真器容量均核对正确。
宏配置保存于configuration.json，源码hash不能替代宏配置；默认main报告和build/sim未覆盖。
所有数据在build/synth/rob32_fixed_match/：inputs/、baseline-inputs/、configuration.json、diagnose/、
w1/w2/stats/default_w1/default_w2仿真器、validation-results.json、functional-validation.json、statistics/及comparison.json。
四组回归驱动与所有日志均归档，完整默认16项旧版对照日志仍保留在uncontended_wake_candidate/。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose \
  SYNTH_OUT=build/synth/rob32_fixed_match \
  YOSYS="$REPO_ROOT/build/synth/rob32_fixed_match/yosys.py"
python3 tools/perf_stats/collect.py --skip-build \
  --plain-sim build/synth/rob32_fixed_match/w2/sim \
  --stats-sim build/synth/rob32_fixed_match/stats/sim \
  --reference-report build/synth/rob32_fixed_match/diagnose/report.json \
  --out build/synth/rob32_fixed_match/statistics
```

REPO_ROOT为仓库绝对路径；重测必须另建输出目录保护旧报告。回归使用归档validate_rob32_fixed_match.py及同目录宏wrapper，
每个宽度走官方make build/test/perf MAX_CYCLES=50000000；功能RTL、参数manifest和wrapper必须成套保留。
