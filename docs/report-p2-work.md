# P2 工作总结（2026-10-21）

> 起点：`b52b276`（P1 完成，tag `p1-ooo-final`）
> 终点：`63899bd`（tag `p2-dual-issue`）
> 分支/远端：`main` → `origin/main`（个人 fork）

## 1. 结论

本轮完成了 P2 的功能主体：真正的双发射、双 bank 取指、流水化访存、
双 CDB、store-to-load forwarding，并保持 W=1/W=2 全量正确性。

课程阶段 1 的三项硬指标（IPC ≥ 0.6000、面积 ≤ 9,000 µm²、频率 ≥ 300 MHz）
**仍未达到**，因此没有打 `p2-stage1` tag；最终验收数据：

| 指标 | 结果 |
| --- | ---: |
| W=2 correctness | 19/19 PASS |
| W=1 correctness | 19/19 PASS |
| IPC GEOMEAN（W=2） | **0.5507** |
| IPC GEOMEAN（W=1） | **0.5017** |
| 面积（opt） | **24,288.346 µm²** |
| 频率（opt） | **56.08 MHz** |
| 频率（diagnose） | 53.93 MHz |

与 P1 对比：IPC 0.1689 → 0.5507（约 3.26×），面积 17.2k → 24.3k，
频率 64.48 → 56.08 MHz。

## 2. 提交记录

| commit | 内容 |
| --- | --- |
| `bcca331` | 流水化访存路径；fetch FIFO 解耦取指与 rename |
| `4cf171e` | 双发射后端、双 bank 取指、双 CDB、store-to-load forwarding |
| `9661240` | 记录 P2 perf/面积/频率 |
| `a95a938` | 任意 pc/pc+4 成对取指（不要求 8B 对齐） |
| `e73402a` | 文档数据固定到最终 commit |
| `63899bd` | 标注尚未适配 P2 接口的旧单测 |

tag：`p2-dual-issue`。

## 3. RTL 改动

### 3.1 前端/取指

- `frontend_ooo.sv` 重写：
  - decoded-uop FIFO（深度 8），取指与 rename 解耦；
  - 双 bank I-Cache：`pc` 和 `pc+4` 各一个 refill 口，每拍最多取两条；
  - BPU 在 **取指请求侧** 查询，预测 taken 时下一拍直接切目标，消除
    每条 taken 分支的取指气泡；
  - 预测/配对信息进入请求 FIFO，响应回来时与指令一起压入 decode FIFO；
  - 任意 `pc/pc+4` 都可成对取指，不再限制 8B 对齐；
  - 分支解析改为 issue 当拍组合发送 `br_update`，ROB redirect 也改为组合
    输出，缩短误预测恢复路径。
- `bpu.sv`：单份 BTB/BHT 增加第二个只读取指口，避免双 BPU 复制面积。
- `icache_pipe.sv`：保留 `discard` 口，当前顶层不再使用。
- `core_ooo.sv`：适配双 refill 口、`cdb[R]` 解包和 wake 掩码。

### 3.2 后端/执行

- `issue_queue.sv`：
  - `IW=2`，每拍发射两条最老 ready；
  - `out_ready` 改为按 lane 握手，未发射的 lane 留在队列；
  - 支持同拍 CDB 唤醒后直接发射（后端 PRF 读口旁路）。
- `backend_ooo.sv`：
  - 第二 ALU（`u_alu1`）和独立结果缓冲；
  - CDB 源固定为 `alu0/alu1/load/div` 四路，`R=2`；
  - 同拍多 CDB 旁路（4 个源操作数都检查 R 条 CDB）；
  - wake 改为 `CPU_PRF_SIZE` 位掩码，支持同拍多条完成；
  - 无值完成（store/branch/非写回 ALU）进入 complete FIFO，避免同拍
    覆盖和连续 store 丢完成；
  - `br_update` 改为 issue 当拍组合输出。

### 3.3 访存

- `lsu.sv` v2：
  - 多笔在途 load（`LDQ_DEPTH=8`），元数据 FIFO 按序配对响应；
  - load 结果 FIFO，经 CDB 写回；
  - squash 按 seq 标记丢弃；
  - store issue 即完成（ROB 用 complete），commit 后由 LSQ 流水 drain；
  - 支持同地址整字 store-to-load forwarding。
- `lsq.sv` v2：
  - 增加 `sent` 位和 sent FIFO，支持多笔在途 store；
  - store 响应按序释放表项；
  - load 排序查询改为按 `query_seq`（issue 前即可查询）；
  - 返回 forwarding 数据。
- `mem_subsystem.sv`：
  - 客户口拆为 I$ 双 refill、流水 load、流水 store，并保留 P1 单事务
    `data_*` 兼容口；
  - 读 owner FIFO、写 owner FIFO，按 AXI 响应顺序路由。
- `axi_mem_if.sv`：
  - 支持最多 `QDEPTH` 笔在途读/写；
  - AR/AW/W 连续发出，R/B 按序返回；
  - 上游 `rd/wr` 请求流带 ready 握手。

### 3.4 参数与其它

- `tools/config_gen.py` 默认值切到 P2 性能配置：
  W=2、ROB=32、PRF=64、RS=8、CDB=2、LSQ=8、I$ 每 bank 2 KB、
  BTB 64、BHT 256。
- `prf.sv` 复位改为阻塞赋值，支持 PRF=96/128 的 Verilator 构建。
- `rename.sv` wake 改为掩码。
- `rob.sv` 支持 `R` 条 CDB，redirect 组合输出。

## 4. 验证

```sh
python3 tools/config_gen.py --check                 # up to date
make build JOBS=4
make test MAX_CYCLES=50000000                       # W=2: 19/19 PASS
make perf MAX_CYCLES=50000000                       # IPC geomean 0.5507
make synth MODE=diagnose
make synth MODE=opt
sh test/run_all.sh                                  # ALL PASS
```

W=1 档用带 `+define+CPU_ISSUE_WIDTH=1` 的 Verilator wrapper 构建到
`build/w1`：

```sh
REPO_ROOT="$(git rev-parse --show-toplevel)" \
  make build BUILD=build/w1 VERILATOR=/tmp/opencode/verilator_w1.sh JOBS=4
python3 scripts/testcase.py --build build/w1 --kind correctness \
  --max-cycles 50000000 --latency 10                  # 19/19 PASS
```

### perf 明细

W=2（默认配置）：

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 14,513 | 0.4796 |
| perf_multiply | 21,722 | 20,237 | 1.0734 |
| perf_qsort | 139,900 | 315,417 | 0.4435 |
| perf_rsort | 195,719 | 369,323 | 0.5299 |
| perf_towers | 5,278 | 14,558 | 0.3625 |
| perf_vvadd | 4,524 | 7,119 | 0.6355 |
| **GEOMEAN** |  |  | **0.5507** |

W=1：

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 15,671 | 0.4442 |
| perf_multiply | 21,722 | 26,890 | 0.8078 |
| perf_qsort | 139,900 | 338,025 | 0.4139 |
| perf_rsort | 195,719 | 376,168 | 0.5203 |
| perf_towers | 5,278 | 14,993 | 0.3520 |
| perf_vvadd | 4,524 | 7,719 | 0.5861 |
| **GEOMEAN** |  |  | **0.5017** |

### 综合

| mode | area µm² | comb | seq | SRAM | Fmax | min period |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| diagnose | 25,025.438 | 17,101.917 | 5,644.618 | 2,278.903 | 53.93 MHz | 18.5430 ns |
| opt | 24,288.346 | 16,361.326 | 5,648.117 | 2,278.903 | 56.08 MHz | 17.8320 ns |

diagnose 面积 breakdown：front 7,873、ROB 5,243、backend 10,770、mem 526 µm²。
关键路径仍为 `u_rob → u_backend`。

## 5. 踩坑与修复

1. **前端 FIFO 同拍 push/pop 覆盖**：深度 8 绕回时，pop 清掉了同拍 push
   的新表项，导致随机丢指令。修复为先清 pop 槽位，再写 push（push 胜出）。
   W=1 的 13/19 失败由此修复。
2. **ALU1 结果缓冲同拍 set/clear**：广播旧结果与发射新结果同拍时，
   clear 覆盖 set，导致 tag1 结果丢失、后续 IQ 永久等待。调整优先级为
   clear 在前、set 在后。
3. **mem_subsystem ready 组合环**：`ld_req_ready` 依赖 `ld_req_valid`，
   再回灌 LSU `issue_ready`。改为 ready 只依赖仲裁/队列状态。
4. **wake 丢事件**：双发射后同拍可能有多条 CDB/complete，原 W 路 wake
   口会覆盖；改为 PRF 掩码。
5. **load miss 无响应**：D-Cache 原型只在命中路径产生响应，miss 回填后
   忘记返回；该原型最终回退。
6. **ROB redirect 慢一拍**：改为组合输出，缩短误预测恢复。

## 6. 被否决的实验

| 实验 | 结果 | 处理 |
| --- | --- | --- |
| 4KB 阻塞式 D-Cache + 写直达 | IPC 0.15，反而变慢 | 回退 |
| gshare（GHR 在 br_update 更新，无快照） | geomean 0.49 | 回退，保留参数化钩子未启用 |
| ROB 64 / PRF 96 / RS 16 | IPC 0.5507，几乎无收益 | 回退到 32/64/8 |
| I$ index 10/11 | IPC 不变 | 使用 9（每 bank 2 KB） |
| BTB 256 / BHT 1024 | IPC 不变，面积大涨 | 使用 64/256 |
| 双 BPU 实例 | 面积 +10.7k | 改为单 BPU 双读口 |

## 7. 未完成/下一步

1. **IPC 0.5507 → 0.6000**：主要损失在 qsort/median 的数据相关分支误预测
   （约 6–7 拍恢复气泡）和 towers 的 pointer-chasing load 延迟。
   - 优先级：精确 GHR 快照的 gshare、RAS、非阻塞低延迟 D-Cache；
   - 也可把 branch 恢复、IQ select、ROB recovery 再流水化。
2. **频率 56 → 300 MHz**：关键路径 `ROB → backend`，需要结构性流水，
   不是 ABC 能解决的。
3. **面积 24.3k → 9k/18k**：双 ALU、双 I$、ROB、BPU 是主要开销；需要
   参数收缩和端口复用。
4. **旧单测**：`test/lsu_test`、`test/mem_subsystem_test`、
   `test/backend_test` 已在 2026-10-22 适配 P2 端口（LSU/backend 验证双 CDB
   与流水访存，mem_subsystem 验证 dual-IF/ld/st 客户口），并加入
   `run_all.sh`。
5. **接口文档**：`docs/interface.md` 已补 P2 内部 ld/st/双 refill 说明，
   但顶部冻结总线表仍主要是 P1 视角，P3 可再整理。

## 8. 复现入口

- 性能/面积/参数敏感度：`docs/perf-log.md`
- 集成状态与已知问题：`docs/integration-status.md`
- 交接入口：`docs/handoff.md`
- 接口：`docs/interface.md`
