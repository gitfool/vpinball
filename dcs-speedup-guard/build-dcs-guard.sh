#!/usr/bin/env bash
# Re-arm the dcs_speedup diagnostic guard in the vpinball ./build app.
# Idempotent and self-verifying. Run this when a blue-moon TOTAN crash makes
# the hunt worth resuming and a rebuild/external.sh has since wiped the guard.
#
#   bash build-dcs-guard.sh
#
# It patches the source (via apply-dcs-guard.py), rebuilds only the pinmame
# dylib, swaps it into the app bundle, re-signs, and checks the guard is live
# AND that dcs_speedup kept its optimized codegen. See README.md.
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM=/Users/sean/devel/vpinball/external/macos-arm64/Release/pinmame/pinmame
BUILD="$PM/build"
BUNDLE=/Users/sean/devel/vpinball/build/VPinballX_BGFX.app/Contents/Frameworks/libpinmame.3.7.0.dylib

echo "==> 1/5 patch source (idempotent)"
python3 "$HERE/apply-dcs-guard.py"

echo "==> 2/5 build pinmame_shared (do NOT run external.sh, it clobbers the patch)"
cmake --build "$BUILD" --target pinmame_shared -j >/dev/null
echo "    built."

echo "==> 3/5 install dylib into app bundle"
SRC="$(readlink -f "$BUILD/libpinmame.dylib" 2>/dev/null || echo "$BUILD/libpinmame.3.7.0.dylib")"
cp "$SRC" "$BUNDLE"
echo "    copied $SRC -> bundle"

echo "==> 4/5 re-sign ad-hoc"
codesign --force --sign - "$BUNDLE"

echo "==> 5/5 verify"
guard=$(strings "$BUNDLE" | grep -c "dcs_speedup OUT-OF-RANGE" || true)
calls=$(objdump --disassemble-symbols=_dcs_speedup --no-show-raw-insn "$BUNDLE" 2>/dev/null | grep -c "_dcs_guard_bad" || true)
vec=$(objdump --disassemble-symbols=_dcs_speedup --no-show-raw-insn "$BUNDLE" 2>/dev/null | grep -c "add.8h" || true)
echo "    log-string present : $guard  (expect 1)"
echo "    guard call sites    : $calls  (expect 2)"
echo "    NEON ops in hot path: $vec  (expect >0: codegen preserved)"
if [ "$guard" -ge 1 ] && [ "$calls" -ge 2 ] && [ "$vec" -gt 0 ]; then
  echo "OK: guard armed in ./build app. Play TOTAN; watch /tmp/dcs_speedup_guard.log"
else
  echo "WARN: verification failed, inspect above" >&2
  exit 1
fi
