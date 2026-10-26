# Core dispatch admission reproducer

Current status: fixed-core W1/W2 each pass 72 checks. The test is included in
`test/run_all.sh`. The archived uncorrected W1/W2 each fail six checks.

It uses the production core_ooo wrapper and explicit test-only interface
fixtures for frontend, rename and ROB. The fixtures independently control
free-tag availability, ROB capacity and backend capacity. Both downstream
receivers must see a dispatch only when all three permit acceptance.

Run both widths:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 sh test/core_admission_test/run.sh
```

The equivalent W2 invocation is:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 CPU_UNIT_JOBS=1 python3 tools/unit/build.py \
  --top core_admission_top --tb test/core_admission_test/core_admission_tb.cpp \
  --sources verilog/rv32_defs.sv verilog/cpu_config.sv verilog/if_defs.sv \
    test/core_admission_test/fixture.sv verilog/core_ooo.sv \
  --define CPU_ISSUE_WIDTH=2 --define CPU_PRF_SIZE=56 \
  --define CPU_ROB_DEPTH=32 --cxx-define TB_W=2 \
  --out build/unit/core_admission_regression
```

Before correction, both widths produced 72 checks and six failures when tags
were unavailable but ROB/backend were ready. Dispatch now uses rename_ready,
which includes successful allocation. The real PRF56 hanoi reproducer also
passes; complete correctness, performance and timing are measured separately.
