#!/usr/bin/env python3
"""Collect default-W2 counters through the official make perf driver."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CASES = ("median", "multiply", "qsort", "rsort", "towers", "vvadd")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/perf_stats_20261025")
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    os.chdir(ROOT)
    env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1")
    plain = ROOT / "build/main_perf_plain/sim"
    stats = ROOT / "build/main_perf_stats/sim"
    monitor = ROOT / "tools/perf_stats/monitors.sv"
    image = ROOT / "cpu2026-tools-x86_64.AppImage"
    wrapper = out / "verilator_stats.py"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport os,sys\n"
        f"image={str(image)!r}\nmonitor={str(monitor)!r}\n"
        "os.execv(image,[image,'exec','/bin/sh','-c',"
        "'exec \"$CPU2026_APPDIR/bin/verilator\" +define+LOCAL_STATS \"$@\"',"
        "'sh',*sys.argv[1:],monitor])\n"
    )
    wrapper.chmod(0o755)

    def run(command, log, extra_env=None):
        with log.open("w") as f:
            subprocess.run(command, env=dict(env, **(extra_env or {})),
                           stdout=f, stderr=subprocess.STDOUT, check=True)

    report = json.loads((ROOT / "build/synth/opt/report.json").read_text())
    for source in report["inputs"]:
        assert digest(Path(source["path"])) == source["sha256"], source["path"]
    if not args.skip_build:
        print("Building plain and instrumented simulators", flush=True)
        run(["make", "build", "BUILD=build/main_perf_plain", "JOBS=4"], out / "build-plain.log")
        run(["make", "build", "BUILD=build/main_perf_stats", "JOBS=4", "VERILATOR=" + str(wrapper)], out / "build-stats.log")
    assert plain.is_file() and stats.is_file()
    shutil.copy2(plain, out / "sim-plain")
    shutil.copy2(stats, out / "sim-stats")
    shutil.copy2(monitor, out / "monitors.sv")
    shutil.copy2(Path(__file__), out / "collect.py")
    plain, stats = out / "sim-plain", out / "sim-stats"
    for mode, sim in (("plain", plain), ("stats", stats)):
        capture = out / ("capture-" + mode + ".py")
        capture.write_text(
            "#!/usr/bin/env python3\nimport os,sys,subprocess,hashlib\nfrom pathlib import Path\n"
            f"out=Path({str(out)!r});mode={mode!r};sim={str(sim)!r}\n"
            "case=os.environ['PERF_STATS_CASE']; data=sys.stdin.buffer.read()\n"
            "assert case in " + repr(tuple("perf_" + x for x in CASES)) + "\n"
            "p=subprocess.run([sim],input=data,capture_output=True)\n"
            "(out/(case+'-'+mode+'.stdout')).write_bytes(p.stdout)\n"
            "(out/(case+'-'+mode+'.stderr')).write_bytes(p.stderr)\n"
            "(out/(case+'-'+mode+'.input.sha256')).write_text(hashlib.sha256(data).hexdigest())\n"
            "sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)\n"
        )
        capture.chmod(0o755)

    rows = []
    for suffix in CASES:
        case = "perf_" + suffix
        for mode in ("plain", "stats"):
            run(["make", "perf", "MAX_CYCLES=50000000", "LATENCY=10", "Case=" + case,
                 "SIM=" + str(out / ("capture-" + mode + ".py"))],
                out / (case + "-" + mode + ".log"), {"PERF_STATS_CASE": case})
        assert (out / (case + "-plain.stdout")).read_bytes() == (out / (case + "-stats.stdout")).read_bytes(), case
        assert (out / (case + "-plain.input.sha256")).read_text() == (out / (case + "-stats.input.sha256")).read_text(), case
        errors = [(out / (case + "-" + mode + ".stderr")).read_text() for mode in ("plain", "stats")]
        cycles = [int(re.search(r"^CPU2026 cycles=(\d+)$", text, re.M)[1]) for text in errors]
        assert cycles[0] == cycles[1], (case, cycles)
        counters = {}
        for line in errors[1].splitlines():
            match = re.search(r"\[STATS\] (\w+) (.*)", line)
            if match:
                assert match[1] not in counters, match[1]
                counters[match[1]] = {key: int(value) for key, value in re.findall(r"(\w+)=(-?\d+)", match[2])}
        required = {"FE", "BE", "ROB", "LSU", "LSQ", "IQ_EXTRA", "LSU_EXTRA", "ROB_EXTRA", "LOAD_HEAD"}
        assert required <= counters.keys(), counters.keys()
        assert len({x["cycles"] for x in counters.values()}) == 1
        assert counters["ROB"]["cycles"] == cycles[0]
        iq, ls, rb, lq = [counters[k] for k in ("IQ_EXTRA", "LSU_EXTRA", "ROB_EXTRA", "LSQ")]
        assert sum(iq[k] for k in ("empty", "wait_sources", "cancel_no_offer", "other_no_offer", "offered")) == iq["cycles"]
        assert sum(ls[k] for k in ("pending_squash", "executed", "blocked", "credits", "mem_wait", "result_wait", "other_wait", "pending_no_r")) == ls["pending"]
        assert sum(value for key, value in rb.items() if key not in ("cycles", "one_slot", "full")) == rb["cycles"]
        assert rb["one_slot"] + rb["full"] == counters["ROB"]["rob_full_cycles"]
        head = counters["LOAD_HEAD"]
        assert head["total"] == rb["load_wait"]
        assert sum(head[k] for k in ("iq_sources", "iq_ready", "pending", "memory", "result_queue", "other")) == head["total"]
        assert head["overlap"] == 0, head
        assert sum(lq[k] for k in ("unknown", "partial", "fwd", "clear")) == lq["queries"]
        assert lq["blocked"] == lq["unknown"] + lq["partial"]
        instructions = json.loads((ROOT / "testcases" / case / "metrics.json").read_text())["dynamic_instructions"]
        assert counters["ROB"]["commits"] == instructions
        row = dict(case=case, instructions=instructions, cycles=cycles[0], ipc=instructions / cycles[0], counters=counters)
        rows.append(row)
        print(f"{case}: answers/cycles identical, cycles={cycles[0]}, IPC={row['ipc']:.6f}", flush=True)

    result = dict(head=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  source_inputs=report["inputs"], monitor_sha256=digest(monitor),
                  simulators={"plain": digest(plain), "stats": digest(stats)},
                  max_cycles=50000000, latency=10, width=2, benchmarks=rows,
                  ipc_geomean=math.exp(sum(math.log(x["ipc"]) for x in rows) / len(rows)))
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"GEOMEAN {result['ipc_geomean']:.12f}; all counter partitions verified", flush=True)


if __name__ == "__main__":
    main()
