# The Glitchyard Training Camp — Implementation Handoff

> **Status: PLAN ONLY (2026-06-28).** Nothing below is built yet. This doc reconciles the design docs
> (enemy roster, asset list, layout, GDD, top-down maps) against how the engine *actually* works today, and
> lays out a phased, shippable build order. Read `CLAUDE.md` + `HANDOFF.md` first for engine conventions.
> Source design docs live in the chat that produced this file; the canonical roster/layout/GDD is summarized
> here where it affects implementation.

---

## 0. TL;DR + the three decisions that shape everything

**Goal:** replace the current bare open-field PvE zone(s) with **The Glitchyard Training Camp** — a themed
starter area of 5 staged subzones, populated by **8 new sports-equipment enemy types** (4 basic, 3 elite, 1
boss) built from the user's Meshy GLBs, with real map geometry (cover, hazards, props) instead of green
rectangles.

**The engine reality that drives the plan:**
1. A "mob" today is a **reskinned one of the 8 player classes** running the full AI brain. There is no
   separate monster system, and an unknown `classId` **crashes** client (`client/Client.gd:192`, no `.has()`)
   and server (`shared/GameData.gd:239`). → We add a decoupled **`mobType`** path.
2. The user's **mob GLBs are all static** (no skeleton, no animations — verified with `gltf-transform
   inspect`). The existing skeletal-animation system can't use them, and the existing `.res` clips can't
   retarget onto foreign skeletons. → For these **object-enemies** we use **procedural client-side
   transform animation** (bob / lean / wind-up / shake), which is cheaper, deterministic-safe (purely
   cosmetic), and avoids the documented Meshy-rigging dead-end ([[legends-mmo-character-anim-deadend]]).
3. The combat engine **already has** most primitives the roster needs; a handful must be built. We sequence
   so each phase ships something playable and passes the balance harness.

**Decisions — all RESOLVED 2026-06-28 (see §9):** (a) **5 separated sub-worlds** `glitchyard_1..5` chained by
portals (MapleStory / Monster Hunter zoned-maps style — lighter on GFX/assets, max engine reuse); (b) the
Glitchyard **replaces** the current `combat`/`frontier`/`depths` chain as the new starter; (c) **Tackle Bag
Brute** model now present (`~/Downloads/TBB.glb`). Also: `*2` GLBs = alternate mob skins; **Boss2 = a secret
boss, deferred**; the reward loop (tokens/set) is **last + skippable**.

---

## 1. Engine ground truth (what's reusable vs must-build)

### 1.1 How mobs/combat work now (the load-bearing facts)
- **Mob = fighter dict** from `GameData.create_fighter(classId, team=1, ...)` (`shared/GameData.gd:239`) +
  `mobLevel`/`mobTier` + `_scale_mob` (`server/Server.gd:1259`: scales `maxHP`/`hp`/`dmgMult` only; elite
  ≈ ×2.2 HP, boss ≈ ×6.0 HP). Mobs run the **full AI brain** in `Sim.sim_tick` (`shared/Sim.gd:122-370`):
  target pick (peel > team kill-score focus > nearest) → offensive ability loop (`_ab_order`: ult > special
  > basic) → `Abilities.try_cast` → movement → separation. **So a mob already casts its class's whole kit.**
- **Abilities are pure data** in `GameData.CLASSES[id]["abilities"]` — dicts with `type`, `dmg`, `cd`,
  `range`/`dist`/`radius`, `speed`, `cast` (telegraph), and effect fields (`stun`, `slow:{amt,dur}`,
  `knockback`, `knockdown`, `buff:{...}`, `count`, `dur`, `healPct`, `shieldPct`). Dispatched by a single
  `match ab["type"]` in `Abilities.try_cast` (`shared/Abilities.gd:30-178`). **Adding a behavior = a new
  `type` arm here + a data entry.**
- **`Combat.deal_damage`** (`shared/Combat.gd:59-168`) is the one damage pipeline (16 ordered steps incl. the
  P6 proc/DOT hook). Knockback is done inline at each ability site (mutates `tgt.x/y` + `Geom.clamp_arena`),
  **not** in Combat.
- **Sim state**: `{t, seed, rng, fighters[], projectiles[], zones[], events[], focus[2], map, ...}`. Server
  adds `aggro`, `frozenIds` (leash seam, consumed at `Sim.gd:242`), `controlled`, `pvp`, `zone:true`.
  Projectiles are **homing** (track a target id), not velocity vectors. Zones are timed AoE that today only
  buff ally projectiles + repel AI — **they deal no damage yet**.
- **Determinism**: mulberry32 `state["rng"]`; only crit + a few tie-breaks draw it. The P6 rule "procs draw
  zero rng" (`Combat.gd:102-107,140-143`) is the template — **any new mechanic must draw rng in a fixed order
  or not at all**, or it breaks the balance harness + server↔replay. Re-run the **6-seed** harness after any
  combat-affecting change (2-seed runs are ±8 noise — lesson from P6 [[legends-mmo-item-roadmap]]).

### 1.2 Capability matrix (roster behavior → engine)
| Behavior (GDD) | Status | Hook |
|---|---|---|
| Melee + windup telegraph | ✅ reuse | `melee` + `cast` field (`Abilities.gd:60-74`) |
| Charge / dash at target | ✅ reuse | `dashAttack` (`Abilities.gd:93-104,180-209`) |
| Knockback (push away) | ✅ reuse | `knockback` field (dashAttack/melee/meleeAoe) |
| Projectiles (homing) | ✅ reuse | `projectile` (`Abilities.gd:35-48`); carries `stun`/`slow` |
| Sequential burst | ✅ reuse | `barrage` (`Abilities.gd:49-59`) |
| Instant AoE | ✅ reuse | `meleeAoe` (`Abilities.gd:75-92`) |
| Caster-centered delayed AoE (slam) | ✅ reuse | `cast`+`meleeAoe` (e.g. Grand Slam) |
| Slow / stun / knockdown | ✅ reuse | `slow:{amt,dur}`, `stun`, `knockdown` |
| Self DR stance | ✅ reuse | `selfbuff buff:{dr,dur}` (`Abilities.gd:152-154`) |
| Omni reflect (one hit) | ✅ reuse | Goalkeeper reflect (`Combat.gd:118-123`) |
| Proximity aggro + leash + heal-back | ✅ reuse | `_update_mob_ai` (`Server.gd:1173-1199`) |
| Obstacle collision / LOS / AI cover-hugging | ✅ reuse (unfed) | `Geom.has_los`, `Sim.gd:113-116,288-305`; **needs obstacle DATA per zone** |
| **Damaging / slowing hazard zones** | ⚠️ build (80% there) | extend `state["zones"]` tick (`Sim.gd:76-81`) with `dmg`/`slow` + apply-to-enemies-inside loop |
| **Ground-targeted delayed AoE** | ⚠️ build | zone entry with a fuse timer → damage on expiry |
| **DOT from an ability** | ⚠️ build (tick exists) | append to `tgt["dots"]` from a new ability case (P6 shape) |
| **Summon / spawn adds** | ❌ build | fighters live server-side → push `{type:"summon"}` to `state["events"]`, server spawns (sim→server bridge) |
| **Boss phases by HP + phase-gated abilities** | ❌ build | `f["phase"]` advanced by `hp/maxHP`; tag abilities w/ `phase`, filter in `Sim.gd:258` |
| **Arena ultimate w/ LOS-cover counterplay** | ❌ build | arena AoE that spares LOS-blocked fighters (reuse `has_los`) |
| **Pull (toward source)** | ❌ build | mirror knockback negated (3 sites) |
| **Knockback-immune stance** | ❌ build | `kbImmune` flag checked before displacement |
| **Frontal-only reflect / frontal-only DR** | ❌ build | facing-arc gate using `hx/hy`/`facing` (exist) |
| **Status stacks (Wobble→stumble), fatigue** | ❌ build | generic `tgt["stacks"][k]`; idle-timer for fatigue |
| **Bait-into-wall stun** | ❌ build | knockback paths (`Sim.gd:208-223`) check rig contact → `stun` |
| **Angular spread / ricochet projectiles** | ❌ build (big) | needs velocity-vector projectiles (current are homing) |
| **Revive a dead add** | ❌ build (defer) | server re-enables a corpse at % HP |
| **Destructible cover / power cores** | ❌ build | obstacles have no HP; model cores as team-1 fighters |
| **Clear-to-open gates** | ❌ build | per-world camp-clear state gates `_check_portals` (`Server.gd:1149`) |

### 1.3 World / zone / rendering
- 5 worlds (`HOME/COMBAT/FRONTIER/DEPTHS/ARENA`) in `shared/World.gd`, each its **own Sim state** ticked in
  lockstep. A map = `MAPS` cfg (`type,w,h,regen,aggro,pvp,spawn`) + `PORTALS` (free-walk pads) + `MOBS`
  (camps: `{class,level,tier,x,y}`). **No walls/obstacle data, no decoration data** — all zones currently
  borrow the empty `stadium` venue (`Server.gd:29,184`) so they run obstacle-free.
- Portals are **always-open** free-walk pads (`_check_portals`, `Server.gd:1142`); gating today is purely
  spatial (next portal placed past a boss). **No clear-to-open mechanic.**
- Client is **fully procedural Node3D** (one `Main.tscn` that boots `Main.gd`; everything else built in
  code). `_render_portals`/`_render_shop`/`_render_forge` (`Client.gd:533`, `NetClient.gd:1743`...) are the
  "rebuild meshes from snapshot on change" pattern — **the model to copy for an env-prop renderer**. No
  per-zone `.tscn`, no tile system, no existing prop system.
- Model path: `classId → sport → 1 of 4 GLBs` via `_load_meshy` (`Client.gd:143`) + `_make_character`
  (`Client.gd:191`). Animations are extracted `.res` clips merged onto each rig's `AnimationPlayer`, driven
  by `_drive_anim` (`Client.gd:764`) which **infers** idle/run/attack/hit/death from snapshot
  (`alive`, `flash`, position delta, rising `cds`). The bone path `Armature/Skeleton3D:Hips` is hard-coded in
  the root-motion stripper.

---

## 2. Assets: the Meshy GLBs

### 2.1 Inventory (`~/Downloads/`) vs roster
| GDD enemy | GLB(s) | Notes |
|---|---|---|
| Cone Swarmer | `Cone.glb` (52 MB) | object |
| Foam Rookie Dummy | `Dummy1.glb`, `Dummy2.glb` | 2 variants — pick best or use both as visual variety |
| Shooting Dummy | `ShootingDummy.glb` (34), `ShootingDummy2.glb` (29) | pick one |
| Blocking Sled Juggernaut | `Jugg.glb` (63) | elite, object |
| Drill Sergeant Dummy | `DS.glb` (36), `DSstill.glb` (29) | `DSstill` likely a cleaner static pose |
| Overclocked Ball Machine | `OBM.glb` (67) | elite, object |
| Head Coach Prototype (boss) | `Boss1.glb` (48) | **Boss1 = zone boss** (build now) |
| Tackle Bag Brute | `TBB.glb` | uploaded 2026-06-28; object/charger |
| (secret boss — DEFER) | `Boss2.glb` (40) | future hidden boss; keep asset, don't wire in v1 |
| (bonus) Shop NPC | `ShopGirl.glb` (45) | not a mob; could re-skin the home shop pad |

**Variants:** `Dummy2`/`ShootingDummy2`/elite `*2` = alternate **cosmetic skins** of the same mob type
(pick randomly per spawn for MapleStory-style variety; same stats/abilities). `DSstill` = still-pose Drill
Sergeant variant.

### 2.2 Optimization (do FIRST, mandatory)
These are raw Meshy exports (28–67 MB) vs ~6–10 MB for the shipped characters. Per `CLAUDE.md`/`HANDOFF.md`:
`~/.npm-global/bin/gltf-transform` → **resize 1024 + simplify + prune**, **NEVER Draco** (Godot 4.6 can't
import it; Meshopt unverified — avoid). Target ≤ ~8 MB each. Keep the extracted `*_texture_0.png` (tracked
import deps). Place under `models/meshy/mobs/`. Reimport: `godot --headless --import --path .`.
**Risk:** 12 GLBs × ~50 MB → the client export grows; the 1 GB droplet doesn't matter (client-only) but the
release asset size + git repo size do — optimize hard, consider git-lfs if the repo balloons.

### 2.3 Animation: procedural, not skeletal
Static GLBs won't drive the existing `AnimationPlayer` path. For object-enemies, add a **procedural animator**
(client-only) that animates the model's `Transform3D` from the same inferred state `_drive_anim` already
computes. No rig, no Meshy re-pipeline, no determinism impact (cosmetic). Per-`mobType` profile, e.g.:
- **Cone Swarmer:** fast vertical bob + slight tilt while moving (skitter); squash-stretch on Trip Dash;
  scale-pop + fade on death (Safety Violation burst).
- **Foam Dummy:** lean-forward whole-mesh rotate on swing; recoil-flop on `flash` hit.
- **Tackle Bag Brute:** lean-back wind-up during `cast`, lurch forward on charge; wobble on idle.
- **Shooting Dummy:** yaw to face target (already have heading), barrel recoil on shot; spin during
  Calibration.
- **Sled Juggernaut:** forward tilt + wheel-roll fake (rotate child) on Drive Block; plant/shake on Anchor.
- **Ball Machine:** idle vibration; ramp-up shake + emissive pulse before Overcharged Cannon (telegraph).
- **Drill Sergeant:** bob + periodic "shout" scale-pulse; clipboard raise on Clipboard Bash.
- **Boss:** larger procedural moves + per-phase emissive color shift + scoreboard-face state.

The boss could later get a real rig if desired, but ship procedural first.

### 2.4 Client render wiring (the `mobType` path)
1. Server: add `mobType` (+ `phase` for the boss) to the per-fighter snapshot block (`Server.gd:1900-1921`,
   interest-managed).
2. Client `_make_character` (`Client.gd:191`): **guard** `CLASSES.has(classId)`; if `f` has `mobType`, load
   `models/meshy/mobs/<mobType>.glb` (registered in a small `_mob_models` registry mirroring `_load_meshy`),
   scale per profile, attach the procedural animator instead of the clip driver.
3. Nameplate/HP-bar/ground-ring reuse the existing path (`Client.gd:803-813`).

---

## 3. Mob architecture — new enemies as non-playable class defs

The audit's key win: **the AI brain (`Sim.gd:248-344`, `AI.gd`) is fully generic over a class def** — `lane`
drives front/back positioning, `desired_range` (`AI.gd:63-71`) derives kite distance from the basic ability,
support routing fires on `allyheal/teamheal` types. So a new enemy added as a **`CLASSES` entry gets stats +
abilities + full AI for free**. That makes the cheapest correct path:

**Recommended — add each enemy as a `CLASSES` entry flagged `mob:true` + a `model` field, kept out of
`PLAYABLE`:**
```
"cone_swarmer": {
  "name":"Cone Swarmer", "sport":"", "mob":true, "model":"cone", "anim":"cone", "scale":1.2,
  "lane":0, "color":Color(...), "stats":{PWR,PRE,SPD,END,INS,CLU},   # derive() reads these
  "ms_mult":1.5,                                                       # fast (optional helper)
  "abilities":[ {key,name,type,basic:true,...}, ... ],                # same ability dicts as classes
}
```
**Plumbing (small, surgical):**
- `World.MOBS` camps already reference a `class` id (`World.gd:72-96`) → just point them at the new ids.
  `_scale_mob`/`_spawn_fighter`/`_revive`/loot/XP all work **unchanged** (they're class-agnostic).
- **Guards (the only real risk the audit flagged):** a new `CLASSES` key is otherwise globally "playable."
  Keep it out of `client/Client.gd:50 PLAYABLE`, and exclude `mob:true` from any `CLASSES.keys()` consumer
  used for player selection **and from the AI-duel balance harness's player round-robin** (the harness must
  not measure mobs as if they were classes). Add the missing `.has()` guard in `_make_character`
  (`Client.gd:192`) / `create_fighter` (`GameData.gd:239`) defensively.
- **Client model:** branch on the def's `model` field — `_make_character`/`_kit_for` (`Client.gd:190-214`):
  if `def.model` is set → load `models/meshy/mobs/<model>.glb` + attach the procedural animator (`anim`
  profile); else the existing sport-rig path. Carry nothing extra on the wire if the client reads the def
  from its preloaded `GameData` (it already does) — `classId` in the snapshot is enough; the client looks up
  `def.model`. (If you'd rather not preload mob defs client-side, add a `mobType`/`model` snapshot field at
  `Server.gd:1900-1921`.)

**Alternative (stronger separation, more plumbing):** a standalone `GameData.MOB_DEFS` table + a unified
`def_for(id)` used everywhere `CLASSES[classId]` is indexed (many sites: `Sim.gd:55,131`, `AI.gd:11,101,...`,
`Client.gd:192`). Cleaner conceptually but a wider refactor — only do this if polluting `CLASSES` with
non-playable entries becomes a maintenance problem.

**Gotchas (from the audit):**
- `_scale_mob`/`_mob_xp`/`_mob_credits`/`_roll_loot`/`_roll_rarity` hardcode the **3 tiers**
  (minion/elite/boss) — the GDD's basic→minion maps cleanly; don't invent a 4th.
- `_revive` re-runs `create_fighter` then re-applies only `mobLevel`/`mobTier`/`map` (`Server.gd:1236-1257`).
  Any **new per-mob runtime field** (e.g. boss `phase`) must be re-applied there too or it's wiped on
  respawn (same pattern P6 used for procs).
- Admin `spawn_mob` is hardcoded to `linebacker`/`elite` (`Server.gd:1741`) — parameterize it to spawn/test
  the new types on demand.
- **Determinism:** Phase-1 mob kits reuse existing ability types (no new rng). New types (summon/zones/phases)
  added later must follow the zero-/fixed-rng rule (P6 template).

**Per-mob spec** (abilities mapped to engine; **[R]** reuse, **[B]** build):
- **Foam Rookie Dummy** (basic melee, 1/5): Bad Form Swing = `melee` + `cast:0.4` [R]; Practice Shove =
  `melee` + `knockback` [R]. (Flop Counter — skip v1.)
- **Cone Swarmer** (fast swarm, 2/5 in packs): Trip Dash = `dashAttack` low dmg + small `slow` [R] (Wobble
  stacks→stumble = `stacks` **[B]**, defer to polish); Safety Violation = on-death `meleeAoe` burst + shard
  hazard zone **[B]** (defer; v1 = plain death). High `ms_mult`.
- **Tackle Bag Brute** (charger, 3/5): Impact Charge = `dashAttack` + `cast` telegraph + `knockback` [R],
  bait-into-wall stun **[B]** (defer); Rubber Slam = `meleeAoe` small [R]; Brace Up = `selfbuff{dr}` [R]
  (frontal-only **[B]** defer). **Needs the missing model.**
- **Shooting Dummy** (ranged reflector, 3/5): Practice Shot = `projectile` [R]; Target Lock = `cast`+
  `projectile` (marked delayed) [R]; Reflect Plate = frontal reflect **[B]** (v1 = short omni reflect stance
  [R]); Calibration Spin = brief omni reflect [R]. Stationary (low/zero `ms`).
- **Drill Sergeant Dummy** (elite summoner, 4/5): Mandatory Conditioning = **summon [B] (core)** 3 cones;
  Clipboard Bash = `melee` + `stun` (interrupt) [R]; Bad Form! = mark/debuff **[B]** (defer); Run It Again =
  revive **[B]** (defer). Kill-priority enemy.
- **Blocking Sled Juggernaut** (elite push tank, 4/5): Drive Block = `dashAttack`/`melee` + big `knockback`
  [R]; Pancake Slam = `cast`+`meleeAoe` [R]; Resistance Band Lash = `melee` + `slow` [R]; Anchor Stance =
  `selfbuff{dr}` + `kbImmune` **[B]** (defer). Slow mover.
- **Overclocked Ball Machine** (elite turret, 4/5): Triple Shot = `barrage` [R] (true angular spread **[B]**
  defer); Overcharged Cannon = `cast`+`projectile` big [R]; Ricochet **[B]** (defer); Jam Misfire = self
  `stun` [R]. Stationary.
- **Head Coach Prototype** (boss, 5/5): see §5.

---

## 4. New primitives to build (priority order)

1. **`mobType` framework + static-GLB render + procedural animator** (§2.4/§3). *Foundational — without it no
   new mob can appear.* Client-only render + a `shared/` data/plumbing change.
2. **Summon** (Drill Sergeant + boss core): a `summon` ability that pushes `{type:"summon", mobType, count,
   at}` to `state["events"]`; the server (post-tick, like loot) calls `_spawn_fighter` into the same world,
   tagged as the summoner's adds (cap total adds; leash to the camp). Deterministic: the sim only *requests*;
   the server spawns (already non-deterministic-side, fine).
3. **Damaging/slowing hazard zones**: extend the zone entry with `dmg`/`slow`/`team`, add a per-tick
   "apply to enemies inside" loop in `Sim.gd:76-81` (no rng). Powers agility slow-grids, cone formations,
   boss sectors. Persistent (server-placed) vs timed (ability-placed) both supported via lifetime.
4. **Boss phase system**: `f["phase"]` advanced by `hp/maxHP` thresholds; tag abilities with `phase`; filter
   in the offensive loop (`Sim.gd:258`). HP-threshold summons via the summon bridge.
5. **Arena ultimate + LOS-cover counterplay** (boss "Full Camp Reset"): a telegraphed arena-wide AoE that
   spares fighters with `has_los`-blocked to the boss; optional **power-core** objects (team-1 fighters with
   HP) that, if destroyed during the cast, cancel/weaken it.
6. *Polish (defer past v1):* status stacks (Wobble) + stumble, pull, kbImmune, frontal-reflect/DR,
   bait-into-wall stun, angular-spread + ricochet projectiles, revive, clear-to-open gates, fatigue.

---

## 5. The boss — Head Coach Prototype

A `MOB_DEFS` entry, `tier:"boss"` (auto ×6 HP scaling), placed as the sole camp in the Zone-5 arena world.
Four HP phases (100–70 / 70–40 / 40–15 / 15–0) with phase-gated abilities + threshold summons, mapped to the
build list:
- **P1 Evaluation:** Clipboard Check (`cast`+`meleeAoe` frontal) [R]; Whistle Burst (`meleeAoe` short
  interrupt `stun`) [R]; Form Correction (`dashAttack`+`cast` at focus) [R]; Cone Drill (summon [B]).
- **P2 Conditioning:** Ladder Lock (slow hazard zones [B]); Hurdle Shockwave (telegraphed line/expanding AoE
  — approximate w/ `cast`+`meleeAoe` or a moving zone [B]); No Walking (fatigue [B] — *defer*, or a periodic
  AoE that punishes a stationary spot).
- **P3 Contact:** Sled Drive (big `knockback` charge [R]); Pancake Protocol (`cast`+`meleeAoe` slam [R]);
  Bag Wall (summon moving hazard/adds [B]); Resistance Pull (pull [B] — *defer*, v1 use knockback inward
  approximation or skip).
- **Final Run It Again:** all sectors active (summon + hazards + charges) faster; **Full Camp Reset**
  ultimate (§4.5) with sled-cover / power-core counterplay.

**Arena:** a dedicated boss world; floor "sectors" are placed hazard zones + obstacle clusters (sled cover,
rebound panels, cone piles as add-spawn anchors, power cores). Scoreboard countdown = a client-rendered
`Label3D`/billboard driven by a snapshot field. Solo/group scaling: fewer summoned cones + reduced add count
solo (the GDD's scaling table).

---

## 6. Zone layout — building the 5 subzones

**LOCKED: 5 separated sub-worlds** `glitchyard_1` (Rookie Intake) → `glitchyard_2` (Agility Grid) →
`glitchyard_3` (Impact Lanes) → `glitchyard_4` (Target Court & Shed) → `glitchyard_5` (Command Tower + boss),
chained by portals — MapleStory / Monster Hunter zoned-maps style. They **replace** `combat`/`frontier`/
`depths` in `World.gd` (`MAPS`/`PORTALS`/`MOBS`); keep `home` (hub, with the Glitchyard entry portal) +
`arena`. Each is its own Sim state with its own bounds/music/leash/camps — max reuse, light asset load (only
the props for the current subzone are in memory). Clear-to-open **gates are optional polish** (P5): v1 can
stage spatially (next portal placed past the subzone's tough camp, like frontier→depths today).

**To make maps "less basic" (the core ask), wire the dormant systems:**
- **Obstacles/cover:** add `"obstacles":[{x,y,r},...]` to the world's `MAPS` entry; set
  `w["map"]["obstacles"]` from it in `Server._new_world` (`Server.gd:183`) instead of borrowing stadium →
  collision + LOS + AI cover-hug + projectile-block all work for free. Add obstacles to the snapshot
  (`Server.gd:1927`) and add a client `_render_obstacles` (copy `_render_portals`). Obstacles are **circles
  only** — approximate fences/padded walls as rows of circles (or extend `Geom.seg_blocked` for segments —
  bigger change).
- **Hazards:** persistent damaging/slow zones (§4.3) placed per-world (agility slow-grids, charge-lane
  strips, cone-shard piles).
- **Props (the visual identity):** a new client `_render_props` pass (copy `_render_portals`) that
  instantiates the optimized GLB kit (cones, fences, sleds, tackling bags, scoreboards, target boards,
  shelves, light poles, painted-line decals as flat quads) from data — either `World.gd` constants read
  client-side (it already preloads `World.gd`) or a snapshot list. **Purely visual** unless a prop also needs
  collision (then register it as an obstacle too). Reuse the CC0 kits in `models/kits/` for fences/rocks
  where they fit; use the new GLBs for sports props. Decals (drill lines, arrows, grids) = flat textured
  `PlaneMesh`/`QuadMesh` on the ground.
- **Camp layout:** translate the GDD's per-zone encounter tables into `World.MOBS` entries (mobType, level,
  tier, x, y), spaced > `AGGRO_RANGE` (320) apart, difficulty gradient, elite/boss past the prior camp.

---

## 7. Recommended build order (phased, shippable, harness-gated)

Each phase: implement → headless compile → **6-seed balance harness** if combat-affecting → adversarial
review (Workflow) → commit; deploy (server redeploy for `shared/` changes + client re-export) when batched.

- **Phase 0 — Asset prep (no game code):** optimize all GLBs (gltf-transform), pick variants, resolve the
  missing Brute (§9), place under `models/meshy/mobs/`, reimport. Define the procedural-anim profiles.
- **Phase 1 — Mob framework + the 4 basics (reuse-only combat):** `MOB_DEFS` + `def_for`/guards +
  `create_mob`; `mobType` snapshot field; client static-GLB render + procedural animator. Ship Foam Dummy,
  Cone Swarmer, Shooting Dummy, (Brute if model ready) using **existing** ability primitives only. Re-skin
  one existing camp to prove the pipeline end-to-end. *Biggest single win; no new combat rng.*
- **Phase 2 — Summon + hazard zones + the 3 elites:** build summon (§4.2) + damaging/slow zones (§4.3); add
  Drill Sergeant, Sled Juggernaut, Ball Machine. Harness-tune their kits to the GDD threat tiers.
- **Phase 3 — Zone geometry + the Glitchyard map:** obstacles/cover wiring + client `_render_obstacles` +
  `_render_props` + hazards + the redesigned camp layout (1 world or 5 — per §9). This is the "less basic
  maps" deliverable.
- **Phase 4 — The boss:** phase system (§4.4) + arena ultimate (§4.5) + the Head Coach arena world + scaling.
- **Phase 5 — Polish primitives:** Wobble stacks, pull, kbImmune, frontal-reflect, bait-into-wall stun,
  spread/ricochet, clear-to-open gates, revive — as appetite allows; each is independently shippable.

---

## 8. Determinism, balance & deploy notes
- Everything in `shared/` (GameData/World/Sim/Combat/AI/Abilities) needs **server redeploy + client
  re-export**; client-only (render/props/anim) needs only a re-export. (`CLAUDE.md`.)
- New combat mechanics: draw rng in a fixed order or not at all (P6 template). **Re-run the 6-seed AI-duel
  harness** after each combat phase; the 8 player classes must stay ~50% vs each other and mobs must be
  tuned to the GDD threat tiers (1/5 … boss). Never touch `FORMAT_MODS` for mob tuning — scale via MOB_DEFS
  stats + `_scale_mob`.
- New client→server RPCs (e.g. gate interact, destroy core) **must** be rate-limited + serialized
  (dupe-safety contract).
- Migrations: none required for mobs/zones (no new persistent player state) unless we add quest progress /
  practice-token currency (the GDD's reward loop — separate, optional).

## 9. Decisions — RESOLVED (2026-06-28)
1. **Tackle Bag Brute** — model now uploaded as **`~/Downloads/TBB.glb`**. Full 8-mob roster present.
2. **Zone topology — SEPARATED sub-worlds** (5 chained `glitchyard_1..5` worlds with portals between them),
   to keep GFX/asset load light. Think **MapleStory / Monster Hunter**: discrete zoned maps that lead into
   each other via portals, NOT open world. Reuses the existing per-world Sim/bounds/leash/music/persistence.
3. **The Glitchyard IS the new starting zone**, building on the existing zone structure but adding mob + map
   depth → it **replaces** the current `combat`/`frontier`/`depths` chain (those become the 5 Glitchyard
   subzones). Keep `home` (hub) + `arena` (PvP).
4. **Reward loop (Practice Tokens + Rookie Camp set + vendor) = LAST and SKIPPABLE** — only after everything
   else is settled; cut if needed (the item system already covers gear).
5. **Model variants:** the `*2` GLBs (`Dummy2`, `ShootingDummy2`, and elite alts) are **alternate visual
   skins** of the same mob type (spawn-time variety, MapleStory-recolor style — purely cosmetic, pick
   randomly per spawn or per camp). `DSstill` = a still-pose Drill Sergeant variant. **`Boss1` = the Head
   Coach Prototype** (the zone boss we build now). **`Boss2` = a SECRET boss — DEFER**: discoverable later by
   completing/collecting everything in the zone → a secret map → eventually leads to Boss2 when that content
   is developed. Keep the asset; don't wire it in v1.

---

## 10. Quick file-hook index (where each change lands)
- New mob data: `shared/GameData.gd` `CLASSES` (new `mob:true`+`model` entries) + `.has()` guards; keep out
  of `client/Client.gd:50 PLAYABLE` + the balance harness player loop.
- New ability types: `shared/Abilities.gd` (`try_cast` match) + effect application in `shared/Combat.gd`/
  `shared/Sim.gd`.
- Summon bridge: `shared/Sim.gd` (emit event) + `server/Server.gd` (consume, spawn — near `_roll_loot`/
  post-tick).
- Hazard zones: `shared/Sim.gd:76-81` (tick + apply).
- Boss phases: `shared/Sim.gd:258` (ability filter) + phase state on the fighter.
- Mob scaling/spawn/camps: `server/Server.gd` (`_scale_mob` 1259, `_spawn_world_actors` 197, `_spawn_fighter`
  340) + `shared/World.gd` (`MOBS`, `MAPS` + new `obstacles`).
- Gates: `server/Server.gd` `_check_portals` (1142) + `shared/World.gd` PORTALS (`locked_until`).
- Client render: `client/Client.gd` `_load_meshy`/`_make_character`/`_drive_anim` (143/191/764) + new
  `_render_obstacles`/`_render_props` (copy `_render_portals` 533) + procedural animator; snapshot fields in
  `server/Server.gd:1900-1928`.
