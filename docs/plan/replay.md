# Issue Replay / 非阻塞 Issue 设计

> 状态：设计草案，基于 `feat/pipeline-iq`（commit `9a7f9ff`）的 WIP。
> 目标：保留 IQ select / PRF read 分开带来的 **+29.8% Fmax**，同时修复
> load/store issue 死锁，保持 W=1/W=2 19/19。

---

## 1. 已观察到的死锁

WIP 版本：

- IQ select 与 PRF read 分开，pipe 寄存器持有选中 uop；
- 完整 correctness 13/19，qsort/hanoi 等 6 个 case 死锁；
- diagnose Fmax **70.04 MHz**（基线 53.96 MHz，+29.8%）；
- 关键路径 18.19 ns → 14.28 ns。

qsort trace：

- pipe 中是一条 load（pc=0x110 附近）；
- LSQ 中更老的 store seq=14704，`addr_known=0`；
- load 的 LSQ query 被这个 store 阻塞；
- `pipe_blocked` 长期为 1，`stall_lsu` 占满周期；
- ROB 头部是一条 branch/load，无法完成。

尝试过的补丁：

1. address-only store prefill bypass；
2. full store bypass + complete FIFO push；
3. pipe-blocked 寄存触发旁路。

结果仍有 6 个 case 死锁。说明问题不是“缺一个旁路”，而是 **issue 所有权
和 store 地址预填的时机**。

---

## 2. 根因分解

死锁不是单点，而是两个独立问题叠加：

### 问题 A：pipe 持有 load 后，lane0 被占住

- load 被 LSQ 老 store 阻塞时，不能执行；
- pipe 不释放，IQ 无法再选更老的 store 做 prefill/issue；
- 形成“load 等 store 地址，store 等 lane0”循环。

### 问题 B：更老的 store 可能还在 skid / 无法进入 IQ

trace 显示：

- 阻塞 load 的 store seq=14704；
- `SKID_DRAIN seq=14705`，说明 store 14704 可能是上一组 skid 的 uop；
- IQ 长期满（`iq_full_stall` 接近满周期），skid 无法把 store 送进 IQ；
- 即使 pipe 释放 lane0，store 仍可能不在 IQ 中，无法 prefill。

因此只做 replay（释放 pipe）**不一定够**；还必须让 store 地址在
dispatch/skid 阶段就能进入 LSQ，或者为 memory uop 保留 IQ 入口。

---

## 3. 设计目标

1. pipe 中的 load 被阻塞时，不长期占用 lane0；
2. IQ 能继续发射更老的 store / 其他可执行 uop；
3. store 地址不依赖“store 必须先进 IQ 再 issue”；
4. 保持程序序/内存序：load 不能越过未知地址的更老 store；
5. squash 时 replay / prefill 状态可精确清理；
6. W=1/W=2、ROB16/32、PRF48/64、LSQ8/16 都成立。

---

## 4. 推荐架构

分两层解决，不要把所有逻辑塞进一个 replay 寄存器。

### 4.1 层 1：dispatch/skid store 地址预填

目标：store 的地址在 **rename/dispatch/skid** 阶段就尽可能填入 LSQ，
不再依赖 store 先进入 IQ 并 issue。

可选实现：

#### 方案 1A：dispatch 时读 PRF（简单）

- store 在 dispatch 时若 `src1_ready=1`，用额外 PRF 读口读 src1；
- 计算 `addr = src1 + imm`，直接写 LSQ 的 `addr/addr_known`；
- 若 `src1_ready=0`，在 LSQ 中保存 `src1_tag + imm`，等 CDB 唤醒时捕获
  src1 值并计算地址；
- 需要：
  - 1 个额外 PRF 读口（或复用 skid 空闲口）；
  - LSQ 增加 pending address 表项；
  - CDB tag 比较（8 项）写回地址。

优点：彻底消除“store 必须先 issue 才有地址”。
缺点：面积/时序增加；需要小心 PRF 读口和 CDB 唤醒。

#### 方案 1B：skid 阶段预填（折中）

- skid 中持有 store uop 时，若 `src1_ready=1`，用现有 lane1 空闲 PRF 口
  读 src1，写 LSQ；
- 不要求 store 进入 IQ；
- 对 `src1_ready=0` 的 store，仍等 issue。

优点：不改 dispatch/rename；直接解决 skid 堵死。
缺点：只能覆盖 src1 已 ready 的 store；若 src1 很晚 ready，仍可能阻塞。

#### 方案 1C：为 memory uop 保留 IQ 槽位

- IQ 分配时给 load/store 保留至少 1–2 个槽；
- skid 中的 store 可以优先进入 IQ；
- 配合 replay，store 能及时 prefill。

优点：改动小。
缺点：降低 IQ 有效容量，可能影响 IPC；不能覆盖 src1 未 ready 的情况。

**建议先做 1B + 1C**，再评估 1A。

### 4.2 层 2：retain-entry IQ + replay

目标：pipe 阻塞时释放 lane0，同时不丢失 uop，并保持 age 顺序。

#### 设计

- IQ 表项在 **execution accepted** 前不删除；
- 增加 `in_pipe` 位：
  - IQ 选中并送入 pipe 时置 1；
  - pipe 执行成功（`issue_ready`）时清 1 并删除 IQ 表项；
  - pipe 阻塞/回滚时清 1，表项仍在 IQ，可重新选择。
- pipe 只保存一份 copy；真正所有权在 IQ。
- IQ 选择时跳过 `in_pipe=1` 的表项；
- 当 pipe 阻塞：
  - 不删除表项，清 `in_pipe`；
  - 下一拍 IQ 可重新选择该 uop 或其他 uop；
  - 用 seq 保证 age 顺序。
- squash：
  - 按 seq 清 IQ 表项和 `in_pipe`；
  - pipe 中年轻 uop 清 valid；
  - replay 不需要额外队列，IQ 本身就是 replay 存储。

#### 为什么比“独立 replay 寄存器”好

- 不需要第二份 uop 存储；
- 不会出现 pipe 和 replay 同时持有两个 uop 的 age 冲突；
- squash 只需按 seq 清 IQ；
- IQ 容量就是 replay 容量。

#### 关键时序

- IQ 选择 → pipe 写入：仍然是一级寄存器；
- pipe 阻塞 → 清 `in_pipe`：需要一条回压路径，但不进关键路径；
- 执行成功 → IQ 删除：需要 `execute_ack` 信号。

#### 需要新增接口

- `issue_ack`：pipe 执行成功，IQ 删除表项；
- `issue_replay`：pipe 阻塞，IQ 清 `in_pipe`；
- `in_pipe` 位（每表项）；
- `executed_seq` / `replay_seq` 可选，用于调试。

---

## 5. 分阶段实施

### Phase 1：store 地址预填（先做）

1. skid 中 store 的 src1 ready 时，预填 LSQ 地址；
2. 给 IQ 的 memory uop 保留槽位，避免 skid 堵死；
3. 跑 W=2/W=1 + qsort/hanoi 压力；
4. 如果死锁消失，再进入 Phase 2。

**Phase 1 实测（WIP `6971acd`）**：

- 增加了 skid store 预填队列（4 项）+ PRF 第 5 读口；
- skid drain 时捕获 `lsq_id/src1_tag/imm/seq`，src1 ready 后写 LSQ；
- qsort/hanoi/queens 仍然死锁；
- 原因：阻塞 store 的 src1 依赖链本身也被卡住；仅预填地址不足以
  释放 issue/lane0 的所有权循环。
- 结论：**Phase 1 单独不够，必须做 Phase 2 的 retain-entry IQ/replay**。

**Phase 2 实测（WIP `c12ac89`）**：

- 让 LSQ 在 skid 捕获时就分配表项（不等 IQ drain）；
- 预填队列改为从 skid 直接捕获 store；
- 仍然无法解开 qsort/hanoi/queens 死锁。

最终判断：

- 死锁不是单一“store 地址未知”或“IQ 容量”问题；
- 它涉及 **issue 所有权、skid/IQ 反压、LSQ 分配时机、load/store
  内存序** 的联合设计；
- 继续局部补丁会不断产生新的循环等待；
- 要做对，需要把 IQ/LSU 的接口和所有权语义一起重写，并配合专门的
  压力测试，而不是在现有 8 项 IQ + 8 项 LSQ 上继续加旁路。

**时间盒结论**：Phase 2 未在约定时间内得到 19/19，按计划停止这条
实验线，不合并 `feat/pipeline-iq`。WIP 分支保留（`c12ac89`）供后续
有完整时间时重做。

### Phase 2：retain-entry IQ + replay

1. IQ 增加 `in_pipe`、`issue_ack`、`issue_replay`；
2. pipe 阻塞时清 `in_pipe`，不删除表项；
3. 执行成功时删除；
4. squash 清理；
5. 跑全量 + 压力。

### Phase 3：性能/频率评估

- `make perf`；
- `make synth MODE=diagnose`；
- 若 Fmax ≥ 70 MHz 且 IPC ≥ 0.60，保留；
- 再评估下一段关键路径。

---

## 6. 验证矩阵

- W=1/W=2 19/19；
- `run_all` ALL PASS；
- qsort/hanoi/towers 连续压力；
- load/store 同地址 forwarding；
- store 地址晚 ready；
- IQ 满 + skid 满 + LSQ 满；
- 连续 mispredict + replay；
- squash 发生在 pipe/EX/MEM；
- 参数：ROB16/32、PRF48/64、LSQ8/16、W1/W2。

---

## 7. 风险

| 风险 | 应对 |
| --- | --- |
| store 预填面积/时序 | 先做 1B/1C，1A 后置 |
| replay 破坏 age/内存序 | 用 seq 比较，先保守 |
| IQ 有效容量下降 | memory 槽位只保留 1–2 个 |
| 死锁仍在 | 加断言/统计，先小用例 |
| Fmax 回退 | 每阶段 diagnose，不达标回滚 |

---

## 8. 当前结论

- IQ/PRF 分开的 **+29.8% Fmax** 值得保留；
- 但必须先解决 store 地址预填和 issue 所有权；
- 不要继续在 WIP 上叠局部 bypass；
- 按 Phase 1 → Phase 2 实施，每阶段独立分支/验收。
