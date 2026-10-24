# 接收数量寄存与地址分组进位组合实验（2026-10-24）

## 基线与范围

`feat/freq-seq-count-pipe`，基于`a050c13`，RTL与`5c921b7`一致，含增强LSU地址测试。
基线W2/W1 IPC为0.5195/0.4989，diagnose为20,389.871 µm² / 290.50 MHz。
基线报告/仿真器为`build/synth/seq_count_pipe_baseline/`，修改前24个输入hash一致。

上一轮地址加法器单独只提高0.114%频率，因为ROB/CDB/dispatch控制路径随即成为
最长链。本轮同时评估两项：重用`bf08056`已验证的分组地址加法器，并把dispatch
接收数量寄存，使当前ROB ready不再进入32位年龄加法器的数据端。
只测组合版一次diagnose，不给未单独综合的子改动编造频率；不跑opt、不合main、不推送。

## 年龄数值不变量

令A为本拍实际接收的有效lane数，squash或未接收时为0。旧实现的下一空闲年龄
X在接收沿更新为X+A，两个缓冲槽接收时保存X。

新实现用disp_seq=C、seq_pending=P，组合disp_seq_next=C+P。始终保持X=C+P：

- reset令C=P=0。
- 本拍接收组保存C+P，和原来的X完全相同。
- 每拍令C_next=C+P，P_next=A，故下一拍C_next+P_next=X+A。
- squash时本拍A=0，上一拍已接收的P仍正常结算，不撤回已分配年龄；空洞语义不变。

因此连续接收、停顿、单/双lane切换和恢复后的每个组首年龄均与旧实现数值一致，
不是改变步长或延迟dispatch。当前ROB ready只进入小的pending数量寄存器及接收
控制，32位加法的两个操作数都来自寄存状态。n_disp继续统计实际下发，n_push只
计输入有效lane；LOCAL_STATS口径保持原约定。

IQ/LSQ使用skid_seq，后槽提升同时移动tail_seq，ROB年龄映射仍在实际下发时建立。
既有两槽wake保存、squash和访存所有权协议不变。

## 验证

原backend539/541项通过。增加单/双lane混合输入、满IQ及双槽停顿，边界组分别
从第一lane或最后lane执行后squash；随后唤醒另一依赖，检查只保留边界及更老
前缀、年轻同组lane和后槽均不完成，正确路径恢复。只观察外部CDB/握手，增强后
W1/W2为566/592项通过。

LSU继续使用既有4231组操作数的独立load/store地址参考、两拍反压及回绕测试。
qsort/hanoi/queens依次通过。W1/W2全量各19/19，全部correctness/perf周期与基线
逐项相同；IPC仍0.5195/0.4989。完整run_all为ALL PASS，backend566/592项及LSU63757/63948项通过；
diagnose已完成，24个输入hash与本轮RTL一致。
LOCAL_STATS lint通过，无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH；官方配置与filelist不变。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/backend_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/seq_count_pipe_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/seq_count_pipe_w1 SIM="$REPO_ROOT/build/seq_count_pipe_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1。日志为`/tmp/seq-count-pipe-{w1,w2}-test.log`、
`/tmp/seq-count-pipe-{w1,w2}-perf.log`、`/tmp/seq-count-pipe-unit.log`、
`/tmp/seq-count-pipe-diagnose.log`及`/tmp/seq-count-pipe-local-stats-lint.log`。
生成物不提交。

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

两档六个perf与19个correctness周期均与a050c13/5c921b7逐项相同。

## diagnose 与下一步

| 指标 | 290.50 MHz基线 | 组合候选 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | 0.5195 / 0.4989 |
| diagnose面积 µm² | 20,389.871 | **20,441.659** |
| diagnose Fmax MHz | 290.50 | **293.07** |
| 最小周期 ns | 3.4424 | **3.4121** |
| 2 ns目标下WNS ns | -1.4415 | **-1.4121** |

频率+0.887%、面积+51.788 µm²（+0.254%），IPC和全部周期相同。
组合面积13,667.292、寄存器5,613.417、SRAM1,160.951 µm²；寄存面积较基线
增加0.583 µm²。相对单独地址进位trial，组合频率再高约0.77%，仍是小收益。
保存独立中间检查点`freq-seq-count-pipe-20261024`用于后续组合，不据此单独合main。

原年龄加法器不再是首条捕获终点，新首条起点`u_core/u_rob/_57677_/QN`，终点
`u_core/u_front/u_icache0/data_ram/lane_0/addr_in[7]`。
映射确认ROB redirect_valid（累计2.647 ns）→cache1 fetch_ready（2.868 ns）
→frontend fetch_fire（3.096 ns）→cache0 data_addr[7]（3.312 ns）。
上游仍经过squash索引、LSU结果有效、CDB src_ready、分支tag与ROB redirect。

下一轮优先评估I-cache读地址预选择：在不改变SRAM使能、写使能或任何状态更新的
前提下，消除fetch_valid/flush到地址选择的直接路径。验证所有使能访问的地址
一致，覆盖s1停顿重读、pending重放、flush与refill同拍。不能仅依据en=0时地址
可任意变化就放松en=1时的正确性。

候选完整报告、RTL快照与W1/W2仿真器归档在`build/synth/seq_count_pipe_candidate/`。
仅一次diagnose，无opt、未合main、未推送；回滚点`a050c13`。
