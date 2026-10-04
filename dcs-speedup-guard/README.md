# dcs_speedup wild-base crash: re-arm kit

A blue-moon crash. VPinballX_BGFX died once mid-play of Tales of the Arabian
Nights (Williams 1996), a WPC-95 DCS game, with a wild pointer read in the
bundled PinMAME DCS audio speedup. It has not reproduced since (one `.ips`, no
repro across a 150,000-call instrumented session). The full diagnosis lives in
the global dungeon at `~/dungeon/dcs-speedup-crash-diagnosis.md`.

This directory is the button to press when it crashes again: re-arm an always-on
guard that catches the next occurrence without a debugger, keeps the game alive,
and records the one fact that splits the remaining hypotheses.

## When to use

Only when TOTAN (or another WPC-95 DCS game) crashes again and you want to catch
it. The guard does not need to run day-to-day. Because normal vpinball rebuilds
and any pinmame `external.sh` re-fetch overwrite the bundled dylib, the guard is
not meant to persist. You re-apply it on demand with one command.

## Re-arm it

```sh
bash /Users/sean/devel/vpinball-dungeon/dcs-speedup-guard/build-dcs-guard.sh
```

Idempotent and self-verifying. It patches the source, rebuilds only the pinmame
dylib, swaps it into `./build/VPinballX_BGFX.app`, re-signs, and confirms the
guard is live and that `dcs_speedup` kept its optimized codegen. Then launch the
`./build` app normally and play.

## What it does at runtime

- Silent on the normal path. Zero logging when all is well.
- On a read that would fall outside the ADSP CPU region, it writes a few lines to
  `/tmp/dcs_speedup_guard.log` (capped at 5 events, then quiet) and bails to the
  real opcode, so the game keeps running instead of crashing.
- `dcs_speedup` itself keeps normal `-O3` codegen (NEON intact), so a
  codegen-sensitive fault still reproduces. The guard rides in a separate
  `noinline` side-effecting helper (`dcs_guard_bad`) the optimizer cannot elide.

## Read the catch

```sh
cat /tmp/dcs_speedup_guard.log
```

The deciding line per event:

- `[BASE CORRUPT ON ENTRY]` means `dcslocals.cpuRegion` no longer equals
  `memory_region(...)`: something upstream trashed the base. Points at a stray
  write or a concurrency/wrong-context bug. Next step: hardware watchpoint on
  `dcslocals.cpuRegion` to catch the writer.
- `[BASE OK: index drove it out]` means the base was fine and the computed index
  pushed the read out of range: an HLE-misfire / bad-input bug in the decode path.

Either way the backtrace and `pc`/`volumeOP`/`idx` are logged. Bring the file
back and we take it from there.

## Revert to a clean build

Any normal vpinball rebuild or `external.sh` re-fetch restores the stock dylib.
To force it now: rebuild pinmame from a clean source checkout, or re-fetch, then
rebuild the app. The patch only ever touched the extracted-tree
`src/wpc/wmssnd.c`; nothing in the committed vpinball or pinmame source changed.

## Files

- `apply-dcs-guard.py`: string-anchored, idempotent, latin-1-safe source patch.
  Survives whitespace drift and minor pinmame bumps as long as the two read lines
  still exist.
- `build-dcs-guard.sh`: patch + build + install + sign + verify in one shot.
- `README.md`: this file.

Base pinmame at capture time: `PINMAME_SHA=268854a18be9ad334569b5654345c06a7d0ef521`.
Crash dump: `~/Library/Logs/DiagnosticReports/VPinballX_BGFX-2026-10-04-180927.ips`.
