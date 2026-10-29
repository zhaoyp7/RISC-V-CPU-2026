# Small read-cache protocol regression

Run `APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 sh test/lsu_cache_test/run.sh`.
The runner explicitly enables a 64B, two-way cache (eight sets, four-byte lines)
in the existing W1/LSQ8, W2/LSQ16 and W1/W2/LSQ32 LSU matrix. Production defaults
keep the cache disabled. Output uses `build/unit/lsu_cache`, separate from the
cache-disabled LSU matrix.

The testbench observes external requests and tagged results. Checks cover:

- Cold misses, warm hits and signed/unsigned byte and halfword formatting.
- A younger cache hit completing with an unrelated older miss outstanding.
- A stalled miss retaining valid/address when an older request fills its word.
- Committed full-word store allocation and partial-store invalidation/refill.
- Unknown older stores blocking cached loads; store forwarding taking priority.
- Store issue canceling an older pending fill, including a squashed store.
- Canceled responses never populating the cache.
- Two-way replacement and recency after a hit.
- Concurrent memory response and committed store sharing one cache write port.
- Result-credit exhaustion and CDB backpressure without duplicate writeback.
- MMIO bypass and no alias with a cached RAM word.

Existing address-generator cases reset between independent direct modifications
of backing memory. This keeps each case cold and makes its bus-address assertion
meaningful with the cache enabled. All reference arithmetic and stall checks
remain active. The cache currently accepts word-aligned RAM requests only;
unaligned accesses retain the existing LSU bus behavior.
