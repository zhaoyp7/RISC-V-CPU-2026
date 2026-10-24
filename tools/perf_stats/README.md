# 当前main性能统计

```sh
python3 tools/perf_stats/collect.py --out build/perf_stats_20261025
```

面向当前默认W2主线。内部使用官方make build及逐例make perf，LATENCY=10，
MAX_CYCLES=50000000；普通/统计仿真器使用独立build目录，不覆盖build/sim。
统计版仅注入LOCAL_STATS与monitors.sv；官方filelist和功能RTL不改动。

运行前核对当前24个功能输入与build/synth/opt/report.json的hash，确保分析的是已记录的main。
若研究新的功能RTL，应先明确修改此基线核对策略，不能将新统计冒充旧opt版本的数据。
--skip-build仅用于两份仿真器已经由相同源码/监视器构建的情况。

输出目录包含results.json、两份仿真器、脚本/监视器快照、每例driver日志、stdout/stderr
以及输入hash。检查两版输入、答案、周期一致，提交数与软件指令数一致；所有模块的周期相同。

监视器均为input-only bind模块，仅用于完整student_top仿真：

- IQ_EXTRA：真空、源未就绪、取消，以及本拍广播可能形成ready候选的机会。最后一项不保证
  数据前递或执行资源准入，不能直接换算收益。
- LSU_EXTRA：pending所有权下的排他状态。pending_no_r包含查询流水填充、选择与重试，
  不能全部解释成可消除气泡。
- ROB_EXTRA：队首等待类型、恢复及提交状态；另外统计仅剩一槽、满队列的容量状态。
- LOAD_HEAD：按物理tag跟踪队首load处于IQ、pending、内存元数据FIFO还是结果FIFO。
  两个FIFO的valid是历史写标记，必须用head/count活动窗口并排除discard判定当前所有者。

采集器校验各排他分类之和、容量状态、LSQ响应分类，以及LOAD_HEAD各阶段之和与互斥性。
不同模块指标可能重叠，不可横向相加。FE的backend_ready包含ROB ready，BE的backend_bubble
仅指tail满，两者不是同一种停顿。

本次结果与分析见[当前main统计](../../docs/experiments/main-stats-20261025.md)。
