#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for width in 1 2; do
    python3 "$root/tools/unit/build.py" \
        --top core_admission_top --tb "$here/core_admission_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
            "$root/verilog/if_defs.sv" "$here/fixture.sv" "$root/verilog/core_ooo.sv" \
        --define "CPU_ISSUE_WIDTH=$width" --define CPU_PRF_SIZE=56 \
        --define CPU_ROB_DEPTH=32 --cxx-define "TB_W=$width" \
        --out "$root/build/unit/core_admission_w$width" "$@"
done
