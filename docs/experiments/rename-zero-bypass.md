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
test also passes529checks with zero failures. Retained64B, new32B and default
W1/W2 full validation and the complete unit suite are running. No fixed-source
PPA is claimed until its separate diagnose finishes.

Evidence: `build/cache_admission_prf_sweep_20261026/statement-diagnosis/`
(`branch-operands.json`, VCDs, negative regression log); isolated fix and
whole-core source manifest: `build/rename_zero_fix_trial/`.
