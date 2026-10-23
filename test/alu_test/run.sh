#!/bin/sh
# Arithmetic reference checks with and without legacy combinational division.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for enable_div in 0 1; do
    python3 "$root/tools/unit/build.py" \
        --top alu_test_top --tb "$here/alu_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/alu.sv" \
                  "$here/alu_test_top.sv" \
        --define "ALU_TEST_ENABLE_DIV=$enable_div" \
        --cxx-define "TB_ENABLE_DIV=$enable_div"
done
