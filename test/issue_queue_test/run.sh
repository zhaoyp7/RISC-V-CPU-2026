#!/bin/sh
# Issue-queue behavior and independent multi-lane selection scoreboard.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

run_one() {
    w=$1
    r=$2
    python3 "$root/tools/unit/build.py" \
        --top issue_queue \
        --tb "$here/issue_queue_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/issue_queue.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" \
        --define "CPU_LSQ_DEPTH=8" \
        --define "CPU_PRF_SIZE=64" --define "CPU_ROB_DEPTH=32" \
        --cxx-define "TB_W=$w" --cxx-define "TB_R=$r"
}

run_one 1 1
run_one 2 1
run_one 2 2

run_select() {
    w=$1
    r=$2
    depth=$3
    iw=$4
    alu_only=${5:-0}
    lookahead=${6:-0}
    load_hint=${7:-0}
    python3 "$root/tools/unit/build.py" \
        --top issue_queue_select_top \
        --tb "$here/issue_queue_select_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/issue_queue.sv" \
                  "$here/issue_queue_select_top.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" \
        --define "CPU_RS_DEPTH=$depth" --define "IQ_TEST_IW=$iw" \
        --define "IQ_TEST_ALU_ONLY=$alu_only" \
        --define "IQ_TEST_LOOKAHEAD=$lookahead" \
        --define "IQ_TEST_LOAD_HINT=$load_hint" \
        --define CPU_LSQ_DEPTH=8 --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 \
        --cxx-define "TB_W=$w" --cxx-define "TB_R=$r" \
        --cxx-define "TB_D=$depth" --cxx-define "TB_IW=$iw" \
        --cxx-define "TB_ALU_ONLY=$alu_only" --cxx-define "TB_LOOKAHEAD=$lookahead"
}

run_select 2 2 8 1
run_select 1 1 8 2
run_select 2 2 8 2
run_select 2 2 6 2
run_select 2 2 16 2
run_select 1 1 8 2 1
run_select 2 2 8 2 1
run_select 2 2 6 2 1
run_select 2 2 16 2 1
run_select 1 1 8 2 1 1
run_select 2 2 8 2 1 1
run_select 2 2 6 2 1 1
run_select 2 2 16 2 1 1

# Exercise the independent load hint with the existing selection oracle.
run_select 2 2 8 2 1 1 1
run_select 2 2 16 2 1 1 1
