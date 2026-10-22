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
git switch feat/p1-integration
git pull
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

## 1. 当前状态（2026-10-22）

- 分支：`main`
- P1 功能 tag：`p1-ooo-final`（`0d6e07f`）
- P2 RTL 提交：`a95a938`（双发射 + 双取指 + 流水访存）
- 当前 `main`：以 `git log -1 --oneline` 为准（P2 RTL 提交为 `a95a938`）
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
| IPC GEOMEAN | **0.6380**（`a56cca6`） | ≥ 0.6000 | ≥ 0.8450 |
| 面积（diagnose） | 25,134.9 µm²（opt 待重测） | ≤ 9,000 µm² | ≤ 18,000 µm² |
| 频率（diagnose） | 53.96 MHz（opt 待重测） | ≥ 300 MHz | ≥ 300 MHz |

P2 基线 `a95a938` 的 IPC 为 0.5507；`a56cca6` 加入 store 地址预填后
提升到 0.6380（qsort 0.5013、rsort 0.7566、vvadd 0.8477）。W=1 档尚未
在预填 RTL 上重测。perf 明细、参数敏感度和 synth breakdown 见
`docs/perf-log.md` 与 `docs/integration-status.md`。

2026-10-22 还修复了 ROB16 的恢复竞态（`ab00273`），现在 ROB16 配置可用。
参数扫描中 **C2（ROB16/PRF48/LSQ16/1KB I$/小 BPU）IPC 0.6311、
diagnose 20,262.8 µm²**，是当前最接近 18k 面积的可用配置；但频率仍约
53.4 MHz，距 300 MHz 很远。默认配置仍是 ROB32/PRF64（IPC 0.6380）。

---

## 2. 当前架构

`verilog/cpu_config.sv` 默认：

| 参数 | 当前值 |
| --- | ---: |
| `CPU_ISSUE_WIDTH` | 2 |
| `CPU_ROB_DEPTH` | 32 |
| `CPU_PRF_SIZE` | 64 |
| `CPU_RS_DEPTH` | 8 |
| `CPU_CDB_NUM` | 2 |
| `CPU_LSQ_DEPTH` | 8 |
| I-Cache | 双 bank，每 bank 2 KB 直接映射，1 字/行 |
| BTB / BHT | 64 项 / 256 项 2-bit（单 BPU 双读口） |
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
4. 关键路径 `ROB → backend`，56.08 MHz；面积 24.3k，阶段 1/2 均未达
5. 双发射只在 ALU lane 生效；mem/div/branch 仍单端口

---

## 3. 下一步：先频率/面积/分支预测，D-Cache 暂缓

2026-10-22 决策：**不要先做 D-Cache**。当前课程门槛是全有或全无：

| 指标 | 当前 | 阶段 1 | 阶段 2 |
| --- | ---: | ---: | ---: |
| IPC | 0.5507 | ≥ 0.6000 | ≥ 0.8450 |
| 面积 | 24,288 µm² | ≤ 9,000 | ≤ 18,000 |
| 频率 | 56.08 MHz | ≥ 300 | ≥ 300 |

IPC 只差约 9%，但面积/频率差得更远；只把 IPC 提到 0.6 不会改变 85 分。
D-Cache 会增加面积、可能拖慢 ROB→backend 关键路径，而且 P2 的 4KB
阻塞式写直达原型已经测到 IPC 0.1543，不能直接重做。

建议优先级：

1. **性能计数器**：branch miss、I$/D$ miss、load latency、IQ/ROB full、
   LSU blocked、CDB conflict、divider busy。先确认瓶颈，不要凭感觉加 D$。
2. **频率流水化（最高优先）**：关键路径 ROB→backend；拆 ROB recovery/
   recover_rat/busy mask、IQ select/wakeup、ALU 乘法器、I$ tag/BPU 路径。
3. **面积参数收缩**：ROB 16/24、PRF 48、IQ 4/6、LSQ 4/6、I$ 1KB/bank、
   BTB/BHT 缩小；用 `make perf` + `MODE=diagnose` 做参数档。
4. **分支预测**：gshare 必须保存预测时 GHR 快照；加 RAS；配合 fetch queue。
   这比 D-Cache 面积小，直接针对 qsort/median 的数据相关分支。
5. **D-Cache 仅在计数器和面积预算允许时再做**：小型、非阻塞、
   写直达 + store buffer、带 MSHR/hit-under-miss；不要重复阻塞式 4KB。
6. **LSQ 增强**：store-to-load forwarding、non-blocking load、地址消歧。

路线判断：阶段 1 的 9k 面积非常激进；如果频率/面积压不下去，优先评估
阶段 2（面积 18k 更近，但 IPC 要 0.845），不要为了一个 IPC 指标盲目加
D-Cache。当前 P2 已打 tag `p2-dual-issue`，没有 `p2-stage1`。

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
2. `docs/plan/division.md`：P2/P3 工作包和验收标准
3. `docs/interface.md`：八条总线冻结接口
4. `README-ZH.md`：课程评分、工具链、命令

一句话：**P2 功能已全绿（W=2 双发射/双取指/流水访存，IPC 0.5507）；
下一步先做频率流水化、面积收缩和带 GHR 快照的 gshare/RAS，D-Cache 暂缓。**
