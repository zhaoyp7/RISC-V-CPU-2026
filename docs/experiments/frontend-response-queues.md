# 前端独立响应队列（2026-10-24）

## 基线与范围

`feat/freq-frontend-response-queues`，基于`d309093` / `freq-dispatch-seq-20261024`。
基线W2/W1 IPC为0.5274/0.5059，diagnose为20,231.241 µm² / 279.78 MHz。
原路径由ROB redirect经过cache0响应valid、跨bank配对、cache1 ready到SRAM地址。
本轮只运行一次diagnose，不运行opt、不合main、不推送。
基线报告和仿真器保存在`build/synth/frontend_response_baseline/`。

## 实现与协议

两路I-cache出口各增加两个PC/指令响应槽位；ready仅由本路寄存占用小于2决定，
不借用同拍出队空间，也无组合旁路。占用为1时支持同拍入队/出队，连续吞吐
仍可达到每路每拍一条；响应进入队列后下一拍才能参与decode，增加一拍延迟。

请求FIFO仍保存use2及预测快照。第一路始终按请求顺序消费，只有队首use2=1
才消费第二路；因此第二路可以先返回后续双条请求，不会被当前单条请求误取。
redirect/reset同时清请求、响应和decode队列，保留I-cache即时flush与旧refill排空。

同时修复decode FIFO容量计算：只计入pop_fire对应的实际出队槽位。原算法在
rename_ready=0时仍计入pop_n，可能覆盖未消费指令。独立临时源文件恢复旧算法后，
同一新增W2测试出现38项失败；修复后的W1/W2均通过。未修改默认配置或构建脚本。

## 定向验证

扩展`test/bpu_training_test`，继续只观察frontend外部接口：

- 用PC生成不同指令字，验证PC、指令、预测方向及目标对应。
- 两路refill延迟分别为0/9、9/0拍；训练PC0→0x40、0x4c→0x90、0x90→0xc0，
  混合单条和双条请求，检查顺序以及第一条taken抑制第二条。
- backend_ready=1、rename_ready=0持续128拍，随后检查头部稳定，交错恢复供给和消费。
- 有反压时redirect到0x100，验证旧响应清除、新路径继续前进。

W1 281项、W2 284项通过，前端子系统W1/W2通过；qsort、hanoi、queens逐个通过。
一次Verilator运行出现locked Thread Pool内部错误；相同构建重试后通过，未据此修改RTL。
W1/W2全量各19/19、完整`sh test/run_all.sh`为ALL PASS；配置生成检查通过，
无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH警告。diagnose已完成，24个输入SHA-256与当前RTL一致。

## perf

latency=10、MAX_CYCLES=50,000,000。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 18,444 | 0.3774 | 18,926 | 0.3678 |
| perf_multiply | 21,722 | 23,843 | 0.9110 | 29,588 | 0.7341 |
| perf_qsort | 139,900 | 386,378 | 0.3621 | 393,521 | 0.3555 |
| perf_rsort | 195,719 | 364,020 | 0.5377 | 355,740 | 0.5502 |
| perf_towers | 5,278 | 12,148 | 0.4345 | 12,502 | 0.4222 |
| perf_vvadd | 4,524 | 6,686 | 0.6766 | 6,537 | 0.6921 |
| **GEOMEAN** | | | **0.5196** | | **0.4990** |

W2/W1 IPC分别约下降1.49%/1.37%，与本轮实测频率合并后的收益见下文。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/frontend_response_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/frontend_response_w1 SIM="$REPO_ROOT/build/frontend_response_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加`+define+CPU_ISSUE_WIDTH=1`，不修改cpu_config。
日志为`/tmp/frontend-response-{w1,w2}-test.log`、`/tmp/frontend-response-{w1,w2}-perf.log`、
`/tmp/frontend-response-unit.log`、`/tmp/frontend-response-diagnose.log`；不提交生成物。

## diagnose 与保留决定

| 指标 | dispatch年龄预分配 | 前端响应队列 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5196 / 0.4990** |
| diagnose 面积 µm² | 20,231.241 | **20,397.453** |
| diagnose Fmax MHz | 279.78 | **284.44** |
| 最小周期 ns | 3.5742 | **3.5156** |
| 2 ns目标下WNS ns | -1.5734 | **-1.5154** |
| opt | 未运行 | **未运行** |

频率+1.67%，面积+166.212 µm²（+0.82%）。按未取整IPC和频率计算，W2
`IPC×Fmax`仅+0.16%，整体收益很小；W1未单独综合，不给出W1实测吞吐结论。
组合面积13,623.669、寄存器5,612.833、SRAM1,160.951 µm²。

前端跨bank响应链已经切断，但另一条接近原上限的后端路径成为首位，因此频率
提升有限。结合当前优先提高频率的要求，保留`freq-frontend-response-20261024`
作为后续组合实验的独立起点，不作为单独合main的充分依据；回滚点为`d309093`。
本轮只完成一次diagnose，无opt、无main合并、无推送。

## 新瓶颈与下一步

首条起点为`u_core/u_rob/_57299_/QN`，终点为`u_backend/u_iq/_40506_/D`。
映射确认路径为ROB squash_rob_idx[2]→backend查年龄squash_seq[9]→LSU
load_result_valid→CDB src_ready[0]→backend br_update tag[2]→ROB commit_lsq_id[5]
→LSQ alloc_ready→skid_drain/IQ in_valid[1]→IQ寄存器捕获。

累计到达为LSU输出1.088 ns、CDB输出1.372 ns、分支tag 1.660 ns、ROB提交id
2.674 ns、LSQ alloc_ready 3.009 ns、IQ入口3.075 ns、IQ D端3.460 ns。
前端已不在首条路径；不能因频率收益小就认定响应解耦没有切断预期路径。

下一轮优先评估LSQ分配容量对当拍提交释放的借用。现有free_mask结合valid、
free_by_commit、free_by_resp，使ROB提交id组合穿过alloc_ready进入IQ。
可以研究仅使用寄存空闲状态或提前预留容量，但须单独测量可能增加的分配停顿，
并验证load提交释放、store写响应复用、双lane重复id、squash和满表恢复。
不直接延迟redirect，也不把load/store放入旧a0/a1缓冲。本轮到此收尾。
