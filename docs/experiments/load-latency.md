# Load分段延迟测量（2026-10-25）

## 结论

生产RTL冻结ce32682，ROB32/PRF64/IQ8/LSQ16、W2、官方LATENCY=10。
六项perf的请求接收→响应都为13拍（包括内存协议路径，不能全归为外部RAM的10拍），结果FIFO→写回约1.00～1.04拍。
95.94%～100%的结果在入队后一拍写回，说明FIFO很少拥塞，但强制入队本身通常增加一拍。
下一轮评估结果FIFO为空时的内存响应直通：获CDB接收则省一拍，否则入队保存；不改外部延迟、不缩队列，不旁路已有较老结果。

| perf | LSU接收→执行均值 | 请求→响应均值 | 结果入队→写回均值 | 一拍写回比例 | load写回→消费者发射均值 | 消费者可用lane1比例 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| median | 3.000 | 13.000 | 1.005 | 99.55% | 1.170 | 0.00% |
| multiply | 3.000 | 13.000 | 1.000 | 100.00% | 1.000 | 66.22% |
| qsort | 3.205 | 13.000 | 1.002 | 99.80% | 1.228 | 3.03% |
| rsort | 4.339 | 13.000 | 1.041 | 95.94% | 1.048 | 88.29% |
| towers | 3.001 | 13.000 | 1.011 | 98.90% | 1.284 | 23.35% |
| vvadd | 3.000 | 13.000 | 1.000 | 100.00% | 1.000 | 50.00% |

消费者只统计load写回是最后缺失操作数的IQ在飞项，跟踪槽位+seq直到完整发射或squash。
排除store地址预填；不是PRF读/实际ALU执行时刻，也不包含后来进入IQ的消费者，不可视为所有load-use平均延迟。
qsort仅3.03%的此类消费者可走lane1，rsort为88.29%，所以仅加强ALU1提前load唤醒的覆盖不均。
旁路结果FIFO覆盖两条发射通道及访存消费者，但实际IPC/Fmax收益仍须后续实验，不把机会数当收益。

## 被动监控与核验

tools/perf_stats/load_latency.sv仅通过独立Verilator wrapper及LOCAL_STATS注入，不加入正式filelist。
LOAD_LAT用LSQ id/seq与MD/RQ活跃槽时间戳记录接收、执行、请求、响应、入队和写回；同拍pop先于push处理，允许满FIFO回绕。
检查响应seq、槽位占用、请求握手一致性；记录取消响应/结果，不能把旧valid写标记当成队列当前占用。
LOAD_USE用IQ槽位+seq跟踪最后缺失操作数就绪后的发射，检查没有无法归因消失的消费者。
新增两个分组cycles与CPU实际周期相同；请求/响应与BE计数一致，入队/执行/前递/返回/写回的守恒检查通过。
LSU_EXTRA的executed是互斥分类，整个squash周期归入pending_squash，所以可能少算同拍执行的更老load；
新的事件计数包含它们，不强行要求两者相等。该差值受pending_squash包含关系约束。

六项普通/统计版输入、答案、周期及原有全部模块计数器相同，24生产输入hash与ce32682报告一致。
本轮只有仿真测量，无生产RTL变化、无新综合、无默认16/新W1或完整run_all结论；PPA沿用同源ce32682，完整核心表不新增重复行。
归档build/load_latency_20261025/：配置与双monitor的wrapper、stats仿真器、构建日志、results/逐项捕获、summary.json。
监控不依赖当前CDB资格信号驱动设计，所有端口只读。

## 复现

在同一源码与宏配置下构建统计版：在原monitors.sv之外追加load_latency.sv，定义LOCAL_STATS及ROB32/PRF64/W2。
使用tools/perf_stats/collect.py的--stats-sim复用构建结果，再核验原有计数器及新分段守恒：

```sh
python3 tools/perf_stats/collect.py --skip-build \
  --plain-sim build/synth/rob_recovery_masks/w2/sim --stats-sim build/load_latency_20261025/stats/sim \
  --reference-report build/synth/rob_recovery_masks/diagnose/report.json --out build/load_latency_20261025/results
python3 tools/perf_stats/analyze_load_latency.py \
  --results build/load_latency_20261025/results/results.json \
  --baseline build/synth/rob_recovery_masks/statistics/results.json --out build/load_latency_20261025/summary.json
```

另设归档目录保护已测结果；输入RTL、宏和两个monitor版本必须成套保留。
