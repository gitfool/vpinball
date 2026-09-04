# vpxio-bench

Benchmark and profiling harness used to investigate `.vpx` table load performance
(PRs #3814, #3817, #3866). Archived here so it can be resurrected for future load or I/O
work. These scripts were never part of the main build; they lived under a git-excluded
`tools/` path during development.

Everything here is macOS-specific (the profiling tools are `vmmap`, `heap`, `footprint`,
`proc_pid_rusage`, `purge`, `caffeinate`). The measurement methodology, cold-vs-warm and
network-vs-local, carries over to any platform, but the commands do not.

## How to use it

Drop this directory back into a vpinball checkout at `tools/vpxio-bench/`, then run the
scripts from the repo root. Most read the load-phase markers from the app log at
`~/Library/Application Support/VPinballX/10.8/vpinball.log`.

Cold measurements need `purge`, which needs root, so those runs go through `sudo`. Warm
runs (`WARM=1`) do not. Network vs local is the axis that matters most: a table on an SMB
share behaves nothing like one on a local SSD, so always record which one a number is.

## The tools

**`app-matrix.sh`.** The main harness. Builds and stashes one `.app` bundle per git ref,
then loads real tables across every stashed build, cold or warm, N reps, and parses the
extract-phase timing plus a content fingerprint and error count from the log. This is the
tool that produced the headline numbers. `build <ref>...` stashes bundles into `.apps/`;
`run <out.tsv> <table>...` runs the matrix. `WARM=1` skips the purge. `REPS=N` sets the
repetition count. `BYBUILD=1` swaps the loop to rep then build then table, so no build
reads a table right after another build pulled the same file across the wire (removes a
same-table cache-warming confound on cold network runs). Default loop is rep, table, build
so the builds for one table run adjacent and network drift hits them equally.

**`summarise.py`.** Reads a repeated matrix and reports per-arm median, min, max, and
spread, then flags which pairwise gaps are larger than the worst single-arm spread. Built
because single-shot numbers off this harness were being over-read; over WiFi the link
drifts enough that identical configs measured tens of percent apart. Any gap smaller than
an arm's own spread is not evidence.

**`heap_compare.sh` and `heap_diff.py`.** Memory profiling. `heap_compare.sh` launches two
builds, freezes each with SIGSTOP at the extract-phase boundary, and snapshots `heap`,
`vmmap`, and `footprint`. `heap_diff.py` parses the two snapshots and diffs live heap
allocations by class and dirty pages by VM region, then computes the allocator overhead
(malloc dirty pages minus live heap). This is what separated live allocations from
allocator-retained pages when tracking down a memory delta.

**`rss_sample.py`.** Samples resident size and `phys_footprint` over a whole table load,
tagged with the active load phase, via `proc_pid_rusage` (no fork per sample). Reports the
peak within each phase. Note `phys_footprint` and `ps` RSS disagree; state which one a
number is.

**`stream_survey.py`.** Scans a directory tree of `.vpx` files and reports stream-size
statistics: counts, size buckets, percentiles, the largest single stream per table, and
how many tables exceed given thresholds. Uses the Python `olefile` package
(`pip3 install --user olefile`). Answers questions about the table corpus, for example how
large the biggest embedded image is across a whole collection.

**`memcurve.sh`.** Sweeps load pool size and the in-flight byte cap, recording the loader's
own reported high-water mark against OS peak RSS. Needs an instrumented build that reads
`VPX_BENCH_POOLSIZE` and `VPX_BENCH_MAXINFLIGHT` and logs an `INSTR` line. That build no
longer exists, so this needs its companion instrumentation re-created before it will run.
Kept for the sweep logic.

**`scan_layout.sh`.** Classifies every `.vpx` in a tree by whether its physical stream
layout is closer to forward or reverse read order, and counts each. Needs a `layout` helper
binary that was built by a now-removed standalone bench harness, so it needs that companion
re-created before it will run. Kept for the classification logic.

**`tsan-run.sh`.** Builds a ThreadSanitizer tree (separate from the main build, since the
project's sanitizer flag turns on ASan, which is mutually exclusive with TSan) and runs a
table load under it, then triages the report by whether each race names the read path or
the shutdown/plugin-teardown path. `run` loads and kills; `run-exit` drives a clean quit so
`~Player` runs (needed to reach the plugin-teardown races). Encodes two traps worth keeping:
suppression files use `#` comments and a `//` comment makes TSan die during init, and a
`called_from_lib` entry that matches more than one loaded library is also fatal.

## Windows

`windows/vpx-bench.ps1` is the Windows counterpart to `app-matrix.sh`: a PowerShell harness
that measures `.vpx` load timings on Windows, where the profiling tools above do not exist.
See `windows/README.md` for usage. Useful for confirming the network path behaves the same
on Windows as on macOS, since the network detection (`IsNetworkPath`, UNC plus
`GetDriveType`) is a separate code path there.

## What was dropped

The one-off codemods that applied specific source patches during the investigation
(`apply_unit1.py`, `apply_unit1b.py`, `apply_unit3a.py`, `apply_unit3b.py`, `patch_pole.py`)
and the standalone micro-benchmark harness for the abandoned whole-file-slurp approach
(`run.sh`, `matrix.sh`, plus their `bench.cpp` / `layout.cpp`) are not archived. The code
they applied is either merged into master or was deliberately abandoned, and their anchors
are exact source text that has since changed, so they would not re-apply cleanly anyway.
