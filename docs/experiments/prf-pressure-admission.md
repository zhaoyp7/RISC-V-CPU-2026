# Dispatch without rename acceptance under PRF pressure

Status: acceptance gate corrected and verified for the stated PRF64/56 configurations. W1/W2 directed and full-core regressions pass. Timing/statistics are verified; see admission-prf-hour.md. PRF48/ROB32 has a separate unresolved statement_test failure.

With 521fcc7, ROB32/PRF56/LSQ16 and the 64B cache, qsort passes but hanoi
times out at the official 50,000,000-cycle limit. A 100,000-cycle diagnostic
also times out. The ordinary and passive-statistics diagnostic both reach
the same limit. The physical PRF really has 56 entries in the generated
simulator; this is not an ineffective macro override.

The short trace reports ROB occupancy reaching 32, prolonged ROB other_wait,
and mostly empty IQ. All 78 external loads receive responses, all 298 drained
stores receive responses, and SAFE_WAKE missing_grant is zero. These counters
direct investigation toward dispatch/completion ownership rather than a
missing external memory response.

In core_ooo.sv, `ren_ready` means ROB and backend have capacity. Rename's
`in_ready`, connected as `rename_ready`, additionally requires sufficient free
physical tags and no recovery. Rename deliberately keeps `out_valid` asserted
while stalled. However, `ren_fire` is currently `ren_valid & {W{ren_ready}}`.
Consequently ROB and backend can accept instructions when rename did not
allocate their tags or advance its state. A smaller PRF exposes this mismatch.

The focused test in `test/core_admission_test/` uses the real core wrapper and
test-only interface fixtures for frontend, rename and ROB. It independently
controls physical-tag availability, ROB capacity and backend capacity, and
observes both dispatch valid bits and the ROB input. With tag availability
false and the other two ready signals true, the current RTL wrongly sends
both lanes. The W2 test produces 72 checks and 6 failures; the failure log is
preserved under `build/prf_admission_diagnosis/`.

The correction is:

```diff
-  assign ren_fire  = ren_valid & {W{ren_ready}};
+  assign ren_fire  = ren_valid & {W{rename_ready}};
```

`rename_ready` already includes `ren_ready`, so this coordinates frontend,
rename, ROB and backend acceptance. The old W1/W2 tests each fail six of 72
checks; the corrected versions each pass all 72. PRF56 W2 hanoi passes at 8863
cycles. Full default/ROB32 W1/W2 and PRF56 correctness/perf, statistics and
diagnose completed in independent archives under cache_admission_fix_64/56.

The corrected test is now included in `test/run_all.sh`. The earlier timed
session retained a failing reproducer; the renewed one-hour authorization
carries out the fix and all required validation. PRF56 data is attributed only
to new fixed-source measurements, never to the earlier failed configuration.
