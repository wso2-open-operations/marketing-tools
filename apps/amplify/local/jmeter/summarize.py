#!/usr/bin/env python3
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Per-module and per-endpoint latency summary from a JMeter CSV result file (.jtl).
#
#   python3 local/jmeter/summarize.py results.jtl [--target-ms 50] [--max-err-pct 0.1]
#
# Labels are "<module>/<endpoint>". Percentiles are nearest-rank over the elapsed time of every sample.
# Exits 1 when any endpoint's p95 is above --target-ms or its error rate is above --max-err-pct.
import argparse
import csv
import math
import sys
from collections import defaultdict


def percentile(sorted_values, p):
    if not sorted_values:
        return 0
    rank = max(1, math.ceil(p / 100 * len(sorted_values)))
    return sorted_values[rank - 1]


def stats(samples, window_s):
    elapsed = sorted(e for e, _, _ in samples)
    errors = sum(1 for _, ok, _ in samples if not ok)
    return dict(
        count=len(elapsed),
        err_pct=100 * errors / len(elapsed),
        rps=len(elapsed) / window_s if window_s > 0 else 0,
        avg=sum(elapsed) / len(elapsed),
        p50=percentile(elapsed, 50),
        p95=percentile(elapsed, 95),
        p99=percentile(elapsed, 99),
        max=elapsed[-1],
    )


def row(name, st, target, max_err):
    verdict = "PASS" if st["p95"] <= target and st["err_pct"] <= max_err else "FAIL"
    return (f"| {name} | {st['count']} | {st['err_pct']:.2f} | {st['rps']:.1f} | {st['avg']:.1f} | "
            f"{st['p50']} | {st['p95']} | {st['p99']} | {st['max']} | {verdict} |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jtl")
    ap.add_argument("--target-ms", type=float, default=50, help="p95 target per endpoint (default 50)")
    ap.add_argument("--max-err-pct", type=float, default=0.1, help="error budget per endpoint, percent (default 0.1)")
    args = ap.parse_args()

    by_label = defaultdict(list)
    first, last = None, 0
    with open(args.jtl, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            ts, elapsed = int(r["timeStamp"]), int(r["elapsed"])
            by_label[r["label"]].append((elapsed, r["success"] == "true", ts))
            first = ts if first is None else min(first, ts)
            last = max(last, ts + elapsed)

    if not by_label:
        print("No samples in " + args.jtl, file=sys.stderr)
        return 1

    window_s = (last - first) / 1000
    by_module = defaultdict(list)
    for label, samples in by_label.items():
        by_module[label.split("/", 1)[0]].extend(samples)

    header = ("| Scope | Samples | Err % | Req/s | Avg ms | p50 | p95 | p99 | Max | Verdict |\n"
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    target, max_err = args.target_ms, args.max_err_pct
    print(f"## Module latency (window {window_s:.0f} s, p95 target {target:g} ms, error budget {max_err:g} %)\n")
    print(header)
    for module in sorted(by_module):
        print(row(f"**{module}** (all)", stats(by_module[module], window_s), target, max_err))
    print("\n## Endpoint latency\n")
    print(header)
    breaches = 0
    for label in sorted(by_label):
        st = stats(by_label[label], window_s)
        breaches += st["p95"] > target or st["err_pct"] > max_err
        print(row(f"`{label}`", st, target, max_err))
    print()
    if breaches:
        print(f"{breaches} endpoint(s) over the p95 target or the error budget.")
        return 1
    print("All endpoints within the p95 target and the error budget.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
