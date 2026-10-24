# I-cache 本地预读（2026-10-24）

## 基线与目标

`feat/freq-icache-local-read`，基于`cdddde6` / `freq-icache-read-address-20261024`。
基线W2/W1 IPC为0.5195/0.4989，diagnose为20,437.314 µm² / 300.03 MHz。
首条路径是ROB in_ready→rename in_ready→fetch_fire→cache read_en→SRAM CE，
累计到达2.578/2.820/3.047/3.232 ns，频率裕量很小。
修改前核对24个输入hash，报告/仿真器在`build/synth/icache_local_read_baseline/`。

本轮将读使能中的accept_fetch改为lookup_room，保留外层NORMAL与!flush条件，
移除当前fetch_valid/全局取指握手对本地SRAM读使能的直接依赖。
只运行一次diagnose，不跑opt、不合main、不推送。

## 有效数据保持不变量

lookup_room表示本地流水有接收空间。它允许在未接收真实请求时读取data/tag SRAM，
但实际s1_valid/PC/tag/index仍只在accept_fetch或原pending重放条件成立时建立。
refill仍只由有效s2 lookup的miss建立；有效位、写入、响应和flush时序不变。

- 原accept_fetch成立时lookup_room必成立，原有真实读取仍读取同一地址。
- s1停顿重读和pending重放的条件、地址均不变；REFILL仍按原响应/flush条件写入。
- 额外读取只发生在lookup_room成立而accept_fetch不成立时。若旧s1有效且可前进，
  s2在本沿捕获的是上一沿为该s1准备的RAM数据，新空读更新的RAM输出不会覆盖该次捕获。
  此沿没有真实接收，s1随后清空；若旧s1无效，就不建立新的有效s2。
- 因而s1_valid成立时，其对应的上一拍RAM访问仍是两版相同的真实接收、pending重放
  或停顿重读。s2仅在此条件下捕获元数据和RAM数据，PC/指令配对与基线一致。

本轮增加内部只读访问，不能沿用上轮“所有SRAM访问次数相同”的证明；它不增加
外部接受的请求、响应或refill。功耗未测量，不给出功耗不变的结论。
所有cache时序状态更新、写使能及flush门控保持原条件，没有新增流水拍数。

## 验证

新增64拍无效PC变化，检查不产生指令或refill；在真实命中之间插气泡并改变PC，
检查响应顺序及缓存内容不被空读影响。继续覆盖s1停顿重读、pending命中不额外
回填，以及flush和回填响应同拍不写入cache。夹具只观察外部端口。

索引4/10各10万拍随机矩阵通过，响应对拍19259/71513次，失败0；命中吞吐仍8条/10拍。
前端W1/W2预测/配对测试281/284项通过。qsort/hanoi/queens依次通过，周期与基线相同。
完整W1/W2各19/19，全部correctness/perf周期与基线逐项相同，IPC0.5195/0.4989。
完整run_all为ALL PASS，backend566/592项、LSU63757/63948项通过；
diagnose已完成，24个输入hash一致，LOCAL_STATS lint通过，无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH。
未修改官方filelist、默认配置、SRAM包装器或ALU。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/icache_pipe_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 ICACHE_INDEX_BITS=10 sh test/icache_pipe_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/icache_local_read_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/icache_local_read_w1 SIM="$REPO_ROOT/build/icache_local_read_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1。日志为`/tmp/icache-local-read-unit-{4,10}.log`、
`/tmp/icache-local-read-frontend-directed.log`、`/tmp/icache-local-read-{w1,w2}-{test,perf}.log`、
`/tmp/icache-local-read-unit.log`、`/tmp/icache-local-read-local-stats-lint.log`及
`/tmp/icache-local-read-diagnose.log`。生成物不提交。

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

两档六个perf与19个correctness周期均与cdddde6逐项相同。

## diagnose 与中间检查点

| 指标 | 地址预选择基线 | 本地预读 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | 0.5195 / 0.4989 |
| diagnose面积 µm² | 20,437.314 | **20,437.519** |
| diagnose Fmax MHz | 300.03 | **300.29** |
| 最小周期 ns | 3.3330 | **3.3301** |
| 2 ns目标下WNS ns | -1.3324 | **-1.3295** |

频率仅+0.088%、面积+0.001%，没有形成明显余量。保存为独立trial
`freq-icache-local-read-trial-20261024`，作为后续组合对照，不将该单项视为充分采用理由。
完整报告、网表、RTL和W1/W2仿真器在`build/synth/icache_local_read_trial/`。
一次diagnose，24个输入hash一致，未opt、未合main、未推送。

CE不再是首条终点。新路径终点为`u_core/u_front/_31117_/D`，起点仍为ROB
`_57677_/QN`。累计经ROB in_ready 2.578 ns、rename in_ready 2.820 ns，到前端
寄存器D端3.270 ns。利用JSON中DFF源位置与组合扇出核对，终点属于decode FIFO
指令数据位，其输出经选择后对应dec_uop[58]/[190]（每lane指令bit25）。

下一轮优先解耦响应入队容量与当前rename/backend ready，保持整组配对和容量
安全，并测量满队列下一拍复用导致的IPC代价。当前单项收益不足，需组合验证。

## 后续组合验证

[响应容量解耦实验](frontend-response-capacity.md)在本trial上达到322.42 MHz，W2 IPC
0.5221，面积20,441.849 µm²，W1/W2全量及run_all通过。因此在后续组合中保留
本地预读，单项只提高0.088%的测量仍不改变；组合结果不用于编造各子项独立收益。
