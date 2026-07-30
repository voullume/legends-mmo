# World Expansion — Skybox, Bigger Zones & Vertical *Feel* (Handoff)

**Status:** proposal / evaluation draft — **nothing built yet.** Prepared 2026-07-23.
**Prepared from:** a 7-agent read-only survey of the live engine (terrain, movement dimensionality,
netcode, rendering, collision, infra, asset pipeline) cross-checked by hand against the code, plus the
standing `docs/jump-verticality-phase1-decision.md`.
**Purpose:** give the owner a phased, cost-ranked plan to make the world feel like a real MMORPG world
(sky, horizon, bigger + distinct + explorable zones, perceived verticality) **without** touching the
deterministic combat engine. Evaluate this, then a clean chat can begin **Phase 1** from the ready-to-give
prompt in §11.

---

## 1. The one fact that frames everything

**The combat engine is strictly 2-D.** Every fighter is a `Vector2 (x, y)` on a flat `y=0` plane; all
distance / range / AoE / line-of-sight / projectile / knockback / collision math is 2-D, and the client
hardcodes every entity's world height to `0.0`. Verified anchors (re-run `rg` before editing — line
numbers drift):

- Fighter position is `x`/`y` only, no `z` — `shared/GameData.gd` (`create_fighter`, ~L1009), confirmed
  by grepping all of `shared/` + server/client for a z coordinate (none exists).
- 2-D distance / clamp / LOS — `shared/Geom.gd:7` (`dist`), `:10` (`clamp_arena`), `:19`/`:29`
  (`seg_blocked` / `has_los`).
- Movement, abilities, projectiles, hazards all read/write `x`/`y` via `Vector2` — `shared/Sim.gd`,
  `shared/Abilities.gd`, `shared/Combat.gd`, `shared/AI.gd`.
- Client maps sim `(x,y)` → world `(X, 0.0, Z)` — `client/Client.gd:785` (`_world`), `CHAR_Y := 0.0`
  (`:23`), `SCALE := 0.05` (`:20`).
- The only vertical motion is the **cosmetic hop** — a client-only parabola on `model.position.y`, echoed
  as an optional `hopT` snapshot field, deliberately kept OFF the sim (`server/Server.gd` `submit_hop`
  ~L3182; `shared/Protocol.gd:20` VERSION 2).

This splits "elevation" into two projects with a ~100× cost gap:

| | Perceived verticality + bigger world | True walkable elevation (sim-z) |
|---|---|---|
| Touches `shared/` engine? | **No** | Yes — pervasive `Vector2→Vector3` rewrite |
| Breaks `bal_identity` / goldens? | No | Yes (re-tune `FORMAT_MODS`, rebase golden hash) |
| Protocol bump + server+client redeploy? | No (client-only / data-only) | Yes |
| Netcode honesty? | Fine | 30 Hz, no rollback — jump-timing is a visible lie |
| AI determinism? | Fine | Jumping-mob AI needs RNG the invariant forbids |
| Owner decision on record? | — | **Vetoed twice** (see §2) |

**This handoff is entirely the left column.** The right column is out of scope (see §2).

---

## 2. Standing constraints & non-goals (do NOT do these)

- **Sim-z / walkable elevation is CLOSED.** `docs/jump-verticality-phase1-decision.md`: the gate was closed
  2026-07-13 (all three design paths scored 3–4/10; continuous sim-z rejected outright), and the only
  re-open path — the "name one moment where a jump must change an outcome" test — was exercised
  2026-07-14 and answered **No**. The core blockers (netcode can't render jump-timing honestly on a 30 Hz
  tick with no rollback; determinism forbids the RNG a jumping-mob AI needs; every sim-true tier is a
  protocol bump + server-first redeploy) still hold. **Do not add a `z`/height axis to any fighter,
  obstacle, ability, projectile, or the snapshot.** Reopening requires the owner to pass the named-moment
  test first.
- **No balance / determinism changes.** Nothing in this plan may alter `FORMAT_MODS`, the mob-def golden
  hash, `bal_identity` byte-identity, item generation, or any `shared/` sim math. If a phase would, it is
  the wrong phase — stop and re-scope.
- **Prefer client-only and data-only changes.** Client-only = re-launch only (no droplet redeploy). A
  `shared/World.gd` map/obstacle edit ships **server + client together** and needs a droplet redeploy +
  `stab_*` re-run — flag it explicitly and treat it as the heavier path.
- **Sourced/AI assets are surfaced for owner approval before integration** (existing rule) — sky panoramas,
  new props, textures: show them, get a yes, then wire them in.
- **One phase per chat** (existing working style). Compile-check + headless/connect test + adversarial
  review before "done." Report the Meshy credit balance after any Meshy op.

---

## 3. Current-state ground truth (what a clean chat needs to know)

**World model.** 16 static zones + 5 instance templates (`camp`, `camp_b`, `camp_c`, `drill`,
`locker_room`). A map is pure data in `shared/World.gd`: `MAPS` (`:73`) is `{type, w, h, regen,
regen_delay, aggro, pvp, spawn}` — a flat `w×h` rectangle, sizes ranging ~700×460 up to 2000×1100.
`OBSTACLES` (`:561`) are authored panels expanded into **rows of collision circles** by
`circles_from` (`:446`); `PORTALS` (`:135`) move a fighter between maps (it adopts the destination's
bounds); `SERVICE_PADS` (`:123`) registers per-map services. Bounds are enforced server-side each tick by
`Geom.clamp_arena` reading the fighter's carried `arenaW`/`arenaH`. **Enlarging a zone = raise `w`/`h` +
add obstacle circles; the client floor and texture-tiling resize automatically.**

**Rendering (all `client/Client.gd`).** No skybox: `_build_world` (`:1218`) sets
`env.background_mode = Environment.BG_COLOR` / `background_color` (`:1232`), re-tinted per biome by
`_depth_palette`/`_theme_depth` (~`:659`/`:672`). The "horizon" is faked — a flat under-plane + two rings
of squashed-sphere **unreachable** hills (`_build_rim`, `:685`). Ground is two flat `PlaneMesh`es at
`y≈0`, textured per-map via `_apply_ground_tex` from `GROUND_TEX_DIR` (`:615`,`:638`), resized on map
change (`_resize_arena`, ~`:824`). Camera is an orbit-follow rig (`_update_cam`, `:1291`) locked to the
local player: `FOV := 60` (`:74`), `DIST_MIN/MAX := 10/55` (`:77`/`:78`), **pitch clamped
`PITCH_MIN 0.62 … PITCH_MAX 1.45`** (`:79`/`:80`) with default `_pitch := 1.12` (`:175`, high overhead) —
it cannot currently drop toward the horizon. Camera `near`/`far` are never set (Godot defaults). No LOD /
MultiMesh / visibility_range / explicit draw-distance; props/decals are individually instanced GLB nodes
rebuilt on map change (~8–60 per map).

**Netcode.** Fixed 30 Hz sim (`SIM_DT 1/30`, `Server.gd:32`); one full-state (non-delta) snapshot per tick
per peer, `unreliable_ordered`. **Interest-managed** by a single hard radius `INTEREST_RADIUS := 450.0`
(`:41`) — a linear scan, **no spatial index, no per-client entity cap**; phased bosses bypass it. ENet +
DTLS, default channels/MTU, default **32-client** server cap. **Consequence for a bigger world:** because
interest is distance-based, spreading players out in a larger zone *reduces* each client's snapshot — so
bigger area is bandwidth-friendly. The costs that grow are **tick CPU** (snapshot build is
`O(fighters × players)`; collision is brute-force `O(F²)+O(F×O)`, area-independent, no broadphase) and
**per-zone RAM** (`init_worlds` builds every static zone's Sim in RAM at boot).

**Infra.** One headless-Godot Docker container on the DigitalOcean droplet (159.89.132.86, UDP 7777,
DTLS), ticking **every** zone every frame on ~1 vCPU / ~1 GB RAM (inferred: the box needs a swapfile to
build; `deploy/setup.sh` notes a "24G box"). Client ships as **one ~300 MB PCK with everything baked in —
no asset streaming**; every new prop/skybox adds to the download on all platforms and to VRAM up front.
**Supabase is DB-only** (auth + characters/inventory) — **not** asset storage, so world size never touches
it.

**Asset pipeline.** Meshy (image→3D rigged characters; **text→3D static props**), optimized via
`gltf-transform` (resize 1024 + simplify, **never Draco**), imported headless. `tools/gen_ground_textures.py`
emits seamless 2-D ground **albedo** tiles. **There is no heightmap / terrain-mesh / skybox generation
today.**

---

## 4. The plan — four tiers, cheapest first

### Tier 0 — Sky & camera (client-only; biggest payoff per hour) ← **the Phase 1 pilot**
1. **Real skybox.** In `_build_world`, switch `BG_COLOR → BG_SKY` + attach a `Sky` resource. Two source
   options: (a) Godot **procedural/physical sky** (free, animatable, sun-driven, zero new assets), or
   (b) an **AI-generated 360° equirectangular panorama** on a `PanoramaSkyMaterial` (see §5). Keep or
   thin `_build_rim` as mid-ground silhouette. Re-theme per biome through the existing depth seam.
2. **Let the camera show a horizon.** Lower `PITCH_MIN` toward horizontal, raise `DIST_MAX`, set an
   explicit `_cam.far`. Without this, a sky only peeks at frame edges.
3. **Per-biome sky/lighting/fog moods** through `_depth_palette`/`_theme_depth`.

*Risk:* client-only, re-launch to test, revert in one commit. No server, no balance, no protocol.

### Tier 1 — Bigger, distinct, explorable zones (content/data)
4. **De-sameify zones with prop layouts** (the owner's own instinct). Give each zone a distinct
   silhouette, landmarks, chokepoints via the shipped prop/decal pipeline (`WILD_PROP_SWAP` render swap;
   `data/decals/*.json` collision decor). *Client-only if render-swap; server+client if it edits
   collision decals.*
5. **Enlarge select zones into "areas."** Raise `w`/`h` in `MAPS`, fill the new space with points of
   interest (mini-camps, a vista, a hidden pad, an optional sub-boss). *Server+client (data), droplet
   redeploy, re-run `stab_*`.*
6. **Portal-stacked verticality** (endorsed by the verticality review §3). Present a landmark as
   field → concourse → upper deck → rooftop, each an ordinary flat `MAPS` entry joined by a ramp-dressed
   `PORTALS` link. Delivers the climb-the-stadium fantasy at content cost only.
7. **Tall non-walkable backdrop structures** (stadiums, cliffs, towers) as Meshy props just past the play
   boundary — with the Tier 0 camera tilt they become the skyline and sell depth.
8. **More zones over one huge zone** — connect areas through the portal graph (better pacing *and*
   perf, per §3).

### Tier 2 — Engineering headroom (only if you go big/dense)
9. **Spatial hash** for `separation` + the interest scan before any large/populated zone (removes the
   `O(F²)` / `O(fighters × players)` ceiling on 1 vCPU). *Server-side; carefully determinism-preserving —
   must not change results, only speed; re-run `bal_identity`.*
10. **Nearest-N per-client entity cap** in interest management (makes dense clumps bandwidth-safe).
11. **Asset streaming / downloadable packs** — *later, only if the ~300 MB client balloons.* A real
    project; not needed for a modest content pass.

### Tier X — True walkable elevation (OUT OF SCOPE; see §2)
Vetoed. Requires reopening the gate via the named-moment test, then a `Vector3` sim rewrite +
re-balance + protocol bump. Do not attempt as part of this work-stream.

---

## 5. AI tooling — how to actually generate this

**You cannot "prompt a whole area" into existence for this engine, and shouldn't try.** The world is
*data* (bounds + collision circles + decals + ground texture + portal graph), not a 3-D terrain mesh, so
AI world/terrain generators (heightmaps, meshes) don't map onto the 2-D-circle-collision flat-plane sim.
Correct division of labor:

- **The area itself** (bounds, collision, spawns, portals, POIs) → authored as **data, section by section
  (zone by zone), by Claude in-chat.** This is testable and deployable incrementally — it is the "AI that
  works with you," and section-at-a-time is the right cadence, not one giant prompt.
- **The sky** → **Blockade Labs "Skybox AI"** (public API) generates 360° equirectangular panoramas from
  text → drop into a Godot `PanoramaSkyMaterial`. Highest-impact single asset. (Stable-Diffusion
  equirectangular models are a fallback.) Export ≤ a few MB each; mind the client-download budget (§3).
- **Props / structures / skylines** → **Meshy** (already wired): text→3D for backdrop geometry and
  landmarks; optimize via `gltf-transform` (1024, never Draco). Report credit balance after.
- **Ground textures** → existing `tools/gen_ground_textures.py` (procedural, seamless); augment with
  AI-gen tileable PBR only if more variety is wanted (must stay seamless + optimized).
- **Skip AI terrain/heightmap generators** — they only help sim-z (vetoed); on a flat engine a heightmap
  is decorative dead weight.

---

## 6. Feasibility & budget verdict

- **CPU is the real ceiling** (single process, ~1 vCPU, ticks all zones at 30 Hz, brute-force
  collision/snapshot, no spatial index). A few more small/medium flat zones: fine. One massive populated
  zone or many more zones: needs Tier 2 (spatial hash) and likely a bigger droplet. Each static zone also
  holds a full Sim in RAM at boot → more zones grow RAM linearly on a ~1 GB box.
- **Bandwidth is NOT the constraint** — interest radius 450 means bigger zones reduce per-client traffic;
  density inside one bubble is the only risk (Tier 2 nearest-N fix).
- **Storage:** Supabase is DB-only, untouched by world size. The pressure is the **~300 MB client
  download / VRAM** growing as props + skyboxes are added — fine for a reasonable amount, streaming needed
  only if it balloons.
- **Bottom line:** bigger + more varied + skybox + vertical-*feel* + more exploration = **very feasible,
  low risk, fits the architecture.** Walkable elevation = expensive, cross-cutting, vetoed — leave closed.

---

## 7. Phase 1 (the pilot) — detailed spec

**Goal:** prove the "real world" feel with the lowest-risk change: a real sky + a camera that shows a
horizon + **one** existing zone re-dressed with a distinctive prop/landmark layout. **Client-only,
re-launch to test, no server redeploy, revert in one commit.**

**Scope**
- Skybox: start with Godot's **procedural sky** (no new assets, no download growth, no approval gate) so
  the render plumbing lands first; an AI panorama can swap in later behind the same seam.
- Camera: relax `PITCH_MIN`, raise `DIST_MAX`, set `_cam.far`; keep the default overhead pitch so existing
  play is unchanged — the point is that a player *can* tilt to see the horizon.
- One zone (suggest a safe, high-traffic one like HOME or the Base Camp) gets a distinctive prop/landmark
  layout via the render-only prop path (no collision-decal edits, to stay client-only).

**Explicit non-goals for Phase 1:** no `shared/` edits, no `MAPS` `w`/`h` changes, no collision-decal
edits, no new downloadable assets, no portal-stacking yet. Those are Phase 2+.

**Acceptance criteria**
- Skybox visible; per-biome tint still works; no regression in the overhead default view.
- Camera can tilt to frame a horizon and returns cleanly; no clipping (far plane set); existing zoom/orbit
  limits still feel right.
- The re-dressed zone reads as distinctly different from its neighbors; no new collision (props are
  non-walkable backdrop / render-only).
- `grep -c 'SCRIPT ERROR'` clean on headless import; a headless connect/smoke run passes; screenshots at
  1152×648 / 1280×720 / 1920×1080 (existing gallery/capture recipe) show the sky + horizon + re-dress.
- **Zero** changes under `shared/`, `server/`, `supabase/`; `bal_identity` not even relevant (client-only).

**Deploy:** client re-launch / client publish only — **droplet NOT redeployed** (matches the ability-icon
/ art-pass client-only precedent).

---

## 8. Test / verify / capture

- Compile: `godot --headless --import --path .` then `grep -c 'SCRIPT ERROR'`.
- Smoke/connect: the existing headless connect test + relevant `stab_*` if (and only if) a later phase
  touches `shared/`/server.
- Screenshots: the established windowed capture recipe (see `legends-mmo-art-pass` memory) — snapshot +
  byte-verify `settings.cfg` around the session; capture at the three supported sizes.
- Adversarial review (Workflow) before "done," per project convention.

---

## 9. Open questions for the owner (decide before/at Phase 1)

1. **Sky source for the final look:** Godot procedural sky (free, animatable, no download cost) vs
   AI panoramas (richer, but each adds MB to the client + needs your approval). Phase 1 uses procedural to
   land the plumbing; which do you want as the *shipped* look?
2. **Camera:** allow a near-horizontal tilt (dramatic, shows skyline) or keep it gently overhead
   (safer for readability of the 2-D playfield)? This is a feel call.
3. **Which zone** to re-dress first in Phase 1 (HOME / Base Camp / an away zone)?
4. **Ambition ceiling:** are we aiming at "polish the existing 16 zones so they feel distinct + skied"
   (low cost, high ROI), or "add several new bigger exploration zones" (Tier 1 #5/#8 — server+droplet
   work, more Meshy assets)? This sets how far Tier 1 goes.
5. **Portal-stacked landmark:** worth building one multi-level stadium (Tier 1 #6) as a showcase, or skip?

---

## 10. Phase map (suggested sequence, one chat each)

- **P1 — Sky + camera + one zone re-dress** (Tier 0 + Tier 1 #4, client-only). ← ready to start.
- **P2 — Zone-distinction pass** across the remaining zones (prop layouts / landmarks; mostly client-only,
  some collision-decal work is server+client).
- **P3 — One enlarged exploration area OR one portal-stacked landmark** (Tier 1 #5 or #6; server+client +
  droplet).
- **P4 — Perf headroom** (Tier 2 #9/#10) *only if* P3 telemetry shows tick pressure.
- Each phase: compile → smoke → adversarial review → owner approval → ship (client-only phases don't
  redeploy the droplet; `shared`/server phases do).

---

## 11. Ready-to-give implementation prompt (paste into a clean chat to begin Phase 1)

```text
Implement Phase 1 of docs/world-expansion-handoff.md in /home/e/legends-mmo.

Read the handoff fully first, especially §1 (the sim is 2-D — do NOT add any z/height to the sim),
§2 (standing vetoes), §3 (verified code anchors), and §7 (the Phase-1 spec + acceptance criteria).

Goal: make the world feel like a real MMORPG world with the lowest-risk, client-only change —
a real skybox, a camera that can tilt to show a horizon, and ONE existing zone re-dressed with a
distinctive non-walkable prop/landmark layout. Re-launch to test; no server redeploy; revert in one commit.

Requirements:
- Skybox: in client/Client.gd _build_world, switch Environment.BG_COLOR -> BG_SKY with a Sky resource.
  Use Godot's PROCEDURAL sky for Phase 1 (no new assets, no download growth). Keep per-biome tinting
  working through the existing _depth_palette/_theme_depth seam. Keep or thin _build_rim as mid-ground.
- Camera: relax PITCH_MIN, raise DIST_MAX, and set an explicit _cam.far in _update_cam so a horizon is
  visible when the player tilts; keep the default overhead pitch so normal play is unchanged.
- One zone (confirm which with the owner — suggest HOME or Base Camp): a distinctive prop/landmark layout
  via the RENDER-ONLY prop path (no collision-decal edits, to stay client-only).
- Do NOT touch shared/, server/, supabase/, MAPS w/h, collision decals, balance, or the snapshot.
  Do NOT add any elevation to the sim. No new downloadable assets in Phase 1.
- Verify: godot --headless --import + grep -c 'SCRIPT ERROR' clean; a headless connect/smoke run;
  screenshots at 1152x648 / 1280x720 / 1920x1080 via the established capture recipe showing sky + horizon
  + the re-dress; confirm zero changes under shared/ server/ supabase/.
- Run an adversarial review (Workflow) before considering it done, then report changed files, what shipped,
  screenshots, and confirmation that no engine/balance/server/protocol change was made.

Then STOP for owner evaluation before shipping — this is a client-only publish (droplet NOT redeployed).
```

---

*Scope reminder: this entire handoff is the "perceived verticality + bigger flat world" path. Real
walkable elevation stays closed per `docs/jump-verticality-phase1-decision.md` unless the owner first
passes the named-moment re-open test.*
