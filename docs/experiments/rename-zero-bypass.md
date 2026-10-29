# Preserve architectural x0 in intra-bundle rename dependencies

## Reproduction

The ROB32/PRF48 read-cache probe previously passed18/19 correctness cases:
`correctness_statement_test` printed61 instead of50. The same source with
PRF64 passed. Retirement traces agree until the branch at PC0xD4.

The existing VCDs identify the faulty accepted bundle at cycle1533:

- Lane0: jump at PC0x170, decoded `reg_we=1, rd=0`, completion tag8.
- Lane1: branch at PC0xD4, architectural `rs1=0`, renamed `src1_tag=8`.
- At execution cycle1542, tag8 contains372, so the branch incorrectly takes
  the target0x128. The PRF64 schedule places the branch in lane0 and reads zero.

`rename.sv` initializes zero sources correctly, then its intra-bundle RAW
bypass overwrites that initialization when a preceding instruction writes rd0.
This is a grouping-dependent correctness defect, not evidence that PRF48 itself
is fundamentally unsupported.

## Independent regression and isolated fix

`test/rename_zero_test/` asserts constant-zero source tags and ready bits
without copying the existing rename reference model. It also checks both
operand positions, following bundles, allocation pressure and nonzero RAW.

Original source: W1 265checks/0fails; W2 529checks/260fails.
An isolated source copy excludes x0 from the two RAW bypass conditions:
W2 529checks/0fails. The rename reference model now applies the same
architectural x0 rule; fixed-copy full random checks W1/W2 are
200072/200074 with zero failures.

The isolated-copy PRF48 full regression now passes19/19, including the formerly
failing `statement_test`; six-perf W2 IPC is0.659214800883. PRF48 has no new PPA
and is not adopted as an area candidate.

After the independent32B capacity diagnose completed and all source checks
passed, the exact same fix was applied to production. All24 canonical source
hashes match the isolated-copy validation inputs, including rename.sv itself.
The new regression is included in `test/run_all.sh`; production W2 directed
test also passes529checks with zero failures. The complete suite reports
ALL PASS. Retained64B, new32B and default W1/W2 full validation each pass19/19.

## Completed combination: source04eee15,32B cache

ROB32/PRF64/IQ8/CDB2/LSQ16,4sets×2ways×4B, W2 diagnose:
area23,449.323680µm², frequency385.832705MHz. W2/W1 six-perf IPC is
0.659404085311/0.584500492456. The source correction slightly improves W2
IPC; W1 matches the prior32B result.

Relative to prior32B: area−0.042%, frequency+0.490%, throughput+0.514%.
Relative to the original retained64B: area−1.784%, throughput+1.424%,
throughput/area+3.265%. Relative to ba7f0a3: throughput+4.106%,
throughput/area+1.683%. Retain the combined32B candidate and correctness fix.

Six configurations (32B/64B/default ×W1/W2) newly pass19/19; the additional
PRF48 W2 configuration also passes19/19. Only32B has new fixed-source PPA;
64B/default/PRF48 simulation results must not be paired with historical PPA
as though those exact corrected configurations were synthesized.

New32B plain/statistics inputs, answers and cycles match; all counters
conserve. Verified24 production inputs (only rename.sv changes from the
preceding32B experiment),7 libraries, tools/constraints and actual simulator
dimensions, including actual PRF storage words. Same-LSU-source32B protocol
matrix is explicitly reused; the entire unit suite is newly run on production.

One exclusive-lock diagnose took871.08seconds. A2GiB MemAvailable guard
monitored the complete run and was not triggered: minimum2.854GiB available,
minimum3.497GiB SwapFree. Both completed diagnoses in this task were reported
to the user with current/previous/baseline/main tables. Defaults remain
unchanged, with no opt, main merge or push. Archive:
`build/synth/cache32_zero_fix/` (inputs, wrappers, validation, statistics,
verification.json, comparison.json and memory.jsonl).

Evidence: `build/cache_admission_prf_sweep_20261026/statement-diagnosis/`
(`branch-operands.json`, VCDs, negative regression log); isolated fix and
whole-core source manifest: `build/rename_zero_fix_trial/`.
