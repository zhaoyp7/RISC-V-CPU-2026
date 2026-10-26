# Core dispatch admission reproducer

Current status: **expected failure on the uncorrected core**. This test is not
included in `test/run_all.sh` until the acceptance mismatch is corrected.

It uses the production core_ooo wrapper and explicit test-only interface
fixtures for frontend, rename and ROB. The fixtures independently control
free-tag availability, ROB capacity and backend capacity. Both downstream
receivers must see a dispatch only when all three permit acceptance.

Run the measured W2 reproducer:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 python3 tools/unit/build.py \
  --top core_admission_top --tb test/core_admission_test/core_admission_tb.cpp \
  --sources verilog/rv32_defs.sv verilog/cpu_config.sv verilog/if_defs.sv \
    test/core_admission_test/fixture.sv verilog/core_ooo.sv \
  --define CPU_ISSUE_WIDTH=2 --define CPU_PRF_SIZE=56 \
  --define CPU_ROB_DEPTH=32 --cxx-define TB_W=2 \
  --out build/unit/core_admission_before
```

Observed: 72 checks, 6 failures when tags are unavailable but ROB/backend are
ready. Production core dispatch currently uses ren_ready instead of the
rename_ready acceptance signal. The proposed fix and required follow-up are
documented in `docs/experiments/prf-pressure-admission.md`.
