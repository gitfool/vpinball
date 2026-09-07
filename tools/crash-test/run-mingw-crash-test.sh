#!/bin/bash
# Builds the MinGW target and exercises the crash handler at two sites, then
# checks each report is symbolicated. Run from the repo root inside the MSYS2
# UCRT64 shell (MSYSTEM=UCRT64).
#
# This is a TEST branch only. The crash sites are gated behind environment
# variables and injected on this branch (not on the PR branch):
#   VPX_CRASH_MAIN  faults on the main thread during startup (VPApp ctor)
#   VPX_CRASH_PHYS  faults on the player thread during play (PhysicsSimulateCycle)
# The second case is the one that matters: it proves symbols resolve for an
# in-play crash on a non-main thread, which needs the main-thread pre-warm of
# the DWARF reader in CrashHandler::Init.

set -e

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

builddir="build-crashtest"
table="${1:-src/assets/strippedTable.vpx}"

echo "### configure + build ($builddir)"
cmake -DPLATFORM=windows-mingw -DCMAKE_BUILD_TYPE=Release -B "$builddir"
cmake --build "$builddir" -- -j"$(nproc)"

run_case() {
   local name="$1" envvar="$2" runcwd="$3"; shift 3
   echo "### case: $name"
   ( cd "$runcwd" && rm -f crash.txt crash.dmp )
   ( cd "$runcwd" && env "$envvar=1" "$root/$builddir/VPinballX_BGFX64.exe" "$@" ) || true
   "$here/check-crash-report.sh" "$runcwd/crash.txt" 3
}

# Startup crash: no table needed, report lands in the build dir.
run_case "startup (main thread)" VPX_CRASH_MAIN "$root/$builddir"

# In-play crash: needs a table; the process changes cwd to the table's folder,
# so the report lands next to the table.
tabledir="$(cd "$(dirname "$table")" && pwd)"
run_case "in-play (player thread)" VPX_CRASH_PHYS "$tabledir" -Play "$root/$table"
