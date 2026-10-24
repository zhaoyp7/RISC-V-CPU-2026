# ROB完成广播固定槽位匹配（2026-10-24）

## 基线与目标

用户在四轮优化结束后授权再做一轮，仍不跑opt、不合main、不推送。
分支`feat/freq-rob-completion-match`，基于af4e794，RTL同ba7ceb6。
基线：diagnose 20,505.023900 µm² / 402.357564 MHz；W2/W1 IPC0.5221/0.4988。
修改前核对24个输入hash，完整报告和仿真器归档于
`build/synth/rob_completion_match_baseline/`。

首条路径ROB取消→LSU结果valid→CDB tag→ROB完成搜索，累计
0.070/0.528/1.072/1.442/2.425 ns。原完成搜索按head循环动态索引表项、编码最后命中
的槽号，再通过槽号写回done/exception；本轮尝试固定物理槽位并行比较及one-hot写回。

## 改动与等价关系

每个CDB/complete端口独立比较固定表项的valid与dest_tag。由寄存head提前计算
物理槽位间的环形先后关系，命中且没有更年轻命中的槽位才得到one-hot更新资格。
保持原“从head扫描的最后命中”规则，即使接口测试同时给出多个相同tag也不改为全部完成。
广播valid仅在状态更新处门控；done和exception仍在原时钟沿更新，分配的最后写入优先级不变。

恢复用done_now_mask在有命中时直接索引广播tag，因命中表项的dest_tag必与它相等，
无需先编码槽号再读取tag。tag0过滤、无命中忽略、同拍多源完成/异常与分支恢复语义不变。
不改branch查找、提交、CDB、LSU、IQ、配置或官方filelist；不增加流水拍数。
支持原有按MASK循环的2次幂ROB深度。

## 验证准备

增强原有序队列参考：时钟沿前从队尾反向查找最年轻命中，保存其槽位，在后续状态更新
时只修改仍存活的目标；不使用RTL的物理优先矩阵。新增遍历全部32个head位置的两类完成
端口边界：重复tag跨回绕、无效广播不写状态、带异常的年轻重复项被squash、再次完成存活项。
新测试先在原RTL运行，两档28,024/27,978项均通过；改写后两档相同检查均通过。
qsort/hanoi/queens依次通过，W2全量19/19及六项perf通过，周期与基线一致。
LOCAL_STATS lint退出0，无新增IMPLICIT/UNDRIVEN/LATCH，保留既有IQ树节点的两条假依赖提示。
W1/W2全量各19/19、完整run_all ALL PASS、配置检查通过。两档全部19项correctness及
六项perf周期均与基线逐项相同；W2/W1精确IPC为0.522108164152558/0.4988444806718703。

随后按qsort→hanoi→queens顺序冒烟，首错即停，再运行W1/W2各19项、两档perf、完整run_all、
配置检查及一次diagnose。使用`/tmp/freq_four_validate.py rob-completion-match`，命令与
[四轮记录](four-rounds.md#复现与归档约定)一致；W1目录`build/rob_completion_match_w1/`。
候选归档`build/synth/rob_completion_match/`，日志`/tmp/rob-completion-match-*.log`。

## 实测与决定

| 指标 | 402.36 MHz基线 | 固定槽位匹配trial |
| --- | ---: | ---: |
| diagnose面积 µm² | 20,505.023900 | 20,487.732020 |
| diagnose Fmax MHz | 402.357564 | 404.263719 |
| 最小周期 ns | 2.48535156 | 2.47363281 |
| 2 ns目标WNS ns | -0.484783 | -0.473432 |
| W2 / W1 IPC | 0.5221 / 0.4988 | 0.5221 / 0.4988 |

频率+0.47375%、面积-17.29188 µm²（-0.08433%），IPC及两档全部周期相同。
一次diagnose、24个输入hash一致，结构检查0 problems。按既定小收益回退准则，
不替换402.36 MHz检查点；保留trial `freq-rob-completion-match-trial-20261024`供后续组合。
回退只恢复ROB RTL及基线报告/仿真器，保留独立参考和新增边界测试。不跑opt、不合main、不推送。

## 映射网表补查：ROB确有改善，ALU形成相邻瓶颈

对基线和trial的已有网表各补做一次OpenSTA查询，约束/库/负载均与正式报告一致，
没有重新综合，也没有修改官方时序脚本。查询从ROB寄存器经CDB输出到ROB寄存器，
以及通过ALU a输入的最长路径，完整结果归档于两份报告目录的`focused/`。

| 约束路径 | 基线D端到达 ns | trialD端到达 ns |
| --- | ---: | ---: |
| ROB→LSU→CDB→ROB | 2.4252 | 2.0403 |
| a0源tag→PRF→ALU→结果捕获 | 2.4104 | 2.4138 |

ROB段从CDB输出后到D端约0.983→0.581 ns；整条相关路径缩短约0.385 ns。
trial新首位是a0源tag[0]→PRF→ALU a[4]→y[29]→后端结果寄存器，累计
0.083/0.425/0.532/2.385/2.414 ns。ALU内部约1.853 ns，是当前候选的主要剩余段。
基线中ALU路径本就紧邻ROB路径，因此单独改善ROB只提高全核约0.47%。
后续如获授权，先核查ALU这条数据路径的具体运算，再考虑与本trial组合；不直接
将其认定为某一种乘法或加法操作，也不在本轮继续新RTL实验。

最终回退已完成：trial提交52d7c72，复核标签freq-rob-completion-review-20261024。
默认报告与W2仿真器已恢复402.36 MHz，24个输入hash一致，全部RTL逐文件与af4e794/ba7ceb6一致。
新增ROB参考与边界测试保留，已在原RTL通过28,024/27,978项。使用已验证快照不重跑综合；
恢复核对及汇总数据在候选目录restore-proof.txt/results.json。

