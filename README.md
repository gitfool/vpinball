# vpinball dungeon

Code-level research notes on the [Visual Pinball X](https://github.com/vpinball/vpinball)
codebase, for a coder (human or AI) about to change it. `dungeon` is a parentless
orphan branch. It has no `master` ancestry, so it never shows up in project history
and never merges into the code. It lives on a fork of the project but is not a
development branch of it. Docs only, so far.

These capture what the source does not tell you on its own. Why the code is shaped
the way it is, the history behind its present-day oddities, the traps that bite an
edit that assumes the obvious, and anchors straight to the code. They complement
the project's own user-facing [`docs`](https://github.com/vpinball/vpinball/tree/master/docs)
rather than repeat it.

## Enter here

[vpinball-architecture.md](vpinball-architecture.md) is the hub. It has the
overview, the repo map, the build, and an index of every subsystem and topic
deep-dive with a one-line description and a link. Everything else hangs off it.

Each doc records the `master` commit it was verified against in its front matter,
and each section names the files its claims lean on, so staleness is checkable
per-section.

## Layout

- `vpinball-*.md` at the root, the hub and the current deep-dives.
- `vpinball-dungeon-steering.md`, the convention doc: where the dungeon lives, how
  to work with it, bootstrap, and squashing.
- `vpinball-dungeon-bootstrap.sh`, an idempotent script that sets up or rewires the
  worktree and the steering symlink.
- Large subjects that warrant many files get their own subdirectory with its own
  `README.md`. The root stays flat for single-file docs.

## Using it

The docs live in a git worktree beside the main checkout. Edits commit to
`dungeon`, and the branch settles back to a single parentless orphan commit on
request. See [vpinball-dungeon-steering.md](vpinball-dungeon-steering.md) for the
full mechanics.
