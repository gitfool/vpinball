#!/usr/bin/env bash
# Snapshots heap and VM state of two builds at the same load-phase boundary, then diffs them.
#
# Purpose: isolate the ~110 MB of unexplained RSS delta between master and #3817 by capturing
# what is actually allocated (heap) and what the allocator retains (vmmap dirty pages) at the
# moment "Images, Sounds and Items loaded" is logged.
#
# Usage:
#   ./heap_compare.sh <table.vpx> <outdir> [--no-malloc-logging]
#
# Requires: the stashed builds at tools/vpxio-bench/.apps/{upstream_master,perf-vpx-load-order}
#
# With MallocStackLogging=lite (default), `heap` attributes non-ObjC allocations to their
# caller. This adds ~10-20% memory overhead, which is acceptable because both builds get the
# same treatment and we compare them against each other, not against the known 142 MB absolute.
#
# With --no-malloc-logging, only vmmap and footprint are captured. Use this mode to confirm
# the delta magnitude matches the known 142 MB without logging distortion.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apps="$here/.apps"
log="$HOME/Library/Application Support/VPinballX/10.8/vpinball.log"

table="${1:?usage: ./heap_compare.sh <table.vpx> <outdir> [--no-malloc-logging]}"
outdir="${2:?usage: ./heap_compare.sh <table.vpx> <outdir> [--no-malloc-logging]}"
malloc_logging=1
[[ "${3:-}" == "--no-malloc-logging" ]] && malloc_logging=0

builds=(upstream_master perf-vpx-load-order)
for b in "${builds[@]}"; do
    bin="$apps/$b/Contents/MacOS/VPinballX_BGFX"
    [[ -x "$bin" ]] || { echo "error: no binary at $bin" >&2; exit 2; }
done

[[ -f "$table" ]] || { echo "error: table not found: $table" >&2; exit 2; }

mkdir -p "$outdir"
echo "# heap_compare $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$outdir/meta.txt"
echo "# table: $(basename "$table")" >> "$outdir/meta.txt"
echo "# malloc_logging: $malloc_logging" >> "$outdir/meta.txt"

snapshot_build() {
    local name="$1"
    local bin="$apps/$name/Contents/MacOS/VPinballX_BGFX"
    local prefix="$outdir/$name"

    echo "=== $name ===" >&2

    # Record log offset before launch
    local mark=0
    [[ -f "$log" ]] && mark=$(wc -c < "$log" | tr -d ' ')

    # Launch
    if [[ $malloc_logging -eq 1 ]]; then
        env MallocStackLogging=lite "$bin" -Play "$table" >/dev/null 2>&1 &
    else
        "$bin" -Play "$table" >/dev/null 2>&1 &
    fi
    local pid=$!
    echo "  launched pid=$pid" >&2

    # Wait for the phase marker, up to 120s. Sample RSS while waiting (same as memcurve.sh).
    local waited=0
    local peak_rss=0
    while [[ $waited -lt 2400 ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  error: process exited before marker" >&2
            return 1
        fi
        local cur_rss
        cur_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        [[ -n "${cur_rss:-}" && "$cur_rss" -gt "$peak_rss" ]] && peak_rss=$cur_rss
        if tail -c "+$((mark + 1))" "$log" 2>/dev/null | grep -q "Images, Sounds and Items loaded"; then
            break
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    if [[ $waited -ge 2400 ]]; then
        echo "  error: timed out waiting for marker" >&2
        kill "$pid" 2>/dev/null || true
        return 1
    fi
    echo "  peak_rss_during_extract_kb=$peak_rss" >&2
    echo "  marker reached, freezing process..." >&2

    # Freeze immediately so the process cannot advance past the extraction phase.
    # vmmap/heap/footprint all suspend the target internally, but by the time they
    # attach the process may have moved on. SIGSTOP is instantaneous.
    kill -STOP "$pid" 2>/dev/null || true
    sleep 0.2

    # Grab RSS while frozen for cross-reference against the original measurements
    local rss
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
    echo "  rss_at_snapshot_kb=$rss" >&2
    echo "$rss" > "${prefix}.rss_kb.txt"

    # Snapshot heap (requires process to be alive, SIGSTOP is fine)
    if [[ $malloc_logging -eq 1 ]]; then
        echo "  capturing heap..." >&2
        heap "$pid" --sortBySize > "${prefix}.heap.txt" 2>&1 || true
        heap "$pid" --sortBySize --zones > "${prefix}.heap-zones.txt" 2>&1 || true
    fi

    # Snapshot vmmap
    echo "  capturing vmmap..." >&2
    vmmap --summary "$pid" > "${prefix}.vmmap-summary.txt" 2>&1 || true
    vmmap "$pid" > "${prefix}.vmmap-full.txt" 2>&1 || true

    # Snapshot footprint
    echo "  capturing footprint..." >&2
    footprint "$pid" > "${prefix}.footprint.txt" 2>&1 || true

    # Kill (no need to SIGCONT first, SIGKILL works on stopped processes)
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "  done" >&2
}

# Warming pass: run master once and discard, so filesystem caches are hot
echo "--- warming pass ---" >&2
mark_w=0
[[ -f "$log" ]] && mark_w=$(wc -c < "$log" | tr -d ' ')
"$apps/upstream_master/Contents/MacOS/VPinballX_BGFX" -Play "$table" >/dev/null 2>&1 &
warm_pid=$!
for _ in $(seq 1 2400); do
    if ! kill -0 "$warm_pid" 2>/dev/null; then break; fi
    if tail -c "+$((mark_w + 1))" "$log" 2>/dev/null | grep -q "Images, Sounds and Items loaded"; then
        break
    fi
    sleep 0.05
done
sleep 0.5
kill "$warm_pid" 2>/dev/null || true
wait "$warm_pid" 2>/dev/null || true
echo "--- warming done ---" >&2
echo ""

# Run both builds
for b in "${builds[@]}"; do
    snapshot_build "$b"
    echo "" >&2
    # Brief pause between runs so the allocator state is clean
    sleep 2
done

# Run the diff
echo "=== running diff ===" >&2
python3 "$here/heap_diff.py" "$outdir"
echo ""
echo "raw output in $outdir/"
