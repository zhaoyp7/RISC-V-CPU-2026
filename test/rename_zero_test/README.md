# x0 rename regression

Run `APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 sh test/rename_zero_test/run.sh`.

This black-box W1/W2 regression checks the architectural constant-zero source
tags and ready bits independently of the existing rename reference model.
A decoded instruction with `reg_we=1, rd=0` must not create a RAW dependency
on x0 in a younger lane. Both source positions, subsequent bundles, exhausted
allocation credits, and genuine nonzero intra-bundle dependencies are covered.

The reproducing whole-core case is ROB32/PRF48 `correctness_statement_test`:
the bundle at PC0x170/0xD4 maps the branch's x0 operand to the preceding jump's
completion tag. The original core prints61 instead of50.
