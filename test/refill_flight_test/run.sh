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
sh "$root/test/if_line_buffer_test/run.sh" --define IF_LINE_RAW_QUEUE=16 --define IF_LINE_WRITE_QUEUE=8 --define IF_LINE_READ_ADDRESS_SLOTS=2 --define IF_LINE_WRITE_ADDRESS_SLOTS=2 "$@"
for compact in 0 1; do
 if [ "$compact" -eq 1 ]; then rslots=2; wslots=2; else rslots=16; wslots=8; fi
 AXI_TEST_COMPACT="$compact" python3 "$root/tools/unit/build.py" --top axi_mem_if \
  --tb "$here/axi_credit_tb.cpp" --sources "$root/verilog/axi_mem_if.sv" \
  --out "$root/build/unit/axi_credit_$compact" --verilator "$here/verilator_credit.py" \
  --cxx-define TB_READ_ADDRESS_SLOTS="$rslots" --cxx-define TB_WRITE_ADDRESS_SLOTS="$wslots" "$@"
done
