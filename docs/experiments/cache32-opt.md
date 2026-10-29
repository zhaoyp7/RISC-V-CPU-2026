# 32B cache candidate: official opt comparison with main

The user requested exactly one opt run for the verified32B candidate and an
opt-to-opt comparison with current main. No RTL or default configuration is
changed in this measurement, and main is not merged automatically.

Candidate production source04eee15, result checkpoint76e4f73:
W2/ROB32/PRF64/IQ8/CDB2/LSQ16,4sets×2ways×4B read cache. Its seven prior
correctness configurations pass19/19 and the complete unit suite passes.
All24 production input hashes are unchanged; these functional results are
explicitly reused. W2/W1 IPC is0.659404085311/0.584500492456.

The current main f4a0555 archive is
`build/synth/iq_age_matrix_opt_checkpoint/opt/`: area19,808.712260µm²,
frequency456.124722MHz, W2 IPC0.522108164153. All24 archived input hashes
match both `git show main:<path>` and the preserved source snapshots.
Main/candidate six-perf instructions, input hashes and answers match,
with latency10 and50M cycle limits. Main's existing opt result is reused.

The candidate opt started2026-10-26 15:57:12 local time through
`make synth MODE=opt`, with macro injection in a separate Yosys wrapper.
Original framework files, SRAM sources and electrical constraints remain
unchanged. An exclusive lock at `/tmp/riscv_cpu_synthesis.lock` covers the
whole make invocation; a2GiB available-memory guard monitors this job.

## Completed results

| W2 opt metric |32B candidate|Current main|Change vs main|
|---|---:|---:|---:|
|IPC|0.659404085311|0.522108164153|+26.296%|
|Area µm²|22,315.189220|19,808.712260|+12.653%|
|Frequency MHz|417.618271|456.124722|−8.442%|
|IPC×frequency|275.379194|238.146441|+15.634%|
|Throughput/area, main=1|1.026462|1.000000|+2.646%|

The same candidate's diagnose→opt changes are area−1,134.134460µm²
(−4.837%) and frequency+31.785565MHz (+8.238%). It improves throughput
with a larger absolute area and only a small throughput/area improvement.
Retain the independent candidate; main and the production defaults are not
changed by this measurement. IPC0.6594 remains below the stage2 requirement,
and opt area22,315µm² exceeds18,000µm², so this is not a stage2 pass.

The single run completed in626.59seconds. Verified24 candidate source hashes
against the diagnose/functional archives and current source,24 current main
source hashes against Git and its preserved snapshots, all7 libraries,
tool versions, ABC settings and SDC/electrical settings. Actual elaborated
capacities are ROB32/PRF64/IQ8/LSQ16/cache8words. Functional results are reused
only because all24 production inputs match exactly; no new regression is
claimed. The prior plain/statistics runs and the main/candidate input/answer
comparability proofs are preserved.

The memory guard was not triggered: minimum available3.552GiB, minimum
SwapFree3.499GiB. The synthesis lock covered the complete make invocation,
including final OpenSTA analysis. The opt critical path has D arrival2.339ns,
from `_426523_/QN` to `_432976_/D` in the flattened netlist. Future timing
work should locate that mapped path rather than assume the diagnose hierarchy
is still the limiting path.

Archive: `build/synth/cache32_zero_opt_checkpoint/`, including24 source
snapshots, explicit macro definitions, input comparability proofs, main's
verified report, Yosys invocation log, memory samples, verification.json and
comparison.json. The user received the opt-to-opt table immediately after
completion and verification. No merge, push or second synthesis was performed.
