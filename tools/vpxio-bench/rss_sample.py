#!/usr/bin/env python3
"""Samples resident memory across a real table load, tagged with the active load phase.

    tools/vpxio-bench/rss_sample.py "<table>.vpx" out.tsv [--cold] [--interval 0.05]

A single peak figure cannot answer the memory question on PR #3767. What matters is
whether the whole-file buffer is still resident while images are decoded out of it, so
this emits a timestamped curve with the active phase on every sample, then reports the
peak within each phase.

--cold runs `sudo purge` first and will prompt for a password.

Caveat when reading the output: this reports ps RSS, not phys_footprint. macOS judges
memory pressure on the latter, and RSS undercounts once pages are compressed. Treat
these numbers as a floor, not a ceiling.
"""
import argparse
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

# The "For profiling" markers alone attribute the texture loop to "Initializing physics",
# because the loop sits between player.cpp:492 and :703 with no marker of its own. The
# ProgressDialog lines are finer grained, so they are included to place the peak correctly.
PHASES = [
    "LoadGameFromFilename",
    "PinTable Data loaded",
    "Images, Sounds and Items loaded",
    "InitTablePostLoad",
    "Loading player plugins",
    "Compiling script",
    "Creating main window",
    "Initializing player",
    "Initializing renderer (global states & resources)",
    "Initializing inputs & implicit objects",
    "Initializing physics",
    "Initializing Renderer...",
    "Initializing Physics...",
    "Loading Textures...",
    "Starting Game Scripts...",
    "Initializing renderer",
    "Starting script",
    "Startup done",
    "Unpausing Game",
]
PHASE_RE = re.compile(r"\[[^\]]+@\d+\]\s+(" + "|".join(re.escape(p) for p in PHASES) + r")")

REPO = pathlib.Path(__file__).resolve().parents[2]
LOG = pathlib.Path.home() / "Library/Application Support/VPinballX/10.8/vpinball.log"
APP = REPO / "build/VPinballX_BGFX.app/Contents/MacOS/VPinballX_BGFX"


def build_flavour():
    """Optimization level the measured binary was actually compiled with.

    CMAKE_BUILD_TYPE in the cache is not proof. `cmake --build` inherits the type from
    configure time, so a Debug tree can be built with a command that looks like a release
    build. This reads the real compile lines instead.
    """
    cc = REPO / "build/compile_commands.json"
    if not cc.is_file():
        return "unknown (no compile_commands.json)"
    import json
    opts = set()
    for entry in json.load(cc.open()):
        cmd = entry.get("command") or " ".join(entry.get("arguments", []))
        for tok in cmd.split():
            if re.fullmatch(r"-O[0-3sgz]", tok):
                opts.add(tok)
    if not opts:
        return "UNOPTIMIZED-no-O-flag"
    return "+".join(sorted(opts))


def git(*args):
    try:
        return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True,
                              text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        return "unknown"


READ_PATH_SOURCES = [
    "standalone/PoleStorage.cpp",
    "standalone/PoleStorage.h",
    "standalone/PoleStream.cpp",
    "third-party/include/pole/pole.cpp",
    "third-party/include/pole/pole.h",
]


def read_path_fingerprint():
    """Content hash of the files that define the .vpx read strategy.

    The branch name is not enough to identify a variant, because the before/after pair is
    produced by reverting these files in place rather than by switching branches. This
    pins what was actually compiled.
    """
    import hashlib
    h = hashlib.sha256()
    for rel in READ_PATH_SOURCES:
        path = REPO / rel
        h.update(rel.encode())
        h.update(path.read_bytes() if path.is_file() else b"<missing>")
    return h.hexdigest()[:16]


def newest_source_mtime():
    """Newest mtime across the sources that affect the .vpx read path."""
    newest, where = 0.0, None
    roots = [REPO / "src", REPO / "standalone", REPO / "third-party/include/pole"]
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if path.suffix.lower() in (".cpp", ".h", ".hpp", ".c", ".mm", ".m"):
                mt = path.stat().st_mtime
                if mt > newest:
                    newest, where = mt, path
    return newest, where


def assert_build_is_current():
    """A stale binary silently invalidates the whole measurement, so refuse to run.

    This exists because the obvious mistake is to switch branches, forget to rebuild, and
    attribute the previous build's behaviour to the new code.
    """
    binary_mtime = APP.stat().st_mtime
    src_mtime, src_path = newest_source_mtime()
    if src_mtime > binary_mtime:
        rel = src_path.relative_to(REPO) if src_path else "?"
        sys.exit(
            f"error: build is stale.\n"
            f"  binary  {APP.relative_to(REPO)}  {time.ctime(binary_mtime)}\n"
            f"  source  {rel}  {time.ctime(src_mtime)}\n"
            f"Rebuild before measuring, or the numbers describe the previous build."
        )
    return binary_mtime


def power_source():
    out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
    m = re.search(r"drawing from '([^']+)'", out)
    return m.group(1) if m else "unknown"


def _make_rusage_reader():
    """Reads resident size and phys_footprint via proc_pid_rusage.

    Two reasons over shelling out to ps. ps only reports RSS, and macOS makes memory
    pressure decisions on phys_footprint, which measured 53% higher than RSS on this
    workload. And this avoids a fork per sample, so the sampling interval is honest.

    Layout is rusage_info_v0, which is append-only across versions:
      uint8 ri_uuid[16], then uint64 user_time, system_time, pkg_idle_wkups,
      interrupt_wkups, pageins, wired_size, resident_size, phys_footprint, ...
    """
    import ctypes
    import ctypes.util
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    proc_pid_rusage = libc.proc_pid_rusage
    proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    proc_pid_rusage.restype = ctypes.c_int
    RUSAGE_INFO_V0 = 0
    RESIDENT_OFF, FOOTPRINT_OFF = 16 + 8 * 6, 16 + 8 * 7

    def read(pid):
        buf = ctypes.create_string_buffer(16 + 8 * 16)
        rc = proc_pid_rusage(pid, RUSAGE_INFO_V0,
                             ctypes.cast(buf, ctypes.POINTER(ctypes.c_void_p)))
        if rc != 0:
            return None
        raw = buf.raw
        resident = int.from_bytes(raw[RESIDENT_OFF:RESIDENT_OFF + 8], "little")
        footprint = int.from_bytes(raw[FOOTPRINT_OFF:FOOTPRINT_OFF + 8], "little")
        return resident / 1048576.0, footprint / 1048576.0

    return read


read_memory = _make_rusage_reader()


class PhaseTail:
    """Reads only what this run appends to the log, incrementally."""

    def __init__(self, path):
        self.path = path
        self.offset = path.stat().st_size if path.exists() else 0
        self.phase = "launch"
        self.buf = ""
        # Markers must be tracked as "seen", not compared against the current phase.
        # Several arrive in one read, so the current phase can step straight over one.
        self.seen = set()

    def poll(self):
        if not self.path.exists():
            return self.phase
        size = self.path.stat().st_size
        if size < self.offset:
            self.offset = 0
        if size > self.offset:
            with self.path.open("r", encoding="utf-8", errors="replace") as fh:
                fh.seek(self.offset)
                self.buf += fh.read()
                self.offset = fh.tell()
            *lines, self.buf = self.buf.split("\n")
            for line in lines:
                m = PHASE_RE.search(line)
                if m:
                    self.phase = m.group(1)
                    self.seen.add(m.group(1))
        return self.phase


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("table")
    ap.add_argument("out")
    ap.add_argument("--cold", action="store_true")
    ap.add_argument("--interval", type=float, default=0.05)
    ap.add_argument("--deadline", type=float, default=180.0)
    # "Startup done" is not the end of memory growth. It is immediately followed by
    # Unpausing Game, after which the ROM boots, the DMD starts rendering, and every
    # texture that was not in used_textures.xml gets uploaded lazily on first render via
    # TextureManager::AddPendingUpload. Stopping at the marker truncates the measurement
    # before most texture memory is committed, so stop on a resident-size plateau instead.
    ap.add_argument("--plateau-delta", type=float, default=25.0,
                    help="MB of growth below which memory counts as settled")
    ap.add_argument("--plateau-window", type=float, default=15.0,
                    help="seconds of sub-threshold growth required to call it settled")
    ap.add_argument("--min-after-done", type=float, default=20.0,
                    help="minimum seconds to keep sampling past Startup done")
    ap.add_argument("--label", default="unlabelled",
                    help="which variant this run measures, e.g. master or pr3767-slurp")
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a = ap.parse_args()

    table = pathlib.Path(a.table)
    if not table.is_file():
        sys.exit(f"error: no such table: {table}")
    if not APP.is_file():
        sys.exit(f"error: no build at {APP}")
    binary_mtime = assert_build_is_current()

    if a.cold:
        print("purging filesystem cache (needs sudo)...", file=sys.stderr)
        subprocess.run(["sudo", "purge"], check=True)
        time.sleep(2)

    tail = PhaseTail(LOG)

    # Launch the app directly so its pid is unambiguous, then have caffeinate hold off
    # sleep by waiting on that pid. Wrapping the app in caffeinate instead would put the
    # app path into caffeinate's own argv, and any pgrep for it matches both processes.
    proc = subprocess.Popen([str(APP), "-Play", str(table)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = proc.pid
    caff = subprocess.Popen(["caffeinate", "-ims", "-w", str(pid)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    first = None
    for _ in range(200):
        first = read_memory(pid)
        if first is not None:
            break
        time.sleep(0.05)
    if first is None:
        proc.terminate()
        sys.exit("error: app did not start")

    samples = []
    start = time.monotonic()
    done_at = None
    settled_at = None
    stop_reason = "deadline"
    try:
        while True:
            mem = read_memory(pid)
            if mem is None:
                stop_reason = "process exited"
                break
            rss, foot = mem
            elapsed = time.monotonic() - start
            samples.append((elapsed, rss, foot, tail.poll()))
            if done_at is None and "Startup done" in tail.seen:
                done_at = elapsed

            if done_at is not None and elapsed - done_at >= a.min_after_done:
                # Settled means the running maximum has not advanced meaningfully across
                # the whole trailing window, not merely that the latest sample dipped.
                window = [s for s in samples if s[0] >= elapsed - a.plateau_window]
                if len(window) >= 2 and window[0][0] <= elapsed - a.plateau_window * 0.9:
                    peak_before = max(s[2] for s in samples if s[0] < elapsed - a.plateau_window)
                    peak_window = max(s[2] for s in window)
                    if peak_window - peak_before < a.plateau_delta:
                        settled_at = elapsed
                        stop_reason = "memory settled"
                        break

            if elapsed > a.deadline:
                print(f"timeout after {a.deadline}s without settling", file=sys.stderr)
                break
            time.sleep(a.interval)
    finally:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        caff.terminate()

    peak = max((s[1] for s in samples), default=0.0)
    peak_foot = max((s[2] for s in samples), default=0.0)
    # Memory at the old stop point, kept so the truncation error stays visible.
    rss_at_done = None
    if done_at is not None:
        at_done = [s[2] for s in samples if s[0] <= done_at + 2.0]
        rss_at_done = max(at_done) if at_done else None
    out = pathlib.Path(a.out)
    with out.open("w") as fh:
        fh.write(f"# variant\t{a.label}\n")
        fh.write(f"# read_path_sha\t{read_path_fingerprint()}\n")
        fh.write(f"# table\t{table}\n")
        fh.write(f"# size_bytes\t{table.stat().st_size}\n")
        fh.write(f"# branch\t{git('rev-parse', '--abbrev-ref', 'HEAD')}\n")
        fh.write(f"# commit\t{git('rev-parse', '--short', 'HEAD')}\n")
        fh.write(f"# src_dirty_files\t{len(git('status', '--porcelain', '--', 'src', 'standalone', 'third-party').splitlines())}\n")
        fh.write(f"# binary_built\t{time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(binary_mtime))}\n")
        fh.write(f"# build_flavour\t{build_flavour()}\n")
        fh.write(f"# power\t{power_source()}\n")
        fh.write(f"# cold\t{int(a.cold)}\n")
        fh.write(f"# interval_s\t{a.interval}\n")
        fh.write(f"# samples\t{len(samples)}\n")
        fh.write(f"# peak_rss_mb\t{peak:.1f}\n")
        fh.write(f"# peak_footprint_mb\t{peak_foot:.1f}\n")
        fh.write(f"# footprint_at_startup_done_mb\t{rss_at_done:.1f}\n" if rss_at_done else "# footprint_at_startup_done_mb\tn/a\n")
        fh.write(f"# startup_done_at_s\t{done_at:.1f}\n" if done_at else "# startup_done_at_s\tn/a\n")
        fh.write(f"# settled_at_s\t{settled_at:.1f}\n" if settled_at else "# settled_at_s\tnever\n")
        fh.write(f"# stop_reason\t{stop_reason}\n")
        fh.write(f"# reached_startup_done\t{'yes' if done_at is not None else 'no'}\n")
        fh.write("elapsed_s\trss_mb\tfootprint_mb\tphase\n")
        for e, rss, foot, ph in samples:
            fh.write(f"{e:.3f}\t{rss:.1f}\t{foot:.1f}\t{ph}\n")

    order, peaks, foots = [], {}, {}
    for _, rss, foot, ph in samples:
        if ph not in peaks:
            order.append(ph)
            peaks[ph], foots[ph] = rss, foot
        peaks[ph] = max(peaks[ph], rss)
        foots[ph] = max(foots[ph], foot)

    print(f"\npeak RSS {peak:.1f} MB / peak footprint {peak_foot:.1f} MB "
          f"over {len(samples)} samples -> {out}")
    print(f"stopped because: {stop_reason}")
    if done_at is not None:
        print(f"Startup done at {done_at:.1f}s, RSS there {rss_at_done:.1f} MB")
    if settled_at is not None:
        print(f"settled at {settled_at:.1f}s")
    if rss_at_done and peak_foot > rss_at_done:
        print(f"footprint growth after Startup done: +{peak_foot - rss_at_done:.1f} MB "
              f"-- lazily uploaded textures")
    print(f"\n{'phase':<50} {'RSS':>10} {'footprint':>12}")
    for ph in order:
        print(f"  {ph:<48} {peaks[ph]:8.1f} MB {foots[ph]:9.1f} MB")


if __name__ == "__main__":
    main()
