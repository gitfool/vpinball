#!/usr/bin/env pwsh
#
# vpinball-dungeon-bootstrap.ps1 - bootstrap / rewire the vpinball "dungeon" on Windows.
#
# Windows pwsh equivalent of vpinball-dungeon-bootstrap.sh. It performs the same
# wiring as the sh script (worktree, steering symlink, local exclude) and also
# wires the personal CMakeUserPresets.json as a symlink into the dungeon, so the
# presets survive a destructive clean of the main checkout and never show up as a
# git diff (neither the presets file nor .gitignore are tracked).
#
# The dungeon is a floating orphan branch (dungeon) holding personal research docs
# plus its own steering file, checked out in a sibling git worktree. See
# vpinball-dungeon-steering.md on the branch for the full convention.
#
# This script is idempotent. It handles the same three starting states as the sh
# script with one path:
#   1. a fresh clone - no worktree yet; it fetches dungeon and creates one.
#   2. re-run when everything is already correct - a no-op.
#   3. after a destructive clean (git clean -ffxd) in the main checkout - only the
#      steering symlink, the presets symlink, and the local exclude entries are
#      gone; the sibling worktree survives (it lives outside the main checkout), so
#      it just rewires.
#
# The dungeon always lives on the origin remote (origin is always your fork).
#
# Creating symlinks on Windows needs either Developer Mode enabled or an elevated
# shell. If symlink creation fails, the script says so and stops.
#
# Usage, from inside the vpinball clone:
#   pwsh ./vpinball-dungeon-bootstrap.ps1
#   # or, if the dungeon worktree is already present:
#   pwsh ../vpinball-dungeon/vpinball-dungeon-bootstrap.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Remote                = 'origin'
$DungeonBranch         = 'dungeon'
$SteeringCanonical     = 'vpinball-dungeon-steering.md'
$SteeringLinkRel       = '.kiro/steering/vpinball-dungeon.md'
$SteeringLinkTarget    = "../../../vpinball-dungeon/$SteeringCanonical"
$PresetsCanonicalRel   = 'cmake/CMakeUserPresets.json'
$PresetsLinkRel        = 'CMakeUserPresets.json'
$PresetsLinkTarget     = "../vpinball-dungeon/$PresetsCanonicalRel"
$ExcludeEntries        = @('/.kiro/', '/CMakeUserPresets.json')

function Log($msg) { Write-Host "  $msg" }
function Die($msg) { Write-Error "vpinball-dungeon-setup: $msg"; exit 1 }

# --- locate the main checkout -------------------------------------------------
# Anchor on the git toplevel of wherever we are run from.
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    Die 'run this from inside the vpinball clone (cd into it first).'
}

# Resolve the MAIN working tree even if invoked from inside the dungeon worktree:
# the common git dir is <main>/.git, so its parent is the main checkout.
$commonGit = (git rev-parse --path-format=absolute --git-common-dir).Trim()
if (-not $commonGit) { Die 'could not resolve the git common dir.' }
$commonGit = (Resolve-Path -LiteralPath $commonGit).Path
$main = Split-Path -Parent $commonGit
if (-not (Test-Path -LiteralPath (Join-Path $main '.git'))) {
    Die "could not locate the main checkout (found: $main)."
}
Log "main checkout: $main"

$worktree = Join-Path (Split-Path -Parent $main) 'vpinball-dungeon'
Log "dungeon worktree: $worktree"

git -C $main remote get-url $Remote *> $null
if ($LASTEXITCODE -ne 0) {
    Die "remote '$Remote' not found; add your fork as 'origin' first."
}

# --- make sure the dungeon ref is available -----------------------------------
git -C $main show-ref --verify --quiet "refs/remotes/$Remote/$DungeonBranch"
if ($LASTEXITCODE -ne 0) {
    Log "fetching $DungeonBranch from $Remote ..."
    git -C $main fetch $Remote $DungeonBranch
}

# --- create the worktree if missing (idempotent) ------------------------------
$registered = (git -C $main worktree list --porcelain) -split "`n" |
    Where-Object { $_ -eq "worktree $($worktree -replace '\\','/')" }
if ($registered) {
    Log 'worktree already present.'
} elseif (Test-Path -LiteralPath $worktree) {
    Die "$worktree exists but is not a registered worktree; move it aside and re-run."
} else {
    git -C $main show-ref --verify --quiet "refs/heads/$DungeonBranch"
    if ($LASTEXITCODE -eq 0) {
        git -C $main worktree add $worktree $DungeonBranch
    } else {
        git -C $main worktree add $worktree -b $DungeonBranch --track "$Remote/$DungeonBranch"
    }
    Log 'worktree created.'
}

if (-not (Test-Path -LiteralPath (Join-Path $worktree $SteeringCanonical))) {
    Die "canonical steering file missing in worktree: $worktree/$SteeringCanonical"
}

# --- helper: create/refresh a symlink idempotently ----------------------------
function Wire-Symlink($linkPath, $target, $label) {
    $existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    # Windows stores link targets with backslashes; compare separator-insensitively
    # so a correct link is recognized and a re-run stays a true no-op.
    if ($existing -and $existing.LinkType -eq 'SymbolicLink' -and
        ($existing.Target -replace '\\','/') -eq ($target -replace '\\','/')) {
        Log "$label symlink already correct."
        return
    }
    if ($existing) { Remove-Item -LiteralPath $linkPath -Force }
    $dir = Split-Path -Parent $linkPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force *> $null }
    try {
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -ErrorAction Stop *> $null
    } catch {
        Die "could not create $label symlink (enable Developer Mode or run elevated): $_"
    }
    Log "$label symlink wired: $linkPath -> $target"
}

# --- wire the Kiro steering symlink into the main checkout -------------------------
Wire-Symlink (Join-Path $main $SteeringLinkRel) $SteeringLinkTarget 'steering'
if (-not (Test-Path -LiteralPath (Join-Path $main $SteeringLinkRel))) {
    Die 'steering symlink does not resolve to a file.'
}

# --- wire the CMake presets symlink into the main checkout --------------------
if (-not (Test-Path -LiteralPath (Join-Path $worktree $PresetsCanonicalRel))) {
    Die "canonical presets file missing in worktree: $worktree/$PresetsCanonicalRel"
}
Wire-Symlink (Join-Path $main $PresetsLinkRel) $PresetsLinkTarget 'presets'
if (-not (Test-Path -LiteralPath (Join-Path $main $PresetsLinkRel))) {
    Die 'presets symlink does not resolve to a file.'
}

# --- keep personal files out of the main repo's git view (local exclude) ------
$excludeFile = Join-Path $commonGit 'info/exclude'
$excludeDir = Split-Path -Parent $excludeFile
if (-not (Test-Path -LiteralPath $excludeDir)) { New-Item -ItemType Directory -Path $excludeDir -Force *> $null }
if (-not (Test-Path -LiteralPath $excludeFile)) { New-Item -ItemType File -Path $excludeFile -Force *> $null }
$current = Get-Content -LiteralPath $excludeFile -ErrorAction SilentlyContinue
foreach ($entry in $ExcludeEntries) {
    if ($current -contains $entry) {
        Log "local exclude already has $entry"
    } else {
        Add-Content -LiteralPath $excludeFile -Value $entry
        Log "added $entry to local exclude"
    }
}

Write-Host ''
Write-Host 'vpinball-dungeon: ready.'
Write-Host "  docs + steering live in: $worktree"
Write-Host "  kiro steering active in main checkout via: $SteeringLinkRel"
Write-Host "  cmake presets active in main checkout via: $PresetsLinkRel"
