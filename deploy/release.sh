#!/usr/bin/env bash
# Legends MMO — cut a versioned release.
#
# Every deploy should go through here so the version number always goes up and each shipped
# version is saved as an EXACT immutable copy: an annotated git tag `vX.Y.Z` (full source
# snapshot) AND — once CI runs — a matching image `ghcr.io/voullume/legends-mmo:vX.Y.Z`
# (the exact runnable server). The version lives in project.godot `config/version` and is shown
# in-game on the login screen.
#
# Usage:
#   deploy/release.sh [patch|minor|major] ["short changelog note"]
#     patch  1.0.0 -> 1.0.1   (default; bug fixes / polish)
#     minor  1.0.0 -> 1.1.0   (new features, backward compatible)
#     major  1.0.0 -> 2.0.0   (big / breaking changes)
#
# After this pushes the tag, deploy the new version to the droplet:
#   ssh root@<host> 'curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash'
set -euo pipefail

cd "$(dirname "$0")/.."                      # repo root
PROJECT="project.godot"
CHANGELOG="CHANGELOG.md"
LEVEL="${1:-patch}"
NOTE="${2:-}"

case "$LEVEL" in patch|minor|major) ;; *) echo "level must be patch|minor|major (got '$LEVEL')"; exit 1 ;; esac

# --- guards: on main, clean tree, up to date with origin -------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "ERROR: on '$BRANCH', not main. Releases are cut from main."; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "ERROR: working tree has uncommitted changes — commit or stash them first:"; git status --short; exit 1
fi
git fetch --quiet origin main || true
if [ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]; then
  echo "ERROR: local main is behind origin/main — pull first."; exit 1
fi

# --- read + bump the version ------------------------------------------------------------------
CUR="$(sed -n 's/^config\/version="\([0-9]*\.[0-9]*\.[0-9]*\)"/\1/p' "$PROJECT" | head -1)"
[ -n "$CUR" ] || { echo "ERROR: could not read config/version from $PROJECT"; exit 1; }
IFS='.' read -r MA MI PA <<<"$CUR"
case "$LEVEL" in
  major) MA=$((MA+1)); MI=0; PA=0 ;;
  minor) MI=$((MI+1)); PA=0 ;;
  patch) PA=$((PA+1)) ;;
esac
NEW="${MA}.${MI}.${PA}"
TAG="v${NEW}"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "ERROR: tag $TAG already exists."; exit 1; }

echo "==> Releasing $CUR -> $NEW  (tag $TAG)"

# --- write version back into project.godot ----------------------------------------------------
# portable in-place edit (BSD/GNU sed)
sed "s|^config/version=\"$CUR\"|config/version=\"$NEW\"|" "$PROJECT" > "$PROJECT.tmp" && mv "$PROJECT.tmp" "$PROJECT"
grep -q "config/version=\"$NEW\"" "$PROJECT" || { echo "ERROR: version write failed."; exit 1; }

# --- changelog: prepend a new entry -----------------------------------------------------------
DATE="$(date -u +%Y-%m-%d)"
SHORT="$(git rev-parse --short HEAD)"
[ -f "$CHANGELOG" ] || printf '# Changelog\n\nEvery deployed version of Legends MMO, newest first. Each `vX.Y.Z` has a matching\ngit tag and a `ghcr.io/voullume/legends-mmo:vX.Y.Z` image (exact saved copies).\n' > "$CHANGELOG"
# Build the entry in a temp file with printf (%s = literal — a NOTE with backslashes / Windows
# paths is NOT escape-mangled the way `awk -v` would corrupt it), then splice it in via getline.
ENTRY_FILE="$(mktemp)"
{
  printf '## %s — %s\n' "$TAG" "$DATE"
  [ -n "$NOTE" ] && printf '\n- %s\n' "$NOTE"
  printf '\n_(rolls up commits since the previous tag; base %s)_\n' "$SHORT"
} > "$ENTRY_FILE"
# insert the entry right before the newest existing version heading (first `## ` line); if there
# are none yet, append at the end — so the header prose always stays on top, entries newest-first.
awk -v ef="$ENTRY_FILE" '
  !ins && /^## / { while ((getline line < ef) > 0) print line; print ""; ins=1 }
  { print }
  END { if (!ins) { print ""; while ((getline line < ef) > 0) print line } }
' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
rm -f "$ENTRY_FILE"

# --- commit, tag, push ------------------------------------------------------------------------
git add "$PROJECT" "$CHANGELOG"
git commit -m "release: $TAG" -m "${NOTE:-versioned release}"
git tag -a "$TAG" -m "Legends MMO $TAG${NOTE:+ — $NOTE}"
# Atomic push: main and the tag reach origin together or not at all — so a version can never land
# on main without its immutable vX.Y.Z tag/image (and vice-versa). On any failure (rejected
# non-fast-forward, network blip) roll the local commit + tag back so a re-run starts clean and
# never double-bumps or strands a tag.
if ! git push --atomic origin main "$TAG"; then
  echo "ERROR: push failed — rolling back the local release commit + tag $TAG (nothing shipped)."
  git tag -d "$TAG" >/dev/null 2>&1 || true
  git reset --hard "HEAD~1" >/dev/null 2>&1 || true
  exit 1
fi

cat <<EOF

==> Released $TAG (pushed main + tag).
    CI (.github/workflows/build-server-image.yml) is now building the exact image:
      ghcr.io/voullume/legends-mmo:$TAG   (+ :latest, :<sha>)
    Watch it:   https://github.com/voullume/legends-mmo/actions
    Then deploy to the droplet (pulls :latest = this version once CI finishes):
      ssh root@<host> 'curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash'
EOF
