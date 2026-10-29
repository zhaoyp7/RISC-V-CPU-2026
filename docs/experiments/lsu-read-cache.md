# LSU small nonblocking read cache

## Scope and baseline

The first prototype explicitly enables a 64B cache: eight sets, two ways and
four-byte lines. It extends the existing LSU, without changing the official
filelist, bus interface, SRAM models or synthesis flow. `config_gen.py` generates
`CPU_DCACHE_ENABLE=0` by default; experiment wrappers select enable=1, index=3,
ways=2 and line_bytes=4. Existing unused default cache dimensions are preserved.

The measured reference is ba7f0a3 with ROB32/PRF64/IQ8/LSQ16: W2/W1 IPC
0.621226451/0.558327610 and diagnose 22903.492220 µm²/393.392240 MHz. Existing
default ROB16/PRF48 has functional and IPC results, but no new PPA for this RTL.

## Protocol

Lookup follows the LSQ query snapshot. Unknown or conflicting older stores
continue to block a load; LSQ store forwarding has priority over cache lookup.
A hit enters the existing tagged result FIFO and reserves its result credit.
Misses use the existing eight-entry metadata queue and untagged ordered memory
interface. Thus hits can complete while an unrelated older miss is outstanding
without changing response association. A memory response takes the single
result write port before a new cache hit.

Store execution and committed store drain invalidate matching cached words and
cancel pending fills for that word. Full-word committed drain allocates the new
value; byte/halfword stores invalidate without allocation. Each metadata entry
stores its requested word and fill permission. Squashed responses never fill.
The data array has one write port: committed store allocation wins over a read
fill, while the read response still completes normally. Two-way replacement
uses one recency bit per set and accounts for concurrent hit consumption.

After a miss presents valid under backpressure, classification remains locked
until that query advances. An older response filling the same word cannot
withdraw or duplicate the stalled request.

Only word-aligned addresses in RAM below 0x10000000 are cacheable. MMIO and
unaligned requests retain the existing LSU behavior. Aligned byte/halfword reads
use the original LSU sign/zero extension. There is no prefetch or free line-wide
memory transaction in this prototype.

## 测量结论（2026-10-26）

| ROB32/PRF64/IQ8/LSQ16 | W2 IPC | W1 IPC | diagnose面积 µm² | 频率 MHz |
| --- | ---: | ---: | ---: | ---: |
| ba7f0a3基线 | 0.621226 | 0.558328 | 22,903.492 | 393.39 |
| 37e3b1d，64B/2way缓存开启 | 0.654101 | 0.582267 | 23,800.891 | 329.47 |

W2 IPC +5.292%，W1 IPC +4.288%，面积 +3.918%，频率 -16.248%。
W2 IPC×频率 -11.816%，单位面积吞吐 -15.141%。
本轮64B方案仅保留实验检查点，不升级默认、不合main。

四组（缓存开启ROB32两档、默认缓存关闭ROB16两档）各19/19，默认两档全部正确性及perf周期与ba7f0a3相同；
run_all ALL PASS。六perf普通/统计版输入、答案、周期完全一致，计数守恒核验通过。
24个生产输入、7个库、工具/时序/ABC约束、实际综合与仿真容量均已核验。
只改cpu_config与LSU两个生产输入；一次完整diagnose 12.29分钟，无opt。
缓存关闭但含队列修复的配置没有单独PPA，不能套用ba7f0a3频率。

真实命中比例（hits/(hits+misses)）为median34.35%、qsort16.66%、towers51.15%、rsort1.01%；
multiply与vvadd为0。缓存仍须通过原LSQ查询与结果FIFO，store沿原路径写出，不能消除所有访存等待。
门级首条路径从LSQ状态经过drain_addr[9]（约1.721ns），进入LSU的load_result_value[27]（约2.701ns），
再经CDB到PRF D端2.979ns。下一步应先隔离store排空/缓存失效与读结果路径，核对综合逻辑共享，再比较查找寄存化或结果选择重构；
具体结构改动尚未实现，不把时序路径观察等同于已证明的唯一根因。

容量仿真比较（均未综合，故不加入完整核心PPA表）：

| 配置 | W2 IPC | 正确性 |
| --- | ---: | --- |
| cache128_rob32 | 0.664876 | 19/19 |
| cache256_rob32 | 0.671951 | 19/19 |
| cache64_rob16 | 0.580314 | 19/19 |

以上24输入hash、实际尺寸、仿真器hash、原始19项日志和perf指令数已核验，归档build/cache_sizes_20261026/。
128B/256B只比64B进一步增加约1.65%/2.73%的IPC，尚无频率/面积结论。

执行连续性：用户授权持续到07:30 CST；日志在约01:27后出现长间隔，部分验证于09:50后结束。
09:52恢复检查时已超过截止时间。旧工具会话句柄和goal状态已不可用，无法仅凭这些现象确认是额度还是运行环境挂起；
没有实现连续工作到截止时间，也不能保证额度重置后自动唤醒。恢复后只完成已有数据核验和记录，没有启动新优化。

## Result FIFO reuse correction

The first prototype passed the protocol matrix and W1 smoke tests, but W2
queens timed out. No synthesis was started for that version. A simulation-only
reference compared every cache hit against memory updated by committed stores;
all observed hit values matched. At cycle 107935, a queue observer found an
older response (sequence 109276) entering FIFO slot zero while squash boundary
109284 incorrectly classified that slot using its previous sequence 109285.
The old valid bit remained set after the previous occupant had left.

A directed cache-disabled regression fills and drains the result FIFO with
younger local results while retaining an older memory miss. Its response then
reuses the wrapped FIFO slot on the squash edge. The uncorrected version loses
the older result; the correction clears valid on pop and gives new enqueues
ownership of their own discard classification. Metadata slots receive the same
explicit ownership rule. This is a queue reuse defect exposed by changed
completion order, rather than a cache data mismatch.

After the correction, cache-disabled LSU checks are
63832/64023/64303/64303 and enabled checks are 64092/64288/64568/64568, all zero
failures. The original failed source, binaries, oracle and logs remain in
`build/synth/lsu_cache_64b/`; corrected measurements use the separate archive
`build/synth/lsu_cache_64b_reuse_fix/`. Corrected full-core validation and report checks completed as recorded above.
