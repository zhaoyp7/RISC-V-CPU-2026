# IQ 末端 squash 过滤（2026-10-23）

## 基线与范围

`feat/freq-iq-late-squash`，基于`c74d4e2` / `freq-dispatch-buffer-20261023`。
基线W2/W1 IPC 0.5274/0.5059，diagnose 20,103.272 µm² / 251.29 MHz。
关键路径ROB squash→IQ选择→PRF→LSU地址→LSQ fill捕获，IQ段约1.707 ns、
PRF约0.325 ns、地址生成约1.120 ns。

本轮只改IQ组合选择/输出和弹出门控，不加流水拍数，不改后端接口端口、PRF、
LSU请求归属和恢复时序。用户明确暂不opt：本轮仅一次diagnose，不合main、不推送。
此前d81cacb opt已取消（130），无有效结果，产物为`build/synth/opt_cancelled_20261023/`；
原main opt报告在`build/synth/frequency_checkpoint_baseline/`。

## 等价关系与有效性约束

旧IQ在候选比较之前剔除 `seq > squash_seq`，使squash进入选择/tag/AGU数据路径。
新结构先按原有年龄和ready规则预选，再以获胜seq过滤输出valid；out_uop/out_seq
只依赖预选，不经过squash。out_addr_only在valid无效时仍清零。

取消集合是年龄序列的年轻后缀。lane0在完整ready和地址预填候选中选最老项，
lane1在剩余完整ready项中选最老项：只要还有应保留的候选，它必排在年轻项前。
因此末端取消与先剔除再选择的有效输出相同，同龄低id优先仍保持。原参考模型
继续采用先剔除再排序的算法，不随RTL结构改写。

无效时out_uop/out_seq允许非零；消费者只能依据独立out_valid写状态，不能依据
uop内原dispatch valid位执行。IQ内部弹出/预填标记也改用过滤后的out_valid。
已审阅backend：a0/a1接收、LSU issue、complete入队均有iq_out_valid门控；LSQ填入
和store预填均由LSU握手触发。年轻payload可组合计算，不会获得发射握手。
IQ的按项squash清理、wake、同拍dispatch复用优先级保持原状。

## 专项验证

原行为测试61/60/64项通过。原5档参考对拍1,466,117项先通过；新增定向边界后：

| W / CDB / IW / D | 周期 | 检查数 | 结果 |
| --- | ---: | ---: | --- |
| 2 / 2 / 1 / 8 | 40,025 | 227,213 | PASS |
| 1 / 1 / 2 / 8 | 40,025 | 297,597 | PASS |
| 2 / 2 / 2 / 8 | 40,025 | 307,983 | PASS |
| 2 / 2 / 2 / 6 | 40,025 | 300,731 | PASS |
| 2 / 2 / 2 / 16 | 40,025 | 333,147 | PASS |

共200,125周期、1,466,671项。新增年轻预填+边界完整项、年轻完整项+边界预填、
全部候选取消三组，物理槽位与年龄相反；ready全开时核对保留/取消，后续wake
不得复活已取消项。随机检查仍覆盖反压、同拍wake/dispatch/squash和同龄规则。

默认构建无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH；Yosys `proc; opt; check -assert` 检查
0问题。qsort/hanoi/queens已逐个PASS；W1/W2各19/19、run_all ALL PASS，backend
各502项通过。两档全部correctness/perf周期与基线逐项相同，IPC 0.5274/0.5059。
diagnose已完成，24个输入hash与RTL一致。基线报告/仿真器在`build/synth/iq_late_squash_baseline/`。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/issue_queue_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/iq_late_squash_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/iq_late_squash_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper只添加 `+define+CPU_ISSUE_WIDTH=1`，不改默认配置。日志为
`/tmp/iq-late-squash-{w1,w2}-test.log`、`/tmp/iq-late-squash-{w1,w2}-perf.log`、
`/tmp/iq-late-squash-unit.log` 和 `/tmp/iq-late-squash-diagnose.log`；不提交生成物。

## perf

latency=10，MAX_CYCLES=50,000,000；两档全部correctness和六个perf周期与基线逐项相同。

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

| 指标 | 双槽dispatch缓冲 `c74d4e2` | IQ末端squash |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 20,103.272 | **20,162.350** |
| diagnose Fmax MHz | 251.29 | **261.69** |
| 最小周期 ns | 3.9795 | **3.8213** |
| 2 ns目标下WNS ns | -1.9793 | **-1.8204** |
| opt | 未运行 | **未运行** |

Fmax **+4.14%**，面积 **+59.078 µm²（+0.29%）**；全部correctness/perf周期与基线
相同，`IPC×Fmax`约+4.14%。保留独立检查点`freq-iq-late-squash-20261023`，
未合main、未推送；一次diagnose，不追加opt。24个输入hash与当前RTL一致。
组合面积13,503.165、寄存器5,498.235、SRAM1,160.951 µm²；后两项与基线相同。
IQ面积1,851.354→1,881.884 µm²，增加末端比较/门控后的整核面积以报告为准。

## 新瓶颈与下一步

原访存tag/地址路径已不在第一条路径。新路径为：

```text
squash_seq → LSU结果valid → CDB ready → backend分支更新
 → ROB br_update_uncond → BPU同拍训练旁路/predict_taken
 → 第二路取指握手 → I-cache地址端
```

第一条起点`u_core/u_rob/_57667_/QN`，终点
`u_core/u_front/u_icache1/data_ram/lane_0/addr_in[7]`。网表确认ROB出口为
`br_update_uncond`，BPU出口为`predict_taken`，末端为`data_addr[7]`。
累计到达：LSU输出1.083 ns、CDB输出1.362 ns、ROB输出2.872 ns、BPU输出3.334 ns、
第二路I-cache地址端3.720 ns。终点是地址setup约束，不能据此判定SRAM访问本身慢。

BPU当前对同拍upd_valid/PC/taken/target/is_uncond做读写旁路，方向立即影响取指。
下一阶段优先评估仅在frontend的BPU训练入口寄存整组更新字段，保持ROB分支解析、
redirect和squash即时处理；不要把整个分支恢复总线一起延迟。验证连续更新、
同索引训练、取指响应配对及预测快照，记录训练晚一拍对IPC的代价。
本轮到此结束，不追加opt或新RTL实验。
