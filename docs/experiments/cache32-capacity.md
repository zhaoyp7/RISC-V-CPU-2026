# 32B read-cache capacity experiment

Same production source as retained64B checkpoint faa8c87; only
`CPU_DCACHE_INDEX_BITS` changes3→2. Configuration: W2/ROB32/PRF64/IQ8/
CDB2/LSQ16, 4sets×2ways×4B =32B. Defaults remain cache-disabled.

W2/W1 each pass19/19 official correctness cases with50M cycle limit and
latency10. Six-performance geometric IPC is0.659243115973/0.584500492456.
W2 loses1.352% IPC relative to64B, chiefly qsort and towers. At least
380.509766MHz would be needed to match the retained64B IPC×frequency.

The cache protocol matrix W1/LSQ8, W2/LSQ16 and W1/W2/LSQ32 passes
64112/64308/64588/64588 checks. Same-source default regressions and run_all
are explicitly reused; the32B-specific matrix is newly run.

One exclusive-lock diagnose completed in686.50seconds: area23,459.208920µm²,
frequency383.952006MHz, IPC×frequency253.117717. Relative to retained64B:
area−1.742%, frequency+2.287%, throughput+0.905%, throughput/area+2.694%.
Relative to ba7f0a3: throughput+3.573%, throughput/area+1.120%.
The user received a four-way diagnose table immediately after completion.

The plain/statistics inputs, answers and cycles match. All24 inputs,7 libraries,
tools/constraints and actual capacities were verified. The named internal cache
signals are purged from the mapped netlist, so this experiment uses measured
whole-core/module areas rather than claiming a precise internal cone partition.

This source has the separately reproduced architectural x0 bypass defect.
The positive capacity result is retained as a controlled comparison; the next
candidate combines32B with the x0 correction and requires its own PPA.
Archive: `build/synth/cache32_admission/` with24-source snapshots, wrappers,
actual eight-word simulator dimensions, correctness/perf logs and reuse record.
W2 build/perf reuse from `build/cache32b_admission_probe/` requires matching
all24 source hashes, exact macro definitions and simulator SHA256.
