#!/usr/bin/env bash
# Sweeps pool size and in-flight cap, recording both what the loader THINKS is in flight
# (its own high-water mark) and what the OS actually charges the process (peak RSS during the
# stream-extraction phase).
#
#     ./memcurve.sh "/path/to/Table.vpx" out.tsv [reps]
#
# Why: #3817's load phase measured ~126 MB above master in a single sample, and I could not
# explain it. Two candidate mechanisms disagree with the evidence:
#
#   - live in-flight buffers: cap + one stream bounds this at ~75 MB, and cutting the cap 32x
#     should have moved it ~31 MB. It moved 10 MB.
#   - one buffer per pool thread: 12 x mean stream (234 KiB) is 2.7 MB, two orders of magnitude
#     short. Only reachable if the twelve largest streams (262 MiB total) coincide, which the
#     cap should prevent.
#
# So this measures the delta against BOTH knobs. If peak RSS tracks the cap, it is live buffers.
# If it tracks pool size, it is concurrency. If it tracks neither, it is allocator retention and
# the fix is buffer reuse rather than tuning.
#
# Needs the instrumented build (branch perf-vpx-load-order-instr), which reads
# VPX_BENCH_POOLSIZE and VPX_BENCH_MAXINFLIGHT and logs an "INSTR ..." line.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
app="$repo/build/VPinballX_BGFX.app/Contents/MacOS/VPinballX_BGFX"
log="$HOME/Library/Application Support/VPinballX/10.8/vpinball.log"

table="${1:?usage: ./memcurve.sh <table.vpx> <out.tsv> [reps]}"
out="${2:?usage: ./memcurve.sh <table.vpx> <out.tsv> [reps]}"
reps="${3:-3}"

[[ -x "$app" ]] || { echo "no build at $app" >&2; exit 2; }
grep -q "INSTR poolsize" "$repo/src/parts/pintable.cpp" || {
   echo "error: source has no INSTR marker, are you on perf-vpx-load-order-instr?" >&2; exit 2; }

# pool size, cap in bytes. 0 pool means "leave the default".
CONFIGS=(
   "12 33554432"   # shipped default
   "12  1048576"   # same threads, 32x smaller cap  -> isolates the cap
   "12 536870912"  # same threads, effectively uncapped -> isolates the cap upward
   " 4 33554432"   # fewer threads, default cap      -> isolates concurrency
   " 1 33554432"   # single consumer, default cap    -> isolates concurrency hard
   " 1  1048576"   # minimum of both
)

{
   printf '# table\t%s\n' "$(basename "$table" .vpx)"
   printf '# app\t%s\n' "$(cd "$repo" && git rev-parse --short HEAD)"
   printf '# reps\t%s\n' "$reps"
   printf '# note\tpool=threads cap=bytes highwater=loader-reported peak in-flight, rss=OS peak during extract\n'
} > "$out"

total=$(( reps * ${#CONFIGS[@]} ))
n=0
for r in $(seq 1 "$reps"); do
   for cfg in "${CONFIGS[@]}"; do
      read -r pool cap <<<"$cfg"
      n=$((n + 1))
      printf '# %d/%d rep %s pool=%s cap=%s %s\n' "$n" "$total" "$r" "$pool" "$cap" "$(date -u '+%H:%M:%SZ')" >&2

      mark=0
      [[ -f "$log" ]] && mark=$(wc -c < "$log" | tr -d ' ')

      # Sample RSS while it loads. 20 ms is fine: the extract phase is >150 ms in every arm.
      VPX_BENCH_POOLSIZE="$pool" VPX_BENCH_MAXINFLIGHT="$cap" "$app" -Play "$table" >/dev/null 2>&1 &
      pid=$!
      peak=0
      while kill -0 "$pid" 2>/dev/null; do
         rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
         [[ -n "${rss:-}" && "$rss" -gt "$peak" ]] && peak=$rss
         # stop sampling once the extract phase is over; keep the process alive to Startup done
         if tail -c "+$((mark + 1))" "$log" 2>/dev/null | grep -q "Images, Sounds and Items loaded"; then
            break
         fi
         sleep 0.02
      done
      extract_peak_mb=$(python3 -c "print(f'{$peak/1024:.1f}')")

      # let it reach Startup done, then take the whole-process peak too
      for _ in $(seq 1 600); do
         tail -c "+$((mark + 1))" "$log" 2>/dev/null | grep -q "Startup done" && break
         rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
         [[ -n "${rss:-}" && "$rss" -gt "$peak" ]] && peak=$rss
         sleep 0.05
      done
      sleep 1
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true

      instr=$(tail -c "+$((mark + 1))" "$log" | grep -o "INSTR poolsize=.*" | tail -1 || true)
      hw=$(sed -n 's/.*highwater=\([0-9]*\).*/\1/p' <<<"$instr")
      lg=$(sed -n 's/.*largest=\([0-9]*\).*/\1/p' <<<"$instr")
      st=$(sed -n 's/.*stalls=\([0-9]*\).*/\1/p' <<<"$instr")
      ex=$(tail -c "+$((mark + 1))" "$log" | python3 -c '
import sys, re, datetime
t = {}
for line in sys.stdin:
    m = re.match(r"^(\S+ \S+) \w+ +\[[^\]]*\] \[[^\]]*\] (.*)$", line.rstrip())
    if not m: continue
    for k in ("PinTable Data loaded", "Images, Sounds and Items loaded"):
        if m.group(2).startswith(k) and k not in t:
            t[k] = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
a, b = "PinTable Data loaded", "Images, Sounds and Items loaded"
print(f"{(t[b]-t[a]).total_seconds():.3f}" if a in t and b in t else "NaN")')

      printf 'r%s\tpool=%s\tcap=%s\thighwater=%s\tlargest=%s\tstalls=%s\textract=%s\trss_extract_mb=%s\n' \
         "$r" "$pool" "$cap" "${hw:-NA}" "${lg:-NA}" "${st:-NA}" "$ex" "$extract_peak_mb" | tee -a "$out"
   done
done
echo
echo "wrote $out"
