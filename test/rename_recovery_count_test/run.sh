#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for prf in 33 48 56 64 96; do
 python3 "$root/tools/unit/build.py" --top recovery_count_top \
  --tb "$here/recovery_count_tb.cpp" --out "$root/build/unit/recovery_count_p$prf" \
  --sources "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" \
            "$root/verilog/rename.sv" "$here/recovery_count_top.sv" \
  --define "CPU_PRF_SIZE=$prf" --define CPU_ROB_DEPTH=32 --define CPU_LSQ_DEPTH=8 \
  --cxx-define "TB_PRF=$prf"
done
