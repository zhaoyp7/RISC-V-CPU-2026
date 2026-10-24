# IQ年龄关系检查点：opt与diagnose对比（2026-10-24测量）

用户在追加ROB试验回退后授权运行一次opt，比较当前保留的402.36 MHz基线。
启动于2026-10-24 23:32（Asia/Shanghai），工作分支feat/freq-rob-completion-match，
运行前HEAD为69be061；全部RTL与ba7ceb6 / freq-r3-age-matrix-20261024一致。
未采用404.26 MHz的ROB完成固定槽位匹配trial。

## 固定输入与复现

修改前已核对diagnose的24个源码输入hash，面积20,505.023900 µm²，
Fmax402.357564 MHz，最小周期2.4853515625 ns，2 ns目标WNS -0.484783 ns。
W2/W1 IPC0.522108164152558 / 0.4988444806718703；对应RTL已通过W1/W2各19/19、
run_all ALL PASS，新ROB边界在原RTL28,024/27,978项通过。RTL未改，不重复功能回归。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=opt
```

本次只运行一次opt，不追加RTL实验、不合main、不推送。官方filelist、配置、SRAM包装器、
Makefile与综合/时序脚本保持不变。目标时钟2 ns，ABC driving cell INVx1_ASAP7_75t_R，
负载5 fF，Yosys0.63/OpenSTA3.1.0；同一组ASAP7 RVT TT与fakeram库。

脚本的diagnose使用hieropt，opt使用flatten；随后均执行同类ABC映射及OpenSTA分析。
跨模块优化会改变实际逻辑、缓冲与尺寸选择，频率与面积以最终实测为准。

## 状态与归档

opt已完成，24个源码输入（含顺序）、7个库文件hash、工具版本、SRAM模型及全部时序约束均一致。
基线与opt的完整报告/网表、24个源码快照、运行元数据run.json与comparison.json均已归档至
`build/synth/iq_age_matrix_opt_checkpoint/`，默认diagnose/与opt/报告分别对应402.36/456.12 MHz。
日志为`/tmp/iq-age-matrix-opt.log`；之前取消的opt仍在opt_cancelled_20261023/，不作为有效数据。

## 最终对比

| 指标 | diagnose | opt | 变化 |
| --- | ---: | ---: | ---: |
| 总面积 µm² | 20,505.023900 | 19,808.712260 | -696.311640（-3.396%） |
| 组合逻辑面积 µm² | 13,750.485480 | 13,126.199040 | -624.286440（-4.540%） |
| 时序单元面积 µm² | 5,593.587840 | 5,521.562640 | -72.025200（-1.288%） |
| SRAM面积 µm² | 1,160.950580 | 1,160.950580 | 0 |
| Fmax MHz | 402.357564 | 456.124722 | +53.767158（+13.363%） |
| 最小周期 ns | 2.4853515625 | 2.1923828125 | -0.2929687500 |
| 2 ns目标WNS ns | -0.484783 | -0.191631 | +0.293152 |

WNS对应2 ns（500 MHz）分析目标，Fmax由最小可行周期搜索得到。面积与频率均改善，
未改架构、流水拍数或CPU参数。主要面积节省来自组合逻辑，时序单元面积也略减；
不把RTL寄存器数量不变等同于综合后时序单元面积必然不变。

本轮唯一一次opt成功退出，映射后结构检查0 problems；没有再次综合或重跑diagnose。
报告写入于2026-10-24 23:39:51（Asia/Shanghai），距离启动约440.32秒（7分20秒），
早于原估计的25～30分钟。完成时间以报告文件写入时间记录，归档核对时间另记verified_utc。

opt首条映射路径为`_376084_/QN → _376646_/D`，D端到达2.137 ns；扁平化后实例已匿名化，
本轮仅保存完整路径，不直接用旧层级名称推断其所属运算。完整明细见opt/timing.rpt和report.json。

检查点标签`freq-age-matrix-opt-20261024`；测量前HEAD69be061，RTL与ba7ceb6完全一致。
现有W1/W2各19/19、run_all ALL PASS及两档IPC仍对应同一份RTL；本次没有声称新增
门级功能回归。main保持bc795ae，未合并、未推送；原取消opt归档和历史main报告均保留。
