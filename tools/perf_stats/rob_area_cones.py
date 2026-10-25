#!/usr/bin/env python3
"""Measure mapped ROB combinational cones; shared cone area is not additive."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    report = json.loads(args.report.read_text())
    design_path = args.report.parent / "design.json"
    modules = json.loads(design_path.read_text())["modules"]
    top = modules["student_top"]
    core = modules[top["cells"]["u_core"]["type"]]
    rob = modules[core["cells"]["u_rob"]["type"]]
    cells = rob["cells"]

    def area(kind):
        m = modules[kind]
        if "area" in m.get("attributes", {}):
            return float(m["attributes"]["area"])
        return sum(area(c["type"]) for c in m.get("cells", {}).values())

    weights = {n: area(c["type"]) for n, c in cells.items()}
    sequential = {n for n, c in cells.items() if "DFF" in c["type"] or "LATCH" in c["type"]}
    inputs, drivers = {}, {}
    for n, c in cells.items():
        inputs[n] = [b for p, bits in c["connections"].items()
                     if c["port_directions"][p] == "input" for b in bits if isinstance(b, int)]
        for p, bits in c["connections"].items():
            if c["port_directions"][p] == "output":
                for b in bits:
                    if isinstance(b, int):
                        assert b not in drivers, (n, b)
                        drivers[b] = n

    def cone(bits):
        pending, found = list(bits), set()
        while pending:
            n = drivers.get(pending.pop())
            if n is None or n in sequential or n in found:
                continue
            found.add(n)
            pending.extend(inputs[n])
        return found

    def output_registers(port):
        found, pending, seen = set(), list(rob["ports"][port]["bits"]), set()
        while pending:
            b = pending.pop()
            n = drivers.get(b)
            if n is None or n in seen:
                continue
            seen.add(n)
            if n in sequential:
                found.add(n)
            else:
                assert len(inputs[n]) == 1, (port, n, cells[n]["type"])
                pending.extend(inputs[n])
        return found

    registers = {
        "recover_rat": output_registers("recover_rat"),
        "recover_masks": output_registers("recover_free_mask") | output_registers("recover_busy_mask"),
        "recover_lsq_ptr": output_registers("recover_lsq_ptr"),
        "recovery_control": output_registers("recover_valid") | output_registers("squash_valid") | output_registers("squash_rob_idx"),
    }
    assigned = set().union(*registers.values())
    registers["other_state_updates"] = sequential - assigned
    groups = {g: cone([b for n in ns for b in cells[n]["connections"].get("D", [])])
              for g, ns in registers.items()}
    reg_ports = {"recover_rat", "recover_free_mask", "recover_busy_mask", "recover_lsq_ptr",
                 "recover_valid", "squash_valid", "squash_rob_idx"}
    groups["comb_outputs"] = cone([b for n, p in rob["ports"].items()
                                   if p["direction"] == "output" and n not in reg_ports for b in p["bits"]])
    membership = {n: tuple(g for g, ns in groups.items() if n in ns) for n in cells if n not in sequential}
    shared = Counter()
    for n, gs in membership.items():
        shared[" + ".join(gs) if gs else "uncovered"] += weights[n]
    rows = []
    for g, ns in groups.items():
        rows.append(dict(group=g,cone_area_um2=sum(weights[n] for n in ns),
                         exclusive_area_um2=sum(weights[n] for n in ns if len(membership[n]) == 1),
                         cells=len(ns),receiver_registers=len(registers.get(g, set()))))
    direct = sum(weights.values())
    seq = sum(weights[n] for n in sequential)
    rob_tree = next(c for c in report["area"]["module_tree"]["children"] if c["instance"].endswith("/u_core"))
    rob_tree = next(c for c in rob_tree["children"] if c["instance"].endswith("/u_rob"))
    assert abs(direct - rob_tree["area_um2"]) < 1e-5
    assert abs(seq - rob_tree["sequential_area_um2"]) < 1e-5
    assert abs(sum(shared.values()) - (direct - seq)) < 1e-5
    result = dict(report=str(args.report.resolve()),design_sha256=hashlib.sha256(design_path.read_bytes()).hexdigest(),
                  rob_total_um2=direct,sequential_um2=seq,combinational_um2=direct-seq,
                  groups=rows,exclusive_partition=sorted(shared.items(), key=lambda x: -x[1]),
                  note="Cone totals overlap; exclusive_partition counts each combinational cell once. Child commit is an atomic combinational cell.")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    for row in sorted(rows,key=lambda x:-x["exclusive_area_um2"]):
        print(f"{row['group']:22s} cone={row['cone_area_um2']:9.3f} exclusive={row['exclusive_area_um2']:9.3f} um2 registers={row['receiver_registers']}")
    print("Largest disjoint partitions:", result["exclusive_partition"][:5])


if __name__ == "__main__":
    main()
