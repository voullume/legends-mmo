# Asset drop-folder — how to add new buildable props

You build the assets, I wire them into the game. The loop:

## You
1. Drop raw **`.glb`** files here (`models/incoming/`). Any name — `windmill.glb`, `campfire.glb`, etc.
   - GLBs must be **self-contained** (textures embedded). Meshy exports and most CC0 packs already are.
     A GLB that points at an external shared atlas (e.g. Kenney *city* `Textures/colormap.png`) will fail
     to optimize unless you drop that texture folder in too. When in doubt, just drop it and I'll tell you.
2. Tell me "new batch is in incoming/".

## Me
3. `tools/optimize_assets.sh` — Godot-safe optimize (prune/weld/simplify + textures→1024, **never Draco**)
   → `models/incoming/_optimized/`.
4. `--import` then `tools/asset_inspect.gd` — reads each prop's real bounding box and suggests a
   collision footprint factor.
5. **Report back to you a table**: model → size, shape, suggested collision radius, suggested tier + price.
6. On your **approval**, I move the GLBs into `models/kits/…`, register them in the three lists
   (`client/NetClient.gd` DECO_PROPS · `shared/World.gd` PROP_FOOTPRINT · `server/Server.gd` BUILD_CATALOG),
   run the smoke tests, and deploy.

You never edit code — you just approve the table.

## What "collision footprint" means
`PROP_FOOTPRINT[model]` = block-radius per unit of placed height. Collision `r = FOOTPRINT × height`.
The inspector's suggestion is the **visual** footprint (`10 × max(width,depth) / height`, scale-invariant):
- **solid** props (buildings, rocks, fences) → use it as-is,
- **soft/passable** props (bushes, small plants) → dial down so players can brush past,
- **flat décor** (grass, flowers, rugs) → leave OUT of the table entirely (no collision, walk over it).

## Tiers / prices (server BUILD_TIER_PRICE)
`small 250 · medium 600 · tree 1000 · prop 1500 · large 4000` credits. I pick the tier by the prop's
real size + role and you approve it.
