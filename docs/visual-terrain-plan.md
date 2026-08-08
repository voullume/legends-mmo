# Visual Terrain — the render-only heightfield plan

**Date:** 2026-08-08 · **Status:** PROPOSED — awaiting owner approval · **Owner ask:** real ground
relief ("elevation change", the thing dressing alone can't fake).

## The one rule this plan lives under

**The sim stays flat. This does not reopen sim-z / walkable verticality (owner veto,
`docs/jump-verticality-phase1-decision.md`).** Everything here is client render only: no
`shared/` change, no server change, no Protocol bump, `bal_identity` byte-identical by
construction. The ground *looks* like terrain; movement, combat, collision, and netcode never
read it. Same philosophy as the cosmetic hop ("reads as juice, never traversal") and the stacked
Reclaimed Stadium zones — render is free, sim is authoritative.

## Why the map reads flat today (code facts)

- The ground is a single flat `PlaneMesh` quad (`Client.gd` `_build_*` ~line 1550, resized in
  `_resize_arena()` line 1100) with the art-pass A1 per-zone texture and biome palette tint.
- Every renderable assumes ground = y 0: fighters, props (`-min_y*scale + oy`, line 2331),
  rings/cones (line 2323), portals, hazard discs, loot, projectiles (fixed `release_y`), VFX
  (`impact_y`), the hop baseline.
- Uniform overhead light: no slope shading exists because there are no slopes to shade.

## The design

### 1. Heightfield as authored STAMPS, not a raster
Per-zone `data/heights/<map>.json` (client-only data): a list of primitives —
`ridge` (polyline, width, height), `mound`/`basin` (center, radius, height), `bank` (edge
gradient) — plus a low-amplitude deterministic value-noise layer (seeded per map). Height at any
point = sum of stamp falloffs + noise. Tiny files, hand-authorable with the F3 coords overlay,
resolution-free, deterministic on every client.

**Seeded from work already done:** ridge stamps are auto-derived from the berm decals (the
negative-`oy` rock chains from the scale pass), so the ground physically rises under the banks we
already composed — the half-buried rocks become half-buried in *actual* raised earth.

### 2. Honesty constraints (so a flat sim never lies)
- **POI plateaus:** flat discs at every camp, pad, portal, spawn, service, cache, checkpoint
  (positions from `World.gd`) — height locks level inside keep-clear + margin.
- **Walkable amplitude cap:** gentle rolling only (target ≤ ~0.5 world units, slopes ≤ ~10%)
  anywhere players can stand; the test suite enforces whatever numbers we tune to.
- **Free lying inside collision:** ridge masses players can never enter may rise 3–5× higher —
  that's where the drama lives, and it's exactly where the berms already are.

### 3. Engine changes (all `client/`)
- **`client/Heightfield.gd`** (new, ~200 lines): loads stamps, `height_at(x, y)` sampler
  (analytic + cached), zero for zones with no file. Never imported by `shared/` or `server/` —
  a CI static check enforces that isolation forever.
- **Ground mesh:** for zones with a heights file, replace the `PlaneMesh` with an `ArrayMesh`
  grid (8–16 su cells; the 3600×2800 fields ≈ 40k verts, one draw call) displaced by the sampler,
  **smooth per-vertex normals** — the shading is what sells relief. Same texture/palette pipeline.
  Zones without a file keep the exact `PlaneMesh` path → the 18 live zones render byte-identical.
- **The grounding sweep:** route every ground-anchored `position` through `_ground_y(x, z)`:
  fighters/mobs (+ their rings/bars), decal props, rings/cones, portals + labels, hazard discs,
  loot, residents, service pads, projectiles (terrain-follow via height at current x,z),
  leap/impact VFX, the hop baseline, death-anim grounding. Known call sites are already indexed
  (lines 587, 635, 658, 1000, 1537–1560, 2323, 2331, 3898, 3949, 4280 …).
- **Mouse picking + F3:** ground clicks currently intersect the y=0 plane; swap to a 3–4-step
  iterative ray↔heightfield intersection (deterministic, no physics body needed). F3 coord
  readout samples the same function.
- **Raked light per biome:** add sun elevation/azimuth to the biome palette table — loc1 gets a
  lower raking angle so slopes catch light and shadow; every other family keeps today's values
  (zero change to live zones). This is the cheapest half of the whole effect.
- **Polish layer:** slope/height-aware vertex tint (moist dark in hollows, dry crest tone on
  knolls) multiplying the A1 texture.

### 4. Verification
- **`tools/test_heightfield.gd`** (new suite, CI-wired): sampler determinism (golden hash of a
  probe grid per zone), POI plateau flatness, slope caps along every POI-pair path (reusing the
  connectivity machinery), amplitude caps in/out of collision, no-file ⇒ all-zero proof, and the
  shared/-isolation static check.
- **Live-world regression proof:** pixel-diff captures of live zones before/after the engine
  change — must be identical.
- `stab_locale1` grows heights-file asserts; full battery + `bal_identity` (byte-identical, since
  nothing in `shared/` moves); `--perf` numbers for mesh build time and fps on the fields.
- Capture-and-look rounds per zone + the owner gallery, same loop as the last two passes.

## Phasing (one phase per chat, per CLAUDE.md)

- **T1 — the engine core.** Heightfield.gd + stamps schema + ArrayMesh ground + the first-pass
  grounding sweep + picking/F3 + the new test suite + perf measurement. Proof on ONE zone
  (culvert — smallest) with a crude authored heightfield. All suites green.
- **T2 — the hardening pass.** Every remaining renderable edge case (projectile arcs, VFX,
  residents, hop/death anims, builder mode), the raked-light palette hook, the live-world
  pixel-diff proof, adversarial review of the engine diff.
- **T3 — author Locale 1.** Berm-derived ridge stamps + hand-authored swales/knolls per zone
  (five composer/critic agents with capture-and-look, the proven harness), tune the amplitude
  numbers visually, moisture/crest tint, gallery round 3, owner checkpoint.
- **T4 — ship gate.** Full battery + review, PR update, owner look pass. Separate later decision:
  author heights for the live world (glitchyard/away/home) as its own content pass.

## Risks and their answers

| Risk | Answer |
|---|---|
| Something renders floating/sunk | grep-indexed grounding sweep + per-zone capture rounds + a terrain-debug overlay (F3 shows sampler height under cursor) |
| Flat-speed movement feels wrong on slopes | walkable amplitude caps keep relief subliminal underfoot; drama is reserved for unwalkable masses |
| Perf on the big fields zone | one static 40k-vert mesh, one draw call; build time measured in T1, 24-su fallback grid if needed |
| Scope creep into gameplay verticality | the veto line: client-only files, CI isolation check, no sim read — structurally impossible to drift |
| Live zones change appearance | no heights file ⇒ old code path, proven by pixel-diff |
