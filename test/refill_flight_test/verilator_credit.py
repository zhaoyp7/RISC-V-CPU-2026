#!/usr/bin/env python3
import os,sys
from pathlib import Path
image=str(Path(__file__).resolve().parents[2]/'cpu2026-tools-x86_64.AppImage')
os.execv(image,[image,'exec','/bin/sh','-c','exec "$CPU2026_APPDIR/bin/verilator" "$@"','sh','-GQDEPTH=16','-GWRITE_DEPTH=8',*sys.argv[1:]])
