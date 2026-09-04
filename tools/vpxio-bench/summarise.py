#!/usr/bin/env python3
"""Summarises a repeated cold matrix: per-arm median and spread, and which differences
are large enough to mean anything.

    tools/vpxio-bench/summarise.py results-*.tsv

Exists because single-shot numbers from this harness were being over-read. On WiFi the
link drifts: identical configurations measured 62% apart across runs, and a sequential
read of the same file saw 152 then 114 MiB/s. Any difference smaller than an arm's own
observed spread is not evidence.
"""
import pathlib
import statistics
import sys


def load(path):
    arms, meta = {}, {}
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            parts = line.lstrip("# ").split("\t")
            if len(parts) == 2:
                meta[parts[0]] = parts[1]
            continue
        f = line.split("\t")
        d = dict(x.split("=", 1) for x in f[1:] if "=" in x)
        # strip a leading rep tag so reps of one arm group together
        label = f[0].split("-", 1)[1] if f[0].startswith("r") and f[0][1:2].isdigit() else f[0]
        arms.setdefault(label, []).append(float(d["total_ms"]) / 1000.0)
        if "MISMATCH" in line:
            arms.setdefault("__mismatch__", []).append(1)
    return arms, meta


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    arms, meta = load(sys.argv[1])

    if arms.pop("__mismatch__", None):
        print("REFUSING TO SUMMARISE: at least one arm returned different bytes.\n")
        sys.exit(1)

    for k in ("table", "power", "reps", "volume"):
        if k in meta:
            print(f"  {k:<8} {meta[k]}")
    print()

    print(f"  {'arm':<24} {'median':>9} {'min':>9} {'max':>9} {'spread':>8}  n")
    stats = {}
    for label, vals in arms.items():
        med = statistics.median(vals)
        spread = (max(vals) - min(vals)) / med * 100 if med else 0
        stats[label] = (med, spread)
        print(f"  {label:<24} {med:8.2f}s {min(vals):8.2f}s {max(vals):8.2f}s {spread:7.1f}%  {len(vals)}")

    worst = max((s for _, s in stats.values()), default=0)
    print(f"\n  Largest single-arm spread: {worst:.1f}%. Differences below that are not evidence.")

    order = sorted(stats.items(), key=lambda kv: kv[1][0])
    print("\n  Pairwise, fastest first. 'noise' means the gap is within the worst spread.")
    for i in range(len(order) - 1):
        (an, (am, _)), (bn, (bm, _)) = order[i], order[i + 1]
        gap = (bm - am) / am * 100
        verdict = "noise" if gap < worst else f"{bm / am:.2f}x"
        print(f"    {an:<24} vs {bn:<24} {gap:+7.1f}%  {verdict}")


if __name__ == "__main__":
    main()
