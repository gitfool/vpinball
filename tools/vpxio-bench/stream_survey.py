#!/usr/bin/env python3
"""Survey stream sizes across all .vpx tables in a directory tree.

    python3 stream_survey.py /Volumes/Emulators/Pinball/Tables [--out results.tsv]

For each subdirectory, finds the first .vpx file and enumerates all streams in its
OLE Compound Document structure. Produces per-table stats and an aggregate summary.

Does NOT modify any files on the source volume.

Requires: pip install olefile
"""
import argparse
import math
import os
import pathlib
import sys
import time

try:
    import olefile
except ImportError:
    sys.exit("error: olefile not installed. Run: pip3 install --user olefile")


def scan_table(vpx_path):
    """Return list of (stream_path, size_bytes) for all streams in a .vpx file."""
    try:
        ole = olefile.OleFileIO(str(vpx_path))
    except Exception as e:
        return None, str(e)
    streams = []
    try:
        for entry in ole.listdir(storages=False, streams=True):
            path = "/".join(entry)
            try:
                size = ole.get_size(path)
                streams.append((path, size))
            except Exception:
                pass
    finally:
        ole.close()
    return streams, None


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0
    k = (len(sorted_vals) - 1) * p / 100.0
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] * (c - k) + sorted_vals[c] * (k - f)


def size_bucket(size_bytes):
    """Assign a human-readable bucket label."""
    kb = size_bytes / 1024
    mb = kb / 1024
    if mb >= 32:
        return "32+ MB"
    if mb >= 16:
        return "16-32 MB"
    if mb >= 8:
        return "8-16 MB"
    if mb >= 4:
        return "4-8 MB"
    if mb >= 1:
        return "1-4 MB"
    if kb >= 512:
        return "512K-1M"
    if kb >= 128:
        return "128-512K"
    if kb >= 32:
        return "32-128K"
    if kb >= 4:
        return "4-32K"
    return "0-4K"


BUCKET_ORDER = [
    "0-4K", "4-32K", "32-128K", "128-512K", "512K-1M",
    "1-4 MB", "4-8 MB", "8-16 MB", "16-32 MB", "32+ MB"
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tables_dir", help="Root directory containing table subdirectories")
    ap.add_argument("--out", default=None, help="Output CSV path (default: stdout summary only)")
    ap.add_argument("--limit", type=int, default=0, help="Process at most N tables (0=all)")
    args = ap.parse_args()

    tables_dir = pathlib.Path(args.tables_dir)
    if not tables_dir.is_dir():
        sys.exit(f"error: not a directory: {tables_dir}")

    # Find all table subdirectories with a .vpx file
    table_dirs = sorted(d for d in tables_dir.iterdir() if d.is_dir())
    tables = []
    for d in table_dirs:
        vpx_files = list(d.glob("*.vpx"))
        if vpx_files:
            tables.append((d.name, vpx_files[0]))
    if not tables:
        sys.exit(f"error: no .vpx files found in subdirectories of {tables_dir}")

    if args.limit > 0:
        tables = tables[:args.limit]

    print(f"Scanning {len(tables)} tables...", file=sys.stderr)

    # Per-table results
    all_results = []
    all_sizes = []  # flat list of every stream size across all tables
    errors = []
    global_buckets = {b: 0 for b in BUCKET_ORDER}

    out_fh = None
    if args.out:
        out_fh = open(args.out, "w")
        out_fh.write("table,streams,total_bytes,min,max,mean,median,p90,p99,"
                     "gt_1mb,gt_8mb,gt_32mb,largest_stream_mb\n")

    t0 = time.monotonic()
    for i, (name, vpx_path) in enumerate(tables):
        if (i + 1) % 50 == 0 or i == 0:
            elapsed = time.monotonic() - t0
            rate = (i + 1) / elapsed if elapsed > 0 else 0
            eta = (len(tables) - i - 1) / rate if rate > 0 else 0
            print(f"  [{i+1}/{len(tables)}] {rate:.1f} tables/s, ETA {eta:.0f}s", file=sys.stderr)

        streams, err = scan_table(vpx_path)
        if streams is None:
            errors.append((name, err))
            continue

        sizes = sorted(s for _, s in streams)
        if not sizes:
            continue

        total = sum(sizes)
        count = len(sizes)
        mn = sizes[0]
        mx = sizes[-1]
        mean = total / count
        median = percentile(sizes, 50)
        p90 = percentile(sizes, 90)
        p99 = percentile(sizes, 99)
        gt_1mb = sum(1 for s in sizes if s >= 1024 * 1024)
        gt_8mb = sum(1 for s in sizes if s >= 8 * 1024 * 1024)
        gt_32mb = sum(1 for s in sizes if s >= 32 * 1024 * 1024)

        all_results.append({
            "name": name, "count": count, "total": total,
            "min": mn, "max": mx, "mean": mean, "median": median,
            "p90": p90, "p99": p99,
            "gt_1mb": gt_1mb, "gt_8mb": gt_8mb, "gt_32mb": gt_32mb,
        })
        all_sizes.extend(sizes)

        for s in sizes:
            b = size_bucket(s)
            global_buckets[b] += 1

        if out_fh:
            # Quote table name in case it contains commas
            quoted_name = f'"{name}"' if "," in name else name
            out_fh.write(f"{quoted_name},{count},{total},{mn},{mx},{mean:.0f},{median:.0f},"
                         f"{p90:.0f},{p99:.0f},{gt_1mb},{gt_8mb},{gt_32mb},{mx/1024/1024:.2f}\n")

    if out_fh:
        out_fh.close()

    elapsed = time.monotonic() - t0

    # Aggregate summary
    print(f"\n{'='*70}")
    print(f"STREAM SIZE SURVEY: {len(all_results)} tables scanned in {elapsed:.1f}s")
    if errors:
        print(f"  ({len(errors)} tables failed to open)")
    print(f"{'='*70}\n")

    if not all_sizes:
        print("No streams found.")
        return

    all_sizes.sort()
    total_streams = len(all_sizes)
    total_bytes = sum(all_sizes)

    print(f"Total streams across all tables: {total_streams:,}")
    print(f"Total bytes across all tables:   {total_bytes/1024/1024/1024:.2f} GB")
    print()

    print("--- per-stream stats (all tables combined) ---")
    print(f"  min:    {all_sizes[0]:,} bytes")
    print(f"  max:    {all_sizes[-1]:,} bytes ({all_sizes[-1]/1024/1024:.2f} MB)")
    print(f"  mean:   {total_bytes/total_streams:,.0f} bytes ({total_bytes/total_streams/1024:.1f} KB)")
    print(f"  median: {percentile(all_sizes, 50):,.0f} bytes ({percentile(all_sizes, 50)/1024:.1f} KB)")
    print(f"  p90:    {percentile(all_sizes, 90):,.0f} bytes ({percentile(all_sizes, 90)/1024:.1f} KB)")
    print(f"  p95:    {percentile(all_sizes, 95):,.0f} bytes ({percentile(all_sizes, 95)/1024:.1f} KB)")
    print(f"  p99:    {percentile(all_sizes, 99):,.0f} bytes ({percentile(all_sizes, 99)/1024/1024:.2f} MB)")
    print(f"  p99.9:  {percentile(all_sizes, 99.9):,.0f} bytes ({percentile(all_sizes, 99.9)/1024/1024:.2f} MB)")
    print()

    print("--- size distribution (all tables) ---")
    print(f"  {'bucket':<12} {'count':>8} {'%':>7} {'total bytes':>14} {'% bytes':>8}")
    for b in BUCKET_ORDER:
        c = global_buckets[b]
        pct = 100.0 * c / total_streams if total_streams else 0
        # sum bytes in this bucket
        bucket_bytes = sum(s for s in all_sizes if size_bucket(s) == b)
        pct_bytes = 100.0 * bucket_bytes / total_bytes if total_bytes else 0
        print(f"  {b:<12} {c:>8,} {pct:>6.1f}% {bucket_bytes/1024/1024:>10.1f} MB {pct_bytes:>7.1f}%")
    print()

    # Tables with the largest single stream
    print("--- tables with largest single stream (top 20) ---")
    by_max = sorted(all_results, key=lambda r: -r["max"])
    print(f"  {'table':<55} {'max MB':>7} {'streams':>7} {'total MB':>9} {'>32MB':>5}")
    for r in by_max[:20]:
        print(f"  {r['name'][:53]:<55} {r['max']/1024/1024:>7.1f} {r['count']:>7} "
              f"{r['total']/1024/1024:>9.1f} {r['gt_32mb']:>5}")
    print()

    # Tables with the most streams
    print("--- tables with most streams (top 20) ---")
    by_count = sorted(all_results, key=lambda r: -r["count"])
    print(f"  {'table':<55} {'streams':>7} {'total MB':>9} {'max MB':>7}")
    for r in by_count[:20]:
        print(f"  {r['name'][:53]:<55} {r['count']:>7} {r['total']/1024/1024:>9.1f} "
              f"{r['max']/1024/1024:>7.1f}")
    print()

    # Tables with the most bytes
    print("--- largest tables by total stream bytes (top 20) ---")
    by_total = sorted(all_results, key=lambda r: -r["total"])
    print(f"  {'table':<55} {'total MB':>9} {'streams':>7} {'max MB':>7}")
    for r in by_total[:20]:
        print(f"  {r['name'][:53]:<55} {r['total']/1024/1024:>9.1f} {r['count']:>7} "
              f"{r['max']/1024/1024:>7.1f}")
    print()

    # Implications for the cap
    print("--- implications for maxBytesInFlight (32 MB cap) ---")
    tables_over_cap = sum(1 for r in all_results if r["max"] > 32 * 1024 * 1024)
    tables_over_16 = sum(1 for r in all_results if r["max"] > 16 * 1024 * 1024)
    tables_over_8 = sum(1 for r in all_results if r["max"] > 8 * 1024 * 1024)
    streams_over_cap = sum(1 for s in all_sizes if s > 32 * 1024 * 1024)
    streams_over_16 = sum(1 for s in all_sizes if s > 16 * 1024 * 1024)
    streams_over_8 = sum(1 for s in all_sizes if s > 8 * 1024 * 1024)
    print(f"  tables with any stream > 32 MB: {tables_over_cap} / {len(all_results)} "
          f"({100*tables_over_cap/len(all_results):.1f}%)")
    print(f"  tables with any stream > 16 MB: {tables_over_16} / {len(all_results)} "
          f"({100*tables_over_16/len(all_results):.1f}%)")
    print(f"  tables with any stream >  8 MB: {tables_over_8} / {len(all_results)} "
          f"({100*tables_over_8/len(all_results):.1f}%)")
    print(f"  streams > 32 MB: {streams_over_cap:,} / {total_streams:,} "
          f"({100*streams_over_cap/total_streams:.3f}%)")
    print(f"  streams > 16 MB: {streams_over_16:,} / {total_streams:,} "
          f"({100*streams_over_16/total_streams:.3f}%)")
    print(f"  streams >  8 MB: {streams_over_8:,} / {total_streams:,} "
          f"({100*streams_over_8/total_streams:.3f}%)")
    print()

    if errors:
        print(f"--- errors ({len(errors)}) ---")
        for name, err in errors[:20]:
            print(f"  {name}: {err}")


if __name__ == "__main__":
    main()
