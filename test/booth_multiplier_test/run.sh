#!/bin/sh
# Independent 64-bit product reference, all operand signedness combinations.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
python3 "$root/tools/unit/build.py" --top mul_booth_wallace \
 --tb "$here/booth_multiplier_tb.cpp" \
 --sources "$root/verilog/rv32_defs.sv" "$root/verilog/alu.sv"
