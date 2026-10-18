# P1 集成状态（2026-10-18）

## 最终结果：P1 PASS

- **W=1 correctness：19/19 PASS**（`MAX_CYCLES=50,000,000`）
- **W=2 smoke：7/7 PASS**（add_to_100、expr、gcd、naive、manyarguments、
  multiarray、bulgarian）
- 全部单元测试 PASS；官方 `sh test/run_all.sh --build` → **ALL PASS**
- tag：`p1-ooo`
- 集成使用 `test/integration/filelist.f`，官方 `verilog/filelist.f` 仍是
  基线，尚未切换。

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
- 集成：`verilog/student_top_ooo.sv`（模块名 `student_top`，test-only）、
  `test/integration/filelist.f`。

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

## 后续

1. 甲侧确认后，把官方 `verilog/filelist.f`/`student_top.sv` 切换到 OoO
   版本；当前官方 filelist 仍是基线。
2. `make perf` / `make synth` 记录真实 IPC/面积/频率；P1 尚未做性能门禁。
3. P2：W=2 双发射后端、D-Cache、mem_subsystem 三方仲裁。
