# C2 面积档配置（2026-10-23 起为默认）

> **自 `1e99cc8` 起，C2 是默认配置**。面积优先；W=2 IPC 0.6311，
> 仍高于阶段 1 的 0.60，但距阶段 2 的 0.845 很远。
> tournament gshare 在 `feat/gshare-snapshot` 分支，因 +1.45k 面积未入默认。

## 参数

| 参数 | P2 性能默认 | C2（当前默认） |
| --- | ---: | ---: |
| `CPU_ISSUE_WIDTH` | 2 | 2 |
| `CPU_ROB_DEPTH` | 32 | 16 |
| `CPU_PRF_SIZE` | 64 | 48 |
| `CPU_RS_DEPTH` | 8 | 8 |
| `CPU_CDB_NUM` | 2 | 2 |
| `CPU_LSQ_DEPTH` | 8 | 16 |
| `CPU_ICACHE_INDEX_BITS` | 9（2 KB/bank） | 8（1 KB/bank） |
| `CPU_BTB_INDEX_BITS` | 6（64 项） | 5（32 项） |
| `CPU_BHT_INDEX_BITS` | 8（256 项） | 7（128 项） |

## 生成 / 构建

```sh
cd "$(git rev-parse --show-toplevel)"

python3 tools/config_gen.py \
  --issue-width 2 --rob 16 --prf 48 --rs 8 --cdb-num 2 --lsq 16 \
  --icache-index-bits 8 --btb-index-bits 5 --bht-index-bits 7

make build JOBS=4
make test MAX_CYCLES=50000000
make perf MAX_CYCLES=50000000
```

恢复默认配置：

```sh
python3 tools/config_gen.py
# 或
git checkout -- verilog/cpu_config.sv
```

## 结果

| 指标 | P2 性能默认 | C2 |
| --- | ---: | ---: |
| W=2 IPC geomean | 0.6380 | **0.6311** |
| W=1 IPC geomean | 0.5688 | 0.5940 |
| W=2/W=1 correctness | 19/19 | 19/19 |
| diagnose 面积 | 25,134.9 µm² | **20,262.8 µm²** |
| diagnose Fmax | 53.96 MHz | 53.44 MHz |
| opt 面积/Fmax | 24,468.8 µm² / 56.72 MHz | **19,759.4 µm² / 55.47 MHz** |

C2 的 IPC 分项：median 0.4616、multiply 1.0572、qsort 0.4640、
rsort 0.7659、towers 0.4817、vvadd 0.7563。

## 注意

- `ROB32 + PRF48` 是无效组合：32 个在飞表项加 32 个架构映射需要约
  64 个物理寄存器，PRF48 会资源型死锁；ROB32 请保持 PRF64。
- ROB16 依赖 2026-10-22 的 recovery 修复（`ab00273`）；旧 RTL 上
  ROB16 会在 hanoi 超时。
- C2 的 diagnose 面积测量早于 `ab00273`；该修复只给提交路径加
  `!recover_valid` 门控，面积差异很小，但严格精确值需在最终 RTL 上重跑。
- 继续压面积到 18k 的 C3（RS4、512B I$/bank、BTB16/BHT64）IPC 只有
  0.5917，低于阶段 1 的 0.6，暂不作为默认或推荐配置。
