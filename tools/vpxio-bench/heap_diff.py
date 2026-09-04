#!/usr/bin/env python3
"""Parses heap and vmmap snapshots from heap_compare.sh and diffs them.

    python3 heap_diff.py <outdir>

Expects files:
    <outdir>/upstream_master.vmmap-summary.txt
    <outdir>/perf-vpx-load-order.vmmap-summary.txt
    <outdir>/upstream_master.heap.txt          (optional, absent in --no-malloc-logging mode)
    <outdir>/perf-vpx-load-order.heap.txt      (optional)
    <outdir>/upstream_master.rss_kb.txt
    <outdir>/perf-vpx-load-order.rss_kb.txt

Prints a ranked diff of where the memory delta lives.
"""
import pathlib
import re
import sys


def parse_vmmap_summary(path):
    """Parse vmmap --summary output into {region_type: dirty_size_bytes}.

    The summary section looks like:
        REGION TYPE                      VIRTUAL   RESIDENT   DIRTY+SWAP   ...
        ===========                      =======   ========   ==========
        MALLOC                           123.4M     100.2M       98.1M
        ...
        TOTAL                            ...

    We want the DIRTY+SWAP column (index 3 in the data rows), which is what
    the kernel charges the process.
    """
    regions = {}
    text = path.read_text(errors="replace")
    in_summary = False
    saw_header = False
    for line in text.splitlines():
        # The vmmap --summary header spans two lines:
        #   line 1: "                    VIRTUAL RESIDENT    DIRTY ..."
        #   line 2: "REGION TYPE            SIZE     SIZE     SIZE ..."
        #   line 3: "===========         ======= ======== ..."
        # We enter the table after the === separator that follows REGION TYPE.
        if "REGION TYPE" in line:
            saw_header = True
            continue
        if saw_header and line.lstrip().startswith("=="):
            in_summary = True
            continue
        if in_summary and line.lstrip().startswith("=="):
            # Second separator, just before TOTAL
            continue
        if in_summary:
            if not line.strip():
                break
            if line.startswith("TOTAL"):
                # Parse TOTAL the same way as other rows
                parts = line.split()
                sizes = []
                for i, p in enumerate(parts):
                    if _parse_size(p) is not None:
                        sizes = parts[i:]
                        break
                if len(sizes) >= 3:
                    dirty = _parse_size(sizes[2])
                    if dirty is not None:
                        regions["__TOTAL__"] = dirty
                break
            # Region name can contain spaces, sizes are right-aligned
            # Strategy: split from the right, sizes are the last N tokens
            parts = line.rstrip().split()
            if len(parts) < 3:
                continue
            # Find the rightmost tokens that look like sizes (contain K, M, G, or a digit)
            sizes = []
            name_parts = []
            found_first_size = False
            for i, p in enumerate(parts):
                if _parse_size(p) is not None and not found_first_size:
                    found_first_size = True
                    name_parts = parts[:i]
                    sizes = parts[i:]
                    break
            if not found_first_size:
                continue
            name = " ".join(name_parts).strip()
            if not name:
                continue
            # Dirty+swap is typically the 3rd size column, but let's count from available
            # Columns are: VIRTUAL, RESIDENT, DIRTY+SWAP (sometimes more)
            # We want index 2 (0-based) of the sizes
            if len(sizes) >= 3:
                dirty = _parse_size(sizes[2])
                if dirty is not None:
                    regions[name] = dirty
    return regions


def _parse_size(s):
    """Parse a size string like '123.4M', '56K', '2.1G', '0' into bytes. Returns None if not a size."""
    s = s.strip().rstrip("?")
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)", s)
    if not m:
        return None
    val = float(m.group(1))
    unit = m.group(2)
    mult = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}.get(unit, 1)
    return int(val * mult)


def parse_heap_summary(path):
    """Parse heap --sortBySize output into [(type_name, count, total_bytes)].

    The summary block at the top looks like:
        All zones: 12345 nodes (67890123 bytes)
            COUNT     BYTES      AVG   CLASS_NAME
            =====     =====      ===   ==========
             5432   12345678   2272.3   non-object
             ...

    After the summary, there may be per-zone breakdowns. We only want the top-level "All zones".
    """
    entries = []
    text = path.read_text(errors="replace")
    in_table = False
    for line in text.splitlines():
        if "COUNT" in line and "BYTES" in line and "CLASS_NAME" in line:
            in_table = True
            continue
        if in_table and "=====" in line:
            continue
        if in_table:
            if not line.strip():
                break
            parts = line.split()
            if len(parts) >= 4:
                try:
                    count = int(parts[0])
                    total_bytes = int(parts[1])
                    # AVG is parts[2], class name is the rest
                    class_name = " ".join(parts[3:])
                    entries.append((class_name, count, total_bytes))
                except ValueError:
                    break
    return entries


def diff_vmmap(master_regions, pr_regions):
    """Compute per-region delta (pr - master) sorted by absolute delta descending."""
    all_keys = set(master_regions.keys()) | set(pr_regions.keys())
    deltas = []
    for key in all_keys:
        m = master_regions.get(key, 0)
        p = pr_regions.get(key, 0)
        delta = p - m
        if delta != 0:
            deltas.append((key, m, p, delta))
    deltas.sort(key=lambda x: abs(x[3]), reverse=True)
    return deltas


def diff_heap(master_entries, pr_entries):
    """Compute per-class delta sorted by absolute bytes delta descending."""
    master_map = {name: (count, total) for name, count, total in master_entries}
    pr_map = {name: (count, total) for name, count, total in pr_entries}
    all_classes = set(master_map.keys()) | set(pr_map.keys())
    deltas = []
    for cls in all_classes:
        m_count, m_bytes = master_map.get(cls, (0, 0))
        p_count, p_bytes = pr_map.get(cls, (0, 0))
        delta_bytes = p_bytes - m_bytes
        delta_count = p_count - m_count
        if delta_bytes != 0:
            deltas.append((cls, m_bytes, p_bytes, delta_bytes, m_count, p_count, delta_count))
    deltas.sort(key=lambda x: abs(x[3]), reverse=True)
    return deltas


def fmt_mb(b):
    """Format bytes as MB with sign."""
    mb = b / (1024 * 1024)
    return f"{mb:+.1f} MB" if b != 0 else "0"


def fmt_bytes(b):
    if abs(b) >= 1024 * 1024:
        return f"{b / (1024*1024):.1f} MB"
    if abs(b) >= 1024:
        return f"{b / 1024:.1f} KB"
    return f"{b} B"


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: heap_diff.py <outdir>")
    outdir = pathlib.Path(sys.argv[1])

    master_name = "upstream_master"
    pr_name = "perf-vpx-load-order"

    # RSS cross-reference
    rss_master = 0
    rss_pr = 0
    rss_f = outdir / f"{master_name}.rss_kb.txt"
    if rss_f.exists():
        rss_master = int(rss_f.read_text().strip()) * 1024
    rss_f = outdir / f"{pr_name}.rss_kb.txt"
    if rss_f.exists():
        rss_pr = int(rss_f.read_text().strip()) * 1024

    print(f"RSS at snapshot:  master={fmt_bytes(rss_master)}  #3817={fmt_bytes(rss_pr)}  "
          f"delta={fmt_mb(rss_pr - rss_master)}")
    print()

    # vmmap diff
    vm_master_f = outdir / f"{master_name}.vmmap-summary.txt"
    vm_pr_f = outdir / f"{pr_name}.vmmap-summary.txt"
    if vm_master_f.exists() and vm_pr_f.exists():
        vm_master = parse_vmmap_summary(vm_master_f)
        vm_pr = parse_vmmap_summary(vm_pr_f)
        deltas = diff_vmmap(vm_master, vm_pr)

        print("=== vmmap dirty+swap delta (top regions) ===")
        print(f"{'region':<35} {'master':>10} {'#3817':>10} {'delta':>12}")
        print("-" * 70)
        for name, m, p, d in deltas[:20]:
            print(f"  {name:<33} {fmt_bytes(m):>10} {fmt_bytes(p):>10} {fmt_mb(d):>12}")
        if "__TOTAL__" in vm_master and "__TOTAL__" in vm_pr:
            t_m = vm_master["__TOTAL__"]
            t_p = vm_pr["__TOTAL__"]
            print(f"\n  vmmap TOTAL dirty+swap: master={fmt_bytes(t_m)}  #3817={fmt_bytes(t_p)}  delta={fmt_mb(t_p - t_m)}")
        print()
    else:
        print("(vmmap summary files not found, skipping vmmap diff)")
        print()

    # heap diff
    heap_master_f = outdir / f"{master_name}.heap.txt"
    heap_pr_f = outdir / f"{pr_name}.heap.txt"
    if heap_master_f.exists() and heap_pr_f.exists():
        heap_master = parse_heap_summary(heap_master_f)
        heap_pr = parse_heap_summary(heap_pr_f)
        if heap_master and heap_pr:
            deltas = diff_heap(heap_master, heap_pr)
            total_master = sum(t for _, _, t in heap_master)
            total_pr = sum(t for _, _, t in heap_pr)

            print("=== heap live allocations delta (top classes) ===")
            print(f"heap totals: master={fmt_bytes(total_master)}  #3817={fmt_bytes(total_pr)}  "
                  f"delta={fmt_mb(total_pr - total_master)}")
            print()
            print(f"{'class':<55} {'master':>10} {'#3817':>10} {'delta':>12} {'count_delta':>12}")
            print("-" * 102)
            for cls, m_b, p_b, d_b, m_c, p_c, d_c in deltas[:30]:
                # Truncate long class names
                display = cls[:53] if len(cls) > 53 else cls
                print(f"  {display:<53} {fmt_bytes(m_b):>10} {fmt_bytes(p_b):>10} "
                      f"{fmt_mb(d_b):>12} {d_c:>+10}")
            # Sum the explained delta
            explained = sum(d_b for _, _, _, d_b, _, _, _ in deltas if d_b > 0)
            print(f"\n  sum of positive deltas: {fmt_mb(explained)}")
            print(f"  sum of negative deltas: {fmt_mb(sum(d_b for _, _, _, d_b, _, _, _ in deltas if d_b < 0))}")
            print()

            # Compare heap live total against vmmap to show allocator overhead
            if vm_master_f.exists() and vm_pr_f.exists():
                vm_pr_regions = parse_vmmap_summary(vm_pr_f)
                vm_master_regions = parse_vmmap_summary(vm_master_f)
                # MALLOC regions represent the total malloc zone dirty pages
                malloc_dirty_master = sum(v for k, v in vm_master_regions.items()
                                          if "MALLOC" in k.upper() and k != "__TOTAL__")
                malloc_dirty_pr = sum(v for k, v in vm_pr_regions.items()
                                      if "MALLOC" in k.upper() and k != "__TOTAL__")
                print("=== allocator overhead (malloc dirty pages - heap live) ===")
                print(f"  master: malloc_dirty={fmt_bytes(malloc_dirty_master)}  "
                      f"heap_live={fmt_bytes(total_master)}  "
                      f"overhead={fmt_mb(malloc_dirty_master - total_master)}")
                print(f"  #3817:  malloc_dirty={fmt_bytes(malloc_dirty_pr)}  "
                      f"heap_live={fmt_bytes(total_pr)}  "
                      f"overhead={fmt_mb(malloc_dirty_pr - total_pr)}")
                print(f"  overhead delta: {fmt_mb((malloc_dirty_pr - total_pr) - (malloc_dirty_master - total_master))}")
                print()
                print("  If the overhead delta is large, the allocator is retaining freed pages.")
                print("  This would explain memory that heap cannot attribute to live objects.")
        else:
            print("(heap files present but could not parse summary tables)")
            print()
    else:
        print("(heap files not found, run without --no-malloc-logging for heap attribution)")
        print()

    # footprint cross-reference
    for name, label in [(master_name, "master"), (pr_name, "#3817")]:
        fp = outdir / f"{name}.footprint.txt"
        if fp.exists():
            text = fp.read_text(errors="replace")
            # footprint output has a "total:" or "Physical footprint:" line
            for line in text.splitlines():
                if "physical footprint" in line.lower() or "total footprint" in line.lower():
                    print(f"  footprint ({label}): {line.strip()}")
                    break


if __name__ == "__main__":
    main()
