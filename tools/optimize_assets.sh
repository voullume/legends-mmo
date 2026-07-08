#!/usr/bin/env bash
# Batch-optimize raw GLB/GLTF files dropped in models/incoming/ → models/incoming/_optimized/.
# Godot-safe: NO Draco (Godot 4.6 can't import it) — prune/dedup/weld + simplify geometry,
# then an EXPLICIT texture resize to TEX_MAX px (default 1024).
#
# WHY a separate resize step: `gltf-transform optimize --texture-size` ONLY resizes as part of the
# texture-COMPRESS pass, which we disable (Godot can't read KTX2/Draco). So we optimize geometry
# with compress off, then run `resize` to actually shrink the images. Meshy bakes 4× PBR maps at
# 2048² (~22 MB GPU each!) — without this the props stay ~25 MB and murder VRAM.
#
# GLBs must be SELF-CONTAINED (textures embedded). A GLB that references an external image
# (e.g. a shared "Textures/colormap.png" atlas, like the Kenney city kit) will FAIL here unless
# you drop that texture folder alongside it. Meshy exports + most asset packs are self-contained.
#
# Tune per batch:  TEX_MAX=512 tools/optimize_assets.sh   (512² ≈ 5 MB/prop; 1024² ≈ 10 MB/prop)
#
# Workflow:
#   1. drop raw .glb/.gltf into models/incoming/
#   2. tools/optimize_assets.sh
#   3. godot --headless --import --path .            # register the optimized GLBs
#   4. godot --headless --path . --script res://tools/asset_inspect.gd   # dims + suggested collision footprint
set -e
GT="${GTF:-$HOME/.npm-global/bin/gltf-transform}"
TEX_MAX="${TEX_MAX:-1024}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
IN="$DIR/models/incoming"; OUT="$IN/_optimized"
mkdir -p "$OUT"
shopt -s nullglob
n=0
tmp="$OUT/.stage.glb"
for f in "$IN"/*.glb "$IN"/*.gltf; do
  base="$(basename "${f%.*}")"
  out="$OUT/$base.glb"
  before=$(stat -c%s "$f" 2>/dev/null || echo 0)
  # stage 1: geometry optimize (compress OFF so Godot can read it)
  if ! "$GT" optimize "$f" "$tmp" --compress false --texture-compress false --simplify true >/dev/null 2>&1; then
    echo "  ✗ $base — optimize FAILED (external texture? non-self-contained GLB?)"
    rm -f "$tmp"; continue
  fi
  # stage 2: EXPLICIT texture resize (the step optimize skips when compress is off)
  if ! "$GT" resize "$tmp" "$out" --width "$TEX_MAX" --height "$TEX_MAX" >/dev/null 2>&1; then
    mv "$tmp" "$out"   # resize failed (no textures?) — keep the optimized geometry anyway
  fi
  rm -f "$tmp"
  after=$(stat -c%s "$out")
  res="$("$GT" inspect "$out" 2>/dev/null | grep -oE "[0-9]+x[0-9]+" | sort -rn | head -1)"
  printf "  ✓ %-28s %6d KB → %5d KB   (textures ≤ %s)\n" "$base" $((before/1024)) $((after/1024)) "${res:-none}"
  n=$((n+1))
done
echo "optimized $n asset(s) → models/incoming/_optimized/   (TEX_MAX=${TEX_MAX})"
