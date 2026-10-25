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

## Validation in progress

Dedicated protocol tests use external request counts and tagged result values.
All four W1/W2 and LSQ8/16/32 configurations passed, with 64063, 64259, 64539 and
64539 checks. They cover hit/miss overlap, held requests, store invalidation,
store forwarding, canceled fills, replacement, shared fill port, result-credit
backpressure and MMIO bypass. The existing address-generator reference resets
between independent direct backing-memory edits to keep each case cold.

Archive: `build/synth/lsu_cache_64b/`. Candidate inputs are frozen for W1/W2
correctness/perf, cache-disabled default compatibility checks, complete unit
regression, statistics and one diagnose run. Performance and PPA results will
be recorded after these checks finish; fixed-trace hit opportunities from
[the trace study](dcache-trace.md) are not measured IPC improvements.
