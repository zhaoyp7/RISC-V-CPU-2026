"""Discard regenerable Verilator headers after the owning build has finished."""
from __future__ import annotations

from pathlib import Path
import re
import stat


PCH_NAME = re.compile(r"V.+__pch\.h\.(?:fast|slow)\.gch\Z")


def prune_verilator_pch(objects: Path) -> tuple[int, int]:
    """Remove only regular generated PCH files directly in this object directory.

    The caller must have waited for its compiler to exit.  Do not walk other
    build directories: another build may still be using its own PCH files.
    Sources, object files, archives and the linked simulator are retained.
    """
    if objects.is_symlink() or not objects.is_dir():
        return 0, 0
    count = removed_bytes = 0
    for path in objects.iterdir():
        if not PCH_NAME.fullmatch(path.name):
            continue
        entry = path.lstat()
        if not stat.S_ISREG(entry.st_mode):
            continue
        path.unlink()
        count += 1
        removed_bytes += entry.st_size
    return count, removed_bytes
