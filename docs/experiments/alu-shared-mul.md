# ALU 乘法器共享实验（2026-10-23）

## 基线与范围

实验分支 `feat/alu-shared-mul`，起点 `3b3e467`（RTL `21fba79`）。
回滚检查点 `freq-alu-no-comb-div-20261023`：W2 IPC 0.6084、W1 IPC 0.5759，
opt 18,955.695 µm² / 115.80 MHz，diagnose 19,777.030 µm² / 99.38 MHz。

本轮只修改 ALU 的组合乘法表达式，不增加流水级，不改后端握手、访存顺序、
CPU 参数或官方 filelist。`ENABLE_DIV` 默认值和两种配置的除法行为不变。
不修改 `scripts/`、`Makefile`、`config.mk`。

## 基线证据与实现

原 diagnose 的算术映射日志显示，单个 ALU 建立了四个乘法 `$macc`：
MUL 低位、有符号×有符号、有符号×无符号、无符号×无符号。
后续门级优化可能共享部分逻辑，不能仅以表达式数量推断面积收益。
原 ALU / ALU1 diagnose 各为 1,186.593 µm²。

候选将四种指令共享到一个无符号 32×32 乘积 `P`：

```text
MUL     = P[31:0]
MULHU   = P[63:32]
MULHSU  = P[63:32] - (a[31] ? b : 0)
MULH    = P[63:32] - (a[31] ? b : 0) - (b[31] ? a : 0)
```

高半字修正按 32 位回绕。两个修正项由 opcode 控制，避免分别生成三套高位
运算。新展开网表只有一个 `$mul`，算术映射为一个乘法 `$macc`。

## 验证

- 新增 `test/alu_test/`，接入 `sh test/run_all.sh`。
- `ENABLE_DIV=0/1` 分别完成 312,256 / 401,472 次独立参考检查，共 713,728。
- 参考使用 C++ 的 64 位有符号/无符号乘法，不重复 RTL 的修正公式；覆盖符号
  边界、零、全一、交错位、单比特与负单比特、20,000 对固定种子随机输入。
- qsort、hanoi、queens 通过后，标准 W2 `make test MAX_CYCLES=50000000`
  19/19；W1 同样 19/19；两档全部 19 项正确性周期数与基线逐项相同。
- `sh test/run_all.sh`：ALL PASS。
- W2 perf 0.6084、W1 perf 0.5759；六个 benchmark 的周期数均与前一版相同。

## 综合结果

| 版本 | W2 IPC | diagnose 面积 / MHz | opt 面积 / MHz |
| --- | ---: | ---: | ---: |
| 原乘法表达式 `21fba79` | 0.6084 | 19,777.030 / 99.38 | 18,955.695 / 115.80 |
| 共享乘法候选 | 0.6084 | **18,603.442 / 99.38** | **17,895.831 / 115.12** |

diagnose 面积 -1,173.588 µm²（-5.9%）；ALU / ALU1 各降到 600.623 µm²。
频率及关键路径不变，仍为 `ROB → LSU → CDB → IQ → PRF → LSU/LSQ`。
最终 opt 面积 17,895.831 µm² / 115.12 MHz；相对基线面积 -5.6%，Fmax
-0.6%，IPC 不变。面积低于 18k 约 104.2 µm²。
opt 最小周期 8.6865 ns，WNS -6.6859 ns。
仅面积项满足阶段 2，IPC 0.845 和 300 MHz 尚未达到。

本轮已核对 diagnose / opt 报告输入 SHA-256 与候选 RTL 一致。基线 opt 摘要另存于
`build/synth/shared_mul_baseline/opt_report.txt`、`opt_report.json`，避免标准
命令覆盖旧结果；本轮报告使用默认 `build/synth/diagnose/`、`build/synth/opt/`。

## 复现与验收

```sh
export APPIMAGE_EXTRACT_AND_RUN=1
REPO_ROOT="$PWD"
make test MAX_CYCLES=50000000
make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
sh test/run_all.sh
make synth MODE=diagnose
# 阶段验收时再跑，不能与另一轮综合并发：
make synth MODE=opt
```

验收：正确性全通过，IPC / 周期数不变，面积确实下降，频率不明显退步。
用户已要求降低 opt 频率：平时用 diagnose 筛选，积累到阶段检查点再跑 opt。
本轮的一次 opt 已完成并用于阶段最终验收，之后不追加 opt。

## 后续访存分析（未修改 RTL）

`lsu` 当前将 AGU、LSQ query、forwarding / memory request 和 ready 反馈放在
同拍；`lsq` 查询按序扫描，选择最年轻的同地址旧 store。候选的 diagnose
关键路径仍到 LSU，单纯继续改 ALU 不会切断它。

下一轮先按 opt 网表定位实际路径，再独立设计访存请求所有权和重试语义。
阻塞 load 不能长期占住更老 store 的发射入口；必须保留 store address-only
预填、完整 store issue、CDB 唤醒和按 seq squash 的前进能力。不要直接把
load/store 放入现有 a0/a1，也不要重复旧实验的局部 bypass 补丁。

## 最终决定与回滚

保留，以约 0.6% 的频率下降换取 5.6% 面积减少，且不改变任何实测周期数。
纳入本地 main，tag `alu-shared-mul-20261023`，未推送。
回滚时从 `freq-alu-no-comb-div-20261023` 创建独立分支；不删除现有检查点。

访存分析可先评估“最年轻同地址 store”的平衡选择树，保持未知地址阻塞、
最年轻 partial store 阻塞及相等 seq 时的优先级；其面积/频率收益尚未验证。
本轮没有修改 LSU/LSQ，也没有启动下一项 RTL 实验。
