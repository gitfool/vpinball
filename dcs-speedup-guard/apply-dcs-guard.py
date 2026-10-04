#!/usr/bin/env python3
"""Insert the dcs_speedup wild-base diagnostic guard into vpinball's bundled
PinMAME, string-anchored so it survives whitespace drift and minor version
bumps. Idempotent: running twice is a no-op. Latin-1 (binary-safe) so the
driver file's non-UTF8 bytes are preserved.

This only edits the source. Run build-dcs-guard.sh afterwards to compile,
install, and verify. See README.md for the whole workflow.
"""
import io, sys

WMSSND = ("/Users/sean/devel/vpinball/external/macos-arm64/Release/"
          "pinmame/pinmame/src/wpc/wmssnd.c")

MARKER = "dcs_guard_bad"  # presence => already patched

HELPER = (
"/* ===== TEMPORARY diagnostic guard (dcs_speedup wild-base crash hunt) ===== */\n"
"/* Fires only when a dcs_speedup source read would fall outside the ADSP CPU   */\n"
"/* region. Silent on the normal path. Logs at most DCS_GUARD_MAX events to a   */\n"
"/* small capped file, then goes quiet. Crash-preventing: callers bail to the   */\n"
"/* real opcode. dcs_speedup itself keeps normal (-O3) codegen so a             */\n"
"/* codegen-sensitive fault still reproduces; the guard lives in a separate     */\n"
"/* noinline side-effecting helper the optimizer cannot elide. Remove before    */\n"
"/* shipping. */\n"
"#include <execinfo.h>\n"
"#define DCS_GUARD_MAX 5\n"
"static int dcs_guard_count = 0;\n"
"__attribute__((noinline)) static int dcs_guard_bad(const UINT16 *elem, const char *which, UINT32 pc, UINT32 volumeOP, int idx) {\n"
"  const int cpuNo = dcslocals.brdData.cpuNo;\n"
"  UINT8 *cpuRegion = dcslocals.cpuRegion;\n"
"  UINT8 *expected  = memory_region(REGION_CPU1 + cpuNo);\n"
"  size_t len       = memory_region_length(REGION_CPU1 + cpuNo);\n"
"  const UINT8 *lo  = cpuRegion;\n"
"  const UINT8 *hi  = cpuRegion + len;\n"
"  const UINT8 *p   = (const UINT8 *)elem;\n"
"  if (cpuRegion != NULL && expected != NULL && cpuRegion == expected && len != 0\n"
"      && p >= lo && (p + sizeof(UINT16)) <= hi)\n"
"    return 0; /* normal, in-range: silent */\n"
"  if (dcs_guard_count < DCS_GUARD_MAX) {\n"
"    dcs_guard_count++;\n"
"    FILE *lf = fopen(\"/tmp/dcs_speedup_guard.log\", \"a\");\n"
"    if (lf) {\n"
"      fprintf(lf, \"=== dcs_speedup OUT-OF-RANGE #%d (%s) ===\\n\", dcs_guard_count, which);\n"
"      fprintf(lf, \"  pc=0x%x volumeOP=0x%x idx=%d (raw field 0x%x)\\n\",\n"
"              pc, volumeOP, idx, (volumeOP>>4)&0x3fff);\n"
"      fprintf(lf, \"  dcslocals.cpuRegion=%p  memory_region(expected)=%p  %s\\n\",\n"
"              (void*)cpuRegion, (void*)expected,\n"
"              (cpuRegion==expected) ? \"[BASE OK: index drove it out]\" : \"[BASE CORRUPT ON ENTRY]\");\n"
"      fprintf(lf, \"  region len=0x%zx  read elem=%p  valid=[%p,%p)\\n\",\n"
"              len, (void*)p, (void*)lo, (void*)hi);\n"
"      fprintf(lf, \"  RAMbankPtr=%p  brdData.cpuNo=%d\\n\",\n"
"              (void*)dcslocals.RAMbankPtr, cpuNo);\n"
"      void *bt[32];\n"
"      int n = backtrace(bt, 32);\n"
"      char **sy = backtrace_symbols(bt, n);\n"
"      if (sy) { for (int i = 0; i < n; i++) fprintf(lf, \"  bt[%d] %s\\n\", i, sy[i]); free(sy); }\n"
"      fprintf(lf, \"\\n\");\n"
"      fclose(lf);\n"
"    }\n"
"  }\n"
"  return 1; /* out of range: caller must bail */\n"
"}\n"
"#define DCS_GUARD_BAIL_OP (*(UINT32 *)&OP_ROM[ADSP2100_PGM_OFFSET + ((pc)<<2)])\n"
"/* ======================================================================= */\n\n"
)

FUNC_SIG = "UINT32 dcs_speedup(UINT32 pc) {\n"

BRANCH_A_OLD = "    volume = ram1source[((volumeOP>>4)&0x3fff)-0x1000];\n"
BRANCH_A_NEW = (
"    {\n"
"      const int dcs_idxA = (int)(((volumeOP>>4)&0x3fff)-0x1000);\n"
"      if (dcs_guard_bad(&ram1source[dcs_idxA], \"A: ram1source[idx]\", pc, volumeOP, dcs_idxA))\n"
"        return DCS_GUARD_BAIL_OP;\n"
"    }\n"
) + BRANCH_A_OLD

BRANCH_B_OLD = "    volume = ram2source[((volumeOP>>4)&0x3fff)-0x3800];\n"
BRANCH_B_NEW = (
"    {\n"
"      const int dcs_idxB = (int)(((volumeOP>>4)&0x3fff)-0x3800);\n"
"      if (dcs_guard_bad(&ram2source[dcs_idxB], \"B: ram2source[idx]\", pc, volumeOP, dcs_idxB))\n"
"        return DCS_GUARD_BAIL_OP;\n"
"    }\n"
) + BRANCH_B_OLD


def main():
    with io.open(WMSSND, "r", encoding="latin-1", newline="") as f:
        src = f.read()

    if MARKER in src:
        print("Already patched (dcs_guard_bad present); no change.")
        return

    for needle in (FUNC_SIG, BRANCH_A_OLD, BRANCH_B_OLD):
        if needle not in src:
            sys.exit("ERROR: anchor not found, source changed too much:\n  " + needle.strip())

    src = src.replace(FUNC_SIG, HELPER + FUNC_SIG, 1)
    src = src.replace(BRANCH_A_OLD, BRANCH_A_NEW, 1)
    src = src.replace(BRANCH_B_OLD, BRANCH_B_NEW, 1)

    with io.open(WMSSND, "w", encoding="latin-1", newline="") as f:
        f.write(src)
    print("Patched OK: guard helper + branch A + branch B inserted.")


if __name__ == "__main__":
    main()
