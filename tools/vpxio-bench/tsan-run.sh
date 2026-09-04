#!/usr/bin/env bash
# Builds an instrumented VPX and runs a table load under ThreadSanitizer.
#
#     ./tsan-run.sh build
#     ./tsan-run.sh run "/path/to/Table.vpx" [report.log]
#     ./tsan-run.sh triage report.log
#
# Why a separate tree: ENABLE_SANITIZERS in this project turns on AddressSanitizer and UBSan,
# and TSan is mutually exclusive with ASan, so it cannot be reused.
#
# Two traps that cost real time when this was first done, both recorded here so they are not
# rediscovered:
#
#  1. Suppression files use '#' for comments. A '//' comment makes TSan call Die() during
#     initialisation, before main runs, which is indistinguishable from the program crashing.
#     And a called_from_lib entry matching more than one loaded library is also fatal, so
#     'libSDL3' is ambiguous against libSDL3_image and libSDL3_ttf. This script uses no
#     suppressions at all and triages the report instead, which is more robust.
#  2. CMAKE_BUILD_TYPE=RelWithDebInfo used to fail because BX_CONFIG_DEBUG was only set for
#     Debug and Release. Fixed upstream, but this uses Release plus -g regardless, so the
#     optimisation level matches what users actually run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
tree="$repo/build-tsan"
app="$tree/VPinballX_BGFX.app/Contents/MacOS/VPinballX_BGFX"
log="$HOME/Library/Application Support/VPinballX/10.8/vpinball.log"

# Frames that indicate a report belongs to the .vpx read path rather than to one of the
# pre-existing races elsewhere in the codebase.
readonly READ_PATH='PoleStorage|PoleStream|POLE::Storage|POLE::StorageIO|POLE::StreamIO|POLE::Stream|streamOffset|GetStreamOffsets|pole\.cpp|fileio\.cpp'

do_build() {
   cmake -B "$tree" -S "$repo" \
      -DCMAKE_BUILD_TYPE=Release \
      -DPLATFORM=macos -DARCH=arm64 -DRENDERER=BGFX \
      -DPOST_BUILD_COPY_EXT_LIBS=ON -DUSE_SYSTEM_LIBS=OFF -DENABLE_SANITIZERS=OFF \
      -DCMAKE_C_FLAGS="-fsanitize=thread -fno-omit-frame-pointer -g" \
      -DCMAKE_CXX_FLAGS="-fsanitize=thread -fno-omit-frame-pointer -g" \
      -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=thread" \
      -DCMAKE_SHARED_LINKER_FLAGS="-fsanitize=thread"
   cmake --build "$tree" -- -j"$(sysctl -n hw.logicalcpu)"

   # An absent report only means something if the code under test was instrumented.
   echo
   echo "instrumentation check, __tsan_ references per object:"
   for o in third-party/include/pole/pole.cpp standalone/PoleStorage.cpp \
            standalone/PoleStream.cpp src/utils/fileio.cpp src/parts/pintable.cpp; do
      local obj="$tree/CMakeFiles/vpinball.dir/$o.o"
      if [[ -f "$obj" ]]; then
         printf '  %-20s %s\n' "$(basename "$o")" "$(nm -u "$obj" | grep -c '__tsan_')"
      else
         printf '  %-20s MISSING\n' "$(basename "$o")"
      fi
   done
}

do_run() {
   local table="$1" out="${2:-$here/tsan-report.log}"
   [[ -x "$app" ]] || { echo "no instrumented build, run './tsan-run.sh build'" >&2; exit 2; }
   rm -f /tmp/vpx-tsan.log*
   local mark=0
   [[ -f "$log" ]] && mark=$(wc -c < "$log" | tr -d ' ')

   TSAN_OPTIONS="log_path=/tmp/vpx-tsan.log:history_size=7:halt_on_error=0:exitcode=0" \
      "$app" -Play "$table" >/dev/null 2>&1 &
   local pid=$!
   # TSan slows the load by roughly 10x, so allow generously.
   local i
   for i in $(seq 1 1400); do
      tail -c "+$((mark + 1))" "$log" 2>/dev/null | grep -q "Startup done" && break
      sleep 0.5
   done
   sleep 15
   kill "$pid" 2>/dev/null || true
   wait "$pid" 2>/dev/null || true

   local phases
   phases=$(tail -c "+$((mark + 1))" "$log" | grep -cE 'PinTable Data loaded|Images, Sounds and Items loaded' || true)
   echo "reached Startup done after ~$((i / 2))s, load-phase markers seen: $phases"
   [[ "$phases" -ge 2 ]] || echo "WARNING: the load did not complete, so an empty report proves nothing" >&2

   cat /tmp/vpx-tsan.log.* > "$out" 2>/dev/null || : > "$out"
   echo "report: $out ($(wc -c < "$out" | tr -d ' ') bytes)"
   do_triage "$out"
}

do_triage() {
   local out="$1"
   echo
   echo "total warnings: $(grep -c '^WARNING: ThreadSanitizer' "$out" || true)"
   echo
   echo "reports naming the .vpx read path:"
   if grep -qE "$READ_PATH" "$out"; then
      grep -nE "$READ_PATH" "$out" | head -20
   else
      echo "  none"
   fi
   echo
   echo "everything else, by source file:"
   grep -oE '[A-Za-z0-9_./-]+\.(cpp|h|mm|c):[0-9]+' "$out" \
      | sed 's/:[0-9]*$//' | sed 's|.*/||' | sort | uniq -c | sort -rn | head -20
}

case "${1:-}" in
   build)  do_build ;;
   run)    shift; [[ $# -ge 1 ]] || { echo "usage: ./tsan-run.sh run <table.vpx> [out.log]" >&2; exit 2; }; do_run "$@" ;;
   triage) shift; do_triage "${1:?report file}" ;;
   *)      sed -n '2,6p' "$0"; exit 2 ;;
esac
