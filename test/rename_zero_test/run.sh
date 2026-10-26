#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for w in 1 2; do
    python3 "$root/tools/unit/build.py" --top rename \
        --tb "$here/rename_zero_tb.cpp" \
        --sources "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" "$root/verilog/rename.sv" \
        --out "$root/build/unit/rename_zero_w$w" \
        --define "CPU_ISSUE_WIDTH=$w" --define CPU_PRF_SIZE=64 \
        --define CPU_ROB_DEPTH=32 --define CPU_LSQ_DEPTH=8 --cxx-define "TB_W=$w" "$@"
done
