# Main correctness fixes, separate from the performance candidate

The repair branch starts at main f4a0555 and contains three focused fixes:

|Commit|Problem and corrected behavior|
|---|---|
|3710dd1|Dispatch uses rename's actual acceptance, including free-tag and recovery qualification. A stalled rename cannot dispatch unallocated tags.|
|ef5e2ae|Intra-bundle RAW bypass preserves architectural x0 source tags and ready bits, including after a jump writing rd0.|
|81391ca|Retired LSU FIFO slots release their age metadata, and simultaneous enqueue/squash classifies the new payload rather than the previous occupant.|

The production diff from f4a0555 changes only core_ooo.sv, rename.sv and
lsu.sv. No D-cache, enlarged ROB, scheduling optimization or altered default
configuration is imported. Independent regressions and the corresponding
test reference correction are included in the one-command suite. The existing
local `.codex/` ignore rule is preserved when returning to main.

## Verification

Original-main failures were reproduced before changing production RTL:

- Admission W1/W2:72checks each,6failures each.
- x0: W1 265checks/0failures; W2 529checks/260failures.
- LSU: result-FIFO and metadata-FIFO reuse each lose an older payload on a
  simultaneous squash, giving2failures in the63815-check W1/LSQ8 run.

After correction, the admission and x0 directed tests have zero failures.
LSU W1/LSQ8 and W2/LSQ16 pass63815/64006checks. Complete rename random
reference tests pass200072/200074checks. `test/run_all.sh` reports ALL PASS.

|Whole-core configuration, no cache|Correctness|Six-perf IPC|
|---|---:|---:|
|Default W1/ROB16/PRF48/IQ8/LSQ16|19/19|0.498844480672|
|Default W2/ROB16/PRF48/IQ8/LSQ16|19/19|0.522150576060|
|Pressure W2/ROB32/PRF48/IQ8/LSQ16|19/19|0.584363386070|

Tests use the official `make test MAX_CYCLES=50000000` and
`make perf MAX_CYCLES=50000000 SIM=...` drivers. Actual elaborated dimensions,
including48 physical-register storage words, were checked in all three
simulators. All24 source inputs match the frozen validation manifest; only
the three intended production sources differ from the old main.

This merge has no new synthesis result. The old456.12MHz/19,808.71µm² opt
measurement belongs to f4a0555 and must not be paired with the corrected
main's new IPC as a new PPA result. No unmeasured row is added to the full-core
PPA table.

## Preserved performance checkpoint

`cache32-zero-opt-20261026` remains at29e0fc8 on
`feat/ipc-lsu-read-cache`. Its all24 source hashes still match its opt report:
W2/ROB32/PRF64/IQ8/LSQ16/D$32B, IPC0.659404085311,
area22,315.189220µm², frequency417.618271MHz. This performance branch is not
merged into main. Its detailed experiment notes remain inside that tag.

Original main is retained as `main-before-correctness-20261026`.
Validation logs, before/after evidence, source snapshots, simulator hashes and
verification.json are in `build/main_correctness_merge_20261026/`.
