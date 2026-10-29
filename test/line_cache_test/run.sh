#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
exec python3 "$root/tools/unit/build.py" --top load_line_cache \
 --tb "$here/line_cache_tb.cpp" \
 --sources "$root/verilog/mem_subsystem.sv" "$root/scripts/ram/sram_fakeram.sv" "$@"
