# Register the store-drain cache-maintenance payload

The registered-response trial f5df7fa reached 353.59 MHz but W2 IPC fell to
0.643215; throughput remained 6.94% below ba7f0a3. Its new critical path still
started in LSQ and ended at an LSU register (2.772ns at D).

This trial restores the empty-result-FIFO memory-response bypass. It adds one
cache-local register stage for committed store-drain word address, alignment,
data and byte mask. Cache invalidation, pending-fill cancellation and full-word
write allocation consume this registered payload on the following edge. Store
execution still invalidates immediately. Cache-maintenance occupancy contributes
to LSU busy, so the interface cannot report idle with maintenance pending.

The LSQ keeps a drained store until its later memory response. During the one
maintenance cycle, a matching younger load still sees that store in its LSQ
query: a full word forwards and a partial or unknown store blocks. A request
cannot receive its response before its acceptance; the existing protocol and
memory model provide this ordering. Same-edge snapshot capture also sees the
pre-edge store state. Pending cache fills continue to have per-entry permission
and are canceled by both immediate store execution and delayed drain maintenance.

The new directed test creates an older load that fills after a younger partial
store has already issued. It then commits the store and issues a younger load.
The younger load must remain blocked, and committed drain must invalidate the
old cached refill before the load can proceed. The single cache write-port test
aligns its read response with the registered maintenance edge.

Enabled LSU configurations passed 64105/64301/64581/64581 checks. Full-core
validation, units, stats and one diagnose run use
`build/synth/lsu_cache_drain_stage_64b/`. Capacity-only probes use
`build/cache_drain_stage_sizes_20261026/`. No performance/PPA conclusion yet.

Defaults remain cache-disabled. Official filelist, memory interfaces, Makefile,
scripts and SRAM models are unchanged. No opt, main merge or push is requested.

## Verified result

41b206e: W2/W1 IPC 0.654268987/0.581953915; diagnose 23813.400860µm²/377.302874MHz.
Versus ba7f0a3: IPC +5.319%, area +3.973%, frequency -4.090%, throughput +1.011%, throughput/area -2.848%.
Four configurations 19/19, default cache-off cycles identical; run_all ALL PASS; plain/statistics inputs, outputs, cycles and counter accounting verified.
24 source inputs, seven libraries, tool/constraints, simulation/synthesis dimensions and the maintenance-register widths verified. One diagnose 12.02min; no opt.
The critical path moved to ROB→frontend I-cache (D2.594ns), so the targeted store-drain path was removed from first place. The throughput gain remains small and area efficiency is below baseline; retain an experiment, not a default upgrade.
Capacity-only W2 IPC: 128B 0.664696, 256B 0.671590, each19/19; no PPA for these sizes.
Next test: let an idle query stage capture a new load at enqueue, avoiding one pending-table cycle while retaining LP ownership and oldest-candidate priority.
