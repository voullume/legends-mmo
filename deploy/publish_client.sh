#!/usr/bin/env bash
# Export the player-facing client binaries and publish them as a versioned GitHub release, so every
# deployed version has an exact saved CLIENT copy (alongside the git tag + the :vX.Y.Z server image).
# The newest published release is the one players download ("Latest" on the releases page).
#
# Called automatically by deploy/release.sh after the tag is pushed. Also runnable standalone to
# (re)build the client for any existing tag:  deploy/publish_client.sh v1.2.3
#
# Requires: godot (with 4.6.x export templates installed) + gh (GitHub CLI, authenticated).
# NOTE: `gh release create/upload` is a PUBLIC publish — under an agent's auto-mode it is blocked;
# run this yourself (or grant the permission).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "usage: publish_client.sh vX.Y.Z (got '${TAG:-}')"; exit 1 ;; esac

command -v godot >/dev/null 2>&1 || { echo "ERROR: 'godot' not on PATH — needed to export the client."; exit 1; }
command -v gh    >/dev/null 2>&1 || { echo "ERROR: 'gh' (GitHub CLI) not on PATH."; exit 1; }
gh auth status >/dev/null 2>&1   || { echo "ERROR: gh is not authenticated (run: gh auth login)."; exit 1; }

mkdir -p dist
LINUX="dist/Legends-Linux-x86_64.x86_64"
WIN="dist/Legends-Windows-x86_64.exe"
MAC="dist/Legends-macOS.zip"

# --- clean import before packing ---------------------------------------------------------------------
# A stale local Godot import cache (e.g. after a project.godot version/protocol bump busts it) can leave
# gitignored *.import files marked valid=false, so newly-added assets get PACKED UN-IMPORTED and load() to
# null at runtime (empty world of props, missing textures — see the v1.1.0 prop regression). There is NO
# import step before export today, so a build inherits whatever stale cache is on disk. Regenerate the
# gitignored import artifacts from a clean slate first. COMMITTED .import files (the mipmapped ground
# textures) are TRACKED, so `-o -i` skips them and their settings are preserved.
# Export from a PRISTINE, DETACHED git worktree at the exact tag — never the live working tree.
# (v1.5.0 lessons: concurrent local work contaminated a release's export, and two racing clean-imports
# corrupted the shared .godot cache. A throwaway worktree is isolated by construction: exactly the tag's
# files, no stray sidecars, no local edits, no cache races.)
ROOT="$(pwd)"
WORK="$(mktemp -d /tmp/legends-export-XXXXXX)"
cleanup() { cd "$ROOT"; git worktree remove --force "$WORK" >/dev/null 2>&1 || rm -rf "$WORK"; }
trap cleanup EXIT
git worktree add --detach "$WORK" "$TAG" >/dev/null

echo "==> Clean-importing all resources in the isolated worktree ..."
cd "$WORK"
godot --headless --path . --import
godot --headless --path . --import        # second pass: a cold cache sometimes defers import actions
# HARD GUARD: refuse to export a client whose assets didn't import (the v1.1.0/v1.4.0 empty-props class —
# a poisoned or aborted import leaves load()-null resources that exists() checks can't catch).
N_ART=$(ls .godot/imported 2>/dev/null | wc -l)
if [ "$N_ART" -lt 100 ]; then
  echo "ERROR: import produced only $N_ART artifacts — refusing to export a broken client."
  exit 1
fi
echo "    import OK ($N_ART artifacts)"

echo "==> Exporting client binaries for $TAG (from the worktree) ..."
godot --headless --path . --export-release "Linux"          "$ROOT/$LINUX"
godot --headless --path . --export-release "Windows Desktop" "$ROOT/$WIN"
cd "$ROOT"
[ -s "$LINUX" ] || { echo "ERROR: Linux export missing/empty ($LINUX)."; exit 1; }
[ -s "$WIN" ]   || { echo "ERROR: Windows export missing/empty ($WIN)."; exit 1; }
ASSETS=("$LINUX" "$WIN")
# macOS is best-effort (codesign is off, but some hosts still can't produce a .app cleanly)
if (cd "$WORK" && godot --headless --path . --export-release "macOS" "$ROOT/$MAC" >/dev/null 2>&1) && [ -s "$MAC" ]; then
  ASSETS+=("$MAC")
else
  echo "    (macOS export skipped/failed — publishing Linux + Windows only)"
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "==> DRY_RUN=1 — export verified, skipping the GitHub release publish."
  exit 0
fi

# Release notes = this version's CHANGELOG.md section (fallback to a one-liner).
NOTES_FILE="$(mktemp)"
awk -v hdr="## $TAG " 'index($0,hdr)==1{p=1;print;next} p&&/^## /{exit} p{print}' CHANGELOG.md > "$NOTES_FILE" || true
[ -s "$NOTES_FILE" ] || printf '# Legends MMO %s\n\nClient build for %s.\n' "$TAG" "$TAG" > "$NOTES_FILE"

echo "==> Publishing GitHub release $TAG (${#ASSETS[@]} binaries) ..."
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --clobber
else
  gh release create "$TAG" --title "Legends MMO $TAG" --notes-file "$NOTES_FILE" --latest "${ASSETS[@]}"
fi
rm -f "$NOTES_FILE"
echo "==> Client $TAG published — players download from:"
echo "    https://github.com/voullume/legends-mmo/releases/tag/$TAG"
