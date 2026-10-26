# Dispatch without rename acceptance under PRF pressure

Status: reproduced; production RTL is not fixed yet.

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

The proposed correction is:

```diff
-  assign ren_fire  = ren_valid & {W{ren_ready}};
+  assign ren_fire  = ren_valid & {W{rename_ready}};
```

`rename_ready` already includes `ren_ready`, so this coordinates frontend,
rename, ROB and backend acceptance. This correction has not been applied or
tested. Before accepting it, run the directed test in W1/W2, full default and
ROB32 correctness/perf, the PRF56 hanoi reproducer and complete regression,
then remeasure timing because the free-tag qualification enters dispatch.

The pending test is intentionally excluded from `test/run_all.sh`; the earlier
ALL PASS result describes the suite before this newly reproduced defect, not
a claim that this new test passes. No PRF56 IPC geomean or PPA is reported.
The user deadline expired during an execution gap before the correction could
be implemented, so the reproducer and precise handoff are retained.
