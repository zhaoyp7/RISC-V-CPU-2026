# 双槽 dispatch 弹性缓冲（2026-10-23）

## 基线与用户授权

分支 `feat/freq-dispatch-buffer`，基于 `d81cacb` / `freq-store-tree-20261023`。
基线W2/W1 IPC 0.5274/0.5059，diagnose 19,952.559 µm² / 240.60 MHz。
基线关键路径为squash→LSU/CDB→ROB提交→LSQ分配ready→前端I-cache地址。

用户先授权阶段检查点，后明确“先不要opt，继续工作”。已用中断停止刚启动的
opt（退出码130），没有新opt结果。未完成目录已移到
`build/synth/opt_cancelled_20261023/` 并标记CANCELLED；原main opt报告已备份至
`build/synth/frequency_checkpoint_baseline/`。本轮只做正确性/perf/一次diagnose，
不合入main、不推送；main仍为 `bc795ae`。

## 实现与容量不变量

原缓冲只有一槽，`backend_ready = !skid_valid || skid_drain`，使IQ/LSQ分配ready
直接回传前端。新结构保留前槽skid，增加后槽tail，`backend_ready = !tail_valid`，
只由寄存占用状态决定；前槽排空仍需要IQ/LSQ ready且没有squash。

| 状态 | ready | 行为 |
| --- | --- | --- |
| 两槽空 | 1 | 输入进入前槽 |
| 仅前槽有效 | 1 | 同拍排空并替换；或下游停顿时输入进入后槽 |
| 两槽全满 | 0 | 停止接收；前槽排空后提升后槽，下一拍恢复ready |

满缓冲不依赖当拍排空而额外接收，确保已接受的dispatch总有存储位置。正常
前槽连续排空时可每拍接收一组，不增加无停顿情况下的dispatch级数。

两槽每拍都保存CDB唤醒，提升使用更新后的后槽；新输入继续同拍wake旁路。
seq及rob_seq映射仍在前槽实际进入IQ/LSQ时建立，维持程序组顺序；尾槽只保存
原dispatch元数据，不提前分配LSQ。已执行branch比两槽均老，squash优先清两槽，
本拍新输入也不保留；不改变已发射指令/LSU的按seq取消。

## 验证进度

原backend W1/W2 445/449项通过，新增满缓冲唤醒和恢复测试后均为502项通过：
先让老load等待响应，填满8项IQ及两个整组缓冲，核对容量与额外输入反压；
释放唯一一次producer响应，交替让两个源操作数依赖该tag，逐笔检查tag/value、
无重复和可恢复。
另一轮在满缓冲时squash，再发新指令，检查旧两槽及IQ项均不产生结果、老load
和新指令正常完成。fixture改用单线程VerilatedContext。

整核构建无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH警告。qsort/hanoi/queens已逐个PASS，
W2周期为1,897,626 / 9,270 / 667,119（基线1,897,538 / 9,275 / 667,055）。
W1/W2全量各19/19 PASS，完整run_all ALL PASS；增强后的两个源操作数后槽唤醒
检查也单独通过（两档各502项）。W2 perf四位IPC为0.5274，qsort少55周期，其余
五项与基线相同。W1 qsort少47周期，四位IPC仍0.5059；diagnose已完成，24个输入hash与RTL一致。
基线报告/仿真器保存在 `build/synth/dispatch_buffer_baseline/`。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/backend_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/dispatch_buffer_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/dispatch_buffer_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper只添加 `+define+CPU_ISSUE_WIDTH=1`，不修改默认配置。日志为
`/tmp/dispatch-buffer-{w1,w2}-test.log`、`/tmp/dispatch-buffer-{w1,w2}-perf.log`、
`/tmp/dispatch-buffer-unit.log`、`/tmp/dispatch-buffer-diagnose.log`；不提交生成物。

## perf

latency=10，MAX_CYCLES=50,000,000。两档仅perf_qsort周期变化，分别比基线减少55/47周期；四位IPC不变。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,827 | 0.3905 | 18,439 | 0.3775 |
| perf_multiply | 21,722 | 23,161 | 0.9379 | 28,938 | 0.7506 |
| perf_qsort | 139,900 | 375,920 | 0.3722 | 383,094 | 0.3652 |
| perf_rsort | 195,719 | 362,998 | 0.5392 | 355,734 | 0.5502 |
| perf_towers | 5,278 | 12,379 | 0.4264 | 12,411 | 0.4253 |
| perf_vvadd | 4,524 | 6,584 | 0.6871 | 6,536 | 0.6922 |
| **GEOMEAN** | | | **0.5274** | | **0.5059** |

## diagnose 与保留决定

| 指标 | store选择树 `d81cacb` | 双槽dispatch缓冲 |
| --- | ---: | ---: |
| W2 / W1 IPC（四位） | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 19,952.559 | **20,103.272** |
| diagnose Fmax MHz | 240.60 | **251.29** |
| 最小周期 ns | 4.1563 | **3.9795** |
| 2 ns目标下WNS ns | -2.1554 | **-1.9793** |
| opt | 已取消，无有效结果 | **未运行** |

同模式Fmax **+4.44%**、面积 **+150.713 µm²（+0.76%）**。两档仅perf_qsort略快，
四位IPC均不变；W2 `IPC×Fmax` 趋势约+4.44%。保留独立检查点
`freq-dispatch-buffer-20261023`，未合入main、未推送；本候选仅一次diagnose，无opt。
24个输入hash与当前RTL一致。

组合面积13,444.087、寄存器5,498.235、SRAM1,160.951 µm²；寄存器较基线增加
88.355 µm²，对应新增尾槽的存储代价。原通往前端I-cache的ready链已不在第一条
关键路径，收益由下一条路径限制，不能把每个局部延迟减少直接当作整核频率提升。

## 新瓶颈与下一步

新第一条路径 `ROB → IQ → PRF → LSU地址生成 → LSQ fill捕获`，起点为
`u_core/u_rob/_56737_/QN`，终点为 `u_backend/u_lsu/u_lsq/_51711_/D`。
网表确认IQ出口为源tag字段 `out_uop[129]`，PRF出口为 `rdata[0]`，LSU出口为
`issue_addr[30]`，LSQ输入为 `fill_addr[30]`。

累计到达：IQ入口0.5994 ns、出口2.306 ns、PRF出口2.631 ns、LSU地址出口
3.751 ns、LSQ捕获3.924 ns。IQ段约1.707 ns，PRF约0.325 ns，地址生成约1.120 ns。
下一轮应优先检查访存发射的数据路径与squash门控位置；原计划的前端优化暂按
新报告调整优先级，不能因为已有路线图而继续优化已移出第一条路径的模块。

若试图进一步隔离IQ/PRF/AGU，必须保留load等待表所有权和store预填/完整填入
的推进能力，不能把load/store直接塞回旧a0/a1缓冲。可先评估候选预选与末端取消
以减少squash对tag/地址数据路径的影响，再决定是否新增访存地址流水级。
本轮到此结束，不追加opt或新RTL实验。
