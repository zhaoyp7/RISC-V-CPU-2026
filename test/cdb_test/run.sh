#!/bin/sh
# CDB arbitration test: W=1/2 crossed with R=1/2.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)

priority_verilator="$root/build/unit/cdb-priority-verilator.py"
python3 - "$root" "$priority_verilator" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=Path(sys.argv[2]);p.parent.mkdir(parents=True,exist_ok=True)
p.write_text('#!/usr/bin/env python3\nimport os,sys\nimage='+repr(str(r/'cpu2026-tools-x86_64.AppImage'))+'\nos.execv(image,[image,"exec","/bin/sh","-c",\'exec "$CPU2026_APPDIR/bin/verilator" "$@"\',"sh","-GPRIORITY_ALU0=1",*sys.argv[1:],"--verilate-jobs","1","--build-jobs","1"])\n');p.chmod(0o755)
PY

run_one() {
    w=$1
    r=$2
    priority=${3:-0}
    if [ "$priority" -eq 1 ]; then
        set -- --verilator "$priority_verilator"
    else
        set --
    fi
    python3 "$root/tools/unit/build.py" \
        --top cdb \
        --tb "$here/cdb_tb.cpp" \
        --sources "$root/verilog/rv32_defs.sv" "$root/verilog/cpu_config.sv" \
                  "$root/verilog/if_defs.sv" "$root/verilog/cdb.sv" \
        --define "CPU_ISSUE_WIDTH=$w" --define "CPU_CDB_NUM=$r" \
        --cxx-define "TB_W=$w" --cxx-define "TB_R=$r" \
        --cxx-define "TB_PRIORITY_ALU0=$priority" "$@"
}

run_one 1 1
run_one 2 2
run_one 1 2
run_one 2 1
run_one 2 2 1
run_one 1 2 1
run_one 2 1 1
