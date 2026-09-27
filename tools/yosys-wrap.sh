#!/bin/sh
# Workaround: Yosys 0.63's JSON writer encodes non-ASCII bytes in `src` paths
# as broken escapes like \uFFFFFFE5 (8 hex digits, char sign-extended). Python
# json.loads parses those as U+FFFF + literal "FFE5", and json.dumps then
# re-emits \uffffFFE5, which Yosys's own JSON reader rejects:
#   ERROR: Unsupported \uXXXX sequence in JSON string: FFFF.
# This wrapper runs the real Yosys and, after each successful run, sanitizes
# the files written by `write_json` in the script, replacing the broken escape
# sequences with "_". Only source-path strings are affected; module names and
# netlist structure are untouched.
set -eu

if [ -n "${CPU2026_APPDIR:-}" ]; then
    real="$CPU2026_APPDIR/bin/yosys"
else
    real=$(command -v yosys)
fi

script=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-s" ]; then
        script="$arg"
    fi
    prev="$arg"
done

"$real" "$@"
status=$?

if [ "$status" -eq 0 ] && [ -n "$script" ] && [ -f "$script" ]; then
    grep -o 'write_json "[^"]*"' "$script" 2>/dev/null \
        | sed 's/^write_json "//; s/"$//' \
        | while IFS= read -r out; do
            if [ -f "$out" ]; then
                sed -i 's/\\uFFFFFF[0-9A-Fa-f]\{2\}/_/g' "$out"
            fi
        done
fi

exit "$status"
