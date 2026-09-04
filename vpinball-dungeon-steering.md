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
