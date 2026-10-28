#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for bits in 4 8 10; do
 python3 "$root/tools/unit/build.py" --top icache_hit_bypass_top \
 --tb "$here/icache_hit_tb.cpp" \
 --sources "$root/verilog/cpu_config.sv" "$root/verilog/icache_pipe.sv" \
 "$root/scripts/ram/sram_fakeram.sv" "$here/icache_hit_bypass_top.sv" \
 --define "CPU_ICACHE_INDEX_BITS=$bits" --cxx-define "TB_INDEX_BITS=$bits"
done
