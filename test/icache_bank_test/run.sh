#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for bits in 4 8; do
    out="$root/build/unit/icache_banked_$bits"
    python3 "$root/tools/unit/build.py" --top icache_banked_top \
        --tb "$here/icache_bank_tb.cpp" \
        --sources "$root/verilog/cpu_config.sv" "$root/verilog/icache_pipe.sv" \
                  "$root/scripts/ram/sram_fakeram.sv" "$here/icache_banked_top.sv" \
        --define "ICACHE_BANK_TEST_BITS=$bits" --cxx-define "TB_INDEX_BITS=$bits" \
        --out "$out" --no-run
    "$out/tb" 0
    "$out/tb" 1
done
for w in 1 2; do
    python3 "$root/tools/unit/build.py" --top frontend_banked_top \
        --tb "$root/test/bpu_training_test/bpu_training_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/icache_pipe.sv" \
                  "$root/verilog/decoder.sv" "$root/verilog/bpu.sv" \
                  "$root/verilog/frontend_ooo.sv" "$root/scripts/ram/sram_fakeram.sv" \
                  "$here/frontend_banked_top.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define CPU_ICACHE_INDEX_BITS=4 \
        --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 --define CPU_LSQ_DEPTH=8 \
        --cxx-define "TB_W=$w" --cxx-define TB_WORD_BANKING=1
done
