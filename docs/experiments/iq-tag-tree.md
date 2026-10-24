# IQ 源 tag 随候选树传递（2026-10-24）

## 基线与改动

`feat/freq-iq-tag-tree`，基于 `e9390ce` /
`freq-frontend-response-capacity-20261024`。基线 diagnose 为
20,441.849 µm² / 322.42 MHz，W2/W1 IPC 为 0.5221 / 0.4988。
修改前核对24个输入hash，报告、IQ源码和W2仿真器保存在
`build/synth/iq_tag_tree_baseline/`。

基线关键路径经过 IQ 源 tag 选择、PRF 异步读、LSU 地址加法和 LSQ 地址捕获，
累计到达分别为1.759、2.088、2.879和3.042 ns。
原树先选出物理slot，再动态索引完整uop取得源tag；本轮将两个源tag放入候选
packet，随 first/second/prefill 的年龄比较一起传递，直接覆盖输出uop中的tag字段。
这样给综合工具明确表达局部tag选择，避免依赖最终slot索引后的另一层选择。

valid仍为packet的bit40，seq和slot布局不变；比较只使用valid、seq及既有slot
平局规则。两个tag取自与uop同拍分配且不被wake修改的寄存字段，因此输出tag
与所选uop一致。其余uop字段仍通过原slot索引读取。

不增加寄存器或流水拍数。registered wake、最老优先、双发射、独立lane反压、
store地址预填及late squash语义保持一致；IW>2保留逐lane扫描和动态tag选择。
不修改PRF/LSU/LSQ、访存所有权、参数、官方filelist或SRAM包装器。

## 验证与复现

现有独立scoreboard逐拍按(seq, slot)排序，并比较输出全部uop字段，包含两个
源tag。矩阵覆盖IW1/IW2、W1/W2、D6/D8/D16，五档各40,025周期，合计
1,466,671项检查且零失败；原IW1三档行为回归也通过。
qsort、hanoi、queens按顺序通过，周期分别为1,925,924、9,535、678,284。
W1/W2全量正确性各19/19通过，两档全部正确性周期及六个perf周期均与基线逐项相同。
两档perf均重测，W2 IPC为0.522108164152558，W1为0.4988444806718703。
分benchmark数据与[响应容量组合](frontend-response-capacity.md#perf)一致，不重复列相同表格。
完整run_all为ALL PASS；backend W1/W2为566/592项，LSU depth8/depth16为
63,757/63,948项，前端响应队列W1/W2为293/297项，均零失败。
LOCAL_STATS整核lint通过，无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH。
diagnose已完成，24个输入hash一致；映射结构检查0 problems。

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/issue_queue_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/iq_tag_tree_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 BUILD=build/iq_tag_tree_w1 SIM="$REPO_ROOT/build/iq_tag_tree_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1包装器只增加CPU_ISSUE_WIDTH=1。日志位于
`/tmp/iq-tag-tree-{iq,w1-test,w2-test,w1-perf,w2-perf,unit,diagnose}.log`。
本轮仅一次diagnose，不跑opt、不合main、不推送。


## diagnose与决定

| 指标 | 322.42 MHz基线 | IQ tag树trial |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5221 / 0.4988 | 0.5221 / 0.4988 |
| diagnose面积 µm² | 20,441.849 | 20,431.512 |
| diagnose Fmax MHz | 322.42 | 318.90 |
| 最小周期 ns | 3.1015625 | 3.1357422 |
| 2 ns目标WNS ns | -1.101206 | -1.135658 |

频率下降1.090%，面积仅减少10.337 µm²（0.051%），IPC相同，IPC×Fmax也下降1.090%。
不采用为当前频率检查点；保留trial源码、测试和网表作为分析对照，恢复e9390ce的RTL。
本轮一次diagnose，无opt；不合main、不推送，main仍bc795ae。

trial组合面积13,685.138、寄存器5,585.423、SRAM1,160.951 µm²。
虽然没有增加RTL寄存器，映射时寄存器合并/使能实现仍可能变化；总寄存器面积比基线
减少27.994 µm²，不应将“无新流水级”等同于“综合寄存器面积必然相同”。

trial第一条路径为ROB寄存器→backend→LSU→CDB→backend→ROB→rename捕获，
累计0.070/0.560/1.107/1.373/1.640/2.653/3.080 ns。
另一条近邻路径经相同前半段，转向ROB ready→rename ready→前端请求控制→I-cache
寄存器，D端到达3.096 ns。全核瓶颈已经转移，不能只根据IQ路径退出首位判断成功。

对已映射trial网表补做一次以IQ寄存器为起点的OpenSTA查询（没有重新综合）：
同一IQ→PRF→LSU地址→LSQ fill路径累计1.603/1.920/2.712/2.875 ns，
比基线1.759/2.088/2.879/3.042 ns提前0.156/0.168/0.167/0.167 ns。
局部数据路径确有改善，但全核Fmax下降；保留作为后续控制链优化的组合对照，
不以局部收益替代全核测量。附加时序查询在候选归档的`focused/`中。

完整候选在`build/synth/iq_tag_tree_candidate/`，包括diagnose报告/网表、IQ源码、两档
仿真器和本轮日志。基线在`build/synth/iq_tag_tree_baseline/`；恢复后默认综合报告与
仿真器应回到前端容量检查点，trial数据只从归档引用，防止混用。
