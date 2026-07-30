# World Expansion V2 — Open-World Feel, Sky, Landmarks, and Larger Zones

**Status:** evaluation/implementation handoff — nothing in this document has been implemented yet.  
**Prepared:** 2026-07-23.  
**Supersedes for planning:** `docs/world-expansion-handoff.md` after owner approval. The original remains
unchanged as a historical draft.

## 1. Objective

Make Legends MMO feel less like a collection of flat arenas and more like a coherent, explorable MMORPG
world without rewriting its deterministic 2-D combat simulation.

The desired result is:

- A visible sky and believable horizon.
- Strongly differentiated biomes and zone silhouettes.
- Large landmarks that provide orientation and anticipation.
- Zones built around exploration loops, discoveries, and destinations rather than empty acreage.
- Perceived height from skyline composition, stacked scenery, and portal-linked layers.
- Larger spaces only where traversal and content density justify them.
- Measured performance headroom before engineering speculative scaling systems.

The project is **not** true 3-D traversal. Fighters, combat, collision, projectiles, line of sight, and
server authority remain 2-D.

---

## 2. Architectural boundary: preserve the 2-D simulation

The simulation stores fighter positions as `Vector2`. The client renders sim `(x, y)` as world
`(X, 0, Z)`. Range, AoE, collision, line of sight, knockback, projectiles, and AI all operate in the flat
simulation plane.

This handoff must not:

- Add a height coordinate to fighters, obstacles, abilities, projectiles, hazards, or snapshots.
- Convert deterministic simulation math from `Vector2` to `Vector3`.
- Make cosmetic hopping affect combat or traversal outcomes.
- Alter balance definitions, `FORMAT_MODS`, golden hashes, item generation, or simulation RNG.
- Reopen the true-verticality decision without first satisfying the named-moment test in
  `docs/jump-verticality-phase1-decision.md`.

Perceived depth and authored world layers are allowed. Gameplay elevation is not.

---

## 3. Correct current-state model

### 3.1 Zones

Zones are flat bounded simulations defined primarily in `shared/World.gd`:

- `MAPS`: dimensions, spawn, regeneration, aggro, PvP, and other map settings.
- `PORTALS`: transitions between maps.
- `MOBS`: camps and encounter placement.
- `OBSTACLES`: server-authoritative collision and line-of-sight geometry.
- `DECALS` and `data/decals/<map>.json`: client-rendered decoration.

Increasing `MAPS[map].w` and `.h` enlarges the server-authoritative area. The client automatically
resizes its field and ground planes around the reported bounds, but all content must be checked for
valid coordinates, spacing, travel time, and camera presentation.

### 3.2 Important decoration correction

Decoration JSON is **not universally cosmetic anymore**.

`shared/World.gd` derives server collision from decoration props whose model appears in
`PROP_FOOTPRINT` or `DECAL_PANELS`. Buildings, trees, rocks, fences, stadium pieces, and most physical
landmarks can therefore affect movement, AI, projectiles, and line of sight.

Consequences:

- A `data/decals/*.json` change involving collidable models requires server and client to ship together.
- An old server paired with a newly decorated client can show props that the server does not block.
- A prop is render-only only if its model is deliberately excluded from collision derivation.
- “Placed outside the playable boundary” does not by itself make mismatched content a sound deployment
  practice.

The old rule “decals are pure visual/client-only” must not be used as a blanket assumption.

### 3.3 Rendering

`client/Client.gd` currently provides:

- A color background, not a real sky.
- Fog tinted through `_depth_palette()` and `_theme_depth()`.
- A large under-plane and two rings of unreachable hills for the horizon.
- A flat textured field and surrounding apron.
- An orbit-follow camera with an overhead minimum pitch.
- Individually instanced props and decals, rebuilt on map changes.

When changing the environment from `BG_COLOR` to `BG_SKY`, `_env.background_color` will no longer be
the visible-sky theming control. The sky material itself must be stored and re-themed by biome.

### 3.4 Runtime scaling

The server ticks zones at 30 Hz and interest-manages entities around each player. Larger physical area
does not automatically increase a nearby client’s snapshot because the interest radius remains fixed.
The scaling risks are instead:

- Total active fighters and obstacles.
- Per-player scans when many fighters occupy the same world.
- Brute-force separation/collision work.
- Continuously ticking empty or nearly empty zones.
- Per-zone simulation state retained in memory.
- Client draw calls and loaded resources in dense scenes.

Packaged resources definitely increase download/install size. They do not necessarily all occupy VRAM
at startup; runtime memory depends on what is loaded and instantiated.

---

## 4. Design principles for open-world feel

### 4.1 Size is not the goal

A larger rectangle with the same number of encounters will feel emptier. Expansion must be driven by
desired traversal, sightlines, discoveries, and activities.

Select zone dimensions from:

- Desired entrance-to-objective travel time.
- Player movement speed.
- Expected detours.
- Landmark visibility distance.
- Encounter cadence.
- Acceptable return/backtracking time.

Record current traversal times before resizing a zone.

### 4.2 Every exploration zone needs a readable composition

Each expanded or substantially redesigned zone should contain:

1. **Entrance frame:** immediately communicates biome and direction.
2. **Major landmark:** visible from the entrance; anchors orientation.
3. **Secondary landmark:** revealed from the first landmark or main route.
4. **Main route:** readable without a minimap.
5. **Optional loop:** branches and rejoins rather than ending in a dead corridor.
6. **Discovery:** hidden cache, vista, lore point, rare camp, or other reason to leave the shortest path.
7. **Escalation:** visual and encounter intensity increase toward the deep objective.
8. **Recovery space:** a quiet/readable interval around major encounters.
9. **Return solution:** shortcut, portal, checkpoint, or loop that avoids tedious retracing.
10. **Boundary language:** cliffs, walls, vegetation, wreckage, architecture, fog, or water explain the
    playable edge instead of exposing an arbitrary rectangle.

As an initial target, present something visually or interactively meaningful every 20–40 seconds of
normal movement. Tune after real playtests.

### 4.3 Landmarks do three jobs

A good landmark should:

- Provide navigation.
- Foreshadow upcoming content.
- Establish zone identity.

Do not scatter equally important props everywhere. Use a hierarchy:

- One dominant silhouette.
- Two or three supporting landmarks.
- Repeated small motifs that unify the biome.

### 4.4 Preserve combat readability

Backdrop geometry can be dramatic. Walkable combat space must remain readable:

- Avoid tall foreground props that repeatedly occlude the player.
- Keep boss arenas visually quieter than approach routes.
- Preserve sufficient open space around portals, services, spawn points, and telegraphs.
- Use ground texture and low props to define routes before relying on physical walls.
- Test from the lowest allowed camera pitch and the default overhead pitch.

---

## 5. New rendering boundary: client-only backdrops

Before a broad landmark pass, add an explicit backdrop system rather than overloading collision-aware
decals.

### 5.1 Purpose

Backdrop placements are unreachable visual scenery used for:

- Distant towers, stadium shells, cliffs, mountains, trees, cranes, lights, and skyline silhouettes.
- Large objects beyond playable boundaries.
- Foreground framing that never enters gameplay space.
- Per-zone visual identity without server collision or redeployment.

### 5.2 Recommended data shape

Use a new source such as:

`data/backdrops/<map>.json`

Example:

```json
[
  {
    "model": "stadium",
    "x": 850.0,
    "y": -260.0,
    "h": 22.0,
    "yaw": 1.57,
    "oy": -1.0
  }
]
```

The coordinates may reuse map sim-space mapping for authoring convenience, but backdrop records must:

- Be loaded only by the client.
- Never feed `World.collision_from_decals()`.
- Never appear in server simulation state.
- Be rebuilt on map change.
- Be clearly documented as unreachable and non-interactive.

Optional later fields may include tint, visibility range, shadow policy, or a coarse LOD choice. Do not
build those until a real asset requires them.

### 5.3 Safety rules

- Backdrops must sit outside playable bounds or in otherwise unreachable presentation space.
- They must not visually imply a path that players should be able to traverse unless a portal/route
  supports it.
- Disable shadow casting for distant large scenery unless screenshots prove the shadow is useful.
- Prefer shared meshes/materials and avoid dozens of unique high-resolution skyline assets.
- New sourced or generated assets still require owner approval before integration.

This system can be implemented in the landmark phase rather than the initial sky proof if strict minimum
scope is preferred.

---

## 6. Phased implementation plan

### Phase 1A — Sky, atmosphere, and camera proof

**Scope:** client-only. No map data, props, server, shared simulation, or new downloadable assets.

Implement:

1. Replace the flat background with a Godot sky resource.
2. Begin with `ProceduralSkyMaterial`; compare `PhysicalSkyMaterial` only if it offers a visibly better
   result without complicating biome art direction.
3. Store references to the `Sky` and sky material.
4. Extend `_theme_depth(map)` so the sky material, fog, horizon plane, apron, and rim share one biome mood.
5. Preserve the current default overhead pitch.
6. Relax the minimum pitch enough to show the horizon without becoming a flat free camera.
7. Raise maximum zoom only modestly.
8. Set camera `far` once during camera construction; evaluate `near` and depth precision.
9. Keep the current rim during the first comparison. Thin or reshape it only after screenshots show it
   obstructs the sky or skyline.

Suggested first tuning range:

- `PITCH_MIN`: approximately `0.35–0.45` radians, tested rather than blindly selected.
- `DIST_MAX`: approximately `65–75`, only if UI/nameplate behavior remains acceptable.
- Camera `far`: large enough for the 600-unit horizon plane and future backdrop silhouettes, but no
  larger than necessary.

Acceptance:

- Default gameplay view is effectively unchanged.
- The player can deliberately tilt to see a convincing horizon.
- Every biome family still has a distinct sky/fog/ground mood.
- No visible seam between the horizon plane, rim, fog, and sky.
- No clipping, z-fighting, black horizon, or severe depth artifacts.
- UI plates/nameplates remain usable at the new zoom extreme.
- Screenshots pass at 1152×648, 1280×720, and 1920×1080.
- Zero changes under `shared/`, `server/`, or `supabase/`.

Stop for owner visual evaluation before proceeding.

### Phase 1B — Backdrop seam and one landmark proof

**Scope:** client-only if implemented through the new backdrop source.

Implement:

1. Add the client-only backdrop loader and per-map rebuild.
2. Use an existing approved/shipped model—no new asset generation.
3. Redress one relatively plain zone with one dominant unreachable landmark and a small supporting
   silhouette group.
4. Test composition at default pitch, minimum pitch, minimum zoom, and maximum zoom.

Recommended pilot: `glitchyard_1`, because it is less visually saturated than HOME or Base Camp and
should give a clearer before/after comparison.

Do not use collidable decal props while calling this phase client-only.

Acceptance:

- Landmark is visible from the intended entrance or route.
- It improves orientation rather than merely filling space.
- It cannot be reached or mistaken for walkable geometry.
- No server collision mismatch is introduced.
- No meaningful frame-time regression.
- Backdrop data absence or malformed optional records fails safely without breaking scripts.

### Phase 2 — One complete zone-design vertical slice

**Scope:** may become server+client if collision-aware decor or world data changes.

Before editing:

- Record current traversal times.
- Capture before screenshots.
- Map current portals, camps, services, obstacles, and decoration sources.
- Decide the major landmark, secondary landmark, main route, optional loop, discovery, and return route.

Build one zone completely rather than lightly decorating every zone. Use the design principles in §4.
Prefer existing assets and procedural ground textures.

Acceptance:

- A new player can orient without relying exclusively on the minimap.
- The route contains at least one optional loop and one worthwhile discovery.
- No stretch longer than the agreed cadence feels empty.
- Combat remains readable at all supported camera angles.
- Portal/spawn/service pads have safe clearances.
- Collision matches visible physical props.
- Travel and backtracking times fall within the authored target.

### Phase 3 — Enlarge one existing zone

**Scope:** server+client and droplet deployment.

Only begin after Phase 2 proves the content grammar.

Implement:

- Increase one zone’s dimensions.
- Recompose the zone rather than merely adding empty margins.
- Add destinations and loops before adding decorative density.
- Revalidate every camp, portal, spawn, obstacle, decal, backdrop, and service coordinate.
- Test portal round trips and prevent bounce-back drops.

Possible exploration rewards:

- One-time discovery XP.
- A cache or crafting resource.
- A lore/vista trigger.
- An optional elite/champion.
- A temporary zone buff.
- A checkpoint or return portal.

If a new reward system would substantially expand scope, use existing reward mechanics for the pilot.

### Phase 4 — Portal-stacked landmark

Represent vertical progression as multiple ordinary flat maps:

- Exterior/field.
- Concourse or lower interior.
- Upper deck.
- Roof, overlook, or capstone arena.

Mask transitions with ramps, tunnels, stairs, elevators, gates, or interior passages. Preserve orientation
between layers where possible: the player should emerge facing a coherent direction and recognize the
same landmark from a new apparent height.

This phase edits `MAPS`/`PORTALS` and is therefore server+client work, even though it does not add sim
height.

Avoid excessive layers. Two or three convincing transitions are better than numerous loading seams.

### Phase 5 — Broader zone-distinction pass

After the vertical slice and one expansion succeed:

- Define a palette, skyline, landmark hierarchy, ground treatment, and prop motif for each biome family.
- Reuse asset kits deliberately rather than randomly.
- Apply composition rules across the remaining zones.
- Keep quiet zones quiet; visual density should support pacing.

### Phase 6 — Performance work only when measurements demand it

Collect telemetry before choosing an optimization:

- Average, p95, and worst server tick duration.
- Active worlds and players per world.
- Fighters and collision circles per active world.
- Snapshot bytes and entities per client.
- Client frame time and draw calls in the densest supported view.
- Memory cost per initialized zone.

Evaluate optimizations in this order:

1. Sleep, skip, or reduce work for completely empty static zones where simulation semantics allow it.
2. Reduce unnecessary client rendering/shadows in distant backdrop scenery.
3. Add a deterministic spatial index for collision/separation and interest scans.
4. Add entity caps only if dense snapshots remain a demonstrated bandwidth problem.
5. Consider infrastructure scaling only after software measurements.

A nearest-N interest cap must never hide relevant entities merely because they are slightly farther away.
Protected categories should include:

- Party members.
- Current targets and attackers.
- Bosses and boss mechanics.
- Projectiles/hazards capable of affecting the player.
- Quest-critical entities.
- Portals and services.

Any spatial-index optimization must preserve iteration/order behavior where order can affect deterministic
results. Re-run determinism and balance identity checks.

---

## 7. Tooling and asset strategy

### Use now

- Existing F4 editor for collision-aware decoration authoring.
- Existing GLB libraries and approved Meshy assets.
- `tools/gen_ground_textures.py` for seamless ground albedo.
- Godot procedural sky for the first proof.
- Existing screenshot/capture recipes.

### Use later, after approval

- AI-generated equirectangular panoramas for selected hero skies.
- Meshy text-to-3D for unique skyline landmarks.
- Optimized tileable PBR ground materials where procedural albedo is insufficient.

### Avoid

- AI terrain meshes or heightmaps that conflict with the flat simulation.
- Generating a whole zone as one monolithic mesh.
- A unique panorama for every small map before download size and art consistency are known.
- Dense forests/buildings made of individually shadowed high-detail meshes.
- Draco in the established Godot asset pipeline.

For panoramas, first prove that a richer sky materially improves the procedural implementation. If used,
group maps by biome so several maps share one approved panorama rather than packaging a unique large
texture per zone.

---

## 8. Deployment classification

### Client-only

- Sky/environment/camera changes in `client/`.
- A new explicitly client-only backdrop system.
- Backdrop JSON loaded only by the client.
- Truly non-collidable visual decoration, after verifying it is absent from all collision derivation.

### Server + client

- `MAPS`, `PORTALS`, `MOBS`, or `OBSTACLES`.
- Collision-aware `data/decals` changes.
- `PROP_FOOTPRINT` or `DECAL_PANELS`.
- New zones or enlarged bounds.
- Any change affecting server collision, line of sight, AI movement, or world initialization.

Server+client work must ship from the same commit and requires the relevant droplet deployment and
stability checks.

---

## 9. Verification matrix

Every phase:

- Review `git diff` and verify scope.
- Run Godot headless import/parse checks.
- Search logs for `SCRIPT ERROR`.
- Run a local headless server/client smoke where applicable.
- Inspect at all supported window sizes.
- Run an adversarial review before declaring completion.
- Stop for owner evaluation before publishing unless explicitly authorized.

Visual phases:

- Capture default overhead and lowest-pitch horizon views.
- Inspect map edges in all four camera headings.
- Check fog/rim/sky seams.
- Check nameplates, world plates, targeting rings, telegraphs, and minimap.
- Check both minimum and maximum zoom.
- Measure frame time/draw calls before and after in the densest view.

World-data phases:

- Validate all coordinates against bounds.
- Verify spawn and portal clearances.
- Test forward and return portal traversal.
- Test collision around every physical landmark.
- Test ranged line of sight around new collision.
- Test mob accessibility and camp chaining.
- Re-run relevant `stab_*` and balance/determinism checks.

---

## 10. Owner decisions and defaults

The work can begin without answering every long-term question. Use these defaults:

- Phase 1 sky: procedural.
- Camera: gently horizon-capable, not near-horizontal.
- Rim: retain until screenshot review.
- Landmark pilot: `glitchyard_1`.
- Pilot asset: existing approved/shipped GLB.
- World ambition: prove one complete zone before adding several large zones.
- True verticality: remains closed.

Questions to decide after Phase 1A screenshots:

1. Is procedural sky good enough to ship, or should one biome panorama be prototyped?
2. Is the lowest camera pitch comfortable for combat and exploration?
3. Does the existing hill rim help depth or obstruct the desired skyline?
4. Should the backdrop loader land before the first landmark pass?
5. After the zone vertical slice, is the priority enriching existing zones or adding a new exploration
   area?

---

## 11. Recommended project sequence

1. **P1A:** sky, atmosphere, camera proof.
2. Owner screenshot/feel review.
3. **P1B:** client-only backdrop seam and one landmark proof.
4. **P2:** one complete zone-design vertical slice.
5. **P3:** enlarge one existing zone.
6. Measure traversal, client performance, and server performance.
7. **P4:** one portal-stacked showcase if still desired.
8. **P5:** broader zone-distinction pass.
9. **P6:** performance work only where telemetry identifies a real ceiling.

Do not combine all phases into one implementation chat or commit.

---

## 12. Ready-to-give implementation prompt — Phase 1A

```text
Implement Phase 1A from docs/world-expansion-handoff-v2.md in /home/e/legends-mmo.

Read that handoff completely before editing. This phase is ONLY the client-side sky, atmosphere, and
camera proof. Do not implement backdrops, decorate a zone, resize maps, or begin later phases.

Goal:
Make the existing flat world present a convincing sky and horizon while preserving the deterministic
2-D simulation and the current default overhead gameplay view.

Required work:
1. In client/Client.gd, replace the Environment BG_COLOR background with a Godot Sky using
   ProceduralSkyMaterial for the first proof.
2. Retain references to the Sky/material so _theme_depth(map) can theme the visible sky itself.
   Do not rely only on Environment.background_color after switching to BG_SKY.
3. Extend the existing _depth_palette/_theme_depth seam so sky, fog, horizon under-plane, apron, and rim
   form a coherent per-biome mood. Preserve the existing biome families unless a small palette adjustment
   is necessary to remove a visible seam.
4. Keep the existing default camera pitch unchanged.
5. Relax PITCH_MIN only enough to expose a useful horizon. Begin testing in approximately the
   0.35–0.45 radian range; choose the final value from screenshots and gameplay readability.
6. Raise DIST_MAX modestly only if useful, approximately 65–75. Verify nameplates/world UI at the new
   extreme.
7. Set Camera3D.far once during camera construction, not every frame. Evaluate Camera3D.near and use the
   smallest sensible far distance that renders the horizon/rim cleanly.
8. Keep the current _build_rim implementation for the first comparison. Only make a minimal adjustment
   if captures prove it causes a hard seam or completely blocks the sky.

Strict non-goals:
- No changes under shared/, server/, supabase/, data/decals/, or map data.
- No props, landmarks, backdrop loader, or new downloadable assets.
- No sim height, gameplay jump, Vector3 conversion, protocol, balance, collision, AI, or netcode changes.
- Do not deploy or publish.

Verification:
- Run the appropriate Godot headless import/parse check and confirm no SCRIPT ERROR.
- Run a headless/local connect smoke sufficient to prove the client still starts and renders map changes.
- Capture before/after or final screenshots at 1152×648, 1280×720, and 1920×1080.
- At minimum capture the default overhead view and the lowest allowed horizon view.
- Check multiple biome families, including default green, glitchyard/camp, away, and finals if the
  existing test/admin flow makes them available.
- Inspect all four camera headings for horizon seams, clipping, black areas, excessive fog, and rim
  obstruction.
- Check minimum/maximum zoom and verify nameplates/world plates remain usable.
- Run an adversarial review of the final diff.
- Confirm with git diff that no shared/, server/, supabase/, or world-data files changed.

Deliverable:
Report the exact files changed, final camera values, how biome sky theming works, verification results,
and paths to the screenshots. Then STOP for owner visual evaluation. Do not start Phase 1B and do not
publish/deploy.
```

---

## 13. Ready-to-give follow-up prompt — Phase 1B

Use this only after Phase 1A is approved:

```text
Implement Phase 1B from docs/world-expansion-handoff-v2.md in /home/e/legends-mmo.

Read the whole handoff first and inspect the completed Phase 1A implementation. Build an explicitly
client-only backdrop placement path, then use one existing approved/shipped GLB to give glitchyard_1 one
dominant unreachable landmark and a small supporting skyline composition.

Requirements:
- Add a clearly separated client-only source such as data/backdrops/<map>.json.
- Backdrops must never be consumed by shared/World.gd, collision_from_decals, PROP_FOOTPRINT,
  DECAL_PANELS, server simulation, snapshots, AI, movement, projectiles, or LOS.
- Reuse the existing client prop loading/scaling/grounding machinery where safe, without routing the
  records through collision-aware decals.
- Rebuild backdrops on map change and fail safely when a file is absent or optional records are invalid.
- Place all pilot scenery outside playable bounds or otherwise unreachable.
- Use only existing approved/shipped assets. Do not generate or download anything.
- Disable unnecessary distant shadows and avoid avoidable per-instance unique materials.
- Do not edit shared/, server/, supabase/, MAPS, PORTALS, MOBS, OBSTACLES, data/decals, PROP_FOOTPRINT,
  or DECAL_PANELS.

Verification:
- Headless import/parse and client connect smoke.
- Confirm the landmark at default pitch, minimum pitch, minimum zoom, and maximum zoom.
- Capture 1152×648, 1280×720, and 1920×1080.
- Verify it is readable from the intended entrance/route, improves orientation, cannot be reached, and
  does not suggest a false playable path.
- Compare client frame time/draw calls before and after if the available capture tooling supports it.
- Run an adversarial diff review.
- Confirm zero server/shared/world-collision changes.

Report changed files, backdrop data format, pilot composition, verification, and screenshot paths. Then
STOP for owner review. Do not publish and do not begin Phase 2.
```
