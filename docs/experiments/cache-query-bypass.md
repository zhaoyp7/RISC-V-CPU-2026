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
