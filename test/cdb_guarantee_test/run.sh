#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
for lanes in 1 2 3; do
 for priority in 0 1; do
  python3 "$root/tools/unit/build.py" --top cdb_guarantee_top \
  --tb "$here/cdb_guarantee_tb.cpp" \
  --sources "$root/verilog/cpu_config.sv" "$root/verilog/if_defs.sv" "$root/verilog/cdb.sv" "$here/cdb_guarantee_top.sv" \
  --define CPU_PRF_SIZE=64 --define "CPU_CDB_NUM=$lanes" --define "GUARANTEE_TEST_PRIORITY=$priority" \
  --cxx-define "TB_R=$lanes"
 done
done
