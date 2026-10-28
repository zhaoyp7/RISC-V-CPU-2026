#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for w in 1 2; do
 python3 "$root/tools/unit/build.py" --top store_capture_backend_top --out "$root/build/unit/execution_hint_w$w" \
  --tb "$root/test/backend_test/backend_tb.cpp" \
  --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
            "$root/verilog/if_defs.sv" "$root/verilog/alu.sv" "$root/verilog/divider.sv" \
            "$root/verilog/prf.sv" "$root/verilog/cdb.sv" "$root/verilog/issue_queue.sv" \
            "$root/verilog/lsq.sv" "$root/verilog/lsu.sv" "$root/verilog/backend_ooo.sv" \
            "$root/test/store_capture_test/store_capture_backend_top.sv" \
  --define EXECUTION_HINT_TEST=1 --define CPU_RS_DEPTH=8 --define "CPU_ISSUE_WIDTH=$w" --define CPU_LSQ_DEPTH=8 --define CPU_PRF_SIZE=64 \
  --define CPU_ROB_DEPTH=32 --cxx-define TB_EXECUTION_HINT=1 --cxx-define "TB_W=$w" --cxx-define TB_STORE_CAPTURE=1 --cxx-define TB_MEMORY_HINT=1 --cxx-define TB_DISPATCH_BYPASS=1 --cxx-define TB_DISPATCH_COMPUTE_HINT=1 --cxx-define TB_CONTROL_BYPASS=1
done
