#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
python3 "$root/tools/unit/build.py" --top if_line_mem_top \
 --tb "$root/test/mem_subsystem_test/mem_subsystem_tb.cpp" \
 --sources "$root/verilog/cpu_config.sv" "$root/verilog/axi_mem_if.sv" \
           "$root/verilog/mem_subsystem.sv" "$root/scripts/ram/sram_fakeram.sv" \
           "$here/if_line_mem_top.sv" --cxx-define TB_IF_LINE_BUFFER=1 "$@"

python3 "$root/tools/unit/build.py" --top line_queue_top \
 --tb "$root/test/line_cache_test/line_cache_tb.cpp" \
 --sources "$root/verilog/mem_subsystem.sv" "$root/scripts/ram/sram_fakeram.sv" \
           "$here/line_queue_top.sv" --cxx-define TB_LINE_QUEUE_TWO=1 "$@"
