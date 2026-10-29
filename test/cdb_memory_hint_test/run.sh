#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
python3 "$root/tools/unit/build.py" \
    --top cdb_memory_hint_universal \
    --out "$root/build/unit/cdb_memory_hint" \
    --tb "$here/universal_hint_tb.cpp" \
    --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
              "$root/verilog/if_defs.sv" "$root/verilog/backend_ooo.sv"
