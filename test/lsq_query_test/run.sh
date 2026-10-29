#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
run_one() {
    w=$1
    depth=$2
    shift 2
    python3 "$root/tools/unit/build.py" \
        --top lsq --tb "$here/lsq_query_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/lsq.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_LSQ_DEPTH=$depth" \
        --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 \
        --cxx-define "TB_DEPTH=$depth" --cxx-define "TB_W=$w" "$@"
}
run_one 1 8 "$@"
run_one 1 16 "$@"
run_one 2 16 "$@"
run_one 1 32 "$@"
run_one 2 32 "$@"
