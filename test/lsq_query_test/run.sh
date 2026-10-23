#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for depth in 8 16; do
    python3 "$root/tools/unit/build.py" \
        --top lsq --tb "$here/lsq_query_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/lsq.sv" \
        --define CPU_ISSUE_WIDTH=1 --define "CPU_LSQ_DEPTH=$depth" \
        --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 \
        --cxx-define "TB_DEPTH=$depth" "$@"
done
