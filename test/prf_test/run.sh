#!/bin/sh
# PRF unit test: two, four and six read ports with a 64-word reference.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

run_one() {
    w=$1
    r=$2
    python3 "$root/tools/unit/build.py" \
        --top prf \
        --tb "$here/prf_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" "$root/verilog/prf.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" --define CPU_PRF_SIZE=64 \
        --cxx-define "TB_W=$w" --cxx-define "TB_R=$r"
}

run_one 1 1
run_one 2 2
run_one 3 2
