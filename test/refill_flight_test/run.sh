#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for bits in 4 9; do
 python3 "$root/tools/unit/build.py" --top line_flight16_top \
  --tb "$root/test/line_cache_test/line_cache_tb.cpp" \
  --sources "$root/verilog/cpu_config.sv" "$root/verilog/mem_subsystem.sv" \
   "$root/scripts/ram/sram_fakeram.sv" "$here/line_flight16_top.sv" \
  --define CPU_LINE_CACHE_INDEX_BITS="$bits" --cxx-define TB_LINE_FLIGHT_SIXTEEN=1 "$@"
done
sh "$root/test/if_line_buffer_test/run.sh" --define IF_LINE_RAW_QUEUE=16 --define IF_LINE_WRITE_QUEUE=8 "$@"
python3 "$root/tools/unit/build.py" --top axi_mem_if \
 --tb "$here/axi_credit_tb.cpp" --sources "$root/verilog/axi_mem_if.sv" \
 --verilator "$here/verilator_credit.py" "$@"
