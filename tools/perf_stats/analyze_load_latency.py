#!/usr/bin/env python3
"""Validate passive load-stage observations against existing performance data."""
import argparse
import json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results", type=Path, required=True)
    ap.add_argument("--baseline", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    measured = json.loads(args.results.read_text())
    baseline = json.loads(args.baseline.read_text())
    assert measured["source_inputs"] == baseline["source_inputs"]
    rows = []
    for row, old in zip(measured["benchmarks"], baseline["benchmarks"]):
        assert row["case"] == old["case"] and row["cycles"] == old["cycles"]
        for name, counters in old["counters"].items():
            assert row["counters"][name] == counters, (row["case"], name)
        a, b = [row["counters"][k] for k in ("LOAD_LAT", "LOAD_USE")]
        lsu, backend = [row["counters"][k] for k in ("LSU_EXTRA", "BE")]
        assert a["enqueues"] == lsu["enqueues"]
        # LSU_EXTRA assigns every squash cycle to its cancellation category,
        # including cycles where an older load executes and survives.
        assert 0 <= a["executions"] - lsu["executed"] <= lsu["pending_squash"]
        assert a["requests"] == backend["ld_issue"]
        assert a["responses"] == backend["ld_resp"]
        assert a["requests"] + a["forwarded"] + a["illegal"] == a["executions"]
        assert a["writebacks"] == sum(a[k] for k in ("result_one", "result_two", "result_many"))
        assert 0 <= a["requests"] - a["responses"] <= 8
        pending_results = (a["kept_responses"] + a["forwarded"] + a["illegal"]
                           - a["writebacks"] - a["discarded_results"])
        assert 0 <= pending_results <= 8
        assert b["issued"] == sum(b[k] for k in ("same_cycle", "next_cycle", "two_cycles", "later"))
        assert b["vanished"] == 0, (row["case"], b)
        assert 0 <= b["opportunities"] - b["issued"] - b["canceled"] <= 8
        def mean(total, count):
            return total / count if count else None
        rows.append(dict(case=row["case"],
                         enqueue_to_execute=mean(a["lp_sum"], a["executions"]),
                         request_to_response=mean(a["memory_sum"], a["responses"]),
                         result_to_writeback=mean(a["result_sum"], a["writebacks"]),
                         result_one_cycle_pct=100 * a["result_one"] / max(a["writebacks"], 1),
                         consumers=b["issued"],
                         writeback_to_consumer_issue=mean(b["latency_sum"], b["issued"]),
                         consumer_next_cycle_pct=100 * b["next_cycle"] / max(b["issued"], 1),
                         lane1_eligible_pct=100 * b["lane1_issued"] / max(b["issued"], 1)))
    assert len(rows) == len(baseline["benchmarks"]) == 6
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dict(original_counters_unchanged=True,
                                       stage_accounting_verified=True,
                                       consumer_identity_vanished=0,
                                       benchmarks=rows), indent=2) + "\n")
    for row in rows:
        print(row)


if __name__ == "__main__":
    main()
