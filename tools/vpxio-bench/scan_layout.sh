#!/usr/bin/env bash
# Classifies every .vpx in a directory tree by which traversal order matches its physical
# layout, and reports how many fall each way.
#
#     ./scan_layout.sh <tables-dir> [stride]
#
# The question this answers: reading streams in ascending file offset is worth roughly 3.4x
# cold over a network, but obtaining a stream's first block requires POLE, and Windows uses
# real OLE structured storage where IStorage exposes no such thing. If nearly all files were
# written in one consistent direction, a portable ordering heuristic would be possible. If
# the direction varies, it is not, and the ordering has to come from the storage layer.
set -uo pipefail

dir="${1:-/Volumes/Emulators/Pinball/Tables}"
stride="${2:-1}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
layout="$here/.variants/layout"
[[ -x "$layout" ]] || { echo "run './run.sh variants' first" >&2; exit 2; }

fwd=0; rev=0; bad=0; n=0
printf 'forward-layout tables found:\n'
while IFS= read -r f; do
   n=$((n + 1))
   out="$("$layout" "$f" 2>/dev/null)" || { bad=$((bad + 1)); continue; }
   streams=$(sed -n 's/^streams \([0-9]*\) total.*/\1/p' <<< "$out")
   db=$(sed -n 's/.*directory order .*backward seeks *\([0-9]*\) *\/.*/\1/p' <<< "$out")
   rb=$(sed -n 's/.*reverse directory .*backward seeks *\([0-9]*\) *\/.*/\1/p' <<< "$out")
   [[ -z "$streams" || -z "$db" || -z "$rb" ]] && { bad=$((bad + 1)); continue; }
   if (( db < rb )); then
      fwd=$((fwd + 1))
      printf '  %-52s streams %5s  dir-back %5s  rev-back %5s\n' \
         "$(basename "$f" .vpx | cut -c1-51)" "$streams" "$db" "$rb"
   else
      rev=$((rev + 1))
   fi
   if (( n % 25 == 0 )); then
      printf '  ... scanned %d: %d forward, %d reversed, %d unreadable\n' "$n" "$fwd" "$rev" "$bad" >&2
   fi
done < <(ls "$dir"/*/*.vpx 2>/dev/null | awk -v s="$stride" '(NR - 1) % s == 0')

printf '\nscanned %d: %d forward, %d reversed, %d unreadable\n' "$n" "$fwd" "$rev" "$bad"
