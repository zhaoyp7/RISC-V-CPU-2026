# I-cache SRAM 地址预选择（2026-10-24）

## 基线与范围

`feat/freq-icache-read-address`，基于`fd07456` / `freq-seq-count-pipe-20261024`。
基线W2/W1 IPC为0.5195/0.4989，diagnose为20,441.659 µm² / 293.07 MHz。
报告/仿真器保存在`build/synth/icache_read_address_baseline/`，修改前核对24个输入hash。

原第一条路径由ROB redirect经cache1 fetch_ready、frontend fetch_fire到cache0
SRAM地址，累计到达2.647/2.868/3.096/3.312 ns。本轮只重写地址选择，不改变
读使能、写使能或任何cache流水状态更新；一次diagnose，无opt、不合main、不推送。

## 使能访问等价

新增lookup_room，等于原fetch_ready去掉flush门控：NORMAL状态、无buf/pending且
s2可接收。fetch_ready仍为lookup_room且非flush，外部握手与原实现逻辑等价。

读地址由lookup_room预选fetch_index，否则仍按load_pending选择pending地址或s1地址。
这去掉了当前fetch_valid与flush到读地址mux的依赖，并保持每次read_en有效时地址相同：

- lookup_room=1时buf/pending为空且s2_accept=1，load_pending和s1停顿重读均不成立。
  因此若read_en=1，必然由accept_fetch产生，预选的新PC就是本拍应读地址。
- lookup_room=0时accept_fetch必为0，读地址的pending/s1选择与旧实现完全相同。
- NORMAL之外没有读访问。REFILL提前按寄存state选择refill_index，真正写入仍由原
  `!flush && refill_resp_valid`条件控制。DRAIN/flush时没有因此增加任何访问。

data/tag RAM使用同一个预选地址，读写使能、写数据/掩码和所有状态时序不变。
不依赖en=0时rdata保持：课程仿真RAM在不读时可输出X，s1停顿仍按原条件重读。
未使能时地址允许不同；所有使能访问的地址、次数和顺序均保持原语义。

## 验证

扩展I-cache外部端口测试：s2反压且s1持有另一命中时改变无效fetch PC；冷缺失
后保留pending命中、反压回填输出再重放，要求不发生额外回填；flush和回填
响应同拍时丢弃旧数据，重新取该PC必须再次缺失。夹具改为显式单线程context，
reset显式驱动discard=0；不读取RTL内部信号。

索引4/10各10万拍随机矩阵通过，响应对拍计数19247/71501，失败0，命中吞吐仍
8条/10拍。W1/W2前端预测/配对测试281/284项通过。
qsort/hanoi/queens依次通过且周期不变；W1/W2完整各19/19，全部correctness/perf周期与基线逐项相同，
IPC仍0.5195/0.4989。完整run_all为ALL PASS；diagnose已完成，24个输入hash与RTL一致。LOCAL_STATS lint通过，
无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH。
官方配置/filelist及SRAM包装器未修改。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/icache_pipe_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 ICACHE_INDEX_BITS=10 sh test/icache_pipe_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/icache_read_address_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/icache_read_address_w1 SIM="$REPO_ROOT/build/icache_read_address_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1。日志为`/tmp/icache-read-address-unit-{4,10}-final.log`、
`/tmp/icache-read-address-frontend-directed.log`、`/tmp/icache-read-address-{w1,w2}-{test,perf}.log`、
`/tmp/icache-read-address-unit.log`及`/tmp/icache-read-address-diagnose.log`。生成物不提交。

## perf



latency=10、MAX_CYCLES=50,000,000。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 18,444 | 0.3774 | 18,926 | 0.3678 |
| perf_multiply | 21,722 | 23,843 | 0.9110 | 29,588 | 0.7341 |
| perf_qsort | 139,900 | 386,844 | 0.3616 | 393,792 | 0.3553 |
| perf_rsort | 195,719 | 364,020 | 0.5377 | 355,740 | 0.5502 |
| perf_towers | 5,278 | 12,152 | 0.4343 | 12,506 | 0.4220 |
| perf_vvadd | 4,524 | 6,686 | 0.6766 | 6,537 | 0.6921 |
| **GEOMEAN** | | | **0.5195** | | **0.4989** |

两档六个perf及19个correctness周期与fd07456逐项相同。

## diagnose 与保留决定

| 指标 | fd07456基线 | I-cache地址预选择 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | **0.5195 / 0.4989** |
| diagnose面积 µm² | 20,441.659 | **20,437.314** |
| diagnose Fmax MHz | 293.07 | **300.03** |
| 最小周期 ns | 3.4121 | **3.3330** |
| 2 ns目标下WNS ns | -1.4121 | **-1.3324** |
| opt | 未运行 | **未运行** |

频率+2.373%，面积-4.345 µm²（-0.021%），IPC与全部周期相同，保留独立检查点
`freq-icache-read-address-20261024`。相对a050c13/5c921b7原基线，两轮组合频率
+3.282%、面积+47.443 µm²（+0.233%），IPC无损；这说明接近上限的多条路径需
组合处理，不能把各子改动收益简单相加。

组合面积13,662.947、寄存器5,613.417、SRAM1,160.951 µm²。每个I-cache含SRAM为
884.716 µm²，控制逻辑304.241 µm²。当前300.03 MHz只是diagnose估计，贴近300线，
没有充分频率余量；未做opt最终验收，不视为课程阶段通过。用户要求暂不opt，本轮无opt。

首条起点`u_core/u_rob/_57677_/QN`，终点
`u_core/u_front/u_icache0/data_ram/lane_0/ce_in`。映射确认ROB in_ready（累计2.578 ns）
→rename in_ready（2.820 ns）→frontend fetch_fire（3.047 ns）→cache0 data_en
（3.232 ns）→SRAM CE输入；上游仍经过LSU/CDB和分支tag。
原SRAM地址选择路径退出首位，当前限制是读使能而非地址或乘法器。

下一轮优先研究read_en与当前全局取指握手的解耦：评估无副作用的本地预读或
受控请求缓冲，证明s1/s2、pending重放和flush仍正确配对。当前不改变任何访问
次数，后续若引入额外内部读，必须作为单独实验验证，不能把它与本轮等价性证明混用。

完整候选报告、网表、RTL快照及W1/W2仿真器保存在
`build/synth/icache_read_address_candidate/`，默认diagnose报告与当前24个RTL hash一致。
最终I-cache定向日志为`/tmp/icache-read-address-unit-{4,10}-final.log`，其余日志见上文。
本轮到此收尾，不追加RTL/opt；未合main、未推送，回滚点`fd07456`。

## 后续读使能与响应容量组合

本地预读单项达到300.29 MHz，配合响应按寄存容量入队后达到322.42 MHz，W2 IPC
0.5221、面积20,441.849 µm²，W1/W2全量及run_all通过。相对本页300.03 MHz基线，
组合频率+7.46%、W2 `IPC×Fmax`约+8.01%。详见
[本地预读trial](icache-local-read.md)和[响应容量组合](frontend-response-capacity.md)。
