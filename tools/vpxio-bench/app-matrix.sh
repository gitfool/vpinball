#!/usr/bin/env bash
# Cold-cache comparison of real table loads across several builds.
#
#     ./app-matrix.sh build <ref>...        build each ref and stash its .app bundle
#     sudo ./app-matrix.sh run <out.tsv> <table.vpx>...
#
# Everything else in this harness measures container I/O in isolation, which is the right tool
# for comparing read strategies but is not the thing users experience. This measures the
# application: a real table load, cold, from the log's own phase markers.
#
# Bundles are built once and stashed, then run interleaved, because rebuilding between
# repetitions would take longer than the measurements and would not let reps be interleaved.
# Interleaving matters: this link drifts by tens of percent, and blocking the reps would fold
# that drift into whichever build ran during a bad patch. The loop is rep, then table, then
# build, so the three builds for a given table run as close together as possible, since
# build-to-build on one table is the comparison that has to be fair.
#
# `purge` needs root, so `run` is invoked under sudo and drops back to the invoking user to
# launch the app, which needs the user's session and SMB credentials.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
stash="$here/.apps"
log="$HOME/Library/Application Support/VPinballX/10.8/vpinball.log"

do_build() {
   [[ $# -ge 1 ]] || { echo "usage: ./app-matrix.sh build <ref>..." >&2; exit 2; }
   local start_ref
   start_ref="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
   if [[ -n "$(git -C "$repo" status --porcelain -- src standalone third-party CMakeLists.txt)" ]]; then
      echo "error: tracked tree is dirty, refusing to switch refs" >&2
      exit 2
   fi
   mkdir -p "$stash"
   for ref in "$@"; do
      local name="${ref//\//_}"
      echo "=== building $ref ==="
      git -C "$repo" checkout -q "$ref" || { echo "cannot check out $ref" >&2; exit 1; }
      cmake --build "$repo/build" -- -j"$(sysctl -n hw.logicalcpu)" 2>&1 | grep -E "error:" && { echo "build failed for $ref" >&2; exit 1; }
      rm -rf "$stash/$name"
      cp -R "$repo/build/VPinballX_BGFX.app" "$stash/$name"
      printf '%s\n' "$(git -C "$repo" rev-parse --short HEAD)" > "$stash/$name.sha"
      echo "  stashed $name at $(cat "$stash/$name.sha")"
   done
   git -C "$repo" checkout -q "$start_ref"
   echo "returned to $start_ref"
}

# Extracts the load-phase timings that this work is about, from what the run appended.
phases() {
   local mark="$1" label="$2"
   tail -c "+$((mark + 1))" "$log" | python3 -c '
import sys, re, datetime, hashlib
# The extract-end marker was "Images, Sounds and Items loaded" before the POLE-on-all-platforms
# rewrite (master 740b87c17) and "Images, Sounds, Fonts and Parts loaded" after. Match the
# common prefix so one harness measures both old stashed bundles and new builds.
want = ("LoadGameFromFilename /", "PinTable Data loaded",
        "Images, Sounds", "Startup done")
t, content, errors = {}, [], 0
for line in sys.stdin:
    m = re.match(r"^(\S+ \S+) (\w+) +\[[^\]]*\] \[[^\]]*\] (.*)$", line.rstrip())
    if not m:
        continue
    sev, msg = m.group(2), m.group(3)
    if sev in ("ERROR", "FATAL"):
        errors += 1
    if "Duplicate" in msg or "was replaced by" in msg:
        content.append(msg)
    for k in want:
        if msg.startswith(k) and k not in t:
            t[k] = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
def d(a, b):
    return (t[b] - t[a]).total_seconds() if a in t and b in t else float("nan")
fp = hashlib.sha256("\n".join(sorted(content)).encode()).hexdigest()[:12]
print("\t".join(["'"$label"'",
                 f"open_parse={d(want[0], want[1]):.3f}",
                 f"extract={d(want[1], want[2]):.3f}",
                 f"to_startup={d(want[0], want[3]):.3f}",
                 f"content={fp}", f"errors={errors}"]))
'
}

do_run() {
   local out="$1"; shift
   local tables=("$@")
   # Only purge needs root, so a warm run does not.
   [[ "${WARM:-0}" == "1" || $EUID -eq 0 ]] || { echo "error: run under sudo, purge needs root" >&2; exit 2; }
   for t in "${tables[@]}"; do
      [[ -f "$t" ]] || { echo "error: no such table: $t" >&2; exit 2; }
   done
   local runas="${SUDO_USER:-$USER}"
   local reps="${REPS:-3}"

   local variants=()
   for d in "$stash"/*/; do
      [[ -d "$d" ]] && variants+=("$(basename "$d")")
   done
   [[ ${#variants[@]} -gt 0 ]] || { echo "error: nothing stashed, run './app-matrix.sh build <ref>...'" >&2; exit 2; }

   local power
   power="$(pmset -g batt | head -1 | sed 's/.*from .//; s/.$//')"
   [[ "$power" == "AC Power" ]] || echo "WARNING: on $power, cold timings will not be comparable to AC runs" >&2

   emit() { if [[ -n "$out" ]]; then tee -a "$out"; else cat; fi; }
   {
      for t in "${tables[@]}"; do printf '# table\t%s\n' "$(basename "$t" .vpx)"; done
      printf '# power\t%s\n' "$power"
      printf '# reps\t%s\n' "$reps"
      printf '# cache\t%s\n' "$([[ "${WARM:-0}" == "1" ]] && echo warm-no-purge || echo cold-purge-each)"
      for v in "${variants[@]}"; do printf '# variant\t%s\t%s\n' "$v" "$(cat "$stash/$v.sha" 2>/dev/null)"; done
   } | emit

   local total=$(( reps * ${#tables[@]} * ${#variants[@]} ))
   # One measured load. Purge (unless warm), launch, wait for Startup done, emit phases.
   run_one() {
      local r="$1" t="$2" v="$3"
      local tname
      tname="$(basename "$t" .vpx | tr ' ' '_' | cut -c1-24)"
      n=$(( n + 1 ))
      printf '# %d/%d rep %s %s %s %s\n' "$n" "$total" "$r" "$tname" "$v" "$(date -u '+%H:%M:%SZ')" >&2
      # WARM=1 skips the purge, to measure the reader outrunning the parsers. That is the
      # opposite stress to a cold network share and the case where the 32 MB backpressure
      # loop, which polls with SDL_Delay(1), can cost time.
      [[ "${WARM:-0}" == "1" ]] || purge
      sleep 2
      local mark=0
      [[ -f "$log" ]] && mark=$(wc -c < "$log" | tr -d ' ')
      sudo -u "$runas" "$stash/$v/Contents/MacOS/VPinballX_BGFX" -Play "$t" >/dev/null 2>&1 &
      local pid=$!
      # cold over a network share, so allow generously
      for _ in $(seq 1 1800); do
         tail -c "+$((mark + 1))" "$log" 2>/dev/null | grep -q "Startup done" && break
         sleep 0.1
      done
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      phases "$mark" "r$r	$tname	$v" | emit
   }

   local n=0
   for r in $(seq 1 "$reps"); do
      if [[ "${BYBUILD:-0}" == "1" ]]; then
         # rep -> build -> table. All tables for one build run adjacent, so no build reads a
         # table right after another build pulled the same file across the wire. Removes the
         # same-table-back-to-back cache warming that rep->table->build can leak on cold NAS.
         for v in "${variants[@]}"; do
            for t in "${tables[@]}"; do run_one "$r" "$t" "$v"; done
         done
      else
         # rep -> table -> build (default, matches the PR methodology). Builds for one table
         # run adjacent so network drift hits both equally.
         for t in "${tables[@]}"; do
            for v in "${variants[@]}"; do run_one "$r" "$t" "$v"; done
         done
      fi
   done
}

case "${1:-}" in
   build) shift; do_build "$@" ;;
   run)   shift; [[ $# -ge 2 ]] || { echo "usage: sudo ./app-matrix.sh run <out.tsv> <table.vpx>..." >&2; exit 2; }; do_run "$@" ;;
   *)     sed -n '2,6p' "$0"; exit 2 ;;
esac
