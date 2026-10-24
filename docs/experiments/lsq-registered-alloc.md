# LSQ 分配使用寄存占用（2026-10-24）

## 基线与验收

`feat/freq-lsq-registered-alloc`，基于`1706178` / `freq-frontend-response-20261024`。
基线保留前端独立响应队列，W2/W1 IPC为0.5196/0.4990，diagnose为
20,397.453 µm² / 284.44 MHz。报告和仿真器已保存在
`build/synth/lsq_registered_alloc_baseline/`，修改前核对24个输入hash一致。

原首条路径为squash索引→LSU/CDB→分支tag→ROB提交LSQ id→LSQ alloc_ready→IQ捕获。
本轮只运行diagnose，不跑opt、不合main、不推送。另测移除响应队列但保留前端
容量修复的对照，判断上一轮响应缓冲是否有必要；每个候选只跑一次完成的diagnose。

## 实现与所有权

LSQ alloc_ready只检查寄存valid和组内重复id，不再组合借用本拍load提交或
store写响应释放的表项。释放仍在原时钟沿清除valid，下一拍才允许新owner分配，
可能在id复用边界增加一拍停顿；不增加新的流水寄存器或修改表项生命周期。

输入组仍原子接收，任一有效lane目标占用或组内重复id则整组停顿；无效lane不占
表项。backend继续在ready且无squash时驱动alloc_fire。load提交释放、store提交
标记、sent FIFO、写响应释放和查询快照规则保持原语义。

## 验证

增强LSQ外部接口测试：load提交与B响应均不能在释放沿前旁路ready；保持待分配
组跨沿重试，检查拒绝时没有部分接收、释放后只接收一次；覆盖W2逐个释放两lane、
重复id拒绝、无效lane忽略、squash后的新owner数据及已提交store保留。
原store drain测试改为释放沿后复用，继续覆盖多笔在途、回绕与旧响应不能释放新owner。

W1/深度8为677项，W1/深度16为1229项，W2/深度16为1242项，均通过。
qsort/hanoi/queens按顺序通过；保留响应队列的W1/W2全量各19/19通过。
无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH警告。完整run_all为ALL PASS；保留响应队列版diagnose已完成，24个输入hash一致。

## 保留响应队列时的perf

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

相对响应队列基线，W2/W1 IPC分别下降0.026%/0.017%；本次分配停顿代价较小。
选定组合版，具体对照与决定见下文。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsq_query_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lsq_registered_alloc_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lsq_registered_alloc_w1 SIM="$REPO_ROOT/build/lsq_registered_alloc_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1；不改cpu_config、官方filelist或scripts。
保留响应队列版日志为`/tmp/lsq-registered-alloc-{w1,w2}-test.log`、
`/tmp/lsq-registered-alloc-{w1,w2}-perf.log`、`/tmp/lsq-registered-alloc-unit.log`、
`/tmp/lsq-registered-alloc-diagnose.log`；生成物不提交。

## 移除响应队列的对照perf

保留同一LSQ修改和前端容量修复，只移除两路额外响应队列。
先按顺序通过qsort/hanoi/queens，再跑W1/W2全量，均19/19通过。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,827 | 0.3905 | 18,439 | 0.3775 |
| perf_multiply | 21,722 | 23,161 | 0.9379 | 28,938 | 0.7506 |
| perf_qsort | 139,900 | 376,500 | 0.3716 | 383,439 | 0.3649 |
| perf_rsort | 195,719 | 362,998 | 0.5392 | 355,734 | 0.5502 |
| perf_towers | 5,278 | 12,391 | 0.4260 | 12,420 | 0.4250 |
| perf_vvadd | 4,524 | 6,584 | 0.6871 | 6,536 | 0.6922 |
| **GEOMEAN** | | | **0.5272** | | **0.5057** |

对照仿真器通过临时绝对路径filelist在独立BUILD目录构建；官方filelist未修改。
临时frontend来自d309093，补回pop_credit实际出队容量修复，其余RTL与本轮一致。
综合时已切换实际frontend并使用官方filelist，24个输入hash核对一致。
对照日志为`/tmp/lsq-registered-alloc-noqueues-{w1,w2}-{test,perf}.log`。

## 保留响应队列版diagnose

| 指标 | 前端响应队列基线 | LSQ寄存占用（保留响应队列） |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5196 / 0.4990 | **0.5195 / 0.4989** |
| diagnose面积 µm² | 20,397.453 | **20,389.871** |
| diagnose Fmax MHz | 284.44 | **290.50** |
| 最小周期 ns | 3.5156 | **3.4424** |
| 2 ns目标下WNS ns | -1.5154 | **-1.4415** |

Fmax+2.13%、面积-7.582 µm²（-0.037%），W2 `IPC×Fmax`约+2.10%。
报告、网表和仿真器已归档至`build/synth/lsq_registered_alloc_buffered/`。

ROB提交→LSQ ready→IQ路径退出首位。新第一条路径起点
`u_backend/u_iq/_40914_/QN`，终点`u_backend/u_lsu/u_lsq/_52496_/D`。
映射确认经过IQ out_uop[128]→PRF raddr[0]/rdata[0]→LSU issue_src1[0]
与issue_imm[0]相加→issue_addr[31]→LSQ fill_addr[31]捕获。
累计到达IQ输出1.759 ns、PRF输出2.087 ns、地址高位3.220 ns、LSQ D端3.382 ns。
这是一条真实数据通路，不能靠延迟整个squash总线或随意给load/store加旧a0/a1级解决。
下一轮可先研究地址加法器的进位结构，保持现有访存所有权和拍数。

移除响应队列版完整run_all也为ALL PASS，前端测试279/281项通过；
对应diagnose已完成，结果与取舍如下。

## 有无响应队列的最终对照与保留决定

| 指标 | 保留响应队列（选定） | 移除响应队列（撤回） |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | 0.5272 / 0.5057 |
| diagnose面积 µm² | 20,389.871 | 20,261.932 |
| diagnose Fmax MHz | **290.50** | 262.23 |
| 最小周期 ns | 3.4424 | 3.8135 |
| 2 ns目标下WNS ns | -1.4415 | -1.8131 |
| W1 / W2 correctness | 19/19、19/19 | 19/19、19/19 |
| run_all | ALL PASS | ALL PASS |

两版使用相同LSQ修改和实际出队容量修复，结构差异是额外响应队列。移除队列后，
频率损失大于IPC恢复：保留队列时Fmax高10.78%、面积高0.63%、W2 IPC低1.47%，
按未取整IPC与频率计算，W2 `IPC×Fmax`高**9.15%**。因此保留组合版，并将其保存为
`freq-lsq-registered-alloc-20261024`。这一结论来自组合对照，原响应队列单项实验
收益仅0.16%的结论仍然成立。

旧d309093直连前端尚无实际出队容量修复，不能把本轮直连版262.23 MHz与旧
279.78 MHz直接解释为同一基线上的LSQ频率退化。正确容量计算使rename_ready
参与空间判断；独立响应队列能阻止该反压继续穿过cache响应ready。

直连版首条路径起点`u_core/u_rob/_57839_/QN`，终点
`u_core/u_front/u_icache0/data_ram/lane_0/addr_in[7]`。映射确认经过
ROB in_ready（累计2.470 ns）→rename in_ready（2.705 ns）→frontend resp_accept1
（3.112 ns）→cache1 fetch_ready（3.312 ns）→frontend fetch_fire（3.498 ns）
→cache0 data_addr[7]（3.713 ns）。前端跨cache/反压链重新成为瓶颈。

本轮两版各完成一次diagnose，综合顺序执行；各自24个输入SHA-256核对通过。
直连版报告、网表、frontend/LSQ源码快照与W1/W2仿真器保存在
`build/synth/lsq_registered_alloc_direct/`，选定组合版在
`build/synth/lsq_registered_alloc_buffered/`。最后已恢复组合版RTL、默认仿真器及
`build/synth/diagnose/`报告，恢复后再次核对24个hash。生成物不提交。

下一步优先评估LSU地址加法器进位结构，保留原始`src1+imm`结果语义、访存所有权
和拍数，并通过独立加法参考与现有LSU/整机回归验证。本轮到此结束，不追加opt、
未合入main、未推送；回滚点为`1706178`，原main仍`bc795ae`。
