# dispatch 接收时预分配年龄（2026-10-23启动，24日收尾）

## 基线与范围

`feat/freq-dispatch-seq`，基于`b80df1d` / `freq-bpu-training-20261023`。
基线W2/W1 IPC 0.5274/0.5059，diagnose 20,170.865 µm² / 263.10 MHz。
原第一条路径经LSU/CDB、ROB提交、LSQ alloc_ready、skid_drain到disp_seq[31]捕获。
用户明确暂不opt，本轮仅采用一次完成的diagnose，未合main、未推送。

## 实现与不变量

next-free disp_seq在dispatch被缓冲接收时按输入有效lane数递增，解除其与下游
IQ/LSQ ready的直接组合依赖。前后槽分别保存skid_seq/tail_seq，接收时随整组
payload捕获；后槽提升时同时移动seq，停顿时保持，替换前槽时捕获新组首年龄。
IQ和LSU的seq_base均改用前槽保存值，ROB映射仍在实际下发时按skid_seq+lane建立。

squash优先清两槽且不接收当拍输入；已分配给被丢弃组的年龄不回退，允许出现
空洞，但所有存活指令的数值年龄仍保持程序序。seq用于先后比较，不依赖连续值。
原按有效lane计数和lane偏移规则保留，producer维持有效lane前缀约定。
不改变数据唤醒、容量、发射拍数或访存所有权，也不提前改写ROB映射。

## 验证进度

原backend W1/W2各502项通过。新增混合单/双lane组、满缓冲停顿、后槽年龄保存
和部分squash边界测试后，W1/W2为539/541项通过：先以老load阻塞IQ，再填入
前槽组与依赖另一tag的年轻后槽；老load返回后，等待前槽边界指令完成并触发
squash，最后发出后槽依赖的producer。检查只有边界及更老指令完成，年轻后槽
即使随后得到唤醒也不能完成，新正确路径可继续执行。全程只观察外部握手/CDB。

整核构建通过，qsort/hanoi/queens已逐个PASS且周期与基线相同。
完整回归及测量已完成，最终结果见下节。基线报告/仿真器为
`build/synth/dispatch_seq_baseline/`。此前取消opt无有效新结果，产物在
`build/synth/opt_cancelled_20261023/`；原main opt报告在
`build/synth/frequency_checkpoint_baseline/`。

统计口径检查发现n_disp原来用于LOCAL_STATS下发统计，故新增n_push专用于输入组
计数，保留n_disp对前槽计数。第一次diagnose在早期中断（130），修正后重新开始；
最终只采用`/tmp/dispatch-seq-diagnose-final.log`对应的一次完成结果。
LOCAL_STATS lint通过，无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH。修正后W2全量19/19，
W1全量也19/19；完整单元回归在修正后复跑ALL PASS。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/backend_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/dispatch_seq_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/dispatch_seq_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

最终日志为`/tmp/dispatch-seq-w2-test-final.log`、`/tmp/dispatch-seq-w1-test.log`、
`/tmp/dispatch-seq-{w1,w2}-perf.log`、`/tmp/dispatch-seq-unit-final.log`及
`/tmp/dispatch-seq-diagnose-final.log`；不提交生成物。

## perf

latency=10，MAX_CYCLES=50,000,000；两档全部correctness和六个perf周期与基线相同。

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

| 指标 | BPU训练寄存 `b80df1d` | dispatch年龄预分配 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 20,170.865 | **20,231.241** |
| diagnose Fmax MHz | 263.10 | **279.78** |
| 最小周期 ns | 3.8008 | **3.5742** |
| 2 ns目标下WNS ns | -1.7998 | **-1.5734** |
| opt | 未运行 | **未运行** |

Fmax **+6.34%**，面积 **+60.376 µm²（+0.30%）**；两档全部correctness/perf周期
与基线相同，`IPC×Fmax`约+6.34%。W1/W2各19/19、修正后的完整run_all ALL PASS，
backend539/541项通过。最终一次完成的diagnose输入24个hash与RTL一致；前一项
早期中断不作为测量结果。保留独立检查点`freq-dispatch-seq-20261024`，无opt、
未合main、未推送。

组合面积13,534.439、寄存器5,535.851、SRAM1,160.951 µm²；寄存器较基线增加
18.662 µm²，对应两槽保存年龄的存储代价。报告为`build/synth/diagnose/`，基线
报告/仿真器为`build/synth/dispatch_seq_baseline/`。

## 新瓶颈与下一步

原disp_seq计数器捕获移出第一条路径。新路径为squash→LSU结果valid→CDB ready
→backend分支更新→ROB redirect_valid→cache0 fetch_resp_valid→frontend resp_accept1
→cache1 fetch_ready→cache1 SRAM地址。首条起点`u_core/u_rob/_56737_/QN`，终点
`u_core/u_front/u_icache1/data_ram/lane_0/addr_in[7]`。

映射确认ROB输出`redirect_valid`到cache0的flush，cache0出口`fetch_resp_valid`，
前端出口`resp_accept1`，cache1出口`fetch_ready`，最终为`data_addr[7]`。
累计到达：LSU输出1.087 ns、CDB输出1.371 ns、ROB redirect输出2.536 ns、cache0
响应valid2.634 ns、resp_accept1为2.884 ns、cache1 ready为3.084 ns、地址端3.473 ns。

下一阶段优先研究前端跨cache响应/ready依赖，评估独立响应缓冲及配对/容量控制；
必须保持请求FIFO的use2/预测快照、响应顺序、反压及redirect清理一致性。先不直接
延迟redirect本身；如评估恢复分级，需要单独定义恢复协议。BPU训练寄存切掉另一
条接近上限路径，本轮作为组合后的实验基线保留，不能仅看上轮0.54%就推断它无用。
本轮结束，不追加opt或新RTL实验。
