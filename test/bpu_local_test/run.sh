#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for history in 1 3; do
 BPU_TEST_HISTORY="$history" python3 "$root/tools/unit/build.py" --top bpu \
 --tb "$here/bpu_local_tb.cpp" --sources "$root/verilog/cpu_config.sv" "$root/verilog/bpu.sv" \
 --out "$root/build/unit/bpu_local_$history" --verilator "$here/verilator.py" \
 --define CPU_BTB_INDEX_BITS=5 --cxx-define TB_HISTORY="$history" "$@"
done
