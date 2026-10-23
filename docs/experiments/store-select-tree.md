# LSQ 已提交 store 的平衡最老选择（2026-10-23）

## 基线与范围

分支 `feat/freq-store-select-tree`，基于 `6ae6be2` / `freq-lsu-tree-20261023`。
基线 W2/W1 IPC 0.5274/0.5059，diagnose 19,980.042 µm² / 232.04 MHz。
第一条路径为LSQ已提交store选择→drain_addr→AXI写请求捕获，LSQ段约4.1136 ns，
占4.3096 ns周期约95%。用户允许IPC/面积暂时越线，本轮仍以正确性和频率为主。

只调整 `lsq.sv` 的store drain组合选择，不增加流水寄存器或拍数，不改变load
查询快照、store提交/发送/释放与接口。候选独立保存，不合入main、不推送；
只运行一次diagnose，不追加opt。

## 实现

候选条件保持 `valid && is_store && committed && !sent`。对每个物理槽位形成
valid/seq/id，平衡树归约最老seq；相等seq时左子树优先，左侧为较低物理id。
默认16项4层，8项3层，无效补叶不参与选择。获胜id仍用于读取地址、数据和掩码。

发送握手仍设置sent并把id写入sent FIFO；写响应仍按FIFO头释放槽位，分配写入
优先级仍在最后，允许写响应与该槽位新分配同拍。不新增排空缓冲，ready低时
保持原有候选选择与payload。回归检查未提交store不可写、已发送store不可重复发送。

## 专项验证

直接LSQ测试原查询快照覆盖保持，新增store drain多笔在途场景：

- 按置换物理id分配，验证只在commit边沿后可排空，按seq最老或同龄低id选择；
  W2同时提交两个store，覆盖双提交候选更新。
- 逐笔反压3拍，核对id/addr/data/wstrb稳定，随后无B响应连续发满D笔，确保sent
  项不重复发送、发出后仍占用槽位。
- 依次返回旧B响应并在同拍分配其id，填入/提交新owner并再次发送；旧响应尚未
  收完时持续复用，覆盖sent FIFO两轮回绕，核对旧响应不能清除其他新owner。
- 返回全部新B响应，逐笔检查释放的id可分配、下一笔在途owner仍被保留，最终
  count=0且无drain；另检查squash移除speculative store、保留committed store。

W1/LSQ8 **637项 PASS**、W1/LSQ16 **1,173项 PASS**、W2/LSQ16 **1,173项 PASS**。
全部通过外部接口检查，不读取RTL内部信号。原LSQ8/16查询快照测试保留，测试
矩阵已接入现有 `test/lsq_query_test/run.sh` 和run_all。
默认整核构建无IMPLICIT/UNDRIVEN/UNOPTFLAT/LATCH警告；Yosys `proc; opt; check -assert`
检查0问题。qsort/hanoi/queens已逐个PASS；W1/W2全量各19/19 PASS，全部周期
与基线相同。完整run_all ALL PASS，LSU 292/483项、backend 445/449项均通过。
两档六个perf周期与基线相同，IPC 0.5274/0.5059。唯一一次diagnose已完成，
24个输入文件SHA-256均与当前RTL一致。

基线报告与仿真器已归档在 `build/synth/store_tree_baseline/`；本轮输出将写入
`build/synth/diagnose/`。`build/synth/opt/` 仍为main `bc795ae`旧结果。

## 复现命令

```sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/lsq_query_test/run.sh
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000
APPIMAGE_EXTRACT_AND_RUN=1 make test MAX_CYCLES=50000000 BUILD=build/store_tree_w1 VERILATOR=/tmp/freq_verilator_w1.sh
APPIMAGE_EXTRACT_AND_RUN=1 sh test/run_all.sh
REPO_ROOT=/home/zhaoyp/acm/RISC-V-CPU-2026
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/store_tree_w1/sim"
APPIMAGE_EXTRACT_AND_RUN=1 make synth MODE=diagnose
```

W1 wrapper仅添加 `+define+CPU_ISSUE_WIDTH=1`，不改默认配置，创建方法见本地
`prompt.md`。日志为 `/tmp/store-tree-{w1,w2}-test.log`、`/tmp/store-tree-{w1,w2}-perf.log`、
`/tmp/store-tree-unit.log`、`/tmp/store-tree-diagnose.log`；生成物不随Git提交。

## perf

latency=10，MAX_CYCLES=50,000,000。两档全部correctness和六个perf周期与基线相同。

| benchmark | instructions | W2 cycles | W2 IPC | W1 cycles | W1 IPC |
| --- | ---: | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 17,827 | 0.3905 | 18,439 | 0.3775 |
| perf_multiply | 21,722 | 23,161 | 0.9379 | 28,938 | 0.7506 |
| perf_qsort | 139,900 | 375,975 | 0.3721 | 383,141 | 0.3651 |
| perf_rsort | 195,719 | 362,998 | 0.5392 | 355,734 | 0.5502 |
| perf_towers | 5,278 | 12,379 | 0.4264 | 12,411 | 0.4253 |
| perf_vvadd | 4,524 | 6,584 | 0.6871 | 6,536 | 0.6922 |
| **GEOMEAN** | | | **0.5274** | | **0.5059** |

## diagnose 与保留决定

| 指标 | LSU 最老选择树 `6ae6be2` | store 排空选择树 |
| --- | ---: | ---: |
| W2 / W1 IPC | 0.5274 / 0.5059 | **0.5274 / 0.5059** |
| diagnose 面积 µm² | 19,980.042 | **19,952.559** |
| diagnose Fmax MHz | 232.04 | **240.60** |
| 最小周期 ns | 4.3096 | **4.1563** |
| 2 ns 目标下 WNS ns | -2.3093 | **-2.1554** |
| opt | 未运行 | **未运行** |

同模式Fmax **+3.69%**、面积 **-27.483 µm²（-0.14%）**；IPC不变，
`IPC×Fmax`约+3.69%。没有增加拍数或测得IPC代价，面积略降，保留独立检查点
`freq-store-tree-20261023`；未合入main、未推送，只跑一次diagnose，无opt。

LSQ面积2,638.003→2,607.677 µm²；整核组合13,381.728、寄存器5,409.880、SRAM
1,160.951 µm²。后两项与基线相同；映射/缓冲的少量变化使模块差额与整核差额
不同，总变化以整核报告为准。

本轮报告为 `build/synth/diagnose/{report.txt,report.json,timing.rpt}`，基线报告和
仿真器在 `build/synth/store_tree_baseline/`。`build/synth/opt/` 仍为main `bc795ae`
旧结果，不是本候选opt。

## 新瓶颈与下一步

报告前5条关键路径均转到ROB至第二路I-cache SRAM地址端，第一条为：
`u_core/u_rob/_57871_/QN → u_core/u_front/u_icache1/data_ram/lane_0/addr_in[7]`。
映射与源码确认的控制链为：

```text
squash_seq → LSU load_result_valid → CDB src_ready → branch update
 → ROB commit_lsq_id → LSQ alloc_ready → backend_ready / ren_ready
 → frontend resp_accept → icache0 fetch_ready → icache1 SRAM读地址
```

累计到达时间为LSU输出1.078 ns、CDB输出1.359 ns、ROB提交输出2.647 ns、
LSQ分配ready输出3.007 ns、backend_ready输出3.168 ns、前端resp_accept输出
3.472 ns、cache0 fetch_ready输出3.671 ns、cache1地址端4.055 ns。
这是跨模块控制/反压传播，不能把I-cache终点直接当作SRAM自身访问延迟。

本轮store选择已移出第一条路径。下一阶段先研究切断同拍资源释放到前端取指
的ready链：backend当前 `!skid_valid || skid_drain` 允许分配ready组合回传前端，
可评估增加弹性缓冲并使用寄存容量/ready，确保停顿时有空间接住已接受的dispatch，
避免ROB/LSQ分配重复或丢失；同时检查前端response容量和双cache握手是否能独立
推进。若评估恢复控制分级，需与ready链改动分开，保留按seq取消和分支恢复一致性。

本轮到此结束，不追加opt，也不继续叠加控制通路改动。
