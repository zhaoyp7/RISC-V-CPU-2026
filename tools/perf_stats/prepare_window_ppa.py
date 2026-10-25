#!/usr/bin/env python3
"""Prepare isolated official synthesis/W1 wrappers for measured W2 windows."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from sensitivity import CONFIGS, ROOT


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(out):
    manifest = json.loads((out / "configuration.json").read_text())
    report = json.loads((out / "diagnose/report.json").read_text())
    baseline_dir = ROOT / "build/synth/uncontended_wake_candidate/diagnose"
    baseline = json.loads((baseline_dir / "report.json").read_text())
    assert report["mode"] == "diagnose"
    assert report["inputs"] == manifest["source_inputs"] == baseline["inputs"]
    for entry in report["inputs"]:
        assert digest(Path(entry["path"])) == entry["sha256"]
    assert digest(out / "yosys.py") == manifest["yosys_wrapper_sha256"]
    assert digest(out / "verilator_w1.py") == manifest["w1_wrapper_sha256"]
    assert [e["sha256"] for e in report["libraries"]] == [e["sha256"] for e in baseline["libraries"]]
    assert report["tools"] == baseline["tools"]
    assert report["sram_model"] == baseline["sram_model"]
    assert report["abc_constraints"] == baseline["abc_constraints"]
    for filename in ("abc.constr", "constraints.sdc"):
        clean = lambda p: [s.strip() for s in p.read_text().splitlines() if s.strip() and not s.lstrip().startswith("#")]
        assert clean(out / "diagnose" / filename) == clean(baseline_dir / filename), filename
    elaboration = json.loads((out / "elaboration-verified.json").read_text())
    assert elaboration["verified"]
    definitions = manifest["defines"]
    assert elaboration["capacities"] == dict(rob=definitions.get("CPU_ROB_DEPTH", 16),
                                            rename=definitions.get("CPU_PRF_SIZE", 48),
                                            issue_queue=definitions.get("CPU_RS_DEPTH", 8),
                                            lsq=definitions.get("CPU_LSQ_DEPTH", 16))
    modules = json.loads((out / "diagnose/elaborated.json").read_text())["modules"]
    prf = next(m for n, m in modules.items() if n.endswith("\\prf"))
    assert int(prf["cells"]["regs"]["parameters"]["SIZE"], 2) == definitions["CPU_PRF_SIZE"]
    for stage in ("elaborate", "synth"):
        script = out / "diagnose" / (stage + ".with_defines.ys")
        assert script.read_text().splitlines()[0] == manifest["yosys_pre_command"]
    measured = Path(manifest["reference_perf"]).parents[1]
    w2 = json.loads((out / "w2-perf.json").read_text())
    w1 = json.loads((out / "w1-perf.json").read_text())
    assert w1["source_inputs"] == w2["source_inputs"] == report["inputs"]
    assert w1["defines"] == w2["defines"] == manifest["defines"]
    assert digest(out / "sim_w2") == w2["simulators"]["plain"]
    assert digest(out / "w1/sim") == w1["sim_sha256"]
    assert "Results: 19 passed, 0 failed" in (out / "w1-correctness.log").read_text()
    assert "Results: 19 passed, 0 failed" in (measured / "correctness.log").read_text()
    area, frequency = report["area"]["area_um2"], report["timing"]["estimated_fmax_mhz"]
    old_perf = json.loads((ROOT / "build/uncontended_wake_stats/results.json").read_text())
    assert old_perf["source_inputs"] == baseline["inputs"]
    assert old_perf["width"] == 2 and old_perf["latency"] == 10
    ipc, old_ipc = w2["ipc_geomean"], old_perf["ipc_geomean"]
    old_area, old_frequency = baseline["area"]["area_um2"], baseline["timing"]["estimated_fmax_mhz"]
    result = dict(config=manifest["config"], defines=manifest["defines"], ipc_w2=ipc,
                  ipc_w1=w1["ipc_geomean"], area_um2=area, fmax_mhz=frequency,
                  ipc_change_pct=100 * (ipc / old_ipc - 1),
                  area_change_pct=100 * (area / old_area - 1),
                  frequency_change_pct=100 * (frequency / old_frequency - 1),
                  ipc_frequency_change_pct=100 * (ipc * frequency / (old_ipc * old_frequency) - 1),
                  source_hashes_verified=len(report["inputs"]), library_hashes_verified=len(report["libraries"]),
                  tools_and_constraints_match=True, correctness_w1="19/19", correctness_w2="19/19",
                  elapsed_seconds=(out / "diagnose/report.json").stat().st_mtime - (out / "diagnose/elaborate.with_defines.ys").stat().st_mtime)
    path = json.loads((out / "diagnose/critical_paths.json").read_text())["checks"][0]
    result["critical_path"] = dict(startpoint=path["startpoint"], endpoint=path["endpoint"],
                                   d_arrival_ns=path["source_path"][-1]["arrival"] * 1e9,
                                   boundaries=[dict(pins=p["hier_pins"], arrival_ns=p["arrival"] * 1e9)
                                               for p in path["source_path"] if p.get("hier_pins")])
    shutil.copy2(measured / "correctness.log", out / "w2-correctness.log")
    (out / "comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("config", choices=("rob32_prf64", "rob32_lsq32", "window32"))
    ap.add_argument("--verify", action="store_true", help="verify completed PPA against its explicit macro manifest")
    args = ap.parse_args()
    name = args.config
    definitions = CONFIGS[name]
    out = ROOT / "build/synth" / ("ipc_" + name)
    if args.verify:
        verify(out)
        return
    out.mkdir(parents=True, exist_ok=True)
    assert not (out / "diagnose/report.json").exists(), "preserve the completed report"
    measured = ROOT / "build/ipc_sensitivity_20261025" / name
    data = json.loads((measured / "latency10/results.json").read_text())
    assert data["defines"] == definitions
    for entry in data["source_inputs"]:
        src = Path(entry["path"])
        assert digest(src) == entry["sha256"], src
        dst = out / "inputs" / src.relative_to(ROOT)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    for mode in ("plain", "stats"):
        assert digest(measured / mode / "sim") == data["simulators"][mode]
    shutil.copy2(measured / "plain/sim", out / "sim_w2")
    shutil.copy2(measured / "latency10/results.json", out / "w2-perf.json")
    command = "verilog_defines " + " ".join(f"-D{k}={v}" for k, v in definitions.items())
    wrapper = out / "yosys.py"
    wrapper.write_text(
        "#!/usr/bin/env python3\nimport os,sys,json,subprocess\nfrom pathlib import Path\n"
        f"real={str(ROOT / 'tools/yosys-wrap.sh')!r}\ncommand={command!r}\n"
        f"trace=Path({str(out / 'yosys-invocations.jsonl')!r})\n"
        f"expected={dict(rob=definitions.get('CPU_ROB_DEPTH', 16), rename=definitions.get('CPU_PRF_SIZE', 48), issue_queue=definitions.get('CPU_RS_DEPTH', 8), lsq=definitions.get('CPU_LSQ_DEPTH', 16))!r}\n"
        "args=sys.argv[1:]\n"
        "if '-s' in args:\n"
        "    index=args.index('-s')+1\n"
        "    original=Path(args[index]); injected=original.with_suffix('.with_defines.ys')\n"
        "    injected.write_text(command+'\\n'+original.read_text())\n"
        "    args[index]=str(injected)\n"
        "    with trace.open('a') as f: f.write(json.dumps({'pre_command':command,'args':args})+'\\n')\n"
        "    subprocess.run([real,*args],check=True)\n"
        "    if original.stem=='elaborate':\n"
        "        modules=json.loads((original.parent/'elaborated.json').read_text())['modules']\n"
        "        fields={'rob':'entry_valid','rename':'free_vec','issue_queue':'valid','lsq':'valid'}\n"
        "        for kind,size in expected.items():\n"
        "            field=fields[kind]\n"
        "            hits=[len(m['netnames'][field]['bits']) for n,m in modules.items() if ('\\\\'+kind+'\\\\' in n or n.endswith('\\\\'+kind)) and field in m.get('netnames',{})]\n"
        "            assert hits==[size],(kind,size,hits)\n"
        "        (trace.parent/'elaboration-verified.json').write_text(json.dumps({'capacities':expected,'verified':True},indent=2)+'\\n')\n"
        "    sys.exit(0)\n"
        "os.execv(real,[real,*args])\n"
    )
    wrapper.chmod(0o755)
    w1_wrapper = out / "verilator_w1.py"
    flags = ["+define+CPU_ISSUE_WIDTH=1", *[f"+define+{k}={v}" for k, v in definitions.items()]]
    w1_wrapper.write_text(
        "#!/usr/bin/env python3\nimport os,sys\n"
        f"image={str(ROOT / 'cpu2026-tools-x86_64.AppImage')!r}\nflags={flags!r}\n"
        "os.execv(image,[image,'exec','/bin/sh','-c',"
        "'exec \"$CPU2026_APPDIR/bin/verilator\" \"$@\"','sh',*flags,*sys.argv[1:]])\n"
    )
    w1_wrapper.chmod(0o755)
    manifest = dict(config=name, defines=definitions, width=2,
                    source_inputs=data["source_inputs"],
                    head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    reference_perf=str(measured / "latency10/results.json"),
                    ipc_w2=data["ipc_geomean"], yosys_pre_command=command,
                    yosys_wrapper_sha256=digest(wrapper), w1_wrapper_sha256=digest(w1_wrapper),
                    mode="diagnose", clock_period_ns=2.0,
                    abc_driving_cell="INVx1_ASAP7_75t_R", abc_load_ff=5.0)
    (out / "configuration.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
