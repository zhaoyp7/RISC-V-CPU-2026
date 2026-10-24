# 前端响应按寄存容量入队（2026-10-24）

## 基线与范围

`feat/freq-frontend-response-capacity`，基于`4dc81b2` /
`freq-icache-local-read-trial-20261024`。基线IPC0.5195/0.4989，diagnose为
20,437.519 µm² / 300.29 MHz；正式地址预选择检查点cdddde6为300.03 MHz。
修改前24个输入hash一致，报告/仿真器在`build/synth/frontend_response_capacity_baseline/`。

本地预读移出了SRAM CE路径，但decode FIFO指令数据写入成为新的首条终点，
经ROB in_ready（2.578 ns）、rename in_ready（2.820 ns）到前端D端（3.270 ns）。
本轮只修改响应入队条件，保持请求发起与rename消费握手不变。
一次diagnose，不跑opt、不合main、不推送。

## 接收与容量不变量

fq_space_resp改为fq_count+2<=FDEPTH，只看寄存占用，不借用当前pop_credit。
即使队列本拍要出队，满队列也要到释放沿后才复用，因此响应入队不再组合依赖
rename_ready。为单条响应仍保守预留两个槽，保持原有最大双条配对约定。

同时移除resp_accept0中的backend_ready门控：已发请求的响应只需等待decode FIFO
容量、请求队首配对信息和redirect条件。backend停顿时可以先缓冲已有响应；
新fetch仍受backend_ready及原请求容量判断限制，rename仍按rename_ready消费。

每组响应最多写2条，寄存空闲至少2才接收；出队最多消费当前count，因此同拍
push/pop也不会覆盖未消费数据或令count溢出。请求FIFO的use2、预测快照与双路
响应队列的配对顺序不变，redirect/reset仍优先清除所有前端队列。
这是接收时序调整，不能假定周期数必然不变；需重新测量两档perf。

## 验证

增强frontend外部端口测试：先接受两笔双条请求，然后关闭backend且停住rename，
检查在途响应仍进入decode FIFO；继续关闭backend而打开rename，只消费原4条
指令，核对PC停在16、没有新请求/重复响应，顺序与预测快照正确。
加上原训练、非对称refill、满队列停顿及redirect矩阵，W1/W2为293/297项通过。

qsort/hanoi/queens依次通过。qsort和queens略快，hanoi略慢，需以完整perf判断收益。
W1/W2全量各19/19，W2 IPC0.5221、W1 IPC0.4988，完整run_all为ALL PASS；diagnose已完成，24个输入hash一致；
LOCAL_STATS lint通过，无新增IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH。
前一轮本地预读已通过索引4/10各10万拍随机矩阵及19259/71513次响应对拍。

## 复现

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/bpu_training_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/frontend_response_capacity_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/frontend_response_capacity_w1 SIM="$REPO_ROOT/build/frontend_response_capacity_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1，默认配置、官方filelist和SRAM包装器不变。
日志为`/tmp/frontend-response-capacity-directed.log`、`/tmp/frontend-response-capacity-{w1,w2}-{test,perf}.log`、
`/tmp/frontend-response-capacity-unit.log`、`/tmp/frontend-response-capacity-local-stats-lint.log`及
`/tmp/frontend-response-capacity-diagnose.log`。生成物不提交。

## perf

latency=10、MAX_CYCLES=50,000,000；两档均重新测量。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 18,311 | 0.3802 | 18,926 | 0.3678 |
| perf_multiply | 21,722 | 23,816 | 0.9121 | 29,588 | 0.7341 |
| perf_qsort | 139,900 | 385,836 | 0.3626 | 393,867 | 0.3552 |
| perf_rsort | 195,719 | 363,001 | 0.5392 | 355,740 | 0.5502 |
| perf_towers | 5,278 | 12,134 | 0.4350 | 12,508 | 0.4220 |
| perf_vvadd | 4,524 | 6,585 | 0.6870 | 6,537 | 0.6921 |
| **GEOMEAN** | | | **0.5221** | | **0.4988** |

## diagnose 与保留决定

| 指标 | 本地预读trial | 响应容量组合 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5195 / 0.4989 | **0.5221 / 0.4988** |
| diagnose面积 µm² | 20,437.519 | **20,441.849** |
| diagnose Fmax MHz | 300.29 | **322.42** |
| 最小周期 ns | 3.3301 | **3.1016** |
| 2 ns目标下WNS ns | -1.3295 | **-1.1012** |
| opt | 未运行 | **未运行** |

相对本地预读trial：频率+7.368%、面积+4.330 µm²（+0.021%），W2 IPC+0.509%，
W2 `IPC×Fmax`约+7.91%。相对正式300.03 MHz地址预选择基线cdddde6，组合频率
+7.462%、面积+4.534 µm²（+0.022%），W2 `IPC×Fmax`约+8.01%。W1 IPC仅下降
0.006%，四位显示值0.4989→0.4988不应解释为明显退化。

保留组合检查点`freq-frontend-response-capacity-20261024`。当前诊断频率高于
300 MHz约22.42 MHz（7.47%），形成初步余量，后续面积/IPC优化仍须重测；
没有运行opt，不把diagnose估计当作最终验收。未合main、未推送，main仍bc795ae。
本地预读单项仅0.088%的结论保留，最终收益来自组合版本，不拆分编造子改动频率。

组合面积13,667.482、寄存器5,613.417、SRAM1,160.951 µm²。没有新增寄存器面积。
前端直接面积1,608.786 µm²，含BPU/I-cache等子模块为5,062.267 µm²。

前端CE/响应入队退出首位。新第一条路径为
`u_backend/u_iq/_40914_/QN`→`u_backend/u_lsu/u_lsq/_52496_/D`，映射确认经过
IQ out_uop[128]源tag→PRF raddr[0]/rdata[0]→LSU issue_src1[0]+issue_imm[0]
→issue_addr[31]→LSQ fill_addr[31]捕获。
累计到达IQ输出1.759 ns、PRF输出2.088 ns、地址高位2.879 ns、LSQ D端3.042 ns。
相比早期地址数据通路的3.382 ns，分组地址进位在组合中发挥了作用。
下一轮优先研究IQ源tag选择与PRF地址形成，保持访存所有权和实际握手一致。

本轮两版综合顺序运行，各完成一次diagnose并核对24个输入hash。local-read trial
在`build/synth/icache_local_read_trial/`；当前完整候选报告、网表、RTL快照及
W1/W2仿真器在`build/synth/frontend_response_capacity_candidate/`。
默认`build/synth/diagnose/`和仿真器对应当前组合，全部验证完成后停止本轮RTL修改。
