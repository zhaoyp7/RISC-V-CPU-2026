# RISC-V CPU 2026 — 协作者交接（P2 功能完成，性能优化中）

> 这是**已跟踪**的协作文档，`git pull` 即可获得。
> 本地完整版 `prompt.md` 被 `.gitignore` 忽略，不会随 git 同步；本文件是
> 给协作者/新 agent 的入口。
>
> 仓库根目录 = 本文件所在目录（包含 `verilog/`、`Makefile`、`README-ZH.md`）。
> 所有命令默认在仓库根目录执行。

---

## 0. 拉取后第一件事

```sh
git switch main
git pull --ff-only
git submodule update --init --recursive
git log --oneline -5
```

如果 `testcases/` 是空的，说明 submodule 没初始化：

```sh
git submodule set-url testcases \
  https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026-Testcases.git
git submodule update --init --recursive
```

然后验证环境：

```sh
python3 tools/config_gen.py --check
make build JOBS=4
make test MAX_CYCLES=50000000
```

### 唯一不随 git 拉取的东西

`cpu2026-tools-x86_64.AppImage` 被 `.gitignore` 忽略（课程工具包，约 37 MB），
不在仓库里。如果合作者电脑上还没有：

1. 从旧电脑复制到本仓库根目录，或按 `README-ZH.md` 的方案 B/C 使用 Docker/
   原生工具链；
2. `chmod +x cpu2026-tools-x86_64.AppImage`；
3. 如果 FUSE 不可用（WSL/容器）：`export APPIMAGE_EXTRACT_AND_RUN=1`。

除此之外，RTL、测试、文档、`docs/handoff.md` 都已经在 git 中，拉取即可。
`build/`、`build/synth/` 是本地产物，不需要复制，重新构建即可。

---

## 1. 当前状态（2026-10-23）

- 分支：`main`
- P1 功能 tag：`p1-ooo-final`（`0d6e07f`）
- P2 RTL 提交：`a95a938`（双发射 + 双取指 + 流水访存）
- 性能检查点 tag：`p2-perf-prefill`（store 地址预填 + ROB recovery 修复 +
  LOCAL_STATS；2026-10-22 推送）
- 当前 `main`：以 `git log -1 --oneline` 为准
- 官方 `verilog/filelist.f` 使用 OoO 顶层 `student_top_ooo.sv`
  （模块名仍是 `student_top`）
- 基线 `core.sv`/`icache.sv`/`student_top.sv` 保留但不在 filelist

### 已验证

- 官方 W=1 correctness：**19/19 PASS**
- 官方 W=2 correctness：**19/19 PASS**（`MAX_CYCLES=50,000,000`）
- `sh test/run_all.sh`：**ALL PASS**
- `test/lsu_test`、`test/mem_subsystem_test`、`test/backend_test` 已适配
  P2 端口并加入 `run_all.sh`
- `python3 tools/config_gen.py --check`：up to date
- 当前课程分数估算：仍约 **85/100**（性能/面积/频率未达阶段门槛）

### 当前性能/面积（W=2）

| 指标 | 当前值 | 阶段 1 门槛 | 阶段 2 门槛 |
| --- | ---: | ---: | ---: |
| IPC GEOMEAN | **0.6311**（C2 面积档，`1e99cc8`） | ≥ 0.6000 | ≥ 0.8450 |
| 面积（opt） | **19,759.4 µm²**（C2；diag 20,262.8） | ≤ 9,000 µm² | ≤ 18,000 µm² |
| 频率（opt） | **55.47 MHz**（C2；diag 53.44） | ≥ 300 MHz | ≥ 300 MHz |

P2 基线 `a95a938` 的 IPC 为 0.5507；`a56cca6` 加入 store 地址预填后
提升到 0.6380。2026-10-23 曾用 LSQ32 把 IPC 推到 0.7295，但面积涨到
28.4k；随后按“频率/面积优先”切回 **C2 面积档**（`1e99cc8`，ROB16/
PRF48/LSQ16/1KB I$），W=2 IPC **0.6311**、diagnose 20.26k。
tournament gshare + GHR 快照（`9666237`）在 LSQ32 上把 IPC 推到 0.7563，
但面积 +1.45k，保留在 `feat/gshare-snapshot` 分支，未入默认。
W=1 档 C2 为 19/19 PASS、IPC 0.5940。perf 明细、参数敏感度和 synth
breakdown 见 `docs/perf-log.md` 与 `docs/integration-status.md`。

2026-10-22 还修复了 ROB16 的恢复竞态（`ab00273`），C2 依赖该修复。
C2 的完整参数/复现命令/注意事项见 `docs/configs/c2-area.md`。

### 频率流水化分支（未合并）

分支 `feat/freq-alupipe`（HEAD `fa8920f`）在 C2 参数上把非访存发射流水化：

- lane1：IQ → a1 缓冲 → PRF/ALU1；
- lane0：非访存 IQ → a0 缓冲 → PRF/ALU/分支/div；load/store 仍直连 LSU；
- PRF 扩为 6 读口，避免 a0/a1 同时执行时读口冲突。

| 指标 | C2 `main` | 频率分支 |
| --- | ---: | ---: |
| W2 IPC | 0.6311 | **0.6084** |
| W1 IPC | 0.5940 | **0.5759** |
| diagnose 面积 / Fmax | 20,262.8 / 53.44 | 21,092.6 / **67.91** |
| opt 面积 / Fmax | 19,759.4 / 55.47 | **20,306.7 / 72.73** |
| correctness | W2/W1 19/19 | W2/W1 19/19 |
| `run_all` | ALL PASS | ALL PASS |

相对 C2 opt：面积 +2.8%，Fmax +31.1%，IPC -3.6%，`IPC × Fmax` +26.4%。
分支**尚未合并**；若接受面积换频率，再合入 `main`。回滚点：
`main` 的 `94eac37`，或本分支的 `0621c83`（仅 lane1 版本）。

---

## 2. 当前架构

`verilog/cpu_config.sv` 默认：

| 参数 | 当前值 |
| --- | ---: |
| `CPU_ISSUE_WIDTH` | 2 |
| `CPU_ROB_DEPTH` | 16 |
| `CPU_PRF_SIZE` | 48 |
| `CPU_RS_DEPTH` | 8 |
| `CPU_CDB_NUM` | 2 |
| `CPU_LSQ_DEPTH` | 16 |
| I-Cache | 双 bank，每 bank 1 KB 直接映射，1 字/行 |
| BTB / BHT | 32 项 / 128 项 2-bit（单 BPU 双读口） |
| D-Cache | **未实现**（原型已验证不适合当前阻塞式方案，已回退） |

### 已实现

- RV32IM；乱序发射/乱序完成/按序提交
- 精确分支恢复、RAT replay、ROB 恢复、统一 32-bit dispatch seq squash
- 双 bank I-Cache、fetch FIFO、取指侧 BPU 预测（消除 taken 气泡）
- 双发射 IQ、第二 ALU、两条 CDB、wake 掩码（同拍多条完成）
- PRF/IQ/CDB/ALU/多周期 divider/LSU/LSQ
- 流水化 load/store、多笔在途 load、按序响应、store-to-load forwarding
- `mem_subsystem` + `axi_mem_if` 多笔在途读/流水写、I$ 双 refill 客户

### 关键限制

1. 取指仍限制吞吐：每 bank 每拍一条，分支误预测恢复约 6–7 拍
2. 无低延迟 D-Cache：towers 等 pointer chasing 直接暴露 10 拍内存延迟
3. BPU 仍是 BTB + 2-bit BHT；gshare/RAS 未接入
4. 关键路径仍是 `ROB → backend`；`main` C2 opt 55.47 MHz / 19.76k，
   频率分支 opt 72.73 MHz / 20.31k，阶段 1/2 的面积/频率门槛均未达
5. 双发射只在 ALU lane 生效；mem/div/branch 仍单端口
6. 频率分支已验证“非访存 IQ/PRF 分开”可行，但 load/store 仍直连 LSU；
   独立 memory issue queue（MIQ）尚未实现

---

## 3. 下一步：先频率/面积/分支预测，D-Cache 暂缓

2026-10-22 决策：**不要先做 D-Cache**。当前课程门槛是全有或全无：

| 指标 | `main` C2 | 频率分支 | 阶段 1 | 阶段 2 |
| --- | ---: | ---: | ---: | ---: |
| IPC | 0.6311 | 0.6084 | ≥ 0.6000 | ≥ 0.8450 |
| 面积（opt） | 19,759 µm² | 20,307 µm² | ≤ 9,000 | ≤ 18,000 |
| 频率（opt） | 55.47 MHz | 72.73 MHz | ≥ 300 | ≥ 300 |

IPC 已过阶段 1，但面积/频率差得更远；只把 IPC 提到 0.6 不会改变 85 分。
D-Cache 会增加面积、可能拖慢 ROB→backend 关键路径，而且 P2 的 4KB
阻塞式写直达原型已经测到 IPC 0.1543，不能直接重做。

建议优先级：

1. **先决定频率分支是否合入**：`feat/freq-alupipe` 已全绿，Fmax +31%，
   但面积 +0.55k、IPC -3.6%；接受后合入 `main` 再跑 opt 文档。
2. **频率继续（最高优先）**：关键路径仍是 ROB→backend，终点在 ALU
   结果寄存器。先试把 a0/a1 的结果捕获从 squash 组合使能路径上移走，
   再考虑两级 squash / MIQ；不要重复“把 load/store 放进流水级”的旧死锁。
3. **面积**：当前频率版 20.3k opt，距 18k 还差约 2.3k；需要 LSQ/ROB/BPU/
   I$ 的结构性缩减，单纯扫参数会把 IPC 压到 0.60 以下。
4. **分支预测**：gshare 必须保存预测时 GHR 快照；分支 `feat/gshare-snapshot`
   已有实现（LSQ32 上 IPC 0.7563，但面积 29.9k），未入默认。
5. **D-Cache 仅在计数器和面积预算允许时再做**：小型、非阻塞、
   写直达 + store buffer、带 MSHR/hit-under-miss；不要重复阻塞式 4KB。
6. **LSQ 增强**：store-to-load forwarding、non-blocking load、地址消歧。

路线判断：阶段 1 的 9k 面积非常激进；如果频率/面积压不下去，优先评估
阶段 2（面积 18k 更近，但 IPC 要 0.845），不要为了一个 IPC 指标盲目加
D-Cache。`main` 已打 tag `p2-dual-issue`，没有 `p2-stage1`。

---

## 4. 常用命令

```sh
# 默认 W=2
make build JOBS=4
make test MAX_CYCLES=50000000
REPO_ROOT="$(git rev-parse --show-toplevel)"
make perf MAX_CYCLES=50000000 SIM="$REPO_ROOT/build/sim"
make synth MODE=diagnose
make synth MODE=opt

# 单测
sh test/run_all.sh --build
sh test/lsu_test/run.sh
sh test/backend_test/run.sh
sh test/issue_queue_test/run.sh
sh test/rob_test/run.sh --quick
ROB_W=2 sh test/rob_test/run.sh --quick
sh test/rename_test/run.sh --quick
RENAME_W=2 sh test/rename_test/run.sh --quick
```

### W=1 构建（默认已是 W=2）

`cpu_config.sv` 默认 W=2，直接 `make build` 即可。W=1 用带
`CPU_ISSUE_WIDTH=1` 的 wrapper：

```sh
export REPO_ROOT="$(git rev-parse --show-toplevel)"

cat > /tmp/opencode/verilator_w1.sh <<'EOF'
#!/bin/sh
exec "${REPO_ROOT:?export REPO_ROOT}/cpu2026-tools-x86_64.AppImage" exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+CPU_ISSUE_WIDTH=1 "$@"' sh "$@"
EOF
chmod +x /tmp/opencode/verilator_w1.sh

make build FILELIST=verilog/filelist.f BUILD=build/w1 \
  VERILATOR=/tmp/opencode/verilator_w1.sh JOBS=4
```

W=1/W=2 的 correctness 都由队友记录为 19/19；本机独立复核了 W=2 19/19。

---

## 5. 硬性约束 / 坑

1. 不改 `scripts/`、`Makefile`、`config.mk`；参数用
   `python3 tools/config_gen.py` 生成，不手改 `cpu_config.sv`。
2. `verilog/filelist.f` 顺序：`rv32_defs.sv`、`cpu_config.sv`、`if_defs.sv`
   必须在前；顶层模块名必须是 `student_top`。
3. 不要再把基线 `student_top.sv` 加进 filelist（与 `student_top_ooo.sv`
   模块重名）。
4. 正常构建不能有 `$display`（污染 OJ stdout）；调试用
   `` `ifdef LOCAL_TRACE ``。
5. 不要向 `upstream` 模板仓库开 PR；只在个人 fork 上提交。
6. 不要提交 `build/`、VCD、日志、AppImage、`prompt.md`。
7. 没有跑过 perf/synth 就不要声称 IPC/面积/频率或“阶段通过”。

### P1 已修复、不要回归

- ROB：`recover_rat` 重放、`done_now_mask` 同拍 completion/recovery
- rename：恢复时排除同拍 wake
- frontend：BPU taken 寄存一拍重定向，断开 `flush → resp_valid` 环
- backend：dispatch skid、`skid_drain` 门控、skid stale-ready 更新、
  skid squash、统一 32-bit dispatch seq
- LSU：未启动请求的 squashed load 清理
- LSQ：组合块独立循环变量，避免 Yosys latch
- `core_ooo.sv`：`pc_out` 空连接已删除，不要加回

### 综合

- `make synth MODE=diagnose`：面积 breakdown
- `make synth MODE=opt`：最终面积/频率
- 报告在 `build/synth/<mode>/report.txt`
- `docs/perf-log.md` 已记录 P1/P2 perf、面积、频率和参数敏感度

---

## 6. 推荐阅读

1. `docs/integration-status.md`：P1/P2 结果、perf/synth 数据、下一步策略
2. `docs/plan/pipeline.md`：系统性流水化设计草案（当前/目标流水级、验收、风险）
3. `docs/plan/replay.md`：IQ/PRF 分开后的 replay / store 地址预填设计
4. `docs/experiments/freq-log.md`：频率实验记录（成功/失败/回滚原因）
5. `docs/plan/division.md`：P2/P3 工作包和验收标准
6. `docs/interface.md`：八条总线冻结接口
7. `README-ZH.md`：课程评分、工具链、命令

一句话：**P2 功能已全绿（W=2 双发射/双取指/流水访存，IPC 0.5507）；
下一步先做频率流水化、面积收缩和带 GHR 快照的 gshare/RAS，D-Cache 暂缓。**
