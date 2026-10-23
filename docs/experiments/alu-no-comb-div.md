# OoO ALU 移除冗余组合除法（2026-10-23）

## 基线与范围

本地 `main` 已从 C2 `94eac37` 快进到 `b6c009c`，接受非访存发射流水化。
回滚标签：`c2-area-baseline-20261023`、`freq-alupipe-baseline-20261023`。
本实验在 `feat/freq-alu-no-comb-div` 上进行，不改参数、流水拍数或访存路径。

## 原因

OoO 后端已经把 DIV/DIVU/REM/REMU 路由到独立的多周期 `u_div`，但两个
`alu` 实例仍保留组合 `/` 和 `%`。原综合展开网表中每个 ALU 模块含两个
`$div`、两个 `$mod`；即使执行控制不使用其结果，组合电路仍进入综合和
静态时序分析。

原 diagnose 第一条关键路径的累计到达时间：

| 路径段 | 进入 / 离开时间（ns） |
| --- | ---: |
| ROB / backend 控制 | 0.062 / 0.688 |
| LSU | 0.688 / 1.011 |
| CDB | 1.011 / 1.401 |
| backend 旁路 | 1.401 / 1.827 |
| ALU | 1.827 / 14.610 |
| 结果寄存器之前 | 14.610 / 14.670 |

因此先验证移除未使用的组合除法，而不是直接更改 squash 时序。

## 实现

- `alu.sv` 新增 `ENABLE_DIV` 参数，默认 1，保留顺序基线的完整组合行为。
- `backend_ooo.sv` 的两个 ALU 显式设 `ENABLE_DIV=0`；独立串行除法器不变。
- 本轮展开的后端 ALU 中 `$div` / `$mod` 均为 0。
- 不改 `scripts/`、`Makefile`、`config.mk`、`cpu_config.sv` 或 filelist。

## 验证

重新构建原基线与候选版本，内存延迟 10、每例上限 50,000,000 周期。
qsort、hanoi、queens 逐个运行，首次失败即停止；随后完成剩余用例。

- 基线与候选 W2/W1 correctness 各 19/19；两档全部 19 项周期数逐项相同。
- W2 六个 perf 的周期数逐项相同，IPC 0.6084；候选 W1 IPC 0.5759。
- `sh test/run_all.sh`：ALL PASS。
- `sh test/issue_queue_test/run.sh`：W1/W2 PASS。
- 独立 divider quick：5,031 项检查，0 失败。
- backend W1/W2 新增 32 组 DIV/DIVU/REM/REMU 集成测试，包括有符号负数、
  除零、INT_MIN/-1、无符号大数、依赖消费者和无重复广播。
- W1/W2 官方构建与 backend 测试无 IMPLICIT / UNDRIVEN 警告。

## 综合结果

diagnose 与标准 `make synth MODE=opt` 均已完成，报告记录的输入 SHA-256
与本轮 RTL 一致。

| 版本 | W2 IPC | diagnose 面积 / MHz | opt 面积 / MHz |
| --- | ---: | ---: | ---: |
| C2 `94eac37` | 0.6311 | 20,262.8 / 53.44 | 19,759.4 / 55.47 |
| 非访存流水 `b6c009c` | 0.6084 | 21,092.6 / 67.91 | 20,306.7 / 72.73 |
| 关闭组合除法 | 0.6084 | **19,777.0 / 99.38** | **18,955.7 / 115.80** |

diagnose 相对非访存流水基线：面积 -1,315.5 µm²（-6.2%），Fmax +46.3%，
IPC 不变。两个 ALU 各从 1,870.337 降到 1,186.593 µm²。

diagnose 的新关键路径从 ROB 到 LSU 寄存器，中间经过
`LSU → CDB → IQ select → PRF → AGU → LSQ query`。第一条路径中 IQ 输出约
3.755 ns、PRF 输出约 4.085 ns、LSQ 查询完成约 9.293 ns；总最小周期
10.0625 ns。后续若继续优化，应先研究访存 issue/消歧路径的所有权和分级，
不能直接把 load/store 放入旧的 a0/a1 缓冲。

## 复现

工具包无 FUSE 时设置 `APPIMAGE_EXTRACT_AND_RUN=1`。

```sh
export APPIMAGE_EXTRACT_AND_RUN=1
REPO_ROOT="$PWD"
make test MAX_CYCLES=50000000
make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
sh test/run_all.sh
sh test/issue_queue_test/run.sh
make synth MODE=diagnose
# diagnose 达标后串行运行，不能与上一条综合并发：
make synth MODE=opt
```

原报告已与本轮改动前的 RTL SHA-256 核对一致：
`build/synth/alupipe2/diagnose/report.txt`、
`build/synth/alupipe2_opt/opt/report.txt`。
本轮 diagnose 为保留实验对照另设输出目录
`build/synth/alu_no_comb_div/diagnose/`；opt 使用默认 `build/synth/opt/`。

## 最终决定与回滚

保留并纳入本地 `main`，tag `freq-alu-no-comb-div-20261023`，未推送。
opt 最小周期 8.6357 ns；相对流水基线，面积 -6.7%，
Fmax +59.2%，W2/W1 IPC 不变。

回退本轮时使用独立分支检出 `freq-alupipe-baseline-20261023`；
回退非访存流水化时检出 `c2-area-baseline-20261023`。保留原分支、标签和报告，
不要用破坏性 reset 覆盖已验证检查点。
