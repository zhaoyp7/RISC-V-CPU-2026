#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
run_lsq() {
 w=$1
 depth=$2
 ordered=${3:-1}
 python3 "$root/tools/unit/build.py" --top store_capture_lsq_top \
  --tb "$here/store_capture_lsq_tb.cpp" \
  --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
            "$root/verilog/if_defs.sv" "$root/verilog/lsq.sv" "$here/store_capture_lsq_top.sv" \
  --define "CPU_ISSUE_WIDTH=$w" --define CPU_CDB_NUM=2 --define "CPU_LSQ_DEPTH=$depth" \
  --define CPU_PRF_SIZE=64 --define CPU_ROB_DEPTH=32 --define "STORE_TEST_ORDERED=$ordered" \
  --cxx-define "TB_W=$w" --cxx-define "TB_DEPTH=$depth"
}
run_lsq 1 8
run_lsq 1 16
run_lsq 2 16
run_lsq 1 32
run_lsq 2 32
run_lsq 2 16 0
for w in 1 2; do
 python3 "$root/tools/unit/build.py" --top store_capture_backend_top \
  --tb "$root/test/backend_test/backend_tb.cpp" \
  --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
            "$root/verilog/if_defs.sv" "$root/verilog/alu.sv" "$root/verilog/divider.sv" \
            "$root/verilog/prf.sv" "$root/verilog/cdb.sv" "$root/verilog/issue_queue.sv" \
            "$root/verilog/lsq.sv" "$root/verilog/lsu.sv" "$root/verilog/backend_ooo.sv" \
            "$here/store_capture_backend_top.sv" \
  --define "CPU_ISSUE_WIDTH=$w" --define CPU_LSQ_DEPTH=8 --define CPU_PRF_SIZE=64 \
  --define CPU_ROB_DEPTH=32 --cxx-define "TB_W=$w" --cxx-define TB_STORE_CAPTURE=1 --cxx-define TB_DISPATCH_BYPASS=1
done
