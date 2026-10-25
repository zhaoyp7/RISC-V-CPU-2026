#!/bin/sh
# Run the existing LSU matrix plus cache protocol checks with explicit small caches.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
sh "$root/test/lsu_test/run.sh" \
    --out "$root/build/unit/lsu_cache" \
    --define CPU_DCACHE_ENABLE=1 --define CPU_DCACHE_INDEX_BITS=3 \
    --define CPU_DCACHE_WAYS=2 --define CPU_DCACHE_LINE_BYTES=4 \
    --cxx-define TB_READ_CACHE=1 --cxx-define TB_DCACHE_INDEX_BITS=3 \
    --cxx-define TB_DCACHE_WAYS=2 "$@"
