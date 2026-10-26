# Capture a new load in an idle LSU query stage

The store-maintenance stage in 41b206e removed the drain path from first place
and reached 377.30 MHz, but W2 IPC×frequency improved only 1.01% over ba7f0a3
while throughput/area remained 2.85% lower.

This trial lets the cache-enabled LSU capture a newly enqueued load directly
into an available query stage if the pending-table selector has no candidate.
An existing selected candidate retains priority. The load keeps its pending
table ownership; existing query/response owner exclusions prevent duplicate
selection, and consumption still clears the pending entry. The LSQ snapshot
is captured on the next edge, after enqueue/fill state is available. Squashed
enqueues retain their existing rejection condition.

No new pipeline storage or result port is added. Cache-disabled configurations
retain the old enqueue path. The potential tradeoff is the added AGU-to-query
input mux, so real frequency must be remeasured.

An external-request timing check verifies that the query snapshot edge remains
and the first miss is accepted one cycle sooner in the empty case. It fails
on the archived 41b206e LSU with exactly one failed check, then passes on this
trial. W1/LSQ8, W2/LSQ16 and W1/W2/LSQ32 protocol matrices pass
64112/64308/64588/64588 checks. W1/W2 qsort/hanoi/queens pass before diagnose.

Core correctness/perf, full units, statistics and diagnose are running under
`build/synth/lsu_cache_query_stage_64b/`. Independent PRF56 and LSQ8 parameter
probes use `build/cache_query_window_probes_20261026/`; they have no PPA until
separately synthesized and verified. Default capacities remain unchanged.

## Verified result

521fcc7: W2/W1 IPC 0.668275932/0.590333035; diagnose 23875.147160µm²/375.917768MHz.
Against ba7f0a3: W2 IPC +7.574%, frequency -4.442%, area +4.242%, IPC×frequency +2.795%, throughput/area -1.388%.
Against 41b206e, W2 IPC improves 2.141% and frequency decreases slightly. The one pending-table cycle is a measured IPC improvement.
Four configurations each19/19; default cache-off correctness/perf cycles unchanged. Full run_all ALL PASS. Six ordinary/statistics inputs, outputs, cycles and accounting agree.
24 production input hashes, seven libraries, tools/constraints, elaboration and five simulator dimensions verified. One diagnose 12.12min, no opt.
Critical path remains ROB→frontend I-cache, D2.604ns. Retain an independent IPC candidate; area efficiency remains below ba7f0a3, so do not upgrade defaults or main.

Parameter probes: LSQ8 W2/W1 IPC0.588446/0.534335 (both19/19), down11.95% from this LSQ16 configuration; no PPA was run. PRF56 passed qsort but hanoi timed out at the official50,000,000-cycle limit. Its dispatch/rename acceptance defect is reproduced and documented separately; no PRF56 PPA or complete-correctness claim.

Execution continuity: the renewed user goal ended at11:30CST. The clock advanced from11:07 to12:36 between tool checks, indicating a substantial execution gap whose platform cause is not confirmed. New optimization stopped on observing the expired deadline; only result recording and handoff followed. Continuous execution through11:30 was not achieved.
