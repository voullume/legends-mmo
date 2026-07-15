# Collision Pass-3 — Measured footprints for EVERY prop (handoff)

**Created:** 2026-07-15 · **Status: NOT STARTED — ready-to-go prompt at the bottom.** Owner-reported
(2 screenshots, 2026-07-15 08:23): the avatar stands *inside* the reward chest / salvage hopper / other
boxy props at HOME. Pass-2 (v1.6.0) fixed the LONG props properly; the boxy props still use
**hand-guessed** footprint multipliers, so their collision circles are much smaller than the rendered
meshes. Effort: **S–M (one session)**.

## The diagnosis in one line
`PROP_FOOTPRINT` values were eyeballed, not measured — e.g. `championship_reward_chest: 2.0` at h2.4
blocks at r+14 ≈ **19 sim** from center while the mesh's real half-length at h2.4 is ≈ **40+ sim**
(native ~1.9 long × ~1.0 high) → the player sinks ~1+ world unit into the mesh before stopping.

## How this exact bug was fixed before (the proven patterns — reuse them)
All in `shared/World.gd`, shipped in v1.6.0 (`30df68b`):
1. **Measure the real GLB AABB** (`~/.npm-global/bin/gltf-transform inspect models/meshy/props/<id>.glb`
   → bboxMin/bboxMax → native `long`(X) / `height`(Y) / `depth`(Z)). The client scales props uniformly
   to the decal's `h`: **sim_extent = native_extent / native_height × h × 20**.
2. **Long models (aspect ≳1.6)** → `DECAL_PANELS` (model → native height) + a `PROP_DIM` entry
   ({long, depth}) → `collision_from_decals` synthesizes `{x,y,prop,len,yaw}` panels expanded by
   `circles_from` into a **row of circles** hugging the true rectangle (walls: championship_arena_wall,
   glitchyard_wall, spectator_safety_rail, straight_cover_barrier).
3. **Arches** → two solid post circles, walkable opening (player_tunnel_gate: `GATE_LONG_H`/`GATE_POST_R_H`).
4. **Block-boundary rule**: players/AI are blocked at `r + OBSTACLE_PAD(14)` — so a face-accurate single
   circle wants **r ≈ half_extent_sim − 14** (min 4), not `footprint × h` with a guessed multiplier.

## The Pass-3 design (generalize the measurement to ALL props)
1. **Tool** (`tools/gen_prop_dims.sh` or a python one-shot): loop every collidable model
   (all of `PROP_FOOTPRINT`'s Meshy ids + `DECAL_PANELS` + the gate), run `gltf-transform inspect`,
   emit a `PROP_AABB := {id: {"long": L, "height": H, "depth": D}}` const block to paste into
   `shared/World.gd`. (Kenney kit props — trees/rocks/fences — are already fine; keep their hand values
   or measure too if cheap. Flat flora stays excluded.)
2. **Unified derivation in `collision_from_decals`** (replaces the guessed single-circle path for
   measured models):
   - `half_long = L/H × h × 10`, `half_depth = D/H × h × 10` (sim; ×20 then ÷2).
   - `aspect = L / D`. If `aspect ≥ 1.6` → the existing row expansion (add the model to
     `DECAL_PANELS` + `PROP_DIM`). Else → single circle
     `r = clamp(max(half_long, half_depth) − OBSTACLE_PAD, 4, 130)` → block boundary sits AT the widest
     face (slight over-block on the thin axis of near-square props is fine for décor).
   - Keep the arch special-case + the flora exclusion.
3. **Known offenders from the screenshots** (verify all 11 S5 props + the batch-005 utility set +
   locker/arena-tech sets): championship_reward_chest, loot_drop_capsule, open_salvage_hopper,
   community_team_table, championship_fountain (owner places it at h3.0 in the decorator — smaller than
   the authored h5 decals; the per-h math handles it, guessed multipliers don't).
4. **Verification (extend the shipped sweeps in `tools/stab_away.gd`)**:
   - Generalize the *phantom-wall* sweep into a **mesh-face coverage sweep**: for every collidable prop
     decal on every map, sample the measured rectangle's 4 face midpoints + 4 corners (rotated by yaw);
     each sample must lie within some circle's block band (r+14+ε) → "you cannot stand at a mesh face".
   - The existing **walkway clearance sweeps must stay green** — fatter circles WILL newly threaten
     pads/camps/service points; the sweep names each offender → nudge the decal or the placement.
   - Screenshot check at HOME: press the avatar against the chest/hopper/fountain — no sinking.
5. **Ship**: `shared/` change → same-commit client re-export; patch release; `bal_identity` re-proof
   (duel venues don't read decals — expect byte-identical, prove it anyway).

## Gotchas (hard-won, don't rediscover)
- The owner decorates HOME live (F4) — **their placements only gain server collision once the decals
  JSON lands in the repo**; re-run the stab sweeps after committing their decorated `home.json`.
- `gltf-transform optimize` needs `--compress false` (Godot 4.6 can't read meshopt) — props handoff §A.1.
- Never run imports/tests concurrently with a client export (worktree publish is isolated, local godot
  runs are not).
- Don't touch `too_add_models/` except dirs the owner names.

## ▶ READY-TO-GO PROMPT (paste to start the session)
> Do Collision Pass-3 per `docs/collision-pass3-handoff.md`: measure every collidable prop's GLB AABB
> with gltf-transform, generate the PROP_AABB table, and replace the hand-guessed PROP_FOOTPRINT
> single-circle path in `shared/World.gd::collision_from_decals` with the measured derivation (row
> expansion for aspect ≥1.6 via the existing DECAL_PANELS/circles_from machinery, face-accurate single
> circles `r = max(half_long, half_depth) − OBSTACLE_PAD` otherwise; keep the arch + flora rules). Add
> the mesh-face coverage sweep to `tools/stab_away.gd`, keep every walkway-clearance sweep green
> (nudge offending decals), re-prove `bal_identity`, screenshot-verify at HOME against the chest/
> hopper/fountain, then adversarial-review and ask me before shipping the patch release.
