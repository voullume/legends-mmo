#!/usr/bin/env bash
# Batch-optimize raw GLB/GLTF files dropped in models/incoming/ → models/incoming/_optimized/.
# Godot-safe: NO Draco (Godot 4.6 can't import it) — just prune/dedup/weld + simplify + texture resize 1024.
#
# GLBs must be SELF-CONTAINED (textures embedded). A GLB that references an external image
# (e.g. a shared "Textures/colormap.png" atlas, like the Kenney city kit) will FAIL here unless
# you drop that texture folder alongside it. Meshy exports + most asset packs are self-contained.
#
# Workflow:
#   1. drop raw .glb/.gltf into models/incoming/
#   2. tools/optimize_assets.sh
#   3. godot --headless --import --path .            # register the optimized GLBs
#   4. godot --headless --path . --script res://tools/asset_inspect.gd   # dims + suggested collision footprint
set -e
GT="${GTF:-$HOME/.npm-global/bin/gltf-transform}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
IN="$DIR/models/incoming"; OUT="$IN/_optimized"
mkdir -p "$OUT"
shopt -s nullglob
n=0
for f in "$IN"/*.glb "$IN"/*.gltf; do
  base="$(basename "${f%.*}")"
  out="$OUT/$base.glb"
  before=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if "$GT" optimize "$f" "$out" --compress false --texture-compress false --texture-size 1024 --simplify true >/dev/null 2>&1; then
    after=$(stat -c%s "$out")
    printf "  ✓ %-28s %6d KB → %5d KB\n" "$base" $((before/1024)) $((after/1024))
    n=$((n+1))
  else
    echo "  ✗ $base — optimize FAILED (check the source file)"
  fi
done
echo "optimized $n asset(s) → models/incoming/_optimized/"
