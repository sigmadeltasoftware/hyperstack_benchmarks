#!/usr/bin/env python3
import json, glob, os, sys
from statistics import median, mean

RAW = os.path.expanduser("~/HyperStack/bench/results/raw")

def parse(path):
    d = json.load(open(path))
    m = d.get("metrics", {})
    hr = m.get("http_reqs", {})
    dur = m.get("http_req_duration", {})
    failed = not bool(d.get("__bench_threshold_failed", False))
    # storage scenarios: use iterations rate; rest: http_reqs rate
    it = m.get("iterations", {})
    return {
        "rps": hr.get("rate"),
        "iter_rate": it.get("rate"),
        "p50": dur.get("med"),
        "p95": dur.get("p(95)"),
        "p99": dur.get("p(99)"),
        "passed": failed,
        "errrate": m.get("http_req_failed", {}).get("value"),
    }

def summarize(pattern, label, metric="rps"):
    files = sorted(glob.glob(os.path.join(RAW, pattern)))
    if not files:
        print(f"  {label}: NO FILES ({pattern})")
        return
    rows = [parse(f) for f in files]
    rate = [r[metric] for r in rows if r[metric] is not None]
    p50 = [r["p50"] for r in rows if r["p50"] is not None]
    p95 = [r["p95"] for r in rows if r["p95"] is not None]
    p99 = [r["p99"] for r in rows if r["p99"] is not None]
    npass = sum(1 for r in rows if r["passed"])
    per_run = ", ".join(f"{r[metric]:.0f}" for r in rows if r[metric] is not None)
    print(f"  {label}: N={len(rows)} pass={npass}/{len(rows)}")
    print(f"    {metric} mean={mean(rate):.1f} min={min(rate):.1f} max={max(rate):.1f}  per-run=[{per_run}]")
    print(f"    p50(med)={median(p50):.1f}ms p95(med)={median(p95):.1f}ms p99(med)={median(p99) if p99 else 0:.1f}ms")

runid = sys.argv[1] if len(sys.argv) > 1 else "*"
scenario = sys.argv[2] if len(sys.argv) > 2 else "rest-insert-plain"
metric = sys.argv[3] if len(sys.argv) > 3 else "rps"

print(f"=== {scenario} (runid={runid}, metric={metric}) ===")
for framing in ["a", "b"]:
    for target in ["hyperstack", "supabase"]:
        summarize(f"k6-{framing}-{scenario}-{target}-{runid}-run*.json", f"[{framing}] {target}", metric)
