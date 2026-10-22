# 集成状态（P1 完成，P2 进入性能优化）

## P2 当前结果（RTL `a95a938`，2026-10-22）

- **W=1 correctness：19/19 PASS**；**W=2 correctness：19/19 PASS**（`MAX_CYCLES=50,000,000`）。
- 单元测试：`sh test/run_all.sh` → **ALL PASS**（frontend W=1/W=2 已适配
  双 bank I$ 和 wake mask；LSU、mem_subsystem、backend 三套 P2 测试已适配
  并加入 `run_all.sh`）。
- 2026-10-22 本机独立复核：W=2 19/19；perf 0.5507；synth opt
  24,288.346 µm² / 56.08 MHz，与队友记录一致。
- `tools/config_gen.py --check`：up to date（默认值已切到 P2 双发射配置）。
- perf（官方 OoO filelist，W=2）：P2 基线 IPC geomean **0.5507**；W=1 为
  0.5017。2026-10-22 加入 store 地址预填后，W=2 IPC 提升到 **0.6380**
  （qsort 0.5013、rsort 0.7566、vvadd 0.8477）。
- synth（ASAP7，2 ns 目标）：P2 基线 opt **24,288.346 µm² / 56.08 MHz**；
  diagnose 25,025.438 µm² / 53.93 MHz。预填 RTL 的 diagnose 为
  **25,134.890 µm² / 53.96 MHz**，面积仅 +109.5 µm²，opt 待重测。
- **未达到课程阶段门槛**：阶段 1 需要 9,000 µm²、IPC 0.6000、300 MHz；
  IPC 已过 0.6，但面积/频率仍差很远；阶段 2 的 18,000 µm² 也未满足。
- 2026-10-22 修复 ROB16 恢复竞态（`ab00273`）：恢复拍停止提交，避免
  rename 装载快照时丢失 ROB crat/free 更新。ROB16 配置现已 19/19 PASS。
- 参数扫描：C2（ROB16/PRF48/LSQ16/1KB I$/BTB32/BHT128）IPC 0.6311，
  diagnose 20,262.8 µm² / 53.44 MHz；C3（RS4/512B I$/BTB16/BHT64）
  IPC 0.5917，预计面积接近 18k。面积与 IPC 仍无法同时满足阶段 2。
- 双发射、双 bank 取指、双 CDB、流水化 load/store、store-to-load forwarding、
  取指侧 BPU 预测均已接入；D-Cache 原型因阻塞式 miss 反而降低 IPC，已回退。

### P2 关键改动

1. 前端改为双 bank I-Cache（pc/pc+4 各一个 refill 口），fetch 请求 FIFO
   解耦取指与 rename；取指侧 BPU 预测消除 taken 分支的一拍气泡。
2. IQ 支持每拍两条发射；第二 ALU、两条 CDB；wake 改为 PRF 掩码，支持
   同拍多条完成。
3. load/store 改为流水化：多笔在途 load、按序响应；store 流水 drain；
   同地址整字 store-to-load forwarding；store 在 issue 时发送给 LSQ。
4. mem_subsystem/axi_mem_if 支持多笔在途读、流水写和 I$ 双 refill 客户。
5. 分支解析改为 issue 当拍组合发送 `br_update`，ROB redirect 也改为组合
   输出，缩短恢复路径。

### 下一步策略（2026-10-22）

**先频率/面积/分支预测，D-Cache 暂缓。**

- 当前 IPC 0.5507，距离阶段 1 只差约 9%；但面积 24.3k（阶段 1 ≤9k、
  阶段 2 ≤18k）和频率 56.08 MHz（≥300 MHz）差得更远。只把 IPC 提到 0.6
  不会改变 85 分，因为门槛是全有或全无。
- P2 的 4KB 阻塞式写直达 D-Cache 原型 IPC 只有 0.1543，已回退；直接重做
  风险高，且会增加面积、拖慢 ROB→backend 关键路径。
- 优先顺序：
  1. 性能计数器/停顿分类（branch/I$/D$/IQ/ROB/LSU/CDB/divider）；
  2. 频率流水化：ROB recovery、IQ select/wakeup、ALU 乘法器、
     I$ tag/BPU 路径；
  3. 面积参数收缩：ROB/PRF/IQ/LSQ/I$/BTB/BHT；
  4. 分支预测：gshare 保存预测时 GHR 快照 + RAS；
  5. D-Cache 仅在计数器证明 load stall 主导且面积预算允许时再做，
     采用小型、非阻塞、写直达 + store buffer 的形态。

### 复现命令

```sh
python3 tools/config_gen.py --check
make build JOBS=4
make test MAX_CYCLES=50000000          # 本机约 45 s
make perf MAX_CYCLES=50000000
make synth MODE=diagnose               # 本机约 716 s
make synth MODE=opt                    # 本机约 25 min
# W=1 档：默认是 W=2，用 +define+CPU_ISSUE_WIDTH=1 的 wrapper
sh test/run_all.sh
```

---

# P1 集成状态（2026-10-18）

## 最终结果：P1 PASS

- **W=1 correctness：19/19 PASS**（`MAX_CYCLES=50,000,000`）
- **W=2 smoke：7/7 PASS**（add_to_100、expr、gcd、naive、manyarguments、
  multiarray、bulgarian）
- 全部单元测试 PASS；官方 `sh test/run_all.sh --build` → **ALL PASS**
- tag：`p1-ooo`（功能集成）、`p1-ooo-official`（官方 filelist 切换）
- **官方 `verilog/filelist.f` 已切换到 OoO 顶层**；官方
  `make test MAX_CYCLES=50000000` → **19/19 PASS**；官方 filelist 的
  W=2 smoke → **7/7 PASS**。

### W=1 记录（cycles）

| case | cycles |
| --- | ---: |
| correctness_add_to_100 | 2,401 |
| correctness_expr | 2,002 |
| correctness_gcd | 1,464 |
| correctness_naive | 849 |
| correctness_manyarguments | 860 |
| correctness_multiarray | 9,483 |
| correctness_bulgarian | 1,450,991 |
| correctness_hanoi | 26,010 |
| correctness_lvalue2 | 904 |
| correctness_magic | 3,170,417 |
| correctness_pi | 21,204,137 |
| correctness_qsort | 4,667,870 |
| correctness_queens | 1,891,253 |
| correctness_statement_test | 4,495 |
| correctness_superloop | 1,059,467 |
| correctness_tak | 9,446,589 |
| correctness_array_test1/2 | 1,867 / 2,193 |
| correctness_basicopt1 | 761,342 |

### W=2 smoke 记录

add_to_100 2,407；expr 1,877；gcd 1,458；naive 837；manyarguments 863；
multiarray 9,511；bulgarian 1,448,579。全部 PASS。

## 复现命令

```sh
# W=1 全量 correctness
make build FILELIST=test/integration/filelist.f BUILD=build/ooo JOBS=4
python3 scripts/testcase.py --build build/ooo --kind correctness \
    --max-cycles 50000000 --latency 10

# W=2 smoke（需要带 define 的 Verilator wrapper，见 docs 记录）
make build FILELIST=test/integration/filelist.f BUILD=build/ooo_w2 \
    VERILATOR=/path/to/verilator_w2.sh JOBS=4
python3 scripts/testcase.py --build build/ooo_w2 \
    --case correctness_add_to_100 --max-cycles 50000000 --latency 10
```

W=2 wrapper 的内容：

```sh
#!/bin/sh
exec <repo>/cpu2026-tools-x86_64.AppImage exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+CPU_ISSUE_WIDTH=2 "$@"' sh "$@"
```

## P0/P1 交付

- P0：`tools/unit/build.py`、divider 边界修复、`mem_subsystem` v1、
  RV32IM 黄金模型/`trace_diff`、接口复核、`p0-baseline` tag。
- P1 后端：`prf.sv`、`cdb.sv`、`issue_queue.sv`、`lsu.sv`、`lsq.sv`、
  `backend_ooo.sv`、`stub_front_ooo.sv`，含 W=1/2 单测。
- 集成：`verilog/student_top_ooo.sv`（模块名 `student_top`，现为官方
  顶层）、`verilog/filelist.f`（官方 OoO filelist）、
  `test/integration/filelist.f`（历史 test-only filelist）。

## 集成期间定位并修复的问题

1. **ROB 恢复丢失在飞 RAT**：`rename` 恢复时只装载 `crat`，丢失 branch
   自身及更老在飞 uop 的 rd 映射。`rob.sv` 新增 `recover_rat`，按程序序
   从 `crat` 重放 branch 及更老表项。
2. **同拍 completion / recovery 竞态**：ROB 的 `recover_busy_mask` 采到了
   CDB/complete 置 done 前的状态，把刚完成的 tag 重新标 busy。`rob.sv`
   增加 `done_now_mask`；`rename.sv` 恢复时排除本拍 wake tag。
3. **前端 BPU 预测未驱动 PC**：预测 taken 时仍顺序取 fall-through。
   `frontend_ooo.sv` 用寄存一拍的 `bpu_redirect_q` 重定向 PC 并 flush
   I-Cache，同时避免 `bpu_redirect → flush → resp_valid` 组合环。
4. **ready/valid 组合环**：`backend_ready → ren_ready → dispatch.valid →
   iq/lsu ready → backend_ready` 会振荡。`backend_ooo.sv` 增加 dispatch
   skid buffer；IQ 用寄存后的 `in_alloc_mask` 计容量，LSQ 用 `alloc_fire`
   控制真正分配。
5. **skid 中的 stale ready**：skid 停住期间 producer 的 CDB 已过，保存的
   `src_ready` 不会更新。skid 在 hold 期间用 CDB wake 更新 ready 位，并在
   捕获新组时做同拍旁路。
6. **squash 边界不一致**：IQ/LSQ/skid/LSU 原来用 `rob_idx` 模 32 的半窗口，
   ROB 用 age；两者在回绕边界不一致，导致旧 store/load 残留。统一改为
   32-bit dispatch seq：ROB squash 点映射到 `squash_seq`，后端按
   `seq > squash_seq` 清理。
7. **squash 后已发射结果仍广播**：ALU/divider/branch-complete/store-complete
   按 seq 过滤；divider 在跑的 uop 用 discard 标记。
8. **load 被误 squash 后永久占住 LSU**：请求尚未真正发出时被 squash，
   `load_active/load_inflight` 永远不清。`lsu.sv` 在请求未启动时直接取消；
   已在途的读响应丢弃。

## P1 性能与综合（官方 OoO filelist）

### perf（`make perf MAX_CYCLES=50000000`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 46,505 | 0.1497 |
| perf_multiply | 21,722 | 64,422 | 0.3372 |
| perf_qsort | 139,900 | 862,789 | 0.1621 |
| perf_rsort | 195,719 | 1,105,270 | 0.1771 |
| perf_towers | 5,278 | 55,429 | 0.0952 |
| perf_vvadd | 4,524 | 26,869 | 0.1684 |
| **GEOMEAN** |  |  | **0.1689** |

说明：P1 的目标是功能打通，不是性能门禁；0.1689 是当前 OoO 实现的真实
IPC，主要受 branch/I-Cache 停顿和单发射后端限制。P2 再针对 IPC 做优化。

### 综合（ASAP7 / 2 ns 目标）

| mode | total area (µm²) | comb (µm²) | seq (µm²) | SRAM (µm²) | Fmax | min period | WNS vs 2 ns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| diagnose | 17,383.665 | 10,569.232 | 4,578.528 | 2,235.905 | 63.53 MHz | 15.7412 ns | -13.7406 ns |
| opt | 17,204.622 | 10,394.855 | 4,573.863 | 2,235.905 | 64.48 MHz | 15.5098 ns | -13.5088 ns |

- 关键路径（diagnose）：`u_core/u_rob` → `u_backend`。
- `opt` 相比 `diagnose`：面积减少 179.043 µm²，Fmax 提高 0.95 MHz。
- 2 ns（500 MHz）目标未达到；当前 Fmax 约 64 MHz。P1 只要求综合可跑通，
  时序优化留到 P2/P3。
- 综合修复：`lsq.sv` 各组合块使用独立循环变量，避免 Yosys 对复用 `i`
  推断 latch；`core_ooo.sv` 删除未使用的 `pc_out` 空连接。

## 后续

1. 官方 filelist 已切换；下一步跑 `make perf` / `make synth`，记录真实
   IPC/面积/频率（P1 尚未做性能门禁）。
2. P2：W=2 双发射后端、D-Cache、mem_subsystem 三方仲裁。
3. 保留基线 `core.sv`/`icache.sv`/`student_top.sv` 作为回滚点。
