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
echo "==> Clean-importing all resources before export (guards against a stale import cache) ..."
git ls-files -o -i --exclude-standard -- '*.import' 2>/dev/null | xargs -r rm -f
rm -rf .godot/imported
godot --headless --path . --import

echo "==> Exporting client binaries for $TAG ..."
godot --headless --path . --export-release "Linux"          "$LINUX"
godot --headless --path . --export-release "Windows Desktop" "$WIN"
[ -s "$LINUX" ] || { echo "ERROR: Linux export missing/empty ($LINUX)."; exit 1; }
[ -s "$WIN" ]   || { echo "ERROR: Windows export missing/empty ($WIN)."; exit 1; }
ASSETS=("$LINUX" "$WIN")
# macOS is best-effort (codesign is off, but some hosts still can't produce a .app cleanly)
if godot --headless --path . --export-release "macOS" "$MAC" >/dev/null 2>&1 && [ -s "$MAC" ]; then
  ASSETS+=("$MAC")
else
  echo "    (macOS export skipped/failed — publishing Linux + Windows only)"
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
