#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for w in 1 2; do
    python3 "$root/tools/unit/build.py" --top frontend_ooo \
        --tb "$here/bpu_training_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/icache_pipe.sv" \
                  "$root/verilog/decoder.sv" "$root/verilog/bpu.sv" \
                  "$root/verilog/frontend_ooo.sv" "$root/scripts/ram/sram_fakeram.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define CPU_ICACHE_INDEX_BITS=4 \
        --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 --define CPU_LSQ_DEPTH=8 \
        --cxx-define "TB_W=$w" "$@"
done
