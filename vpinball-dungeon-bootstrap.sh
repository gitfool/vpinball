#!/usr/bin/env bash
#
# vpinball-dungeon-bootstrap.sh — bootstrap / rewire the vpinball "dungeon".
#
# The dungeon is a floating orphan branch (`dungeon`) holding personal research
# docs plus its own steering file, checked out in a sibling git worktree so it can
# be read/edited while a feature branch is active in the main checkout. See
# vpinball-dungeon-steering.md on the branch for the full convention.
#
# This script is idempotent. It handles three starting states with one path:
#   1. a fresh clone — no worktree yet; it fetches `dungeon` and creates one.
#   2. re-run when everything is already correct — a no-op.
#   3. after `git clean -ffxd` in the main checkout — only the steering symlink and
#      the local exclude entry are gone; the sibling worktree survives (it lives
#      outside the main checkout, so clean never reaches it), so it just rewires.
#
# The dungeon always lives on the `origin` remote (origin is always your fork).
#
# Usage:
#   From inside the vpinball clone:   ./vpinball-dungeon-bootstrap.sh
#   From a fresh clone via curl:
#     curl -fsSL https://raw.githubusercontent.com/gitfool/vpinball/dungeon/vpinball-dungeon-bootstrap.sh | bash
#
set -euo pipefail

REMOTE="origin"
DUNGEON_BRANCH="dungeon"
STEERING_CANONICAL="vpinball-dungeon-steering.md"
STEERING_LINK_REL=".kiro/steering/vpinball-dungeon.md"
STEERING_LINK_TARGET="../../../vpinball-dungeon/${STEERING_CANONICAL}"
PRESETS_CANONICAL_REL="cmake/CMakeUserPresets.json"
PRESETS_LINK_REL="CMakeUserPresets.json"
PRESETS_LINK_TARGET="../vpinball-dungeon/${PRESETS_CANONICAL_REL}"
EXCLUDE_ENTRIES=("/.kiro/" "/CMakeUserPresets.json")

log() { printf '  %s\n' "$*"; }
die() { printf 'vpinball-dungeon-setup: %s\n' "$*" >&2; exit 1; }

# --- locate the main checkout -------------------------------------------------
# Anchor on the git toplevel of wherever we are run from. When piped from curl,
# $0 is not a usable path, so the current directory must be inside the clone.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "run this from inside the vpinball clone (cd into it first)."

# Resolve the MAIN working tree even if invoked from inside the dungeon worktree:
# the common git dir is <main>/.git, so its parent is the main checkout.
COMMON_GIT="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN="$(dirname "$COMMON_GIT")"
[ -d "$MAIN/.git" ] || die "could not locate the main checkout (found: $MAIN)."
log "main checkout: $MAIN"

WORKTREE="$(dirname "$MAIN")/vpinball-dungeon"
log "dungeon worktree: $WORKTREE"

git -C "$MAIN" remote get-url "$REMOTE" >/dev/null 2>&1 \
  || die "remote '$REMOTE' not found; add your fork as 'origin' first."

# --- make sure the dungeon ref is available -----------------------------------
if ! git -C "$MAIN" show-ref --verify --quiet "refs/remotes/$REMOTE/$DUNGEON_BRANCH"; then
  log "fetching $DUNGEON_BRANCH from $REMOTE ..."
  git -C "$MAIN" fetch "$REMOTE" "$DUNGEON_BRANCH"
fi

# --- create the worktree if missing (idempotent) ------------------------------
if git -C "$MAIN" worktree list --porcelain | grep -qx "worktree $WORKTREE"; then
  log "worktree already present."
elif [ -e "$WORKTREE" ]; then
  die "$WORKTREE exists but is not a registered worktree; move it aside and re-run."
else
  if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$DUNGEON_BRANCH"; then
    git -C "$MAIN" worktree add "$WORKTREE" "$DUNGEON_BRANCH"
  else
    git -C "$MAIN" worktree add "$WORKTREE" -b "$DUNGEON_BRANCH" --track "$REMOTE/$DUNGEON_BRANCH"
  fi
  log "worktree created."
fi

[ -f "$WORKTREE/$STEERING_CANONICAL" ] \
  || die "canonical steering file missing in worktree: $WORKTREE/$STEERING_CANONICAL"

# --- wire the Kiro steering symlink into the main checkout (idempotent) -------
LINK_PATH="$MAIN/$STEERING_LINK_REL"
mkdir -p "$(dirname "$LINK_PATH")"
if [ -L "$LINK_PATH" ] && [ "$(readlink "$LINK_PATH")" = "$STEERING_LINK_TARGET" ]; then
  log "steering symlink already correct."
else
  ln -sfn "$STEERING_LINK_TARGET" "$LINK_PATH"
  log "steering symlink wired: $STEERING_LINK_REL -> $STEERING_LINK_TARGET"
fi
[ -f "$LINK_PATH" ] || die "steering symlink does not resolve to a file."

# --- wire the CMake presets symlink into the main checkout (idempotent) -------
# The personal CMakeUserPresets.json lives on the dungeon orphan so it survives a
# destructive clean and never diffs; the main checkout just points at it.
[ -f "$WORKTREE/$PRESETS_CANONICAL_REL" ] \
  || die "canonical presets file missing in worktree: $WORKTREE/$PRESETS_CANONICAL_REL"
PRESETS_LINK_PATH="$MAIN/$PRESETS_LINK_REL"
if [ -L "$PRESETS_LINK_PATH" ] && [ "$(readlink "$PRESETS_LINK_PATH")" = "$PRESETS_LINK_TARGET" ]; then
  log "presets symlink already correct."
else
  ln -sfn "$PRESETS_LINK_TARGET" "$PRESETS_LINK_PATH"
  log "presets symlink wired: $PRESETS_LINK_REL -> $PRESETS_LINK_TARGET"
fi
[ -f "$PRESETS_LINK_PATH" ] || die "presets symlink does not resolve to a file."

# --- keep personal files out of the main repo's git view (local exclude) ------
EXCLUDE_FILE="$COMMON_GIT/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
touch "$EXCLUDE_FILE"
for entry in "${EXCLUDE_ENTRIES[@]}"; do
  if grep -qxF "$entry" "$EXCLUDE_FILE"; then
    log "local exclude already has $entry"
  else
    printf '%s\n' "$entry" >> "$EXCLUDE_FILE"
    log "added $entry to local exclude"
  fi
done

printf '\nvpinball-dungeon: ready.\n'
printf '  docs + steering live in: %s\n' "$WORKTREE"
printf '  kiro steering active in main checkout via: %s\n' "$STEERING_LINK_REL"
printf '  cmake presets active in main checkout via: %s\n' "$PRESETS_LINK_REL"
