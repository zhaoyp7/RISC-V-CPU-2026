# LSU 地址分组进位实验（2026-10-24）

## 基线与范围

`feat/freq-lsu-address-prefix`，基于`5c921b7` / `freq-lsq-registered-alloc-20261024`。
基线保留前端响应队列及LSQ寄存占用分配，W2/W1 IPC为0.5195/0.4989，
diagnose为20,389.871 µm² / 290.50 MHz，最小周期3.4424 ns。
报告和仿真器保存在`build/synth/lsu_address_prefix_baseline/`；修改前24个输入hash一致。

原第一条路径为IQ源tag选择→PRF读→LSU地址加法→LSQ fill地址捕获，累计到达
1.759/2.087/3.220/3.382 ns。地址低位经32位进位影响高位，LSU段约1.133 ns。
本轮只改地址加法的组合结构，不增加访存拍数、不改接收时机或所有权。
只运行一次diagnose，不运行opt、不合main、不推送。

## 实现

issue_addr从直接的src1+imm表达式改为模块内address_add函数：按4位分为8组，
各组并行计算无输入进位的局部和及输入进位为1的候选和。组传播条件是四位
异或均为1，组生成条件是局部和的第5位。

组进位用跨度1、2、4的三级前缀组合：G=G高或(P高且G低)，P=P高且P低。
每组按低组汇总进位选择候选和，丢弃第33位；结果仍为模2^32加法。
函数中的数组只是组合临时值，不引入时钟状态；现有预填、load等待表及store
fill均使用同一个issue_addr，所有valid、ready和squash逻辑保持原协议。

## 验证

扩展现有LSU/LSQ外部接口测试，参考为C++ uint64加法取低32位，与RTL进位结构独立。
每档4231组操作数分别走实际load和store端口，包括每一位进位、32位溢出回绕、
符号扩展12位偏移及固定种子随机数。每笔请求反压两拍，期间改变issue操作数，
检查已捕获地址、store数据/掩码稳定，最后验证实际读写结果和id释放。

W1/LSQ8为63757项，W2/LSQ16为63948项，通过。qsort/hanoi/queens依次通过，
周期与基线相同。完整W1/W2各19/19通过，全部correctness/perf周期与基线逐项相同，
IPC仍为0.5195/0.4989。一次run_all在IQ测试处遇到Verilator locked Thread Pool
内部错误（250），无测试断言失败；整机测量结束后重跑完整run_all为ALL PASS，
最终采用`/tmp/lsu-address-prefix-unit-final.log`，地址检查仍为63757/63948项。
diagnose已完成，24个输入SHA-256与本次RTL核对一致。
无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH警告；官方filelist与默认配置不变。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsu_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/lsu_address_prefix_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/lsu_address_prefix_w1 SIM="$REPO_ROOT/build/lsu_address_prefix_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1。日志为`/tmp/lsu-address-prefix-{w1,w2}-test.log`、
`/tmp/lsu-address-prefix-{w1,w2}-perf.log`、`/tmp/lsu-address-prefix-unit.log`及
`/tmp/lsu-address-prefix-diagnose.log`。生成物不提交。

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

两档六个perf及19个correctness周期与`5c921b7`逐项相同。

## diagnose 与验收

| 指标 | 基线 `5c921b7` | 分组进位候选 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | **0.5195 / 0.4989** |
| diagnose面积 µm² | 20,389.871 | **20,442.024** |
| diagnose Fmax MHz | 290.50 | **290.83** |
| 最小周期 ns | 3.4424 | **3.4385** |
| 2 ns目标下WNS ns | -1.4415 | **-1.4385** |

Fmax仅+0.114%，面积+52.153 µm²（+0.256%），IPC与全部周期相同。
组合面积13,668.240、寄存器5,612.833、SRAM1,160.951 µm²；没有新增时序面积。
实际总周期只改善约3.906 ps，不能据此声称有显著频率收益，也不值得追加opt。
候选源码、报告、网表、W1/W2仿真器在`build/synth/lsu_address_prefix_trial/`，
代码检查点为`freq-lsu-address-prefix-trial-20261024`。

地址数据通路退出首位，新首条起点为`u_core/u_rob/_57677_/QN`，终点为
`u_backend/_24095_/D`。映射确认经过squash_rob_idx[2]→backend squash_seq[1]
→LSU load_result_valid（累计1.117 ns）→CDB src_ready[0]（1.387 ns）
→backend br_update tag[0]（1.684 ns）→ROB in_ready（2.553 ns）
→core dispatch[150]有效位（2.619 ns）→backend接收相关寄存器（3.384 ns）。
另一条接近原上限的控制链限制了总频率，单独改变加法结构收益很小。

本轮不将此RTL纳入当前候选：保存trial代码与测量后回退到5c921b7的LSU，保留
新增地址参考测试，供后续组合优化验证。后续应同时评估IQ/PRF/AGU数据通路与
ROB/CDB/dispatch控制链；不能仅凭一条路径退出首位就判定整体优化有效。
无opt、未合main、未推送。
