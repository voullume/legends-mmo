# Handoff — More Props / Objects + Ground Textures (and a note on Jump)

Goal of the next chat: **get the ~22 generated props into the world**, each classified as either a
player-buyable build item (with a price) or an admin/dev-placed decoration, via a single **prop
"host file"**; and **add ground/background textures** so maps feel less flat. Jump/verticality is
**deferred** — see §D for why it's a separate project.

Everything here is **additive** — it does not touch the deterministic combat sim, netcode, or
balance. The one caveat: giving a prop *collision* touches `shared/` (needs a server redeploy);
pure-visual decor and player build items do not.

### ⭐ Owner decisions locked (2026-07-13)
- **First pass = ALL props are admin/dev world decor** (register in `DECO_PROPS`, place via the F4
  world decorator; NOT in `BUILD_CATALOG`). No player-buyable build items yet.
- **Buyable build items + pricing = a deferred Phase 2** — once the props are seen placed in the
  world, revisit which (likely the 5 locker items) become buyable, and set exact Credit prices then.
  The mechanism is fully documented below (§A.0, §A.2, §A.5) so Phase 2 is a small, known change.
- So for now: **skip the pricing questions** — just get everything in as admin decor + textures.

---

## 0. What's ready to integrate

**Approved GLBs** (in `too_add_models/approved/`, 6–9 MB each → must be optimized first, §A.1):

| Category | Props |
|---|---|
| `arena_structure` | `player_tunnel_gate`, `arena_service_door`, `equipment_transport_crate`, `straight_cover_barrier`, `spectator_safety_rail` |
| `arena_technology` | `boundary_pylon`, `bounty_terminal`, `leaderboard_kiosk`, `zone_terminal` |
| `environment` | `championship_arena_wall`, `glitchyard_wall` |
| `locker` | `single_locker`, `player_bench`, `equipment_shelf`, `sports_ball_rack`, `championship_trophy` |

**In-flight** (`too_add_models/batches/batch_005_glitchyard_utility/`, still generating): `power_transformer_cabinet`,
`coolant_pump_station`, `industrial_ventilation_unit`, `cable_spool_cart`, `maintenance_tool_cart`,
`scrap_sports_equipment_pile`.

---

## A. Adding props / objects

### A.0 — The two prop systems (know which one each prop is for)

There is **no interaction/clickable system** for props — interactivity (shop/forge/quest-giver) is
hardcoded home-only. So every new prop is one of:

1. **World decoration / cover** — placed by devs/admins into a *map*. Data lives in
   `data/decals/<map>.json` (visual) and, if it should block movement, `OBSTACLES` +
   `PROP_FOOTPRINT`/`PROP_DIM` in `shared/World.gd`. Players cannot buy or move these.
2. **Player build item** — bought at the Build Shop with **Credits** and placed by the player inside
   their own **Locker Room** instance (Builder Mode). Data lives in `BUILD_CATALOG` + `BUILD_TIER_PRICE`
   (`server/Server.gd:1367-1368`).

**Classification decides which lists a model id goes into** (there is no single `admin_only` flag):

| Intent | Register the model id in… | Result |
|---|---|---|
| **Player-buyable** (Locker Room) | `BUILD_CATALOG` (+ a tier → `BUILD_TIER_PRICE`) **and** the client palette `DECO_PROPS` | `_build_price` returns a real price; buyable at Build Shop, capped 50/char & 20/model |
| **Admin/dev world decor** | `DECO_PROPS` only (**not** `BUILD_CATALOG`) | placeable via the source F4 world decorator; `build_buy` refuses it (exact pattern of `gear_forge`, `quest_board`, `power_core`) |
| **Gameplay cover** | above **+** `PROP_FOOTPRINT` (derived circle) or `OBSTACLES`+`PROP_DIM` (deliberate cover panel) | blocks movement / line-of-sight (server-side → redeploy) |

Currencies: **Credits** is the prop/cosmetic currency (also tokens/scrap/pages exist for other
systems). Build tiers today: `small 250 · medium 600 · tree 1000 · prop 1500 · large 4000`
(`server/Server.gd:1367`) — add a new tier there for a custom price.

### A.1 — Prerequisite: optimize each GLB (once per prop)

Approved GLBs are 6–9 MB (Meshy raw). Before integrating, shrink them (per `CLAUDE.md`):

```bash
~/.npm-global/bin/gltf-transform optimize \
  too_add_models/approved/<cat>/<id>/model.glb  models/meshy/props/<id>.glb \
  --texture-size 1024 --simplify   # NEVER --draco (Godot 4.6 can't import it)
godot --headless --path . --import          # extracts *_texture_0.png sidecars — KEEP them (tracked deps)
```
Result: `models/meshy/props/<id>.glb` is now referenceable by **bare basename** `<id>` (the loader
searches `models/meshy/props/` → `models/kits/nature/` → `models/kits/city/`, `client/Client.gd:1498`).

### A.2 — The "host file": one manifest per prop

Today the three registration points are **split** across the tree:
`DECO_PROPS` (`client/Client.gd:704`), `BUILD_CATALOG`/`BUILD_TIER_PRICE` (`server/Server.gd:1367`),
`PROP_FOOTPRINT` (`shared/World.gd:309`). The **recommended host file** is a single manifest in
`shared/` (compiled into both server and client) that declares each prop **once**, and the three
lists are derived from it. Proposed `shared/World.gd` (or a new `shared/PropLibrary.gd`):

```gdscript
# THE HOST FILE — register every new prop here, once. class = build|admin|decor.
const PROP_LIBRARY := {
    "single_locker":      {"label": "Single Locker",     "footprint": 2.4, "class": "build", "tier": "medium"},
    "championship_trophy":{"label": "Championship Trophy","footprint": 0.0, "class": "build", "tier": "prop"},
    "player_tunnel_gate": {"label": "Player Tunnel Gate", "footprint": 5.0, "class": "admin"},
    "straight_cover_barrier":{"label":"Cover Barrier",    "footprint": 6.0, "class": "admin"},  # + OBSTACLES for real cover
    # ...one line per prop...
}
#   glb basename = the key.  footprint 0.0 = walk-through (no collision).
#   class "build" → buyable (needs "tier"); "admin" → GM/source-only; "decor" → only baked into a map's decals.
```
Then derive the existing consts (small change, keeps every downstream system working unchanged):
```gdscript
# client/Client.gd — palette = build + admin props
DECO_PROPS  = PROP_LIBRARY.keys().filter(func(k): return PROP_LIBRARY[k]["class"] != "decor")
# server/Server.gd — buyable catalog
BUILD_CATALOG = <k:tier for k in PROP_LIBRARY where class=="build">
# shared/World.gd — collision
PROP_FOOTPRINT (merge) = <k:footprint for k in PROP_LIBRARY where footprint>0>
```
> **Immediate path (no new infra):** if the manifest/derivation is more than the next chat wants to
> build first, just edit the three consts directly using the table in §A.4 as the source of truth,
> and add `PROP_LIBRARY` as a follow-up refactor. Both ship the same props; the manifest just makes
> the *next* 50 props a one-line edit each.

### A.3 — Step plan (per prop)

1. **Optimize** the GLB into `models/meshy/props/<id>.glb` + `--import` (§A.1).
2. **Classify** it — this pass, **all admin world-decor** (locked decision); buyable is Phase 2 (§A.5).
3. **Register** it — add to `PROP_LIBRARY` with `"class": "admin"` (or straight into `DECO_PROPS`, §A.2).
4. **Collision?** If it should block movement, set `footprint` > 0 (a circle: radius ≈
   horizontal-extent ÷ height; buildings ~5.5, rocks ~8, crates ~3, walls handled via `OBSTACLES`).
   Walk-through decor stays 0.0.
5. **Place it:**
   - *Build items* — nothing to place; players buy + place them in their Locker Room.
   - *World decor* — run `./play.sh dev`, walk to the zone, **F4**, `[`/`]` to your prop, click to
     place, `G`/`,`/`.`/`-`/`=`/PgUp to arrange, **Ctrl+S** → saves `data/decals/<map>.json`.
     (Admin-gated on live; source-only save.)
6. **Test** locally (§C), then **ship** (§C).

### A.4 — Integration table (all **admin world-decor** this pass; `footprint` is the collision hint)

Per the locked decision, **every prop here goes in `DECO_PROPS` only** (placed via the F4 world
decorator, §A.3 step 5). The `footprint` column is the suggested collision factor for
`PROP_FOOTPRINT` — `0` = walk-through, or use `OBSTACLES` for real cover walls. The last column flags
the likely **Phase-2 buyable** candidates (do nothing with these now — just noted so Phase 2 is easy).

| Prop | Where it fits | footprint | Phase-2 buyable? |
|---|---|---|---|
| `single_locker` | Locker Room decor | ~2.4 | ✔ (locker set) |
| `player_bench` | Locker Room decor | ~2.0 | ✔ |
| `equipment_shelf` | Locker Room decor | ~2.2 | ✔ |
| `sports_ball_rack` | Locker Room decor | ~1.8 | ✔ |
| `championship_trophy` | Locker Room / home | 0 | ✔ (prestige) |
| `equipment_transport_crate` | arena / glitchyard | ~3.0 | maybe |
| `straight_cover_barrier` | arena cover (`OBSTACLES`) | cover | — |
| `spectator_safety_rail` | arena edge | optional | — |
| `player_tunnel_gate` | arena entrance landmark | ~5.0 | — |
| `arena_service_door` | arena wall landmark | ~4.0 | — |
| `boundary_pylon` | arena perimeter | optional | — |
| `bounty_terminal` | near a service pad¹ | yes | — |
| `leaderboard_kiosk` | near a service pad¹ | yes | — |
| `zone_terminal` | near a portal¹ | yes | — |
| `championship_arena_wall` | arena wall (`OBSTACLES`) | wall | — |
| `glitchyard_wall` | glitchyard wall (`OBSTACLES`) | wall | — |
| batch_005 utility (×6) | glitchyard industrial decor | mostly 0 | maybe |

¹ Props can't be clicked, so the terminals are set-dressing beside the real (home-only) services
unless someone wires a new interactive feature — out of scope.

### A.5 — Phase 2 (later): make some props buyable

When ready, promote the ✔ props to player-buildable: add each model id to `BUILD_CATALOG` with a tier
(`server/Server.gd:1368`) and confirm the tier→price with the owner (tiers at `:1367`, or add a custom
tier). No other change — they already render (in `DECO_PROPS`) and, once in `BUILD_CATALOG`,
`_build_price` returns a real price and they appear in the Build Shop, placeable in the player's
Locker Room (capped 50/char, 20/model). This is the entire Phase-2 delta.

---

## B. Ground / background textures

**Current state:** the floor is two flat `PlaneMesh` planes with solid `albedo_color` and **no
texture** — `_ground` (dark border) + `_field` (mid-green, what players see), built globally in
`client/Client.gd:_build_world()` (`:1046-1061`) via `_mat()` (`:556-559`). The `WorldEnvironment`
(background/ambient/fog) is also global, set once (`:1033-1044`). No per-map theme exists; `MAPS`
carries only size/gameplay keys. **This is a client-render-only area** → no server redeploy (unless
you add a per-map key to `shared/World.gd`).

### B.1 — Global texture (smallest change, biggest lift)

Add a tiled albedo texture to the `_field` material. Because a `PlaneMesh` maps UV 0..1 across the
whole plane, set `uv1_scale` to tile it:
```gdscript
# in _build_world, replacing field.material_override = _mat(Color(0.16,0.30,0.18))
var fm := StandardMaterial3D.new()
fm.albedo_texture = load("res://textures/ground/turf_albedo.png")
fm.uv1_scale = Vector3(GameData.ARENA_W * SCALE / 4.0, GameData.ARENA_H * SCALE / 4.0, 1.0)  # ~4u tiles
fm.albedo_color = Color(0.9, 1.0, 0.9)   # subtle tint to keep the field's green identity
field.material_override = fm
```
Add a normal/roughness map the same way for depth (`normal_texture` + `normal_enabled`,
`roughness_texture`). Re-tiling on zone resize: `_resize_arena()` (`:638-647`) already fires on map
change — update `uv1_scale` there so tiles stay square when W/H change.

### B.2 — Per-map / per-zone themes (nicer, slightly more work)

Add an optional theme key to `MAPS` in `shared/World.gd` and read it at the `_resize_arena`/map-change
seam:
```gdscript
# shared/World.gd MAPS entry (optional keys, default to today's look if absent)
GY1: {..., "floor": "scrapyard_concrete", "field_tint": "#3a4030", "fog": "#141b12"},
```
Client keys the `_field` texture (and optionally `Environment.fog_light_color`/`ambient`) off
`_state["map"]` → distinct biomes (grass pitch vs. scrapyard vs. glitchyard) without new zones. This
adds a key to `shared/` → server redeploy + client re-export together.

### B.3 — Where to get textures (CC0)

No `textures/` dir exists yet. Create `textures/ground/` and add **CC0** tileable images —
**Kenney** ("Prototype Textures", "Pattern Pack") or **ambientCG**/Poly Haven (CC0) grass/turf/concrete/
dirt. Keep them ≤1024², `.png`, seamless. Import with `godot --headless --path . --import`. **Surface
sourced assets for owner approval first** (per `CLAUDE.md`), and drop a `CREDITS.txt` noting the CC0
source (mirrors `models/kits/CREDITS.txt`).

### B.4 — Step plan

1. Add CC0 tileable(s) to `textures/ground/`, `--import`.
2. Wire the global `_field` texture + tiling (§B.1); relaunch client, eyeball it.
3. If you want variety, add the `MAPS` theme key + per-map lookup (§B.2).
4. Ship: client re-export (+ server redeploy only if you added the `MAPS` key).

---

## C. Safe test + ship loop (same for props & textures)

```bash
# compile + boot check
godot --headless --path . --import
timeout 20 godot --headless --path . -- --server 2>&1 | grep -i "script error" || echo "✓ clean"

# run + LOOK (NOT ./play.sh bare / --practice — those load a fixed sandbox, not your zones)
./play.sh server      # terminal A: server that loads your zones
./play.sh online      # terminal B: client (demo: legends_smoke1@testmail.dev / Testpass1234!)
#   admin@legends.dev → F1 → goto to jump zones; F4 to decorate

# ship — VERSIONED (this repo now versions every deploy; see docs + deploy/release.sh)
deploy/release.sh patch "props: <what you added>"      # bumps ver, tags, pushes, builds :vX.Y.Z image + client release
gh run watch <id> --exit-status                        # WAIT for the image build or you deploy stale code
ssh root@159.89.132.86 'curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash'
```
**Redeploy matrix:** pure-visual decals / textures / build items = **client only**. Collision
(`PROP_FOOTPRINT`/`OBSTACLES`) or a `MAPS` theme key = **server redeploy + client**, from the **same
commit** (client draws walls/decals from its own `World.gd`, so drift = phantom geometry).

---

## D. DEFERRED — Jump / verticality (its own future project)

**Not in this handoff by design.** The combat engine is a **2-D top-down deterministic simulation** —
every position is a `Vector2` (x,y) in a flat plane; the 3-D view maps `(x,y) → (x, 0, y)` with a
constant Y=0. Adding a real jump + climbable height is **not a client tweak** — it reaches into the
protected core:

- **`shared/` sim** — positions/movement/collision would need a Z axis (or a height field);
  everything from `AI.separation` to ability ranges/line-of-sight assumes a plane.
- **Determinism + netcode** — the server is authoritative and lockstep-deterministic; vertical
  movement + landing must be server-simulated and snapshot-encoded, or it desyncs.
- **Balance** — verticality changes kiting, LOS, ability reach, aggro — exactly the tuned surface
  (`FORMAT_MODS`, camp spacing) the owner wants to protect.
- **Content** — maps are flat data (`w×h`); heightmaps/ramps/climb targets are a new authoring concept.

**Recommendation:** spin this up as its **own dedicated chat/handoff** with a phased plan (e.g. (1)
cosmetic client-only hop that doesn't affect the sim → (2) sim Z-axis behind a flag → (3) map height
data → (4) rebalance). A purely cosmetic "hop" animation could be client-only and safe, but *true
climbable height* is a multi-phase sim change. Flagged, not started.

---

## Key file/line index (verified during research)

- **Maps / props data** — `shared/World.gd`: `MAPS` `:56`, `DECALS` `:426`, `PROP_FOOTPRINT` `:309`,
  `collision_from_decals` `:327`, `OBSTACLES`/`PROP_DIM` `:353`/`:262`, decals-source (JSON override) `:342`.
- **Rendering / F4 decorator** — `client/Client.gd`: `PROP_DIRS` `:1498`, `_prop_entry` (loader) `:1500`,
  `_render_decals` `:1479`, `_build_world`/ground `:1021`/`:1046`, `_mat` `:556`, `_resize_arena` `:638`,
  `DECO_PROPS` `:704`, `_deco_place` `:959`, `_deco_save`→`data/decals/*.json` `:1003`.
- **Pricing / build** — `server/Server.gd`: gear prices `:137`, `_catalog` `:2514`, `BUILD_CATALOG`/
  `BUILD_TIER_PRICE`/`_build_price` `:1367-1404`, `build_buy`/`place`/`move`/`remove` `:1531-1620`,
  Locker caps `:1354-1364`, `admin_cmd` `:4464`. Dyes `shared/GameData.gd:612`.
- **Build gating** — `client/NetClient.gd`: `_world_build_allowed` (admin) `:4099`, `_locker_build_available` `:4089`.
- **Docs** — `docs/map-authoring-guide.md` (author workflow + free-prop catalog), `docs/builder-mode-handoff.md`
  (build design). Smoke ref: `tools/smoke_new_props.gd`.
</content>
