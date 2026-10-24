# 接口规定

- 甲（前端/提交线）：取指、译码、BPU、rename、ROB、commit
- 乙（执行/存储线）：PRF、Issue Queue、CDB、ALU/divider、LSU/LSQ、D-Cache、mem_subsystem
- 参数：`verilog/cpu_config.sv`（由 `tools/config_gen.py` 生成）
- 字段切片宏：`verilog/if_defs.sv`（P1 创建，排在 `cpu_config.sv` 之后）；本文档表格是唯一依据，禁止手写偏移

## 约定

1. 所有 bundle 为扁平 `logic [N-1:0]`，字段从低位按表序打包；多路时 lane i 位于 `[i*BUS_W +: BUS_W]`，lane 0 最老。
2. tag = 物理寄存器号（`CPU_PRF_IDX_W`）：每条 uop 都分配唯一 `dest_preg`（含 `reg_we=0`）作为唯一标识；`PRF[0]` 恒 0 不分配，x0 作源时 `tag=0, ready=1`。同拍 lane 间依赖（lane 1 读 lane 0 的结果）用 `src_ready=0` + tag 指向对方 `dest_tag` 表达，由 CDB 唤醒，不做同拍旁路。
3. `dispatch`/`commit` 的 valid 前缀有效（lane i 有效 ⇒ 更低 lane 全有效）：`backend_ready=1` 时 dispatch 整体吸收，commit 按序逐 lane 吸收；`complete` 的 lane 相互独立（乱序完成，无前缀要求）。
4. 采样语义"本拍末有效、次拍消费"。预测失败的恢复：甲收到 `br_update` 后与保存的预测比较，自行冲刷前端并切 PC；后端中错误路径的 uop 由 `squash` 清除。
5. 反压：
   - `dispatch`：`backend_ready=1` 时乙吸收全部有效 lane；`=0` 时甲冻结 lane、IF/ID 与取指，保持到其恢复为 1 的下一拍。电平信号，不得脉冲丢失，复位后为 1。
   - 其余总线无 ready：`commit`/`cdb`/`complete`/`br_update`/`squash` 接收方每拍吸收；`if_refill`/`data_mem` 单未完成事务，请求保持到响应。

## 总线总览

| 总线 | 方向 | 单路宽度 | 打包后宽度（默认 W=1, R=1） |
| --- | --- | ---: | ---: |
| `dispatch[W]` | 甲 → 乙 | `124 + 3·PRF + LSQ + ROB` | W×150 |
| `cdb[R]` | 乙 → 甲 | `34 + PRF` | R×40 |
| `complete[W]` | 乙 → 甲 | `2 + PRF` | W×8 |
| `commit[W]` | 甲 → 乙 | `3 + PRF + LSQ` | W×12 |
| `br_update` | 乙 → 甲 | `67 + PRF` | 73 |
| `squash` | 甲 → 乙 | `1 + ROB` | 6 |
| `if_refill` | 甲 ↔ mem_subsystem | 请求 33 + 响应 33 | 66 |
| `data_mem` | 乙 ↔ mem_subsystem | 请求 70 + 响应 33 | 103 |
| `backend_ready` | 乙 → 甲 | 1 | 1 |

W = `CPU_ISSUE_WIDTH`（发射宽度，每拍可同时 dispatch/commit/complete 的 uop 数，默认 1）；

R = `CPU_CDB_NUM`（CDB 条数，默认 1）；

PRF = `CPU_PRF_IDX_W`（默认 6），LSQ = `CPU_LSQ_IDX_W`（默认 3），ROB = `CPU_ROB_TAG_W`（默认 5）。

各总线字段表见下文。

## 参数（默认 bring-up）

| 宏 | 默认 | 说明 |
| --- | ---: | --- |
| `CPU_ISSUE_WIDTH`（W） | 1 | dispatch/commit/complete 路数 |
| `CPU_CDB_NUM`（R） | 1 | CDB 条数 |
| `CPU_ROB_DEPTH` | 32 | ROB 深度；`CPU_ROB_TAG_W = $clog2(CPU_ROB_DEPTH)`（也用于跨接缝的 `rob_idx`） |
| `CPU_PRF_SIZE` | 64 | 物理寄存器数，任意整数 4..4096（验收含 96）；`CPU_PRF_IDX_W = $clog2(CPU_PRF_SIZE)` |
| `CPU_RS_DEPTH` | 8 | 每个发射队列深度；`CPU_RS_IDX_W = $clog2(CPU_RS_DEPTH)` |
| `CPU_LSQ_DEPTH` | 8 | LSQ 深度；`CPU_LSQ_IDX_W = $clog2(CPU_LSQ_DEPTH)` |
| `CPU_ICACHE_*` / `CPU_DCACHE_*` | 10/1/4 | index bits / ways / line bytes |
| `CPU_BTB_INDEX_BITS` / `CPU_BHT_INDEX_BITS` | 6 / 8 | BPU 项数 = 2^index_bits（BTB 64 项 / BHT 256 项） |

以下偏移列中 `PRF` = `CPU_PRF_IDX_W`（默认 6），`LSQ` = `CPU_LSQ_IDX_W`（默认 3），`ROB` = `CPU_ROB_TAG_W`（默认 5）。

## dispatch[W]（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `pc` | 32 | 1 | |
| `inst` | 32 | 33 | 原始指令（调试/异常） |
| `imm` | 32 | 65 | |
| `rd` | 5 | 97 | 提交时更新 RAT |
| `reg_we` | 1 | 102 | |
| `alu_op` | 5 | 103 | `rv32_defs.sv` 编码（含 M） |
| `a_sel` | 2 | 108 | |
| `b_sel` | 1 | 110 | |
| `wb_sel` | 2 | 111 | |
| `is_branch` | 1 | 113 | |
| `is_jal` | 1 | 114 | |
| `is_jalr` | 1 | 115 | |
| `is_load` | 1 | 116 | |
| `is_store` | 1 | 117 | |
| `illegal` | 1 | 118 | 提交时停机（P1） |
| `mem_size` | 2 | 119 | |
| `mem_unsigned` | 1 | 121 | |
| `dest_tag` | PRF (6) | 122 | 唯一 tag |
| `src1_tag` | PRF (6) | 122+PRF | |
| `src1_ready` | 1 | 122+2·PRF | |
| `src2_tag` | PRF (6) | 123+2·PRF | |
| `src2_ready` | 1 | 123+3·PRF | |
| `lsq_id` | LSQ (3) | 124+3·PRF | 非访存 don't-care |
| `rob_idx` | ROB (5) | 124+3·PRF+LSQ | 该 uop 的 ROB 分配序号（按程序序、在飞唯一），用于恢复排序 |

总宽 `CPU_DISPATCH_W = 124 + 3·PRF + LSQ + ROB`（默认 150）。

`lsq_id` 由前端在 rename 时分配（循环计数器），乙的 LSQ 以其为下标；load 的表项
在 commit 时释放；store 的表项在 commit 时排入写内存，真正写完成前仍占位并计入
`backend_ready` 反压（否则新 dispatch 复用 `lsq_id` 会覆盖未写出的数据）。

## cdb[R]（乙 → 甲 + 乙内部）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `tag` | PRF (6) | 1 | 结果的物理寄存器号 |
| `value` | 32 | 1+PRF | |
| `exception` | 1 | 33+PRF | 与 ROB 完成同拍 |

总宽 `CPU_CDB_W = 34 + PRF`（默认 40）。PRF 写回由乙在 cdb 广播同拍完成；无值结果走
`complete`；多 CDB 仲裁在乙内部，每 lane 一个赢家。

唤醒竞态：`cdb` 广播与 `dispatch` 同拍时，乙必须在把 dispatch uop 写入 IQ 的
同拍用本拍 `cdb` 做旁路比较（`src_tag` 命中即直接置就绪）；甲保证更早完成的
结果在 dispatch 时 `src_ready` 已为 1。否则消费者会等待一个永不重发的广播，
导致死锁。

## complete[W]（乙 → 甲）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `tag` | PRF (6) | 1 | 完成 uop 的 dest_tag |
| `exception` | 1 | 1+PRF | |

总宽 `CPU_COMPLETE_W = 2 + PRF`（默认 8）。用于不产生 CDB 值的 uop；
同一条 uop 只允许 `cdb`/`complete` 二选一。

## commit[W]（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | 按序提交窗口 |
| `tag` | PRF (6) | 1 | 提交 uop 的 dest_tag |
| `is_store` | 1 | 1+PRF | |
| `is_load` | 1 | 2+PRF | |
| `lsq_id` | LSQ (3) | 3+PRF | 该 uop 的 LSQ 表项（load/store） |

总宽 `CPU_COMMIT_W = 3 + PRF + LSQ`（默认 12）。语义：`is_store=1` 把该 store
排入写内存，排空前其 LSQ 表项保持占用（见 dispatch 小节）；`is_load=1` 直接
释放 LSQ 表项；两者都为 0 则忽略 `lsq_id`。提交前 store 不得写内存。

## br_update（乙 → 甲）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `pc` | 32 | 1 | |
| `taken` | 1 | 33 | 真实方向 |
| `target` | 32 | 34 | 真实目标 |
| `is_jalr` | 1 | 66 | 供 RAS 备用 |
| `tag` | PRF (6) | 67 | 该分支 uop 的 dest_tag，用于 ROB 精确定位 |

总宽 `CPU_BR_UPDATE_W = 67 + PRF`（默认 73）。每条解析完成的分支/跳转都发
一条；甲据此更新 BPU，并用 `tag` 在 ROB 中精确定位该表项（同一 PC 可能有多
条在飞，如循环），与保存的预测比较：不一致（含未预测的跳转）时由甲自行冲刷
并切 PC，无需乙判定。每拍最多一条；同拍多条解析完成时由乙内部排队、择机发出
（BPU 更新与恢复不在关键路径上）。`tag` 已不在 ROB（被更老的恢复冲刷）时忽略
本条；BPU 更新是否照常由实现决定。

精确恢复前提：**分支/跳转在甲收到其 `br_update` 之前不得提交**（`cdb`/
`complete` 提前到达无害，只标记 done、不改变这条约束）；乙必须保证每条
`br_update` 最终送达、不丢失/不覆盖（队列满时自行反压分支执行）。否则预测
失败会在分支提交之后才被发现，错误路径的年轻指令可能已被退休。

## squash（甲 → 乙）

| 字段 | 位宽 | 偏移 | 说明 |
| --- | ---: | ---: | --- |
| `valid` | 1 | 0 | |
| `rob_idx` | ROB (5) | 1 | 保留该序号及更老，丢弃更年轻的 |

总宽 `CPU_SQUASH_W = 1 + ROB`（默认 6）。甲在 `br_update` 比对失败时发出；
乙丢弃所有比 `rob_idx` 更年轻的在飞 uop（按 dispatch 顺序判定），释放其
IQ/LSQ 资源，并保证它们不再广播 `cdb`/`complete`；更老的 uop 不受影响。
每拍最多一条；与 dispatch 同拍时 squash 优先（先清后收），乙以本条 `rob_idx`
重置用于排序比较的基准。

## if_refill（甲 ↔ mem_subsystem）

| 方向 | 字段 | 位宽 | 偏移 |
| --- | --- | ---: | ---: |
| 请求 | `valid` | 1 | 0 |
| | `addr` | 32 | 1 |
| 响应 | `valid` | 1 | 0 |
| | `rdata` | 32 | 1 |

总宽 33 / 33。I-Cache 缺失时发起；响应 1 拍脉冲。P1 行宽 = 4B；行宽 >4B 时的
多拍/burst 方案在 P2 走 M5 扩展。

## data_mem（乙 ↔ mem_subsystem）

| 方向 | 字段 | 位宽 | 偏移 |
| --- | --- | ---: | ---: |
| 请求 | `valid` | 1 | 0 |
| | `we` | 1 | 1 |
| | `addr` | 32 | 2 |
| | `wdata` | 32 | 34 |
| | `wstrb` | 4 | 66 |
| 响应 | `valid` | 1 | 0 |
| | `rdata` | 32 | 1 |

总宽 70 / 33。store 响应表示已受理；与 `if_refill` 的仲裁在 mem_subsystem
内部，对甲透明。

## backend_ready（乙 → 甲）

1 位电平信号。`1` = 后端本拍可吸收全部有效 lane；`0` = 前端冻结 lane、IF/ID
与取指，保持到其恢复为 1 的下一拍。不得脉冲丢失，复位后为 1。

## Stub（P1 起）

Stub 是接口与真实模块完全一致、行为简化/脚本化的假模块：对方 RTL 没写完
时，用它替换对方那一侧，自己就能编译并跑单元测试（M3 机制）。

规则：

- 端口、时序、字段切片宏必须与真实模块一致（都取自 `if_defs.sv`），否则集成
  时对不上；
- 不要求功能正确，只按协议制造延迟、反压、异常、分支误预测等边界场景；
- 绝不进 `filelist.f`，只出现在单元测试里；
- 集成窗口按 M4 逐边替换：真前端 + stub 后端 → stub 前端 + 真后端 → 全真。

| stub | 主人 | 给谁用 | 行为 |
| --- | --- | --- | --- |
| `stub_exec.sv` | 甲 | 甲测前端/ROB | 收 `dispatch[W]`/`squash`/`commit[W]`，随机延迟回 `cdb[R]`/`complete[W]`（被 squash 的 uop 不再回），可造异常；按脚本发 `br_update`、驱动 `backend_ready`（可拉低测反压） |
| `stub_front_ooo.sv` | 乙 | 乙测后端 | 按脚本发 `dispatch[W]`/`squash`/`commit[W]`；收 `cdb`/`complete`/`br_update`；收 `backend_ready`（低时冻结发送） |
| `stub_mem.sv` | 乙 | 乙测访存 | 对 `if_refill`/`data_mem` 固定延迟响应，可注入错误 |

## 决策记录

1. tag 方案：唯一 `dest_preg`（每条 uop 分配，含 `reg_we=0`）；不采用 `cdb` 带 `rob_id`。
2. `cdb`/`complete` 分工：有值走 `cdb`，无值（store/branch 等）走 `complete`；同一条 uop 只发一种。
3. 参数：接受 `CPU_CDB_NUM=1`、`CPU_LSQ_DEPTH=8`（`config_gen.py` 可调）。
4. `commit` 字段：`valid/tag/is_store/is_load/lsq_id`（新增 `is_load` 用于 load 释放）；暂不补 `pc`/`exception`。
5. `br_update` 字段：`valid/pc/taken/target/is_jalr/tag`（新增 `tag` 用于 ROB 精确定位）；`is_call`/`is_return` 等 P2 升级预测时再加。
6. W 路规则：`dispatch`/`commit` 前缀有效；dispatch 由 `backend_ready` 整体吸收，commit 按序逐 lane；`complete` 的 lane 相互独立（乱序完成）。
7. `data_mem`：不补 `size`（`wstrb` 足够；该总线两端均属乙）。
8. `illegal`：P1 提交时停机；P3 需要精确异常时再引入状态位。
9. 分支恢复：删除 `redirect` 总线；乙对所有分支/跳转发 `br_update`（含 `tag`），甲基于 ROB 中保存的预测自行判定，并向后端发 `squash`。
10. 后端恢复：`dispatch` 增加 `rob_idx`（ROB 分配序号）；新增 `squash`（甲→乙，`valid + rob_idx`）用于丢弃错误路径的在飞 uop。
11. 精确恢复前提：分支/跳转在甲收到 `br_update` 前不得提交；乙保证 `br_update` 不丢失（队列满时自行反压）。


## 乙内部：divider（P1 执行端口使用）

`verilog/divider.sv` 是乙内部的多周期串行除法器，不属于甲/乙跨接缝总线，
但 P1 的 ALU 执行端口会例化它，因此在这里固定时序：

| 信号 | 方向 | 位宽 | 说明 |
| --- | --- | ---: | --- |
| `clk` / `reset` | in | 1 | 同步复位 |
| `start` | in | 1 | 1 拍脉冲；`busy=1` 时忽略 |
| `is_signed` | in | 1 | 1 = DIV/REM，0 = DIVU/REMU |
| `a` / `b` | in | 32 | 被除数 / 除数；运算期间保持稳定 |
| `busy` | out | 1 | 运算中为 1 |
| `done` | out | 1 | 完成脉冲；**`done=1` 当拍 `quotient/remainder` 已有效** |
| `quotient` | out | 32 | 商 |
| `remainder` | out | 32 | 余数 |

边界语义按 RISC-V M 扩展：除零时商为 `0xffff_ffff`、余数为被除数；
`signed INT_MIN / -1` 时商为 `INT_MIN`、余数为 0。


---

## P2 内部接口变更（乙内部，对甲/顶层 AXI 不变）

P2 把 LSU 与 mem_subsystem 之间的单事务 `data_mem` 口拆成三个流水接口，
并给 I-Cache 增加第二个 refill 口；顶层 `student_top` 的 AXI4-Lite 端口
保持不变。

### load 流（LSU → mem_subsystem）

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `ld_req_valid` | 1 | 请求有效，直到 `ld_req_ready` |
| `ld_req_addr` | 32 | 读地址 |
| `ld_req_ready` | 1 | 本拍可接收 |
| `ld_resp_valid` | 1 | 按请求顺序返回 |
| `ld_resp_rdata` | 32 | 读数据 |

LSU 内部最多 8 笔在途 load；响应按发请求顺序返回，LSU 用元数据 FIFO 配对。

### store 流（LSU → mem_subsystem）

| 字段 | 位宽 | 说明 |
| --- | ---: | --- |
| `st_req_valid` / `st_req_ready` | 1 / 1 | 写请求握手 |
| `st_req_addr` | 32 | 写地址 |
| `st_req_wdata` / `st_req_wstrb` | 32 / 4 | 写数据/掩码 |
| `st_resp_valid` | 1 | 写完成（按请求顺序，用于释放 LSQ） |

store 在 commit 后由 LSQ 按序 drain；写响应不必在提交路径上等待。

### I-Cache 双 refill（甲 ↔ mem_subsystem）

`if_refill` 与 `if_refill1` 两套 `valid/addr/resp_valid/rdata`，分别服务
双 bank I$ 的 pc 和 pc+4 取指流；两者都是单未完成事务协议。

### 兼容口

`mem_subsystem` 仍保留 P1 的 `data_req_* / data_resp_*` 单事务口，供
`test/mem_subsystem_test` 使用；官方顶层不连接该口。

## 访存查询分级实验的内部接收语义（独立分支）

`feat/freq-load-query-pipe` 不改变上述八条总线或 AXI 接口。乙内部 LSU 的
`issue_valid && issue_ready` 对 load 表示“按 LSQ id 的等待表已接收”，不再
表示读请求已发出；后端删除 IQ 表项后由 LSU 负责重试，不重复提交该 load。
load 的 ROB 完成仍只由实际 CDB 结果通知，不在接收时提前 complete。

store 地址预填 / 数据填入仍在接收拍执行，前者保留 IQ 表项，后者才完成。
load 内存 valid 独立于 ready，等待 ready 时地址稳定；查询 / 在途 / 结果
均携带 seq 处理 squash。在途与结果队列共同预留 LDQ_DEPTH 个结果容量。
详情见 `docs/plan/memory-query-pipeline.md`，该实验尚未合入 main。

### LSQ 内部查询快照握手（频率实验分支）

`feat/freq-lsq-snapshot` 把 LSU/LSQ 内部查询改为有反压的流水接口，外部
issue、load/store 流与 AXI 口保持原协议。请求 `query_valid && query_ready`
捕获匹配位、未知地址状态、候选 seq/data/full；下一拍
`query_resp_valid` 标识 `query_blocked/query_fwd_valid/query_fwd_data` 有效。
响应在 `query_resp_ready` 消费前保持不变，不再随 live store 表变化。

`query_flush` 丢弃当前响应，LSU 用 r 级 load seq 判断该响应是否被 squash。
消费或 flush 与新请求握手可同拍发生，新快照优先保存。LSU 的 r 级元数据
使用相同握手，q/r id 均从等待表选择集合排除。阻塞响应被消费后留表重试，
只有实际读请求握手或本地结果入队才释放等待表所有者。

### LSQ 分配只使用寄存占用（频率实验）

`feat/freq-lsq-registered-alloc`中，alloc_ready只检查寄存valid和组内重复id，
不借用当拍load提交、store写响应或squash释放的表项。释放在时钟沿生效后，
下一拍才可接收该id的新owner。整组分配仍原子执行；等待方保持请求直到ready。
load提交释放、store提交后排空及写响应释放的状态更新规则不变。

### IQ 末端取消的无效载荷约定（频率实验）

`feat/freq-iq-late-squash` 先预选最老候选，再按squash过滤独立out_valid。
当out_valid=0时out_uop/out_seq允许保留预选数据；backend必须用out_valid控制
接收、LSU握手及complete入队，不能依据uop内原dispatch valid位写状态。
out_addr_only在无效时仍为0；IQ弹出/预填标记也仅在out_valid与out_ready同时
为1时执行。有效输出的年龄、payload和握手语义保持原约定。

### BPU 训练入口寄存（频率实验）

`feat/freq-bpu-training-pipe` 只在frontend的BPU训练入口寄存valid、PC、taken、target、
is_uncond。训练相对输入晚一拍，连续每拍一笔可接收，reset清pending valid，
redirect不丢已接受的训练。BPU独立模块同拍旁路协议保持不变。

### 前端独立响应队列（频率实验）

两路I-cache出口各接两槽PC/指令队列，fetch_resp_ready只依赖本路寄存占用，
不借用当拍出队空间。无旁路，响应入队后下一拍才能参与配对。
请求FIFO仍保存use2和预测快照；只有队首use2=1才消费第二路响应，单条请求
不会误消费后续双条请求的第二路数据。decode FIFO空间只计实际rename出队。
redirect/reset同拍清请求、响应和decode队列；I-cache原flush即时生效。

### dispatch 年龄接收数量寄存（频率组合实验）

seq_pending保存上一拍实际接收的有效lane数，disp_seq_next=disp_seq+seq_pending
提前计算本拍组首；前后槽在接收时保存disp_seq_next。disp_seq每拍结算pending，
当前接收数量留给下一拍结算。组首数值、接收时机、ROB映射建立点及squash空洞
规则与原实现完全相同，不改变外部dispatch/ready协议。

### I-cache SRAM 地址预选择（频率实验）

lookup_room只由本地容量和s2接收条件产生，用于提前选择读地址；未使能时addr
可以变化。read_en有效时仍读取本拍接收的新PC、pending重放或停顿s1的原地址。
REFILL提前选refill_index，写入仍受原响应与flush条件控制；没有额外读写访问，
外部取指、响应、refill和flush时序保持原协议。
ROB分支解析、redirect/squash的对外时序不变；请求FIFO保存发请求当拍的预测快照，
后续训练不得改写在途指令的预测metadata。
