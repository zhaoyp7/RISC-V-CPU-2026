# RISC-V CPU 2026 — 协作者交接（P2 进行中）

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

## 1. 当前状态（2026-10-21）

- 分支：`main`
- P1 功能 tag：`p1-ooo-final`（`0d6e07f`）
- P2 当前提交：`a95a938`（双发射 + 双取指 + 流水访存）
- 官方 `verilog/filelist.f` 使用 OoO 顶层 `student_top_ooo.sv`
  （模块名仍是 `student_top`）
- 基线 `core.sv`/`icache.sv`/`student_top.sv` 保留但不在 filelist

### 已验证

- 官方 W=1 correctness：**19/19 PASS**
- 官方 W=2 correctness：**19/19 PASS**（`MAX_CYCLES=50,000,000`）
- `sh test/run_all.sh`：**ALL PASS**
- `python3 tools/config_gen.py --check`：up to date
- 当前课程分数估算：仍约 **85/100**（性能/面积/频率未达阶段门槛）

### 当前性能/面积（W=2，commit `4cf171e`）

| 指标 | 当前值 | 阶段 1 门槛 | 阶段 2 门槛 |
| --- | ---: | ---: | ---: |
| IPC GEOMEAN | **0.5507** | ≥ 0.6000 | ≥ 0.8450 |
| 面积（opt） | **24,288.3 µm²** | ≤ 9,000 µm² | ≤ 18,000 µm² |
| 频率 | **56.08 MHz** | ≥ 300 MHz | ≥ 300 MHz |

W=1 档 IPC 为 0.5017。perf 明细、参数敏感度和 synth breakdown 见
`docs/perf-log.md` 与 `docs/integration-status.md`。

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
4. 关键路径 `ROB → backend`，57.11 MHz；面积 24.2k，阶段 1/2 均未达
5. 双发射只在 ALU lane 生效；mem/div/branch 仍单端口

---

## 3. 下一步：P2 收尾 / P3

当前 P2 功能已打通但未达门槛。优先级：
1. 降低分支误预测代价（RAS/gshare、恢复流水化）；
2. 非阻塞 D-Cache 或低延迟 load 通路（towers/median）；
3. 频率流水化（ROB → backend、IQ select、I$ tag/BPU）；
4. 面积收缩（ROB/PRF/IQ、单 BPU 已做，双 I$ 与双 ALU 是主要开销）。

以下为原始 P2 目标（课程阶段 1）：

- W=1 与 W=2 都 **19/19 PASS**
- IPC ≥ **0.6000**
- 面积 ≤ **9,000 µm²**
- 频率 ≥ **300 MHz**
- tag：`p2-stage1`

建议顺序：

1. **性能计数器/瓶颈统计**：branch miss、I$/D$ miss、IQ/ROB full、
   LSU blocked、CDB conflict、divider busy。
2. **D-Cache + store buffer + mem_subsystem 仲裁**（最高 IPC 收益）。
   - 直接映射、写直达 + 写缓冲；
   - I-Cache refill / D-Cache miss / store drain 三方仲裁；
   - 保持 LSU 上游接口尽量不变。
3. **W=2 双发射**：双路 select、第二 ALU、CDB 仲裁/双 CDB、2 宽取指；
   W=1 不能回归。
4. **频率流水化**：ROB recovery、IQ select/wakeup、ALU/multiplier、
   I-Cache/BPU 路径；目标 300 MHz。
5. **面积参数收缩**：ROB/PRF/IQ/LSQ/I-Cache/BTB/BHT 参数扫描；
   D-Cache 会增加面积，必须同时缩其他模块。
6. **gshare/RAS + 2 宽取指**：接入前 ROB 表项要保存预测时 GHR 快照。
7. **LSQ 增强**：store-to-load forwarding、non-blocking load、地址消歧。

如果 9k 面积在双发射 + D-Cache 下不可达，先保证 W=1/W=2 全量功能，再决定
是继续压面积冲 90 分，还是走阶段 2（面积 18k 已满足，但 IPC 要 0.845）。

---

## 4. 常用命令

```sh
# 官方 W=1
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

### W=2 构建

```sh
export REPO_ROOT="$(git rev-parse --show-toplevel)"

cat > /tmp/opencode/verilator_w2.sh <<'EOF'
#!/bin/sh
exec "${REPO_ROOT:?export REPO_ROOT}/cpu2026-tools-x86_64.AppImage" exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+CPU_ISSUE_WIDTH=2 "$@"' sh "$@"
EOF
chmod +x /tmp/opencode/verilator_w2.sh

make build FILELIST=verilog/filelist.f BUILD=build/w2 \
  VERILATOR=/tmp/opencode/verilator_w2.sh JOBS=4
```

W=2 全量 19/19 还没跑；P2 必须补上。

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
- 当前 `docs/perf-log.md` 还是旧模板，P2 第一件事应填入 P1 真实数据

---

## 6. 推荐阅读

1. `docs/integration-status.md`：P1 结果、perf/synth 数据、修复根因
2. `docs/plan/division.md`：P2/P3 工作包和验收标准
3. `docs/interface.md`：八条总线冻结接口
4. `README-ZH.md`：课程评分、工具链、命令

一句话：**P1 已全绿，当前是单发射乱序核心；P2 先做 D-Cache 和 W=2 双发射，
再解决 300 MHz 频率与 9k 面积。**
