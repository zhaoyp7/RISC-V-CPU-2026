# 性能记录

> 数据来自本仓库 `make perf` / `make synth`。没有跑过的数字写“未验证”，
> 不把模块级吞吐当作课程 IPC。

## 完整核心

| 日期 | commit | 配置（W/ROB/PRF/RS/CDB/LSQ/I$） | IPC geomean | 面积 µm² | 频率 MHz | 备注 |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 2026-10-18 | `0d6e07f` | W1/32/64/8/1/8/4KB×1 | 0.1689 | 17,204.622 (opt) | 64.48 | P1 单发射 + 无 D$ |
| 2026-10-21 | `a95a938` | W1/32/64/8/2/8/2KB×2 | 0.5017 | 未单独综合 | 未单独综合 | P2 双取指/双 ALU 的 W=1 档 |
| 2026-10-21 | `a95a938` | W2/32/64/8/2/8/2KB×2 | 0.5507 | 24,288.346 (opt) | 56.08 | 当前默认配置 |
| 2026-10-22 | `a95a938` | W2/32/64/8/2/8/2KB×2 | 0.5507 | 24,288.346 (opt) | 56.08 | 本机独立复核，与上一行一致 |

最终 opt 综合：comb 16,361.326、seq 5,648.117、SRAM 2,278.903 µm²，
min period 17.8320 ns（目标 2 ns，WNS −15.8320 ns）。diagnose 为 25,025.438 µm²、
53.93 MHz、18.5430 ns。

> **2026-10-22 策略**：先做频率流水化、面积参数收缩和分支预测
> （gshare 需 GHR 快照 + RAS）；D-Cache 暂缓，只有在计数器证明 load
> stall 主导且面积预算允许时再做小型非阻塞 D$。

## 分 benchmark（W=2，最终）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 14,513 | 0.4796 |
| perf_multiply | 21,722 | 20,237 | 1.0734 |
| perf_qsort | 139,900 | 315,417 | 0.4435 |
| perf_rsort | 195,719 | 369,323 | 0.5299 |
| perf_towers | 5,278 | 14,558 | 0.3625 |
| perf_vvadd | 4,524 | 7,119 | 0.6355 |
| **GEOMEAN** |  |  | **0.5507** |

## 分 benchmark（W=1，最终，同 RTL 参数覆盖）

| benchmark | instructions | cycles | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6,961 | 15,671 | 0.4442 |
| perf_multiply | 21,722 | 26,890 | 0.8078 |
| perf_qsort | 139,900 | 338,025 | 0.4139 |
| perf_rsort | 195,719 | 376,168 | 0.5203 |
| perf_towers | 5,278 | 14,993 | 0.3520 |
| perf_vvadd | 4,524 | 7,719 | 0.5861 |
| **GEOMEAN** |  |  | **0.5017** |

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
