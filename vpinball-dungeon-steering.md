---
inclusion: always
---

# vpinball dungeon

Personal research and docs for the vpinball repo, kept on a floating orphan
branch called `dungeon` (no relationship to `master`). This steering file is the
convention doc; it explains where the dungeon lives and how to work with it.

## Where the dungeon lives

- Branch: `dungeon`, a parentless orphan on the `origin` fork. It floats free of
  `master` on purpose, so it never appears as a fork or merges into project code.
- Working copy: a git worktree at `../vpinball-dungeon` (sibling of the main
  checkout). The orphan is always checked out there.
- This steering file's canonical copy lives ON the orphan
  (`vpinball-dungeon-steering.md`) and is surfaced into the main checkout at
  `.kiro/steering/vpinball-dungeon.md` via a symlink into the worktree. Edit it in
  the worktree; the main checkout follows the link.

## The dungeon docs (all in the worktree root, kebab-case)

These are the *dungeon docs*, code-level research notes on the orphan, for a
human or AI coder about to change vpinball. They are distinct from the main repo's
`docs/` directory on `master` (which is user- and creator-facing); when this file
or the user says "dungeon docs" it means the files here, not the project
documentation.

The worktree root has a `README.md` as the web landing page (a thin router into
the hub, not a second index), and `vpinball-architecture.md` as the hub. Start at
the hub: it carries the overview, the repo map, the build, and an index of every
subsystem and topic deep-dive with a one-line description and a link. The other
`vpinball-*.md` files are the deep-dives it points to. Neither the README nor this
file re-lists them, so they cannot go stale as docs are added, renamed, or
retired; the hub's index is the source of truth.

Single-file docs live flat at the root. A large subject that warrants many files
gets its own subdirectory with its own `README.md` (for example a future
`vpinball-plugin-pinmame/` for the PinMAME dependency deep-dive).

## How to work with it

Read and edit the docs in the `../vpinball-dungeon` worktree while working on any
feature branch in the main checkout. The two never interact:
- Doc edits commit to `dungeon` (from inside `../vpinball-dungeon`).
- Code edits commit to your feature branch (from the main checkout).
- No cherry-pick, no stray docs commit on feature branches, no risk of docs
  leaking into a PR, nothing to reconcile.

To read a doc without touching your tree: `git show dungeon:<file>.md`.

## Bootstrapping / rewiring (the command you'll forget)

The worktree lives outside the main checkout, so `git clean -ffxd` in the main
repo never touches the docs. It only removes the steering symlink (and the empty
`.kiro/` dir). The local exclude under `.git/info/` also survives a clean.

`vpinball-dungeon-bootstrap.sh` (committed to the orphan, executable, idempotent)
re-establishes everything: on a fresh clone it fetches `dungeon` and creates the
worktree; after a clean it just rewires the steering symlink. It assumes the
dungeon lives on `origin`, and re-running when already wired is a no-op.

**Fresh clone, curl bootstrap (run from inside the freshly-cloned vpinball dir):**

    curl -fsSL https://raw.githubusercontent.com/gitfool/vpinball/dungeon/vpinball-dungeon-bootstrap.sh | bash

**After the worktree already exists (e.g. post `git clean -ffxd`):**

    ../vpinball-dungeon/vpinball-dungeon-bootstrap.sh

Either way, run it from inside the vpinball clone. It anchors on the git toplevel.

## Commits and squashing

While actively working on the dungeon docs, commit normally, adding as many commits
as the work warrants. Don't force `--amend` mid-flight just to preserve a single
commit; ordinary incremental commits are fine and expected here.

The intent, though, is that `dungeon` ultimately settles back to a *single
parentless orphan commit* (less noise in GitKraken, and it stays a clean float).
So expect the user to ask, once a batch of doc work is done, to squash the branch
back down to one commit. When asked, rebuild the orphan tree from the current
worktree state and `git push --force-with-lease`. The branch must remain
parentless (no `master` ancestry). This squash is a deliberate, on-request
tidy-up, not something to do automatically after every edit.

## Building and testing pinmame fixes through vpinball

vpinball has a hard dependency on pinmame and bundles its own copy, so we
reproduce, fix, and test pinmame driver issues here in the vpinball build, then
port the change to the sibling `../pinmame` checkout for the upstream PR.

### The pinmame copy vpinball builds (not the standalone checkout)

The build compiles its *own* pinmame, fetched by SHA, not `~/devel/pinmame`:
- `platforms/config.sh` pins `PINMAME_SHA`; `platforms/<platform>/external.sh`
  downloads that tarball to `external/<platform>/Release/pinmame/pinmame/` and
  builds `libpinmame` from `cmake/libpinmame/CMakeLists.txt`. A `cache.txt` holds
  the built SHA to skip rebuilds.
- Patch the driver in that extracted tree, e.g. on macOS arm64:
  `external/macos-arm64/Release/pinmame/pinmame/src/wpc/<driver>.c`.
- Rebuild the dylib directly (fast, ~15s incremental):
  `cmake --build external/macos-arm64/Release/pinmame/pinmame/build --target pinmame_shared -j`
- Do NOT re-run `external.sh` to rebuild; it re-downloads the tarball and clobbers
  the patch.

### Swapping the built dylib into the app

The app bundle embeds the dylib at
`build/VPinballX_BGFX.app/Contents/Frameworks/libpinmame.<ver>.dylib`
(with `libpinmame.dylib` symlinked to it). Copy the freshly built dylib over it,
then re-sign ad-hoc so macOS loads it:

    codesign --force --sign - build/VPinballX_BGFX.app/Contents/Frameworks/libpinmame.<ver>.dylib

### Running a table

Launch a table directly (background process, then read stderr via the process
tools):

    ./build/VPinballX_BGFX.app/Contents/MacOS/VPinballX_BGFX -Play "<table.vpx>"

To exit the table yourself, send it `SIGINT` (Ctrl+C) — its signal handler now
drives a clean shutdown (player close, PUP stop, all plugins unloaded), which the
static-destructor crash on exit used to prevent but no longer does in current
builds. Prefer this over a hard process kill: the graceful teardown is observable
in the log (`Closing from signal: 2` … `Closing VPX...`), so it doubles as a way
to confirm the exit path (and any destructor cleanup you added) runs without fault.
Get the pid with `pgrep -f 'VPinballX_BGFX.*<table>'` and `kill -INT "$pid"`.

For driver-init diagnostics, a temporary `fprintf(stderr, ...)` in the driver's
`MACHINE_INIT` is the deterministic surface (e.g. dumping each solenoid's final
output type). Remove it before committing.

Two testing modes, depending on whether the check needs gameplay:
- **Needs user input** (playing shots, watching a visual effect): launch the table,
  then give the user clear instructions on exactly what to do and what to look for.
  The user plays, quits with the Esc key, and reports the result. Do not quit the
  table yourself in this mode. (Note that self-driven screen capture is blocked by
  macOS Screen Recording permission, so a visual effect is one the user must confirm
  — you cannot screenshot the window yourself to check it.)
- **No interaction** (startup dumps, log output, anything observable without
  playing): drive it end to end yourself, read the output, and quit the table
  yourself with `SIGINT` (Ctrl+C, as above) when done. The user is hands-off here.

### The NAS tables (functional, ROMs included)

Tables live at `/Volumes/Emulators/Pinball/Tables/<Table Name> (<Manufacturer> <Year>)/`.
Every table there is complete and playable: the `vpx` file, its `vbs` file, and a
local `zip` in `pinmame/roms/` with the ROM already present, plus altsound/pup/etc.
as needed. Don't hunt for ROMs or assume they're missing; the table's own
`pinmame/roms/` has them.

The files you actually work with, the `vpx` and the `vbs` file, sit directly in the
table subdirectory, not deeper. The user always extracts the `vbs` script from the
`vpx` file so it can be searched and edited for testing: an external `vbs` file
beside the `vpx` overrides the one embedded in the `vpx` whenever it exists, so
editing that file is how you change table script behavior for a test.

`/Volumes/Emulators` is a network drive. Two rules for touching it:
- A broad `find` over it times out. Target known subpaths instead (the table dir,
  its `pinmame/roms/`).
- Don't recursively traverse a table's subdirectories: they can be very large
  (puppacks, media, altsound). Read the top-level `vpx`/`vbs` files and the specific
  `pinmame/roms/` path you need, nothing deeper.

### Ball control (steer the ball to hit specific shots)

Add to the table's `ini` file to enable the built-in debugger ball control on macOS
BGFX:

    [Editor]
    BallControlAlwaysOn = 1

Hold left mouse to steer the active ball, double-click to teleport it to the
cursor (drops from glass height), left flipper key releases it. Revert the ini
line when done.

### Editing driver C files (capcom.c, sam.c, ...)

Two traps when editing these with the normal edit tools:
- They contain non-UTF-8 bytes (e.g. the micro sign `0xb5` in timing comments).
- The editor strips trailing whitespace file-wide on save, producing many spurious
  whitespace-only diff hunks.

To keep the diff to just the intended change, restore the file from `origin/master`
and apply the edit with a small script that reads/writes `encoding='latin-1'`
(binary-safe), then verify `git diff origin/master -- <file>` shows only the
intended hunks before committing.

## Porting the fix to the pinmame repo and opening the PR

Once verified in vpinball, apply the same edit to the sibling `../pinmame`
checkout and PR it upstream.

- Remotes there: `origin` = `gitfool/pinmame` (fork), `upstream` = `vpinball/pinmame`.
- Branch off `master`, apply the edit (same latin-1-script care as above),
  commit with a subject-only message (details go in the PR body, not the commit).
- Push to the fork and open the PR into `vpinball/pinmame` `master` from the fork
  branch.
- Part numbers: write bulb/part numbers in the authentic `#89` form, but stop
  GitHub from autolinking them as issue references. GitHub autolinks a bare `#89`
  everywhere it renders, including commit subjects and PR/issue titles. Two ways to
  suppress it, by context:
  - **Prose** (PR/issue body, comments): wrap in backticks, e.g. `` `#89` ``. The
    code span renders literally and does not autolink.
  - **Commit subjects and PR/issue titles** (no markdown, so backticks would show
    as literal characters): put a space after the hash, e.g. `# 89`. Any space
    between `#` and the digits defeats the autolink while keeping the hash.
  Leave real issue/PR references as bare `#662` so they do link.
