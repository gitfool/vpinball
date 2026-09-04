# Windows load timings

Measures `.vpx` load phases on Windows using the same boundaries and the same content
fingerprint as the macos harness in `tools/vpxio-bench`, so results are directly comparable.

The parser was validated against the macos harness on the same log file and produces identical
output, fingerprint included:

```
python  open_parse=0.031  extract=3.143  to_startup=7.245  content=522afb44f631  errors=7
pwsh    open_parse=0.031  extract=3.143  to_startup=7.245  content=522afb44f631  errors=7
```

## The two Windows builds are not what the names suggest

This matters more than anything else here.

| | `PLATFORM=windows` | `PLATFORM=windows-mingw` |
| --- | --- | --- |
| toolchain | MSVC, needs VS | GCC via MSYS2 UCRT64 |
| source list | `VPX_SOURCES` | `VPX_STANDALONE_SOURCES` |
| `__STANDALONE__` | not defined | **defined** |
| editor UI | yes | no |
| VBScript | Windows scripting | `libwinevbs` |
| **container storage** | **OLE structured storage** | **POLE** |

So `windows-mingw` is a standalone build that targets Windows. It is not a different way of
producing the same binary. Critically, it already reads `.vpx` through POLE, which means a
POLE-based Windows build exists and ships today.

That is worth exploiting. Comparing the two builds of the same commit on the same machine
measures what unifying Windows onto POLE would change, with no migration work at all.

You do **not** need the VS IDE for the MSVC build. CI drives it from the command line with the
Visual Studio generator, which invokes MSBuild for you.

## One-time setup

```powershell
git fetch --all
git checkout windows-bench
mkdir $HOME\vpx-bench
copy tools\vpxio-bench\windows\vpx-bench.ps1 $HOME\vpx-bench\
```

Copy it out of the repo, because the build steps switch branches and would delete it.

Optional, only for `-Cold`: put Sysinternals
[RAMMap](https://learn.microsoft.com/sysinternals/downloads/rammap) on `PATH` and use an
elevated shell. Without it `-Cold` refuses rather than quietly labelling warm numbers cold.

## Build and stash the four variants

Configure once per platform, into separate build trees so they do not fight:

```powershell
# MSVC, full build with the editor, reads via OLE. From any shell, no IDE.
cmake -DRENDERER=BGFX -DPLATFORM=windows -DARCH=x64 -G "Visual Studio 18 2026" -A x64 -B build-msvc
```

```bash
# MSYS2 UCRT64 shell, standalone build, reads via POLE
cmake -DRENDERER=BGFX -DPLATFORM=windows-mingw -DARCH=x64 -DCMAKE_BUILD_TYPE=Release -B build-mingw
```

Then for each of the two refs, build both platforms and stash:

```powershell
git checkout <vpinball/vpinball master>
cmake --build build-msvc --config Release --parallel
& $HOME\vpx-bench\vpx-bench.ps1 -Stash msvc-master -BuildDir build-msvc
# ... and in the UCRT64 shell: cmake --build build-mingw -- -j$(nproc)
& $HOME\vpx-bench\vpx-bench.ps1 -Stash mingw-master -BuildDir build-mingw

git checkout perf-vpx-load-order
cmake --build build-msvc --config Release --parallel
& $HOME\vpx-bench\vpx-bench.ps1 -Stash msvc-order -BuildDir build-msvc
& $HOME\vpx-bench\vpx-bench.ps1 -Stash mingw-order -BuildDir build-mingw
```

If you only have time for two, build `msvc-master` and `msvc-order`. That answers whether #3817
is safe to merge for Windows users, which is the question blocking an open PR.

## If your mingw and MSVC checkouts are separate

They usually are, since MSYS2 has its own home. Two checkouts mean two chances to accidentally
compare different commits, so this is the part to be careful about.

**Run the script from Windows, never from inside MSYS2.** The MSYS2 home is an ordinary NTFS
path from the Windows side, so build in the UCRT64 shell and then stash from a normal pwsh:

```powershell
& $HOME\vpx-bench\vpx-bench.ps1 -Stash mingw-master `
  -BuildDir 'C:\Users\Sean\scoop\apps\msys2\current\home\Sean\devel\vpinball\build-mingw'
```

No path translation, and `-Stash` reads the commit from *that* path's repository rather than from
the current directory, so it labels the mingw build with the mingw checkout's commit.

It does work from inside MSYS2 if you prefer, but pwsh is a Windows executable so every path has
to be converted:

```bash
pwsh.exe -File "$(cygpath -w ~/vpx-bench/vpx-bench.ps1)" -Stash mingw-master \
         -BuildDir "$(cygpath -w "$PWD/build-mingw")" \
         -WorkDir  "$(cygpath -w ~/vpx-bench)"
```

`-WorkDir` matters there. `$HOME` in Windows pwsh is `C:\Users\Sean`, while `~` in MSYS2 is the
MSYS2 home, so mixing the two environments without pinning `-WorkDir` scatters your variants
across two folders and `-Run` will only see half of them. Pick the Windows-side path and use it
everywhere.

**Check the two checkouts agree before each pair of builds.** The script records sha, branch and
repo path per variant, prints them when `-Run` starts, and warns if a checkout is dirty or if two
variants report the same commit. What it cannot know is that your two checkouts were *meant* to
match. So for each ref:

```bash
git -C ~/devel/vpinball rev-parse --short HEAD              # MSYS2 side
```
```powershell
git -C C:\path\to\msvc\checkout rev-parse --short HEAD    # Windows side
```

Confirm they agree, once for master and again for `perf-vpx-load-order`. Remember to
`git fetch --all` in both, since `perf-vpx-load-order` may not exist in the mingw checkout yet.

## Run

Run the two platforms **separately**, because they may write their logs to different paths and
auto-discovery picks the most recently written one, which would follow the wrong build.

```powershell
cd $HOME\vpx-bench

# local disk first: quickest, most controlled, and msvc-master's extract here is the
# number that decides whether unification is a performance project at all
.\vpx-bench.ps1 -Run -Out msvc-local-warm.tsv  -Variants msvc-master,msvc-order   -Reps 3 -Tables 'C:\Tables\Fish Tales (Williams 1992).vpx','C:\Tables\Dark Chaos (Original 2025).vpx'
.\vpx-bench.ps1 -Run -Out mingw-local-warm.tsv -Variants mingw-master,mingw-order -Reps 3 -Tables 'C:\Tables\Fish Tales (Williams 1992).vpx','C:\Tables\Dark Chaos (Original 2025).vpx'

# then the NAS, your actual setup
.\vpx-bench.ps1 -Run -Out msvc-nas-warm.tsv  -Variants msvc-master,msvc-order   -Reps 3 -Tables '\\nas\...\Fish Tales (Williams 1992).vpx','\\nas\...\Dark Chaos (Original 2025).vpx'
.\vpx-bench.ps1 -Run -Out mingw-nas-warm.tsv -Variants mingw-master,mingw-order -Reps 3 -Tables '\\nas\...\Fish Tales (Williams 1992).vpx','\\nas\...\Dark Chaos (Original 2025).vpx'
```

Keep MSVC and mingw in separate runs via `-Variants`. They may write to different log files, and
auto-discovery picks the most recently written one, which would follow whichever build ran last.


Add `-Cold` for the cold equivalents, elevated and with RAMMap present. Cold matters far more
for the NAS case: on macos, master's extract barely moved between cold and warm on a local SSD,
2.537s against 2.339s, because its cost is per-block overhead rather than data transfer.

Use the same two tables as macos so the numbers line up. The loop is rep, then table, then
build, so the builds for one table sit adjacent in time and link drift spreads across them.

Windows will open and be killed once `Startup done` reaches the log. That is expected.

## What each comparison settles

* **`msvc-master` extract, in absolute terms.** The number that decides whether unification is a
  performance project. macos master is 2.537s cold and 2.339s warm on a local SSD for Fish
  Tales. Comparable means OLE has the same per-block problem and unification would deliver a
  similar 5x to 12x. A few hundred milliseconds means OLE already handles this and unification
  buys tidiness only.
* **`msvc-master` against `mingw-master`.** OLE against POLE, same machine, same commit. Direct
  evidence for or against unification, available today.
* **`msvc-master` against `msvc-order`.** Whether #3817 as it would actually ship helps or hurts
  Windows. It gives Windows serialised reads with no reordering, because `GetStreamOffsets`
  returns false on OLE. Emulated on macos it was 1.16x and 2.19x faster, but with POLE
  underneath.
* **`mingw-master` against `mingw-order`.** Whether the POLE work in #3814 and #3817 delivers on
  Windows. This is the only Windows build it currently reaches.
* **Fingerprints across all four.** If they agree, and agree with macos (`cad268adfcc5` for Fish
  Tales, `33babd9c056a` for Dark Chaos), that is direct evidence OLE and POLE construct
  identical table structure. The unification argument depends on that and nobody has checked it.

Three caveats to keep in mind when reading MSVC against mingw. Different compilers mean
different codegen, though the extract phase is dominated by per-block overhead rather than
compute, so it is a second-order effect. `to_startup` is not strictly comparable because the two
use different script engines, whereas `extract` is pure container reading. And mingw has no
editor, so it says nothing about the write side.

## What to send back

The `.tsv` files. They carry commit shas, table names, cache mode and every individual sample.
`-Summarise <file>` prints medians if you want a look first.

## If something goes wrong

* **Every sample is `NaN`** That build logs somewhere other than the discovered path. Find its
  `vpinball.log` and pass `-LogPath`. The script warns about this case explicitly.
* **"no vpinball.log"** File logging defaults on, but check Editor Options.
* **"nothing stashed"** `-Stash` not run, or `-WorkDir` differs between calls.
* **The MSVC build fails on `MemoryIStream` in `src/utils/fileio.h`** Useful information in its
  own right. Those COM signatures were written against the wine headers used for standalone, and
  MSVC may reject `__stdcall`, `const struct _GUID &` or `union _LARGE_INTEGER`. If so, #3817
  does not currently compile on Windows and I need the errors.
