# 性能记录

> 数据来自本仓库 `make perf` / `make synth`。没有跑过的数字写“未验证”，
> 不把模块级吞吐当作课程 IPC。

## 完整核心

| 日期 | commit | 配置（W/ROB/PRF/RS/CDB/LSQ/I$） | IPC geomean | 面积 µm² | 频率 MHz | 备注 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 2026-10-18 | `0d6e07f` | W1/32/64/8/1/8/4KB×1 | 0.1689 | 17,204.622 (opt) | 64.48 | P1 单发射 + 无 D$ |
| 2026-10-21 | `a95a938` | W1/32/64/8/2/8/2KB×2 | 0.5017 | 未单独综合 | 未单独综合 | P2 双取指/双 ALU 的 W=1 档 |
| 2026-10-21 | `a95a938` | W2/32/64/8/2/8/2KB×2 | 0.5507 | 24,288.346 (opt) | 56.08 | P2 双发射基线 |
| 2026-10-22 | `a95a938` | W2/32/64/8/2/8/2KB×2 | 0.5507 | 24,288.346 (opt) | 56.08 | 本机独立复核，与上一行一致 |
| 2026-10-22 | `8f44fed` | W2/32/64/8/2/8/2KB×2 | 0.5507 | 未重测 | 未重测 | 仅加 LOCAL_STATS 计数器，周期数不变 |
| 2026-10-22 | `a56cca6` | W2/32/64/8/2/8/2KB×2 | **0.6380** | **24,468.759 (opt)** | **56.72 (opt)** | store 地址预填；diag 25,134.890/53.96 |
| 2026-10-22 | `ab00273` | W1/32/64/8/2/8/2KB×2 | **0.5688** | 未单独综合 | 未单独综合 | W=1 兼容性复测；19/19 PASS |
| 2026-10-23 | `116cbb8` | W2/32/64/8/2/32/2KB×2 | **0.7295** | 28,444.463 (diag) | 54.27 (diag) | 默认 LSQ 32；IPC +14.3%，面积 +3.3k |
| 2026-10-23 | `116cbb8` | W1/32/64/8/2/32/2KB×2 | **0.6336** | 未单独综合 | 未单独综合 | LSQ32 的 W=1；19/19 PASS |

P2 基线 opt 综合：comb 16,361.326、seq 5,648.117、SRAM 2,278.903 µm²，
min period 17.8320 ns（目标 2 ns，WNS −15.8320 ns）。diagnose 为 25,025.438 µm²、
53.93 MHz、18.5430 ns。

当前 RTL（`ab00273`，tag `p2-perf-prefill`）opt 综合：
comb 16,539.406、seq 5,650.450、SRAM 2,278.903 µm²，总面积
**24,468.759 µm²**，min period **17.6318 ns**，Fmax **56.72 MHz**，
WNS **−15.6312 ns**。相对 P2 opt：面积 +180.413 µm²（+0.74%），
Fmax +0.64 MHz，WNS 改善 0.2001 ns。

> **2026-10-22 策略**：先做频率流水化、面积参数收缩和分支预测
> （gshare 需 GHR 快照 + RAS）；D-Cache 暂缓，只有在计数器证明 load
> stall 主导且面积预算允许时再做小型非阻塞 D$。

## 分 benchmark（W=2，P2 基线 `a95a938`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 14,513 | 0.4796 |
| perf_multiply | 21,722 | 20,237 | 1.0734 |
| perf_qsort | 139,900 | 315,417 | 0.4435 |
| perf_rsort | 195,719 | 369,323 | 0.5299 |
| perf_towers | 5,278 | 14,558 | 0.3625 |
| perf_vvadd | 4,524 | 7,119 | 0.6355 |
| **GEOMEAN** |  |  | **0.5507** |

## 分 benchmark（W=2，store 地址预填 `a56cca6`）

| benchmark | instructions | cycles | IPC | 相对基线 |
| --- | ---: | ---: | ---: | ---: |
| perf_median | 6,961 | 14,014 | 0.4967 | +3.6% |
| perf_multiply | 21,722 | 20,237 | 1.0734 | 0.0% |
| perf_qsort | 139,900 | 279,088 | 0.5013 | +13.0% |
| perf_rsort | 195,719 | 258,690 | 0.7566 | +42.8% |
| perf_towers | 5,278 | 13,411 | 0.3936 | +8.6% |
| perf_vvadd | 4,524 | 5,337 | 0.8477 | +33.4% |
| **GEOMEAN** |  |  | **0.6380** | **+15.9%** |

## 分 benchmark（W=2，默认 LSQ32 `116cbb8`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 14,016 | 0.4966 |
| perf_multiply | 21,722 | 20,237 | 1.0734 |
| perf_qsort | 139,900 | 274,329 | 0.5100 |
| perf_rsort | 195,719 | 227,001 | 0.8622 |
| perf_towers | 5,278 | 9,398 | 0.5616 |
| perf_vvadd | 4,524 | 3,952 | 1.1447 |
| **GEOMEAN** |  |  | **0.7295** |

LSQ 深度扫描：

| LSQ | IPC geomean | 备注 |
| ---: | ---: | --- |
| 8 | 0.6380 | 原默认 |
| 16 | 0.7176 | +12.5% |
| 32 | **0.7295** | +14.3%，towers 继续受益 |
| 64 | 0.7295 | 与 32 相同，已饱和 |

结论：LSQ32 是当前 IPC/面积折中的性能默认；LSQ64 无额外收益。

LSQ32 的 diagnose 代价：

| 指标 | LSQ8（`ab00273`） | LSQ32（`116cbb8`） | 变化 |
| --- | ---: | ---: | ---: |
| IPC geomean | 0.6380 | **0.7295** | +14.3% |
| diagnose 面积 | 25,134.9 µm² | 28,444.5 µm² | +3,309.6 µm² |
| diagnose Fmax | 53.96 MHz | 54.27 MHz | +0.31 MHz |
| 关键路径 | ROB → backend | ROB → backend | 未变 |
| `u_lsq` 面积 | 1,087.3 µm² | 4,464.1 µm² | +3,376.8 µm² |

面积几乎全部来自 LSQ 表项；如果后续优先面积，可回退 LSQ16（IPC 0.7176，
面积约少 2.2k）或 LSQ8。

## 分 benchmark（W=1，P2 基线 `a95a938`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 15,671 | 0.4442 |
| perf_multiply | 21,722 | 26,890 | 0.8078 |
| perf_qsort | 139,900 | 338,025 | 0.4139 |
| perf_rsort | 195,719 | 376,168 | 0.5203 |
| perf_towers | 5,278 | 14,993 | 0.3520 |
| perf_vvadd | 4,524 | 7,719 | 0.5861 |
| **GEOMEAN** |  |  | **0.5017** |

## 分 benchmark（W=1，预填 + ROB 修复 `ab00273`）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 15,330 | 0.4541 |
| perf_multiply | 21,722 | 26,890 | 0.8078 |
| perf_qsort | 139,900 | 308,107 | 0.4541 |
| perf_rsort | 195,719 | 283,074 | 0.6914 |
| perf_towers | 5,278 | 13,443 | 0.3926 |
| perf_vvadd | 4,524 | 6,040 | 0.7490 |
| **GEOMEAN** |  |  | **0.5688** |

## 面积 breakdown（diagnose，W=2，最终）

| 模块 | 面积 µm² | 占比 |
| --- | ---: | ---: |
| u_front（含双 I$、BPU、FIFO/decoder） | 7,873.234 | 31.46% |
| u_rob | 5,243.128 | 20.95% |
| u_backend（PRF/2×ALU/IQ/LSU/div/cdb） | 10,769.998 | 43.04% |
| u_mem（AXI + 仲裁） | 526.294 | 2.10% |
| **total** | **25,025.438** | 100% |

## 参数敏感度（同一 RTL，`make perf`）

| 参数 | 档位 | IPC geomean | 结论 |
| --- | --- | ---: | --- |
| W | 1 / 2 | 0.5017 / 0.5507 | 双发射有效，但前端取指仍限制吞吐 |
| ROB | 16 / 32 / 64 | 0.5231 / 0.5507 / 0.5507 | 32 已接近饱和；16 明显掉 IPC |
| PRF | 48 / 64 / 96 | 0.5231 / 0.5507 / 0.5507 | 与 ROB 档位一起变化；64 足够 |
| RS | 8 / 16 | 0.5507 / 0.5507 | 基本无差异 |
| I$ index | 9 / 10 / 11（每个 bank） | 0.5507 / 0.5507 / 0.5507 | 工作集不是瓶颈 |
| BTB/BHT | 6/8 / 8/10 | 0.5507 / 0.5507 | 预测容量不是主要瓶颈 |
| D$（原型，已移除） | 4KB 写直达 + 写缓冲 | 0.1543 | 在流水化前的组合上测量；阻塞式 miss 反而拖慢，已回退 |
| 预取/双取指 | 单宽 / 双 bank | 0.5225 / 0.5507 | 双 bank 取指消除 taken 分支气泡 |

## 瓶颈记录

1. **分支误预测**：qsort/median 的 mispredict 集中在数据相关分支
   （例如 qsort 的 `blt` 内层循环）；每次恢复约 6–7 拍取指气泡。
2. **依赖 load**：towers 的链表遍历是 pointer chasing，10 拍内存延迟直接
   暴露；没有低延迟 D$。
3. **取指带宽**：双 bank I$ 每拍最多两条；取指队列满后 rename/双发射会被
   反压。
4. **频率**：关键路径仍是 `u_rob → u_backend`（diagnose），需要结构性流水
   化，而不是只靠 ABC。当前 56.08 MHz（opt），距离 300 MHz 很远。
5. **面积**：双 ALU、双 I$、ROB 和 BPU 是主要开销；当前 24.2k，阶段 1 的
   9k 和阶段 2 的 18k 都未达到。

## 性能计数器（LOCAL_STATS，2026-10-22）

RTL 里增加了只在仿真统计构建中生效的计数器；默认 `make build` / `make synth`
不会生成任何计数逻辑，也没有 `$display`。统计输出走 stderr，避免污染 OJ
stdout。

构建方式（不需要改 `Makefile`）：

```sh
export REPO_ROOT="$(git rev-parse --show-toplevel)"

cat > /tmp/opencode/verilator_stats.sh <<'EOF'
#!/bin/sh
exec "${REPO_ROOT:?export REPO_ROOT}/cpu2026-tools-x86_64.AppImage" exec /bin/sh -c \
  'exec "$CPU2026_APPDIR/bin/verilator" +define+LOCAL_STATS "$@"' sh "$@"
EOF
chmod +x /tmp/opencode/verilator_stats.sh

make build BUILD=build/stats VERILATOR=/tmp/opencode/verilator_stats.sh JOBS=4
# 每个 case 的 stderr 会包含若干 [STATS] ... 行
```

### W=2 stall 分类（统计构建，周期数与默认构建一致）

| benchmark | cycles | commits | branch updates | mispredict | mispred rate | LSQ blocked cycles | LSQ blocked % | backend stall_lsu | stall_lsu % | LSQ unknown | I$ refills |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| perf_median | 14,513 | 6,961 | 3,123 | 551 | 17.6% | 3,545 | 24.4% | 3,557 | 24.5% | 3,545 | 103 |
| perf_multiply | 20,237 | 21,722 | 6,949 | 663 | 9.5% | 0 | 0.0% | 17 | 0.1% | 0 | 106 |
| perf_qsort | 315,417 | 139,900 | 50,325 | 10,911 | 21.7% | 73,023 | 23.2% | 73,077 | 23.2% | 73,023 | 465 |
| perf_rsort | 369,323 | 195,719 | 13,849 | 33 | 0.2% | 184,810 | 50.0% | 184,867 | 50.1% | 184,810 | 287 |
| perf_towers | 14,558 | 5,278 | 383 | 132 | 34.5% | 3,256 | 22.4% | 3,337 | 22.9% | 3,256 | 416 |
| perf_vvadd | 7,119 | 4,524 | 903 | 7 | 0.8% | 3,266 | 45.9% | 3,273 | 46.0% | 3,266 | 62 |

### 结论

1. **load 被老 store 的未知地址长期阻塞，是当前最大的单一瓶颈**。
   `query_blocked` 细分后 `query_unknown` 与它完全相等，`query_partial`
   为 0：不是部分写等待，而是老 store 还没 issue、地址没有填入 LSQ。
   rsort 50.0%、vvadd 45.9%、median 24.4%、qsort 23.2%、towers 22.4%。
2. **分支误预测是第二瓶颈**，在 median（17.6%）、qsort（21.7%）、
   towers（34.5%）上明显；rsort/vvadd 几乎不受影响。
3. **I$ refill 不是主导因素**：全程只有 62–465 次，refill 等待周期远小于
   LSQ 阻塞周期。
4. **ROB 从未满**（`rob_full_cycles=0`，最大占用 30/32），但 IQ/skid 经常
   被反压；根因仍是阻塞的 load 占住 IQ/LSU。
5. **CDB 冲突存在但不主导**：qsort/rsort 约 2k 拍，其余较少。
6. 下一步优先做 **store 地址早填 / load-store 依赖解耦**，而不是先上
   D-Cache；否则 D$ 只能缓解 10 拍内存延迟，无法解决 LSQ 的地址未知阻塞。

## store 地址预填（`a56cca6`）

### 改动

- `issue_queue` 增加 `addr_sent` 位和 `out_addr_only` 口。lane 0 在 store
  的 src1（地址源）ready、src2（数据源）未 ready 时，可以先做一次
  address-only 发射；store 本体仍留在 IQ。
- `backend_ooo` 把 address-only store 送到 LSU，不产生 `complete`，不占用
  complete FIFO。
- `lsu`/`lsq` 新增 prefill 口：只写地址、`is_store`、`addr_known`，并把
  `wstrb` 清 0；数据/写掩码等 store 真正发射时再填。
- 修复 LSQ 表项复用时旧 `wstrb/wdata` 未清空的问题，避免 address-only
  store 把上一位占用者的整字写误前递给 load。

### 效果（W=2）

| 指标 | 基线 `a95a938` | 预填 `a56cca6` |
| --- | ---: | ---: |
| IPC geomean | 0.5507 | **0.6380** |
| perf_qsort | 0.4435 | 0.5013 |
| perf_rsort | 0.5299 | 0.7566 |
| perf_vvadd | 0.6355 | 0.8477 |
| LSQ unknown 阻塞（rsort） | 184,810 拍 | **0** |
| LSU stall_lsu（rsort） | 184,867 拍 | 500 拍 |

### 已验证

- `make test MAX_CYCLES=50000000`：19/19 PASS
- `sh test/run_all.sh`：ALL PASS
- 统计构建复跑 6 个 perf，周期数与默认构建一致

### 剩余瓶颈

- qsort 仍有 2,431 拍 LSQ `query_partial`：address-only store 的数据尚未
  就绪，同地址 load 必须等待转发。
- qsort/median 的分支误预测仍然明显（qsort 11,127 次）。
- rsort/towers 的 LSQ 经常满（rsort 27.3%、towers 47.4% 的周期），说明
  8 项 LSQ 对 store 密集负载偏小；后续可扫 LSQ=16 或在面积允许时加深。

### 综合代价

diagnose 口径：

| 指标 | P2 基线 `a95a938` | 预填 `a56cca6` | 变化 |
| --- | ---: | ---: | ---: |
| 总面积 | 25,025.438 µm² | 25,134.890 µm² | +109.452 µm² (+0.44%) |
| 组合 | 17,101.917 µm² | 17,209.036 µm² | +107.119 µm² |
| 时序 | 5,644.618 µm² | 5,646.951 µm² | +2.333 µm² |
| Fmax | 53.93 MHz | 53.96 MHz | +0.03 MHz |
| 关键路径 | `u_rob → u_backend` | `u_rob → u_backend` | 未变 |

新增面积主要在 `u_backend/u_lsu`（+103.4 µm²，LSQ 增加 prefill 写口和
控制）；`u_iq` 只增加约 6.4 µm²。地址预填是一个低面积代价、高 IPC 收益
的改动。

opt 口径（最终面积/频率）：

| 指标 | P2 基线 `a95a938` | 预填 `ab00273` | 变化 |
| --- | ---: | ---: | ---: |
| 总面积 | 24,288.346 µm² | 24,468.759 µm² | +180.413 µm² (+0.74%) |
| 组合 | 16,361.326 µm² | 16,539.406 µm² | +178.080 µm² |
| 时序 | 5,648.117 µm² | 5,650.450 µm² | +2.333 µm² |
| Fmax | 56.08 MHz | **56.72 MHz** | +0.64 MHz |
| 最小周期 | 17.8320 ns | 17.6318 ns | −0.2002 ns |
| WNS vs 2 ns | −15.8313 ns | −15.6312 ns | +0.2001 ns |

## 频率实验记录

squash recovery 两级化的两版实验（Fmax +1.9% / +4.0%，IPC -1.8%）未达到
保留阈值，对应 WIP 分支 `feat/freq-recovery`，未合并。CDB 输出打一拍实验
（Fmax +3.2%、IPC -4.4%）也不保留，但暴露并修复了 complete FIFO 的
same-cycle push/squash 覆盖 bug（`36e4302`，已合入 `main`）。IQ/PRF 分开
实验达到 **Fmax +29.8%（70.04 MHz）**，但暴露 load/store issue 循环等待，
6 个 case 死锁；WIP 分支 `feat/pipeline-iq`（`9a7f9ff`）保留作 replay
重构参考。完整记录见 `docs/experiments/freq-log.md`。

## 参数扫描与 ROB16 修复（2026-10-22）

### 扫描结果（`make perf`，同 RTL）

| 配置 | ROB | PRF | RS | LSQ | I$ / bank | BTB/BHT | IPC geomean | diagnose 面积 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 默认 | 32 | 64 | 8 | 8 | 2KB | 64/256 | **0.6380** | 25,134.9 µm² |
| A | 16 | 48 | 8 | 8 | 2KB | 64/256 | 0.5936 | 未单独综合 |
| B2 | 16 | 48 | 8 | 8 | 1KB | 32/128 | 0.5924 | 未单独综合 |
| C2 | 16 | 48 | 8 | 16 | 1KB | 32/128 | **0.6311** | **20,262.8 µm²**¹ |
| C3 | 16 | 48 | 4 | 16 | 512B | 16/64 | 0.5917 | 未单独综合（预计接近 18k） |

¹ C2 的 diagnose 综合早于 `ab00273`；该修复只给 ROB 提交路径增加
`!recover_valid` 门控，面积极小，但严格精确值需在最终 RTL 上重跑。

结论：

1. **LSQ=16 是 ROB16 配置下恢复 IPC 的关键**：C2 比 B2 多 +0.039 IPC，
   代价是 LSQ 面积约 +1.17k。
2. **C2 在 20.3k 面积下保持 0.631 IPC**，是当前最接近阶段 2 面积门槛的
   可用配置；但距 18k 仍差约 2.26k，且 IPC 距 0.845 很远。C2 的完整
   实验档与复现命令见 `docs/configs/c2-area.md`。
3. **C3 已接近 18k，但 IPC 只有 0.5917**，低于阶段 1 的 0.6；单纯压参数
   无法同时满足面积和 IPC。
4. `ROB=32 + PRF=48` 会发生资源型死锁：32 个 ROB 在飞表项加上 32 个
   架构映射需要约 64 个物理寄存器，PRF48 不足。该组合不应作为候选。

### ROB16 死锁根因与修复（`ab00273`）

ROB 在 `recover_valid` 那一拍仍然允许更老的表项提交。rename 此时正在
整体装载恢复快照，会忽略 commit 反馈，导致 ROB 的 crat/free 更新与 rename
free list 失步；ROB16 下 recovery 频繁，tag 泄漏累积后 ROB 满且头部表项
永远不完成。

修复：

```systemverilog
assign commit_valid = commit_valid_int & {W{!flush_young && !recover_valid}};
assign commit_halt  = commit_halt_int && !flush_young && !recover_valid;
```

效果：

- C2（ROB16/PRF48）从 hanoi 超时变为 **19/19 PASS**
- 默认配置仍 19/19 PASS，IPC 0.6380 不变
- `sh test/run_all.sh` ALL PASS（ROB 单测期望已同步更新）

### 频率关键路径（C2 diagnose）

- 关键路径：`u_rob → u_backend → u_lsu → u_cdb → u_iq`
- 属于 **squash/recovery 控制路径**，不是单纯 ALU 乘法器
- C2 diagnose：20,262.763 µm² / 53.44 MHz / 18.7129 ns
- 下一步若继续冲频率，需要流水化 squash/recovery 或缩短 `rob_seq` 查找，
  单纯参数收缩只能小幅改善 Fmax
