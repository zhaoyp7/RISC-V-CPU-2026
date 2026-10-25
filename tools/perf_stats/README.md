# 当前main性能统计

```sh
python3 tools/perf_stats/collect.py --out build/perf_stats_20261025
```

面向当前默认W2主线。内部使用官方make build及逐例make perf，LATENCY=10，
MAX_CYCLES=50000000；普通/统计仿真器使用独立build目录，不覆盖build/sim。
统计版仅注入LOCAL_STATS与monitors.sv；官方filelist和功能RTL不改动。

运行前核对当前24个功能输入与参考报告的hash，默认参考build/synth/opt/report.json。
候选RTL可用--reference-report指定它自己的diagnose报告，不能将新统计冒充旧opt版本的数据。
--skip-build仅用于两份仿真器已经由相同源码/监视器构建的情况；--plain-sim可复用已验证的普通仿真器。
若需要独立的统计版构建目录，可结合`--skip-build --stats-sim <路径>`复用已构建的统计仿真器。
使用宏覆盖的实验还应保留两版wrapper和参数manifest；源码hash本身不能表示宏配置。

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

ADMISSION监视器按原始FQ条数区分单/双条机会（不使用容量裁剪后的dec_valid），
同时记录ROB仅剩一槽时实际接收及无同拍提交的接收次数。可用于容量策略前后对照。

LANE1监视器只统计寄存就绪且未被取消的IQ候选，排除lane0预选槽，检查原lane1
不支持所选类型时是否存在普通写回ALU替代项，以及ALU1缓冲是否可接收。
bypass_fire表示实际接收了受支持项，且该拍按原年龄策略选择的第二通道项不受支持；
它是实际发射事件，不直接等于节省周期。采集器检查替代机会和实际接收计数的包含关系。

EARLY1监视器用实际CDB和IQ源tag构造ALU1同拍唤醒后的最老候选，排除lane0预选
及取消的项。opportunity统计获胜项需同拍wake的周期，can_accept进一步要求a1缓冲
可接收；idle/no_offer为机会与原输出空闲的交集，不能直接当作可节省周期。
actual_early统计实际握手且源未寄存就绪的第二通道项，并按一/双源缺失分类。
此路径的数据正确性依靠接收沿CDB写PRF、a1缓冲下一拍才读PRF，不能推广到直连访存口。

SAFE_WAKE只使用ALU0/ALU1/divider的寄存结果valid/tag，在恰好一个compute结果且R>=2
时构造独立提示。它每拍检查该compute确实被CDB接收，missing_grant必须为0。
opportunity/can_accept统计按该提示计算的最老普通ALU1候选需提前wake且资源可接收的周期；
actual_early统计真实提前接收，采集器检查包含关系，监视器检查每次提前接收有安全提示。

## 延迟与窗口容量敏感性

```sh
python3 tools/perf_stats/sensitivity.py --phase latency
python3 tools/perf_stats/sensitivity.py --phase windows
```

该脚本针对`ipc-uncontended-wake-20261025`测量检查点，先核对其diagnose报告的24个源码hash；
latency阶段复用`build/uncontended_wake_w2/sim`和`build/uncontended_wake_stats/sim-stats`，
并核对已有统计记录中的binary/monitor hash。两个阶段输出到`build/ipc_sensitivity_20261025/`。
需要先保留原检查点的报告、仿真器和统计归档；不适合作为任意RTL版本的通用参数扫描器。

latency阶段扫描1/3/5/10/20拍，windows阶段通过独立Verilator宏wrapper测试PRF64、
ROB32+PRF64、IQ16、LSQ32、四者组合，以及ROB32分别与IQ16/LSQ32的交叉对照；
后者各测1/10/20拍。可用`--configs rob32_iq16`只运行指定容量组。ROB32与PRF64对照，
避免把物理寄存器配套扩容的影响误算为ROB收益。默认配置与官方构建/测试脚本不变。
每个新配置先依次检查qsort/hanoi/queens，再跑W2全部19项correctness；首项失败即停止。
全部perf点使用官方`make perf MAX_CYCLES=50000000`，普通/LOCAL_STATS版输入hash、
答案、周期逐项一致，并检查提交数、排他分类和load所有权；无自动综合、合并或推送。

`LATENCY`同时改变指令/数据AXI读和写响应；它不是D-cache模型，也不把内部访存级数降至一拍。
容量实验只测IPC，不能沿用原配置PPA，更不能把IPC变化直接当成整体吞吐收益。

## 窗口候选的独立PPA验证

```sh
python3 tools/perf_stats/prepare_window_ppa.py rob32_prf64
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose \
  SYNTH_OUT=build/synth/ipc_rob32_prf64 \
  YOSYS="$REPO_ROOT/build/synth/ipc_rob32_prf64/yosys.py"
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 \
  BUILD=build/synth/ipc_rob32_prf64/w1 \
  VERILATOR="$REPO_ROOT/build/synth/ipc_rob32_prf64/verilator_w1.py"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 \
  SIM="$REPO_ROOT/build/synth/ipc_rob32_prf64/w1/sim"
```

`REPO_ROOT`为仓库绝对路径。其他两组名称为`rob32_lsq32`、`window32`，保持逐组综合。
prepare先核对已有W2普通/统计版及24个功能输入hash，复制W2仿真器、参数和统计到独立目录。
宏定义写入生成的Yosys脚本开头，wrapper在elaborate结束时检查ROB/PRF/IQ/LSQ实际位宽，
不匹配即停止。报告的源码hash本身不能描述宏覆盖，复现必须同时保留configuration.json、
wrapper与*.with_defines.ys。已有完整报告时prepare拒绝覆盖。
W1验证结果归档后可用`prepare_window_ppa.py <配置> --verify`检查报告、宏配置、两档仿真器、
两档19/19日志、7个库hash、工具及SDC/ABC约束，并生成相对原参数候选的comparison.json。
源码与默认参数不改；默认build/sim和build/synth的main报告保持独立。

## 已映射ROB的面积逻辑锥

```sh
python3 tools/perf_stats/rob_area_cones.py \
  --report build/synth/rob32_fixed_match/diagnose/report.json \
  --out build/rob_area_profile_20261025/cones.json
```

按保存的design.json追踪恢复RAT、掩码、LSQ指针等寄存器D端及组合输出的逻辑锥，
遇到寄存器停止。使用实际库单元面积，并检查单元总和与正式ROB面积/时序面积一致。
cone_area含共享单元，不可相加；exclusive_partition将每个组合单元只计一次。
exclusive仅表示未被其他已分析组共享，不代表可全部删除；复位、使能与反馈选择也可能包含在锥内。
当前commit子模块按一个组合单元处理，来源和design hash保存在输出JSON。
