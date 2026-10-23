# BPU 训练入口寄存（2026-10-23）

## 基线与范围

`feat/freq-bpu-training-pipe`，基于`43b84ac` / `freq-iq-late-squash-20261023`。
基线W2/W1 IPC 0.5274/0.5059，diagnose 20,162.350 µm² / 261.69 MHz。
关键路径squash→LSU/CDB→ROB br_update_uncond→BPU同拍训练旁路→I-cache地址端。

用户明确暂不opt，本轮仅一次diagnose，不合main、不推送。此前取消的opt无有效
新结果，部分产物在`build/synth/opt_cancelled_20261023/`；原main opt报告在
`build/synth/frequency_checkpoint_baseline/`。基线报告/仿真器已保存到
`build/synth/bpu_training_baseline/`。

## 实现与时序边界

仅在frontend内新增一拍训练寄存，保存valid、PC、taken、target、is_uncond，共67位。
valid每拍更新，metadata仅在valid输入有效时捕获；reset清valid和字段。BPU模块
及其同拍读写旁路不变，但旁路现在只读寄存字段，切断后端解析结果到当前取指的
组合传播。

ROB分支解析、redirect、squash及backend的分支更新总线保持原时序。训练寄存不因
redirect被清除，保留已接受更新；reset丢弃pending训练。连续每拍更新不需要ready，
保持每拍一笔训练吞吐。训练晚一拍可能改变预测时机，IPC必须实测。
取指请求FIFO仍在请求握手时保存预测快照，后续训练不修改在途请求的预测metadata。

## 专项验证

新增直接frontend接口测试W1 **35项PASS**、W2 **39项PASS**，不读取内部信号：

- 输入更新当拍发出的PC0/PC4请求保留旧预测，缓存响应稍后返回仍不被训练改写；
- 后续重定向取同一PC可见已训练方向/目标，taken时不错误输出顺序第二条；
- 连续同PC不同target、冲突BTB/BHT索引不同tag更新后，最终tag/target顺序正确；
- 连续not-taken/taken更新验证饱和计数器逐笔推进，不丢训练；
- 训练与redirect同拍，PC当拍切换且更新保留；reset清pending训练，防止幽灵更新；
- 逐条检查PC/指令和预测metadata配对，内存refill反压/响应由测试模型提供。

首次W2执行遇Verilator线程池内部错误（没有断言失败）；同一二进制单独复跑PASS，
完整W1/W2脚本再跑均PASS。原frontend子系统两档也通过；fixture改为显式单线程
VerilatedContext，降低无须并行的线程资源占用。

整核构建无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH；qsort/hanoi/queens已逐个PASS，
周期与基线相同。W1/W2各19/19、run_all ALL PASS；新增训练测试在完整回归中
35/39项均通过，backend各502项通过。两档全部correctness/perf周期与基线相同，
IPC 0.5274/0.5059。diagnose已完成，24个输入hash与当前RTL一致。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/bpu_training_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/bpu_training_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

日志为`/tmp/bpu-training-{w1,w2}-test.log`、`/tmp/bpu-training-{w1,w2}-perf.log`、
`/tmp/bpu-training-unit.log`、`/tmp/bpu-training-diagnose.log`；不提交生成物。

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

## diagnose 与实验决定

| 指标 | IQ末端squash `43b84ac` | BPU训练入口寄存 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 20,162.350 | **20,170.865** |
| diagnose Fmax MHz | 261.69 | **263.10** |
| 最小周期 ns | 3.8213 | **3.8008** |
| 2 ns目标下WNS ns | -1.8204 | **-1.7998** |
| opt | 未运行 | **未运行** |

Fmax仅 **+0.54%**，面积 **+8.515 µm²（+0.04%）**；全部correctness/perf周期与基线
相同。BPU路径已移出第一条路径，但整核收益很小，说明另有接近上限的路径。
保留为独立实验检查点`freq-bpu-training-20261023`，供下一轮组合验证；不把这点
诊断收益作为单独合入main的充分依据，也不宣称显著提频。本轮一次diagnose，
无opt、未合main、未推送，24个输入hash与RTL一致。

组合面积13,492.726、寄存器5,517.189、SRAM1,160.951 µm²；寄存器比基线增加
18.954 µm²。报告为`build/synth/diagnose/{report.txt,report.json,timing.rpt}`，基线
报告/仿真器为`build/synth/bpu_training_baseline/`，可回到`43b84ac`比较。

## 新瓶颈与下一步

新第一条路径仍从ROB出发，经LSU结果valid、CDB ready、backend分支更新、ROB提交
LSQ id、LSQ alloc_ready，最后经过skid_drain进入backend的disp_seq计数器捕获。
第一条为`u_core/u_rob/_56737_/QN → u_backend/_23398_/D`；映射确认终点QN经过
buffer/inverter对应`disp_seq[31]`，后端入口单元同时使用lsu_alloc_ready/iq_in_ready。

累计到达：LSU输出1.101 ns、CDB输出1.385 ns、ROB提交输出2.712 ns、LSQ分配ready
输出3.048 ns、disp_seq捕获端3.745 ns。下一轮应同时分析分支解析与结果接收的
资源耦合，以及seq分配/递增的late-ready使能；改动前定义seq、rob_seq、两个
缓冲槽的归属，不能只把计数器延后一拍而让IQ/LSQ拿到错配年龄。

本轮到此结束，不追加opt或第二项RTL实验。
