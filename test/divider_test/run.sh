#!/bin/sh
# -----------------------------------------------------------------------------
# run.sh — 编译并运行 divider 的 Verilator 单元测试
#
#   sh test/divider_test/run.sh [--quick] [--no-boundary]
#
# 环境变量：
#   VERILATOR    指定 verilator 可执行文件（默认从 PATH 找）
#   DIVIDER_SRC  指定被测的 divider.sv（默认 <repo>/verilog/divider.sv）
# -----------------------------------------------------------------------------
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
vlt=${VERILATOR:-verilator}
src=${DIVIDER_SRC:-"$root/verilog/divider.sv"}
out="$here/build"

if ! command -v "$vlt" >/dev/null 2>&1; then
    echo "error: verilator not found ($vlt)" >&2
    echo 'hint: export PATH="$HOME/.local/bin:$PATH"   # 本机无 sudo 安装的 Verilator' >&2
    echo "hint: or VERILATOR=/path/to/verilator $0 $*" >&2
    exit 2
fi
if [ ! -f "$src" ]; then
    echo "error: divider source not found: $src" >&2
    exit 2
fi

mkdir -p "$out"
"$vlt" --cc --exe --build -Wall -Wno-fatal --assert \
    --top-module divider -Mdir "$out" "$src" "$here/divider_tb.cpp" \
    -CFLAGS -std=c++17 -o tb

exec "$out/tb" "$@"
