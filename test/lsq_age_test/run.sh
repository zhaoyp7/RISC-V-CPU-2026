#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for scenario in subsets boundaries; do
    python3 "$root/tools/unit/build.py" \
        --top lsq --out "$root/build/unit/lsq_age_$scenario" \
        --tb "$here/lsq_age_${scenario}_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/lsq.sv" \
        --define CPU_ISSUE_WIDTH=2 --define CPU_LSQ_DEPTH=16 \
        --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 --define CPU_CDB_NUM=2
done
