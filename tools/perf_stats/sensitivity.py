#!/usr/bin/env python3
"""Simulation-only latency/window study; never changes the default configuration.

Uses official make build/test/perf, isolated macro wrappers, and the existing
input-only monitors. Every perf point compares plain/stats inputs and cycles.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CASES = ("median", "multiply", "qsort", "rsort", "towers", "vvadd")
CONFIGS = {
    "baseline": {},
    "prf64": {"CPU_PRF_SIZE": 64},
    "rob32_prf64": {"CPU_PRF_SIZE": 64, "CPU_ROB_DEPTH": 32},
    "iq16": {"CPU_RS_DEPTH": 16},
    "lsq32": {"CPU_LSQ_DEPTH": 32},
    "window32": {"CPU_PRF_SIZE": 64, "CPU_ROB_DEPTH": 32,
                 "CPU_RS_DEPTH": 16, "CPU_LSQ_DEPTH": 32},
    "rob32_iq16": {"CPU_PRF_SIZE": 64, "CPU_ROB_DEPTH": 32, "CPU_RS_DEPTH": 16},
    "rob32_lsq32": {"CPU_PRF_SIZE": 64, "CPU_ROB_DEPTH": 32, "CPU_LSQ_DEPTH": 32},
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_counters(c, cycles, instructions):
    assert len({x["cycles"] for x in c.values()}) == 1
    assert c["ROB"]["cycles"] == cycles
    assert c["ROB"]["commits"] == instructions
    iq, ls, rb, lq = [c[k] for k in ("IQ_EXTRA", "LSU_EXTRA", "ROB_EXTRA", "LSQ")]
    assert sum(iq[k] for k in ("empty", "wait_sources", "cancel_no_offer", "other_no_offer", "offered")) == cycles
    assert sum(ls[k] for k in ("pending_squash", "executed", "blocked", "credits", "mem_wait", "result_wait", "other_wait", "pending_no_r")) == ls["pending"]
    assert sum(v for k, v in rb.items() if k not in ("cycles", "one_slot", "full")) == cycles
    assert rb["one_slot"] + rb["full"] == c["ROB"]["rob_full_cycles"]
    head = c["LOAD_HEAD"]
    assert head["total"] == rb["load_wait"]
    assert sum(head[k] for k in ("iq_sources", "iq_ready", "pending", "memory", "result_queue", "other")) == head["total"]
    assert head["overlap"] == 0
    assert sum(lq[k] for k in ("unknown", "partial", "fwd", "clear")) == lq["queries"]
    assert lq["blocked"] == lq["unknown"] + lq["partial"]
    safe = c["SAFE_WAKE"]
    assert safe["missing_grant"] == 0
    assert safe["actual_early"] <= safe["can_accept"] <= safe["opportunity"] <= safe["hints"] <= cycles


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=ROOT / "build/ipc_sensitivity_20261025")
    ap.add_argument("--phase", choices=("latency", "windows"), required=True)
    ap.add_argument("--configs", nargs="+", choices=tuple(CONFIGS),
                    help="optional subset for the windows phase")
    args = ap.parse_args()
    if args.phase == "latency" and args.configs:
        ap.error("--configs is only used for the windows phase")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    os.chdir(ROOT)
    env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1")
    report_path = ROOT / "build/synth/uncontended_wake_candidate/diagnose/report.json"
    report = json.loads(report_path.read_text())
    for source in report["inputs"]:
        assert digest(Path(source["path"])) == source["sha256"], source["path"]
    protected = [ROOT / p for p in ("Makefile", "config.mk", "verilog/filelist.f")]
    protected += sorted((ROOT / "scripts").rglob("*.py"))
    protected += sorted((ROOT / "scripts").rglob("*.cpp"))
    protected += [ROOT / "scripts/ram/sram_fakeram.sv"]
    protected_hashes = {str(p): digest(p) for p in protected}
    snapshot = out / "source-inputs.json"
    if snapshot.exists():
        assert json.loads(snapshot.read_text()) == report["inputs"]
    snapshot.write_text(json.dumps(report["inputs"], indent=2) + "\n")
    monitor = ROOT / "tools/perf_stats/monitors.sv"
    shutil.copy2(monitor, out / "monitors.sv")
    shutil.copy2(Path(__file__), out / "sensitivity.py")

    def note(message):
        line = time.strftime("%H:%M:%S ") + message
        print(line, flush=True)
        with (out / "progress.log").open("a") as f:
            f.write(line + "\n")

    def run(command, log, extra=None):
        with log.open("w") as f:
            p = subprocess.run(command, env=dict(env, **(extra or {})), stdout=f, stderr=subprocess.STDOUT)
        if p.returncode:
            note("FAILED " + str(log))
            raise RuntimeError(f"exit {p.returncode}: {command}; see {log}")

    def build(name, definitions, stats):
        mode = "stats" if stats else "plain"
        directory = out / name / mode
        directory.mkdir(parents=True, exist_ok=True)
        flags = [f"+define+{k}={v}" for k, v in definitions.items()]
        if stats:
            flags.append("+define+LOCAL_STATS")
        wrapper = directory / "verilator.py"
        wrapper.write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            f"image={str(ROOT / 'cpu2026-tools-x86_64.AppImage')!r}\n"
            f"flags={flags!r}\nextra={[str(monitor)] if stats else []!r}\n"
            "os.execv(image,[image,'exec','/bin/sh','-c',"
            "'exec \"$CPU2026_APPDIR/bin/verilator\" \"$@\"','sh',*flags,*sys.argv[1:],*extra])\n"
        )
        wrapper.chmod(0o755)
        note("BUILD " + name + " " + mode)
        run(["make", "build", "BUILD=" + str(directory), "JOBS=4", "VERILATOR=" + str(wrapper)], directory / "build.log")
        return directory / "sim"

    def measure(name, plain, stats, latency):
        point = out / name / ("latency" + str(latency))
        point.mkdir(parents=True, exist_ok=True)
        rows = []
        for suffix in CASES:
            case = "perf_" + suffix
            errors = []
            for mode, sim in (("plain", plain), ("stats", stats)):
                capture = point / (case + "-" + mode + ".py")
                prefix = str(point / (case + "-" + mode))
                capture.write_text(
                    "#!/usr/bin/env python3\nimport sys,subprocess,hashlib\nfrom pathlib import Path\n"
                    f"sim={str(sim)!r}; prefix={prefix!r}\n"
                    "data=sys.stdin.buffer.read()\np=subprocess.run([sim],input=data,capture_output=True)\n"
                    "Path(prefix+'.stdout').write_bytes(p.stdout)\nPath(prefix+'.stderr').write_bytes(p.stderr)\n"
                    "Path(prefix+'.input.sha256').write_text(hashlib.sha256(data).hexdigest())\n"
                    "sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)\n"
                )
                capture.chmod(0o755)
                run(["make", "perf", "MAX_CYCLES=50000000", "LATENCY=" + str(latency),
                     "Case=" + case, "SIM=" + str(capture)], point / (case + "-" + mode + ".log"))
                errors.append((point / (case + "-" + mode + ".stderr")).read_text())
            for extension in ("stdout", "input.sha256"):
                assert (point / (case + "-plain." + extension)).read_bytes() == (point / (case + "-stats." + extension)).read_bytes()
            cycles = [int(re.search(r"^CPU2026 cycles=(\d+)$", e, re.M)[1]) for e in errors]
            assert cycles[0] == cycles[1], (name, case, latency, cycles)
            counters = {}
            for line in errors[1].splitlines():
                match = re.search(r"\[STATS\] (\w+) (.*)", line)
                if match:
                    assert match[1] not in counters
                    counters[match[1]] = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", match[2])}
            instructions = json.loads((ROOT / "testcases" / case / "metrics.json").read_text())["dynamic_instructions"]
            check_counters(counters, cycles[0], instructions)
            rows.append(dict(case=case, instructions=instructions, cycles=cycles[0], ipc=instructions / cycles[0], counters=counters))
        result = dict(config=name, defines=CONFIGS[name], latency=latency, width=2,
                      latency_scope="shared instruction/data AXI reads and writes; not a D-cache model",
                      benchmarks=rows, ipc_geomean=math.exp(sum(math.log(r["ipc"]) for r in rows) / len(rows)),
                      simulators={"plain": digest(plain), "stats": digest(stats)},
                      source_inputs=report["inputs"], monitor_sha256=digest(monitor),
                      head=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip())
        (point / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        note(f"PASS {name} LATENCY={latency} IPC={result['ipc_geomean']:.12f}; 6 answers/cycles/counters checked")

    if args.phase == "latency":
        plain = ROOT / "build/uncontended_wake_w2/sim"
        stats = ROOT / "build/uncontended_wake_stats/sim-stats"
        old = json.loads((ROOT / "build/uncontended_wake_stats/results.json").read_text())
        assert digest(plain) == old["simulators"]["plain"]
        assert digest(stats) == old["simulators"]["stats"]
        assert digest(monitor) == old["monitor_sha256"]
        assert old["source_inputs"] == report["inputs"]
        for latency in (1, 3, 5, 10, 20):
            measure("baseline", plain, stats, latency)
    else:
        for name, definitions in CONFIGS.items():
            if name == "baseline" or (args.configs and name not in args.configs):
                continue
            plain = build(name, definitions, False)
            for case in ("qsort", "hanoi", "queens"):
                run(["make", "test", "MAX_CYCLES=50000000", "SIM=" + str(plain), "Case=correctness_" + case],
                    out / name / ("smoke-" + case + ".log"))
            run(["make", "test", "MAX_CYCLES=50000000", "SIM=" + str(plain)], out / name / "correctness.log")
            note("PASS " + name + " smoke + official correctness")
            stats = build(name, definitions, True)
            for latency in (1, 10, 20):
                measure(name, plain, stats, latency)

    for source in report["inputs"]:
        assert digest(Path(source["path"])) == source["sha256"]
    assert {str(p): digest(p) for p in protected} == protected_hashes
    run(["python3", "tools/config_gen.py", "--check"], out / (args.phase + "-config.log"))
    note("DONE " + args.phase + "; production/default/scripts hashes unchanged; no synthesis")


if __name__ == "__main__":
    main()
