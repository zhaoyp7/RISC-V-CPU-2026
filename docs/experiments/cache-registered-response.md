# Register memory responses with the LSU read cache enabled

The first 64B cache prototype improved W2 IPC from 0.621226 to 0.654101, but
diagnose frequency fell from 393.39 to 329.47 MHz. Its critical mapped path
crossed LSQ drain address selection, LSU load-result data, CDB and PRF.

This trial uses the existing result FIFO for every external response when the
cache is enabled. Cache hits already use that FIFO. A miss therefore gains one
result cycle; the structural register boundary isolates memory/cache control
from the same-cycle result path to PRF. Cache-disabled configurations retain
the existing empty-FIFO response bypass.

The LSU protocol tests assert the intended response edge separately for enabled
and disabled cache configurations. They continue to check exact tag/data,
backpressure, overlap, cancellation, FIFO reuse and byte/halfword formatting.
Four enabled configurations passed 64093/64289/64569/64569 checks. W1/W2
qsort, hanoi and queens smoke tests passed before starting diagnose.

The passive response monitor now distinguishes an intentionally queued response
(`forced_queue`) from FIFO occupancy and CDB backpressure. This preserves a
meaningful accounting identity when bypass is disabled.

Validation is in progress under `build/synth/lsu_cache_registered_64b/`: four
core configurations, full units, ordinary/statistics agreement and one
diagnose. Capacity-only comparisons use
`build/cache_registered_sizes_20261026/`. No new IPC/PPA conclusion is recorded
until those measurements and source/library/configuration checks finish.

The user renewed continuous-work authorization through 2026-10-26 11:30 CST.
The earlier interruption is documented in the first cache experiment; the new
authorization supersedes the earlier 07:30 stopping time.
