#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for w in 1 2 3; do
 r=2
 if [ "$w" -eq 1 ]; then r=1; fi
 python3 "$root/tools/unit/build.py" --top prf_masked_test_top \
  --tb "$here/prf_masked_tb.cpp" --out "$root/build/unit/prf_masked_w$w" \
  --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
            "$root/verilog/prf.sv" "$here/prf_masked_test_top.sv" \
  --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" --define CPU_PRF_SIZE=64 \
  --cxx-define "TB_W=$w" --cxx-define "TB_R=$r"
done
