#!/bin/bash
# Verifies a crash report contains a symbolicated stack: function names plus
# file:line, not bare offsets or "??". Exit 0 = resolved, 1 = unresolved/missing.
# Usage: check-crash-report.sh <crash.txt> [min_named_frames]

set -u

report="${1:-}"
min_named="${2:-3}"

if [ -z "$report" ] || [ ! -f "$report" ]; then
   echo "FAIL: crash report not found: $report"
   exit 1
fi

echo "=== $report ==="
cat "$report"
echo "=== analysis ==="

# A resolved frame carries a source location "file.cpp:123". Count them, and
# reject the unresolved markers a DWARF miss produces.
# A resolved frame carries a source location as either "file.cpp(123)" (dbghelp
# style) or "file.cpp:123" (addr2line style).
named=$(grep -cE '[A-Za-z0-9_]+\.(cpp|c|h|hpp|mm|cc)[:(][0-9]+' "$report")
unresolved=$(grep -cE '\?\?|:\?|in function \?' "$report")

echo "named frames (file:line): $named (need >= $min_named)"
echo "unresolved markers:       $unresolved"

if [ "$named" -ge "$min_named" ] && [ "$unresolved" -eq 0 ]; then
   echo "RESULT: PASS"
   exit 0
fi

echo "RESULT: FAIL"
exit 1
