# Phase 8 — Mined System Reference (2026-07-14)

Read-only miner digests from Phase-8 planning: the zone-authoring checklist, the Glitchyard template
dissection, progression/quest machinery, the mob/boss primitive menu, and client theming + deploy
checklist — every claim carries file:line citations (verified by the design judges). Implementation
reference for `docs/phase8-away-circuit-plan.md`.

---

## Map toolkit + the Glitchyard template

LANE REPORT — CODE-AS-MAPS TOOLKIT + GLITCHYARD ZONE-CHAIN TEMPLATE (all paths absolute under /home/e/legends-mmo)

========================================================================
(a) WHAT DEFINES A ZONE END-TO-END
========================================================================

A zone is a map-name string keyed into 5 parallel const dicts in shared/World.gd, plus a handful of consts (docs/map-authoring-guide.md:42-52, 173-183). The full checklist:

1. NAME CONST — e.g. `const GY1 := "glitchyard_1"` (shared/World.gd:13-30). Instance-only templates must ALSO be listed in `INSTANCE_MAPS` (World.gd:30) or the server will boot them as static shared worlds.

2. SPAWN CONST — a `Vector2` arrival point, e.g. `GY1_SPAWN := Vector2(200, 425)` (World.gd:36-49). Convention: arrive far WEST, clear of camps, and > 42 sim units (`PORTAL_RADIUS`, World.gd:78) from any return pad so you don't bounce.

3. MAPS ENTRY (World.gd:56-74) — every key is required: `type` ("safe" = fixed login spawn, no aggro; "combat" = resume-at-logout), `w`/`h` (sim bounds), `regen` (max-HP fraction/sec: 0.12 safe, 0.012 combat, 0.0 drill), `regen_delay` (0.0 safe, 6.0 combat), `aggro` (bool), `pvp` (bool — only ARENA is true), `spawn` (the const from #2). The server copies these onto the world dict verbatim in `_new_world` (server/Server.gd:429-445) — arenaW/arenaH/regen/regenDelay/aggro/pvp.

4. PORTALS entries in BOTH directions (World.gd:94-166). Static pad: `{"x","y","to":<map>,"tx","ty","label"}`. Optional `"gate": <gate-id>`. Instance pad: `{"x","y","instance":<template>,"label"}` + optional `"auto": true` (walk-on). Server walk-on logic: `_check_portals` (Server.gd:3350-3382) — fires when within PORTAL_RADIUS, sets a 1500 ms `TP_GRACE_MS` (Server.gd:74) re-trigger immunity, teleport via `_portal_teleport` (Server.gd:3416-3431) which moves the fighter dict between world arrays, adopts the destination bounds, and re-bases `_spawn_pos` (the respawn point) to the arrival point.

   GATING — three moving parts:
   - `_portal_unlocked(pid, gate)` (Server.gd:3395-3404): `"boss_ready"` = level >= BOSS_GATE_LEVEL (16) AND session item_power >= BOSS_GATE_IP (800) (consts Server.gd:93-94). `"secret_key"` = `_all_quests_done` (every quest in Quests.ORDER completed, Server.gd:3386-3393) AND `_has_master_key` (Server.gd:974). `"all_quests"` = quests only. Unknown gate string → returns true (unlocked) — new gate ids MUST be added to this match.
   - VISIBILITY: `HIDDEN_GATES := ["secret_key", "all_quests"]` (Server.gd:95) — those pads are omitted from the per-player snapshot portal list `_portals_for_player` (Server.gd:3408-3414) until unlocked; `boss_ready` stays visible-but-locked and sends a throttled SYSTEM chat explaining the requirement (Server.gd:3370-3374).
   - GATE RE-VALIDATION on login: `World.gate_for_map` (World.gd:413-418) scans PORTALS for any gated pad leading INTO a map; on connect, after quests/key load, a restored last_map failing its gate relocates the player HOME (Server.gd:2061-2069). This is automatic for any new `to`+`gate` portal — zero extra wiring.

5. MOBS entry (World.gd:171-254) — camp rows `{"class","level","tier","x","y"}` (+ optional `"objective": true` for instance clear-gates). `class` must exist in GameData.CLASSES with `mob:true`; `tier` ∈ minion/elite/boss. Spawned at boot by `_spawn_world_actors` (Server.gd:449-466), which stamps mobLevel/mobTier and calls `_scale_mob` (Server.gd:3596-3613): HP = base × 0.35 × (1+(lvl−1)·0.3) × tier(elite 2.2 / boss 22.0) × per-class hpMult; DMG = base × 0.28 × (1+(lvl−1)·0.2) × tier × dmgScale (consts Server.gd:46-52). No new stat blocks ever — difficulty is purely level+tier+per-class multipliers. Classes with `isCore:true` in GameData get flagged no-loot/no-XP (Server.gd:465-466).
   Placement rule: camps > 320 apart (`AGGRO_RANGE`, Server.gd:43) so pulls don't chain (guide :171).

6. OBSTACLES entry (World.gd:353-409) — cover panels `{x,y,"prop":"barrier"|"rack"|"bag","len","yaw"}` (yaw 1.5708 = N–S wall). `circles_from` (World.gd:271-295) auto-expands panels into collision circles fed to the sim (collision + LOS + projectile-block) — never hand-place circles. A NEW obstacle prop id needs a `PROP_DIM` row (World.gd:262-266) or collision won't match the render (guide :169-171). Decor props from data/decals/<map>.json additionally get server-side collision via `PROP_FOOTPRINT` (World.gd:309-339) — a model not listed = walk-through décor.

7. DECALS entry (World.gd:426-485) or, preferred, an F4-editor-authored `data/decals/<map>.json` (guide :5-32; JSON overrides the const, World.gd:342-351). Kinds: ring / cone / prop (`{"model","x","y","h","yaw"}` — auto-scaled/grounded, guide :78-87). Purely client-side visuals; commit + client re-export ships them.

8. SPAWN/LEASH behavior (automatic): `_update_mob_ai` (Server.gd:3435-3473) — engage a player within AGGRO_RANGE 320, stay engaged to LEASH_RANGE 1600 (hysteresis), tethered to camp within MAX_LEASH 1600; disengage → snap home + heal-to-full on the edge; a leashed BOSS additionally restores base pool, resets phase/threshold-summons/cast (fresh pull). Mob deaths → respawn in MOB_RESPAWN_DELAY 6 s; a `phased` boss respawns in BOSS_RESPAWN_DELAY 1800 s (~30-min world event) (Server.gd:35-36, 3254-3262). Instance mobs never respawn (finite clear, Server.gd:3259-3260).

========================================================================
(b) THE GLITCHYARD 5-ZONE CHAIN — THE TEMPLATE, DISSECTED
========================================================================

SIZES grow along the gradient (World.gd:58-64): GY1 1500×850 → GY2 1650×900 → GY3 1800×980 → GY4 1900×1040 → GY5 2000×1100; then the boss arenas SHRINK to intimate rooms: GY_BOSS 1240×820, GY_SECRET 1440×940. All combat-type: regen 0.012, delay 6.0, aggro true, pvp false.

CAMPS/DENSITY/LEVELS (World.gd:176-226):
- GY1 "Rookie Intake": 4 minion camps, lvl 1-2 (2 mob species). Light cover: 2 barriers + 1 bag (World.gd:357-360).
- GY2 "Agility Grid": 4 minions lvl 2-3 + FIRST ELITE (tackle_brute lvl 3) anchoring the far east @1340 by the forward pad. Cover: 2 barriers + 1 rack + 2 bags flanking the elite.
- GY3 "Impact Lanes": 4 minions lvl 4-5 + elite sled_juggernaut lvl 5 @1500 east.
- GY4 "Target Court": 3 minions lvl 5-6 + TWO elites (sled lvl 6 mid @980,700 + ball_machine turret lvl 6 @1580 east) — the density bump.
- GY5 "Command Tower": 3 minions lvl 7 + ball_machine elite lvl 7 + the drill_sergeant SUMMONER elite lvl 8 @1620 east.
- GY_BOSS: head_coach boss lvl 8 central @620,410 + 4 power_core minions lvl 5 in a square around it (cores gate the ult).
- GY_SECRET: head_coach_prime boss lvl 10 + 6 power_cores lvl 7 (cores = 55% coreShield DR while any lives, GameData.gd:248-250).

The pattern per chain zone: ~2 minion camps in a west "entry lane" band, ~2 more mid, ONE elite far east guarding the forward portal, at two lane y-values (~y=0.35h and ~0.65h) so barriers split the approach into lanes. Camp x-spacing ~430-460 (> AGGRO 320). Elite count ramps 0→1→1→2→2 across GY1-5.

PORTAL TOPOLOGY (World.gd:94-144): strictly LINEAR — Home(north-edge gate) → GY1 ↔ GY2 ↔ GY3 ↔ GY4 ↔ GY5 → GY_BOSS → GY_SECRET, plus Home ↔ Arena and instance pads all on the HOME hub (World.gd:95-108: adventure gates on the north edge, Arena+Locker south). Per zone: back pad at x≈120 west, forward pad at far east (x = w−80…100). Back-portal drop points are deliberately placed clear of the previous zone's elites (comments World.gd:118-120, 128-129: "> AGGRO_RANGE 320… TP grace blocks re-port, not aggro").

GATES BETWEEN ZONES: the GY1-5 chain is UNGATED (pure walk-through; difficulty is the soft gate + quest min_levels pace it). Hard gates only at the caps: GY5→GY_BOSS = `boss_ready` (level 16 + gear 800, visible-but-locked with explainer chat); GY_BOSS→GY_SECRET = `secret_key` (all 9 ORDER quests incl. beating Boss1 + forged Master Key, hidden from the snapshot until earned) (World.gd:131,139; Server.gd:93-95, 3395-3404).

BOSS-ZONE ARCHITECTURE: small room, boss central, cores in a ring, spawn far WEST beyond aggro, and an OBSTACLES cover-RING (W/E barriers + N/S racks around the boss) so the arena-wide ult always has reachable-but-not-passive LOS-break cover (World.gd:381-395). Boss respawn 30 min (world event); its cores respawn at the normal 6 s rate so the mechanic recurs (Server.gd:36, 3261-3262).

QUEST SPINE OVERLAY (shared/Quests.gd): 1-2 quests per subzone, kill objectives matched on `{map, tier, class, min_level}` AND-combined (Quests.gd:190-203), min_level 1→7 pacing the chain, elite/boss kills carrying item rewards (Quests.gd:24-95). ORDER (:171-172) is ALSO the secret gate — comment at :19-21 warns: never fold new quests into ORDER (it would retro-gate the secret boss); the midgame chain is the precedent — a separate MIDGAME_ORDER (:175-176) + display_order() (:183-184). Phase 8 quest chains must be a third separate list, same pattern. Bounties (Server.gd:4306-4330) are server-defined const pools matched by the same kill_matches — a new zone can appear in bounty rotations with ZERO client re-export (pushed via HOME snapshot META).

XP CON-BAND (relevant to zone level design): full XP within ±4 levels of the mob, fading to a 40% floor over 12 more (Server.gd:68-70, 3677-3683); the :70 comment explicitly says the floor "keeps GY5 a viable backup farm… until Phase 8 adds 9-28 zones". Mob XP = 15 × level × tier(1/4/6) (Server.gd:48, 3664-3672) — a lvl-12 zone minion ≈ 180 xp, elites ×4.

========================================================================
(c) AUTOMATIC vs EXPLICIT WIRING FOR A NEW ZONE
========================================================================

AUTOMATIC (free, per MAPS key):
- BOOT: `init_worlds` (Server.gd:242-250 — this is the real site of the handoff's ":196-200" cite) iterates `World.MAPS`, skips `is_instance_template`, and creates one independent sim per static key via `_new_world` (:429-445), which builds the world's own map dict with obstacle circles + decal-prop collision. `_spawn_world_actors` (:449-466) then populates every `World.MOBS[map]` camp. Nothing else registers a zone.
- TICK: every world sims at 30 Hz — `_tick_world` runs mob AI, Sim.sim_tick, boss party-scaling, summon bridge, per-map regen, respawn queueing (Server.gd:3230-3269).
- SNAPSHOTS: interest-managed per player per world (INTEREST_RADIUS 450, Server.gd:41, 4667-4749); a `phased` boss is always shipped regardless of distance (:4747-4749). Portals reach the client as slim per-player-filtered {x,y,label} (:3408-3414).
- PERSISTENCE: `_save_one` writes last_map/last_x/last_y (instance keys map→HOME) (Server.gd:4637-4660); `_spawn_player` restores it, falling back to HOME for unknown maps or instance keys (:2113-2128); combat-type maps resume at the logged-out spot, safe maps at the fixed spawn (:2126-2128). GATE RE-VALIDATION for the restored map is automatic via gate_for_map (:2061-2069). No DB migration needed — last_map is just a string column.
- LEASH/AGGRO/RESPAWN/LOOT/XP/quest-kill-matching: all keyed off the world dict + mob tags; zero per-zone code.
- Admin F1 "goto" server-side already accepts ANY live world (`if _worlds.has(m)`, Server.gd:4530-4533).

EXPLICIT WIRING NEEDED (the full new-zone checklist beyond World.gd data — guide :173-183):
1. `NetClient._zone_name` (client/NetClient.gd:6411-6424) — display name for the zone banner + "Now Entering" card (:6080). Falls back to `map.capitalize()` so it degrades gracefully, but should be added.
2. Admin panel goto BUTTONS (client/NetClient.gd:4834) — the teleport row is a hardcoded list (Home/Arena/GY1-5/BOSS); add entries for dev/testing convenience.
3. Ground-texture theming (client/Client.gd:566-591): `_make_field_material` branches on map-name PREFIX — `begins_with("glitchyard")`/`begins_with("camp")`/DRILL → scrapyard, else turf. A new biome family either adopts a shared name prefix and adds one branch + (optionally) a new tiled albedo in models/meshy/props/ground/, or inherits turf by default. This is the ONE genuinely-new-asset candidate that's cheap and high-value (a desert/away-stadium ground texture) — flag for approval; alternatively re-tint the existing two textures via `albedo_color` (:578) at zero asset cost.
4. Music (optional): `AudioManager.play_music(map)` loads `res://audio/music/<map>.<ext>` by filename (client/AudioManager.gd:12,122-125; NetClient.gd:6084) — a new zone is silent/carry-over unless a file named after the map is dropped in.
5. Gate ids: any NEW gate string needs a `_portal_unlocked` match arm + a HIDDEN_GATES decision (hidden vs visible-but-locked) (Server.gd:95, 3395-3404).
6. Quests/bounties: a new quest chain = new Quests.gd dict entries + a NEW order list (never ORDER) + inclusion in display_order(); new bounty pool rows in Server.gd consts if desired.
7. Decor: F4 editor → data/decals/<newmap>.json (guide :5-32); give solid props PROP_FOOTPRINT rows if they should block.
8. Minimap: NO wiring — it's a schematic of exactly what the snapshot carries (NetClient.gd:5811-5839), zone-agnostic.
9. Mob classes: new remix mobs = GameData.CLASSES entries with `mob:true` + `recolor:true` reusing existing `model`/`anim` ids and ONLY proven ability types (the shipped P3/P3b pattern, GameData.gd:274-380); boss variants reuse `phased`/`coreCount`/`coreShield`/summon fields (GameData.gd:214-270) — note GameData is shared/, so any roster addition = server redeploy + client re-export in the same commit, but it adds dicts only, touching no player-class code path (mob:true keeps them out of the balance harness's player loop, GameData.gd:130).

DEPLOY: MAPS/OBSTACLES/MOBS edits are shared/ (🔴 both halves same commit, guide :58-71, 145-158); DECALS-json-only can ship client-side. Full local round-trip test first: `./play.sh server` + `./play.sh online` (never `--practice` — it loads the fixed sandbox venue, guide :140-142).

========================================================================
(d) INSTANCE TEMPLATES vs SHARED ZONES — WHICH FOR PHASE 8
========================================================================

MECHANICS: instance templates (camp/camp_b/camp_c/drill/locker_room, World.gd:22-33) are never booted statically; the server spins up `"<template>#<owner>"` worlds on demand (`_ensure_instance` Server.gd:788-795), owner = party key or solo fid (party-mates share), populates from the template's MOBS with Intensity + weekly-affix stamped into `_scale_mob` (:754-767), and tears down when the last player leaves (`_maybe_teardown_instance` :851-868). All World.gd lookups resolve by TEMPLATE prefix (`_template` :422-424), so instances share the blueprint's portals/obstacles/decals. Instance mobs don't respawn (finite clear via `objective:true` → `_on_circuit_clear` :917-924, which also records fastest-clear). Entry is via HOME portal pads with `"instance":` (RPC-driven selector for Camp, `auto:true` walk-on for Drill/Locker, Server.gd:3357-3369). last_map never persists an instance (both save- and restore-side, :2118-2124, 4645-4648).

RECOMMENDATION FOR PHASE 8:
- The 5-zone ~9-16 chain and the 2-3-zone ~18-28 capstone should be SHARED STATIC ZONES, exactly like GY1-5: they are the leveling/traversal world — they need respawning camps (con-band XP farming), persistent last_map resume, quest map-matches, world-event bosses on the 30-min timer, and a low-population game benefits from players/AI-residents being visible in them. Everything in (a)-(c) is the proven template; the server cost is one more sim dict per zone in the existing 30 Hz loop (currently ~14 static worlds).
- Reserve INSTANCING only if Phase 8 wants a repeatable capstone-boss "room" with per-party Intensity/affix scaling — in that case add a 4th Circuit-style template (the camp_b/camp_c precedent shows rotating rooms are literally just more template keys + `INSTANCE_MAPS` entries + `_circuit_template` rotation) rather than instancing a leveling zone. New static boss arenas (the GY_BOSS/GY_SECRET pattern: small room, cover ring, gated portal, 30-min respawn, per-party P7c HP scaling already automatic for any `phased` class, Server.gd:3624-3658) fit the shipped model with zero new server plumbing.
- Topology note: branch the new chain off HOME's north gate row (World.gd:97-102 has room for another "▶ <Biome>" pad) — NOT off GY5 — matching the handoff's "branched off the Home hub" (docs/gameplay-length-handoff.md:193-202). Gate the capstone region's entry with a new `boss_ready`-style stat gate (visible-but-locked + explainer chat is the shipped UX) rather than a hidden gate.

CORRECTED CITE: the handoff's "server auto-boots from each MAPS key at :196-200" (gameplay-length-handoff.md:194-195) is stale — the real site is `init_worlds` at server/Server.gd:242-250 (loop :245-248), called from start() at :233.

---

## Progression bands + directed-play machinery

PROGRESSION BANDS + DIRECTED-PLAY MACHINERY — verified against live code 2026-07-14. All paths absolute under /home/e/legends-mmo.

===== (a) THE REAL LEVELING CURVE TODAY =====

XP-to-level: `_xp_to_next(L) = int(50L + 7.5L²)` (server/Server.gd:204-207, reshaped front-loaded by P1e). Per-level cost / cumulative-to-reach-next (computed from the exact formula incl. int truncation):
L1→2: 57 (cum 57) · L2→3: 130 (187) · L3→4: 217 (404) · L4→5: 320 (724) · L5→6: 437 (1,161) · L8→9: 880 (cum to L9 3,328) · L9→10: 1,057 (cum to L10 5,635) · L11→12: 1,680 (cum 8,772 to L12) · L15→16: 2,720 (cum 18,016 to L16) · L17→18: 3,330 (24,363 to L18) · L19→20: 4,000 (32,020 to L20) · L23→24: 5,520 (51,744 to L24) · L28→29: 7,757 (85,905 total to L30). Total 1→30 = 85,905 XP. LEVEL_CAP=30 (Server.gd:66). At cap, overflow diverts to paragon Overtime (Server.gd:3559-3563).

Mob XP: `_mob_xp = MOB_XP_BASE(15) × mobLevel × tier-mult(minion 1 / elite 4 / boss 6) × intensity_reward × con` (Server.gd:48,51,64,3664-3672). intensity_reward = 1 + 0.5×(tier−1), Circuit-only (Server.gd:3661-3662).

Con-scaling (P1a, Server.gd:3674-3683 + consts :68-70): full XP within ±4 levels of the killer (XP_CON_GRACE); beyond that fades linearly over 12 more levels (XP_CON_SPAN) to a 40% floor (XP_CON_FLOOR); SYMMETRIC (anti-trivial-farm AND anti-carry). **Instanced Circuit maps are exempt — full XP at any level** (Server.gd:3668-3671, keyed on `_is_instance`). The :70 comment explicitly says the 40% floor exists "to keep GY5 a viable backup farm for high levels **until Phase 8 adds 9-28 zones**" — the code itself flags Phase 8 as the fix.

Party XP share (P1b, Server.gd:3685-3712): same-zone party members within 900u (XP_SHARE_RANGE), ≤8 levels from the killer (XP_SHARE_MAX_DELTA), hit-recently (noDmgT ≤ 6s anti-leech), each con-scaled by their OWN level. Rested XP (P1d): pool accrues 6%-of-a-level/hr offline, cap 1.5× current level's bar, spends as +50% on earned XP (Server.gd:741-743, 3539-3547).

Where 1-10 happens today: the 9-quest Glitchyard chain (shared/Quests.gd:24-95, min_level 1→7) across GY1-5, whose spawns are mob level 1-8 (shared/World.gd:13-17 zone comments; spawn tables :177-208 — GY1 lvl 1-2, GY2 lvl 2-3 + elite 3, GY3 lvl 4-5 + elite 5, GY4 lvl 5-6 + elites 6, GY5 lvl 7-8 + elite 8), then Head Coach (boss, lvl 8, World.gd:211). Chain quest XP alone = 6,860 (Quests.gd rewards) ≈ carries past L10 (cum-to-L10 = 5,635) before kill XP is counted.

THE CEILING THAT MAKES THE DESERT: **no open-world mob in the game exceeds level 8** (drill_sergeant elite, World.gd:208); the two bosses are lvl 8 and lvl 10 (World.gd:211,219); Circuit rooms run lvl 5-8 (World.gd:231-252). So:
- A **level-12** player: mid3_command (min_level 12, Quests.gd:117-123) sends them back to GY5 to kill 20; con delta |12−8|=4 → still FULL XP (last level where GY5 minions con even). Best XP ≈ GY5 (15×8=120/minion) + Circuit at their max_intensity + dailies. Playable but 100% recycled geography.
- A **level-20** player: between mid6_tower (18, Quests.gd:138-143 — 6 GY5 elites again) and mid7_grind (21, :145-150 — "No shortcuts left — 40 opponents, wherever you find them", the quest text admits the desert). GY5 con: over = 20−8−4 = 8 → mult = 1−(8/12)(0.6) = 0.60 → 60% XP; by L24 over=12 → hard 40% floor. Their real farm is the instanced Camp Circuit (con-exempt + 1.5×/tier reward) — i.e. the same 3 rooms — plus the Drill's capped 0.6-of-a-level/run payout (DRILL_XP_WAVE_FRAC 0.08/wave from wave 3, run cap 0.6 of a level, Server.gd:739-740,1765-1771).
Phase-8 zone bands should target mob levels ~9-16 (chain) and ~18-28 (capstone) so con-scaling makes them the *correct* farm rather than a sidegrade — the ±4 grace band means a 5-zone chain needs roughly 2-level steps per zone (e.g. 9-10 / 11-12 / 12-13 / 14-15 / 15-16) mirroring GY's gradient.

===== (b) QUEST SYSTEM CAPABILITIES =====

Objective types: **kill only.** `objective = {type:"kill", match:{tier?, map?, class?, min_level?}, count}` — match fields AND-combined vs the slain-mob descriptor (Quests.gd:10-12, kill_matches :190-203). P6 added NO new objective types for quests (the doc's "visit"-style breadth doesn't exist); the bounty system added two non-kill KINDS — "circuit" (Circuit clears, optional min_tier) and "drill" (reach wave N) — but those are bounty-only hooks (Server.gd:4314-4316, 4408-4423). Phase-8 quests get: kill-by-map (works for any new zone id automatically), kill-by-tier, kill-by-class, kill-by-mob-min-level (usable once Phase-8 mobs exceed lvl 8 — currently uncompletable above 8, noted at Quests.gd:97-99).

Chains/gating: linear prereq chains — accept requires char level ≥ min_level AND prereq completed (Server.gd:4187-4201). Two chains: ORDER (9 quests, the secret-boss gate — server `_all_quests_done` iterates exactly ORDER; NEVER append to it, Quests.gd:18-21,170-176) and MIDGAME_ORDER (9 quests, L8-27). **Phase-8 chains must be new separate ORDER-style lists** (the MIDGAME precedent) + client display_order() concat (Quests.gd:183-184).

Giver: ONE quest-giver NPC pad in HOME at QUESTGIVER_POS (560,420), radius 80 (World.gd:83-84); accept/turn-in server-validated by proximity (Server.gd:4167-4173). Bounties are claimed at the SAME NPC (Server.gd:4453). A Phase-8 "away" giver would need either a second pad const + a second `_at_questgiver` variant, or reuse of this one.

Rewards per quest: {xp, credits, tokens, pages, dye, item} (Quests.gd:13-16); items are full inventory rows, RARITY_CAP-capped on equip. Grant is exactly-once via quest_mark_rewarded atomic claim (Server.gd:4241-4263). Existing spine already hands out: epic trinkets/weapons, 2 exclusive dyes (azure/gold/obsidian via quests, Quests.gd:129,157,165), a 50,000-credit respec bankroll (mid5, :136), Pages chunks 20-35.

Bounty rotation (P6b, Server.gd:4306-4438): pools BOUNTY_DAILY (6 defs, :4317-4324) and BOUNTY_WEEKLY (3 defs, :4326-4330); each UTC day 3 dailies + each UTC week (Thursday-00:00, same boundary as the Camp affix) 1 weekly are picked by deterministic (id|period) hash sort — same set for all players, no scheduler (:4340-4352). Progress is session-only; the durable state is only the per-period claim ledger (atomic bounty_claim fn); rewards are **currencies only (credits/tokens/Pages) — deliberately no gear/stats** (:4306-4310). Content is server-defined and shipped via snapshot META → **new bounties (e.g. Phase-8-zone kill bounties) deploy with ZERO client re-export** (:4307-4308). Phase 8 can simply append away-biome entries to both pools.

===== (c) ENDGAME GATES — what the ~18-28 capstone must slot under =====

- **Playbook Pages** (attunement currency): earned from Circuit clears (5 + 3×tier, ×affix pages mult, Server.gd:722-723,949), Head Coach kills (50, :734,3511-3512), Drill (2/wave past wave 2, :737), mid-spine quests, bounties (daily 25-60, weekly 220-260). Sinks: the one-time 300-Page **Master Key** (:721,999-1019) and repeatable **Audibles** (per-run Circuit consumables, 30-40 Pages, GameData.gd:530-540).
- **Gate types on portals** (Server.gd:3386-3403 + World.gd:131,139): `boss_ready` (GY5→Head Coach Arena) = level ≥ 16 AND equipped item_power ≥ 800 (BOSS_GATE_LEVEL/IP, :93-94) — visible-but-locked with a throttled "why sealed" prompt (:95-96, 3371); `all_quests` = all 9 ORDER quests done; `secret_key` = all_quests AND Master Key — these two are HIDDEN from snapshots until eligible (:95, 3412). **Phase-8 capstone gating has three ready-made precedents: a level+gear-score gate, a quest-completion gate, and a currency-forged-key gate** — a second key (e.g. an "Away Pass" Pages sink) would reuse progression_craft_key's dupe-safe pattern.
- **Camp Circuit / Intensity**: instanced per-party (enter_camp, tier clamped to [1, max_intensity], :887-896); clearing at your ceiling unlocks the next (max 30, :719,942-947); mobs scale ×1.6 HP / ×1.13 dmg per tier geometric (:745-750); rooms rotate 3 templates per (party,tier,week) (:733); weekly affix rotation of 4 (:727-732). Loot: clear grants an elite-tier bonus roll; intensity raises drop ilvl (+2/tier) and rarity floor (~1 rank/2 tiers) (:3863-3870,3907).
- **Leaderboards/seasons (P7d)**: 5 categories — drill (solo-only), circuit_time, boss_time seasonal (weekly reset), gear + intensity all-time (Server.gd:1786-1813); weekly rank-1 on any seasonal board → exclusive "Season Champion" dye, lazily settled on login (:1815-1847).
Coherent Phase-8 slotting: chain zones sit under the boss_ready gate (levels 9-16 feed exactly to BOSS_GATE_LEVEL 16 — today that L16+IP800 requirement has NO content between L10-ish quest-chain end and itself); capstone (~18-28) sits between headcoach_down and the L27 mid9_legend finale, and its bosses can feed the existing boss_time board + Pages economy rather than new currencies.

===== (d) GROUP-SIZE ASSUMPTIONS (P7c + residents) =====

Party cap = 5 counting humans + bonded AI companions (MAX_PARTY, Server.gd:2176,2209,2246,2364). 6 AI residents live in GY zones (roster :80-87, levels 5-10) and can be recruited into a party; bonded residents follow the leader zone-to-zone (_try_follow :2377-2399) — they do NOT enter instances or PvP (:2389-2393) but DO follow into GY_BOSS/GY_SECRET (no block exists; the handoff's lever ① was NOT implemented — instead v1 shipped ② nerf: RESIDENT_TIERS mid 1.3/1.1, high 1.8/1.25 + stripped ults, :89-91,712-715).

P7c boss scaling (Server.gd:55-63, 3615-3658): applies only to `phased` world bosses. Boss HP pool locks on first real damage (below 90% of base) to clampf(0.30 + 0.175×(peak_force−1), 0.30, 1.0) of the 5-player pool; a bot counts 0.5 of a player; peak-force only rises (upscale adds absolute HP, damage preserved; never downscales; leash resets). Damage is NEVER reduced — a solo faces 30% HP but full mechanics. Design intent stated at :58-59: "near-max-gear-solo-with-bots a tight win, a gate-minimum group a loss."
**Phase-8 content should assume: solo + 1-2 bot companions as the norm (effective force 1.5-2.0 → boss at ~39-48% HP), full 5-stack as the ceiling.** New capstone bosses that reuse `phased` (GameData phased/coreShield/summon primitives) inherit this scaling for free; non-phased minibosses stay fixed-tuned. Base boss tuning: MOB_BOSS_HP 22.0 / DMG 2.1 (:52-53), boss XP mult 6 (:64 — "≈0.9 of a level, kept under a full level"), boss credits ×4, 60 tokens (:2428-2435,2459-2463).

===== (e) REWARDS AVAILABLE WITHOUT NEW STAT SURFACES (P7a vetoed) =====

- **Credits**: kills 8+5×lvl (×2 elite/×4 boss/×1.5-per-intensity-tier, Server.gd:2428-2435); quest/bounty grants; sinks exist (shop :139-141, dyes, 50k talent respec GameData.gd:449, Builder 10k locker).
- **Gear ilvl bands**: drop ilvl = mobLevel + (elite +5 / boss +12) + 2×(intensity−1), clamp 1-80 (Server.gd:3869-3870); item_power = primary + affixes + ilvl (:2514). Open-world drops today cap at ilvl ~8/13/20 (mob lvl 8 ceiling) — **Phase-8 mob levels 9-28 organically raise open-world ilvl to ~28 minion / ~33 elite / ~40 boss with ZERO new item mechanics**, giving the biome a real gear identity vs crafting (ilvl 12/18/26/30 recipes, GameData.gd:563-568) and SHOP_ILVL 8 (:137). Also hangable: uniques (7 defs, boss 15% UNIQUE_DROP_CHANCE :165, GameData.gd:598-608) — new-boss loot tables can pull existing uniques; the vendor-only rookie_camp token set precedent (GameData.gd:555-557) supports an "away" token-vendor set WITHOUT new stats (same stat surface, RARITY/EQUIP caps).
- **Playbook Pages**: quest/bounty/boss chunks (BOSS_PAGES 50 precedent for new bosses at Server.gd:3511-3512); sinks = Audibles + Master-Key-style forged gates.
- **Practice Tokens**: currently Glitchyard-only kill drops (gy flag, Server.gd:3495-3504) — Phase 8 must decide whether away zones drop tokens (the flag is a map-prefix check :3495: `str(mapname).begins_with("glitchyard")`).
- **Cosmetic dyes**: 8 buyable + quest-exclusive grants (azure/gold/obsidian precedent, Quests.gd:129,157,165) + the non-buyable Champion precedent (GameData.gd:612-624) — new biome-exclusive dyes are pure data.
- **Titles: DO NOT EXIST** — no title system anywhere in server/shared (only the appendix wishlist, docs/gameplay-length-handoff.md:245-246). Not available without new work.
- **Leaderboards/seasons hooks**: new capstone bosses can submit to the existing seasonal boss_time board via the _fightStartMs clock (Server.gd:3513-3520, category list :1807); weekly Champion dye rides along free.
- **Paragon (post-cap)**: capstone ~18-28 content feeds the L30→Overtime pipeline automatically (overflow at :3559-3563; 8,250 XP/paragon level, GameData.gd:515); paragon perks are QoL reward-multipliers only (GameData.gd:522-529) — no interaction needed beyond XP.
- **Rested XP + con exemption levers**: Phase-8 zones are open-world → con-scaled by default; if any Phase-8 sub-area is built as an instance template it inherits the full-XP exemption (Server.gd:3668-3671) — a deliberate lever to make capstone instanced content the premium farm.

Key structural facts for the orchestrator: (1) the entire 9-16 band's directed play today is 3 mid-spine quests pointing back at GY5; (2) the game's mob-level ceiling of 8 (10 for PRIME) is the single number Phase 8 raises, and con-scaling (±4 grace) then does the zone-routing automatically; (3) quest objectives are kill-only — any "visit/escort/collect" beat in Phase 8 is NEW machinery; (4) bounties + quest defs are pure data with zero-client-re-export (bounties) / shared-file (Quests.gd → client re-export needed) deployment costs respectively; (5) boss_ready's L16+IP800 gate is currently reachable only by grinding — the 9-16 chain should be tuned to deliver exactly that gate's requirements at its end.

---

## Mob roster + boss primitives

LANE: MOB ROSTER + BOSS PRIMITIVES — findings, all cited (file:line in /home/e/legends-mmo).

=== (a) FULL MOB BESTIARY (20 mob-flagged defs, all in shared/GameData.gd CLASSES, flagged mob:true; playable_ids() filters them out of the balance harness, GameData.gd:628-633) ===

Render fields read by the client: model = models/meshy/mobs/<id>.glb basename; rig:true → models/meshy/mobs/rigged/<id>.glb + clips; skins = per-spawn alt GLB (stable per fighter id, Client.gd:450-453); anim = procedural-animator profile; h = rendered height (scale-to-height, Client.gd:449-472); face = native-front yaw fix (Client.gd:470). Rules: non-melee basic MUST carry range; a reflect buff needs reflectMult (GameData.gd:134-135).

PHASE-1 MINIONS (GameData.gd:136-176):
1. cone_swarmer — fast melee swarmer (melee + dashAttack/slow); static cone.glb, anim "cone", h1.5. Zones: GY1 x2, GY2, CAMP x2, CAMP_B (World.gd:177-243); Drill pool (Server.gd:1694); summon fodder for drill_sergeant (GameData.gd:186) and BOTH bosses' threshSummon (:223,251). HEAVILY used.
2. foam_dummy — rigged melee minion (swing + knockback shove); rigged, skins [foam_dummy,foam_dummy2], h3.3. GY1 x2, GY2 x2, GY3, CAMP; Drill pool. Heavily used.
3. tackle_brute — bruiser (melee/dashAttack-KB/meleeAoe/selfbuff-DR); static tackle_brute.glb, anim "brute", h3.5. Only GY2 elite (World.gd:187) + Drill pool. LIGHTLY USED.
4. shooting_dummy — STATIONARY turret (projectile basic + slow shot + reflect selfbuff; reflectMult 1.4) (GameData.gd:166-176). GY2/GY3/GY4/GY5 minion camps; Drill pool. Heavily used.

PHASE-2 ELITES (GameData.gd:177-213):
5. drill_sergeant — rigged summoner elite: kbImmune, melee+stun, summon cone_swarmer x3, hazard zone (:179-189). ONLY GY5 elite (World.gd:208) — lightly used. Its rigged GLB has idle/run/punch/hit/death + a CAST/shout clip (Client.gd:509,511).
6. sled_juggernaut — kbImmune, frontalDR 0.55, face 90; wallStun 1.5 charge, meleeAoe slam, slow lash (:190-201). GY3 + GY4 elites only; NOT in Drill pool. Lightly used.
7. ball_machine — stationary turret, face 90; wobble-stacking basic + 5-shot spread fan + 2-bounce ricochet + stun overcharge (:202-213). GY4 + GY5 elites; NOT in Drill pool. Lightly used.

BOSSES (GameData.gd:214-270; the handoff-cited primitive block):
8. head_coach — phased, coreCount 4, kbImmune, threshSummon cone x2; 10-ability 4-phase kit incl. campreset ult (dmg 120, cast 3.0, phase 3), wallStun Sled Drive, pull 220 Resistance Pull (:220-241). Static head_coach.glb, anim "boss", h4.6. GY_BOSS only, lvl 8 tier boss (World.gd:211).
9. head_coach_prime — phased, coreCount 6, hpMult 6.0, coreShield 0.55, dmgScale 0.55, threshSummon cone x3; totalreset at phase 2 / cd 12 (fires often — recurring LOS check), wallStun on TWO dashes, pull 260 (:247-270). Static boss2.glb, anim "boss", h6.0. GY_SECRET only, lvl 10 (World.gd:219).
10. power_core — inert destructible objective: isCore:true (no loot/XP), stationary, empty abilities (:382-387); rendered as a PROCEDURAL emissive crystal, no GLB (Client.gd:474-501). GY_BOSS x4 lvl5, GY_SECRET x6 lvl7 (World.gd:212-225). Fully reusable anywhere.

P3a REMIX MINIONS (GameData.gd:277-325, commit e8d4900) — all recolor:true reusing existing GLBs:
11. spring_cone (#7CFF4A on cone) — faster dasher. GY3, CAMP_B, CAMP_C; Drill; summon fodder for blitz_captain (:367).
12. tire_dummy (#8792A6 on foam_dummy) — brace/DR tank. GY3 only + Drill. Lightly used.
13. chalk_liner (#EDEDED on shooting_dummy) — turret + hazard zone. GY4, CAMP_B; Drill.
14. whistle_cone (#FFE04A on cone) — melee stunner. GY4 only + Drill. Lightly used.
15. pop_dummy (#E8564A on foam_dummy, skins reversed) — meleeAoe minion. GY5, CAMP_C; Drill.

P3b REMIX ELITES (GameData.gd:326-381, commit 2b4f714) — all recolor:true:
16. iron_sled (#6E7681 on sled_juggernaut) — kbImmune/frontalDR/wallStun. CAMP, CAMP_B objective; Drill.
17. gatling_machine (#C43C2E on ball_machine) — cd-1.0 rapid turret, 7-shot fan, ricochet. CAMP_B; Drill.
18. field_medic (#2FA79A on drill_sergeant) — mob HEALER via AI.support_tick (allyheal 9% + allybuff shield 13%) (:351-359). CAMP, CAMP_C only; NOT in Drill pool. Lightly used.
19. blitz_captain (#E08A2E on drill_sergeant) — kbImmune summoner (spring_cone x3) + charger. CAMP_C; Drill.
20. tackle_captain (#D9A21A on tackle_brute) — bruiser + hazard zone; the objective gatekeeper of CAMP + CAMP_C; Drill.

AVAILABLE FOR PHASE 8 (unused/lightly used): tackle_brute, sled_juggernaut, ball_machine, drill_sergeant (each anchors only 1-2 open-world camps); tire_dummy, whistle_cone, field_medic (1-2 spots). Base-GLB recolor headroom: cone has 2 variants, foam_dummy 3, shooting_dummy 2, sled 2, ball_machine 2, drill_sergeant 3, tackle_brute 2 — head_coach.glb and boss2.glb have ZERO recolor variants yet (the biggest untapped asset). Drill pool (Server.gd:1694) = 13 ids; excludes sled_juggernaut/ball_machine/drill_sergeant/field_medic/bosses/power_core.

MOB ABILITY TYPES PROVEN ON THE MOB AI: melee, dashAttack, meleeAoe, projectile, zone, selfbuff, summon, spread(+bounces), campreset, allyheal/allybuff (via AI.support_tick, Sim.gd:396; proven by field_medic). NOT mob-proven: barrage, leapAttack, dash, teamheal, barrier (player-only so far). Constraint (hard): new zones/mobs must reuse only these — no new sim mechanics.

=== (b) BOSS PRIMITIVES MENU (each independently attachable to any new mob def) ===

1. PHASED ("phased":true) — Sim.gd:227-250: monotonic HP-band phase 0→3 at hp/maxHP <0.70/<0.40/<0.15; never regresses on heals. Abilities tagged "phase":N unlock at boss phase ≥N (Sim.gd:410 — min-unlock; no-op for players). Structural no-op in the harness path.
2. threshSummon {mobType,count} — one-time add wave per NEW phase entered, latched, multi-band-safe (Sim.gd:242-250); rides the server summon bridge.
3. SUMMON ability type — sim emits event only (zero rng, gated on hostile within 460; Abilities.gd:183-192); server spawns (Server.gd:3308-3347): SUMMON_CAP 3 live per summoner (Server.gd:37), adds tagged isAdd (never respawn, despawn on death :3296-3298, no loot/XP), mobLevel = owner−1, inherit intensity/affix (:3336-3340), ring radius ADD_SPAWN_R 70 (:38).
4. CASTED ARENA ULT (type "campreset") — Abilities.gd:203-211 opens a frozen 3s telegraph; resolves in Sim.gd:361-377: arena-wide AoE that SPARES anyone whose LOS to the boss is cover-blocked, damage × (cores_alive/coreCount). Exemplars: head_coach "campreset" dmg120/cd15/phase3; PRIME "totalreset" dmg150/cd12/phase2. Client warning UI is generic (countdown + "BREAK LINE OF SIGHT!", Client.gd:2289-2291). Requires a cover-ring arena (World.gd:381-395 pattern: 4 walls, no passively-safe spot).
5. POWER CORES + coreCount — cores are just World.MOBS entries of class power_core; coreCount on the boss def sets the ult-weaken denominator. They respawn (MOB_RESPAWN_DELAY 6s) so counterplay recurs (GameData.gd:271-273).
6. coreShield — Combat.gd:71-79: boss takes `coreShield` fraction LESS damage while ANY allied core lives. Client auto-renders a shield aura for any def with coreShield>0 (Client.gd:1392-1411) + a "SHIELDED — DESTROY THE CORES" plate (Client.gd:2292-2296).
7. hpMult / dmgScale — per-def flat multipliers folded into _scale_mob (Server.gd:3606-3608); PRIME uses 6.0/0.55 to make a 10+min raid.
8. wallStun BAIT — Abilities.gd:235-246: a dashAttack with wallStun whose target broke LOS during the telegraph CRASHES: lunges half-dist, self-stuns (1.4-1.6s shipped values), no hit. The skill-dodge primitive.
9. PULL — meleeAoe with "pull": yanks non-kbImmune hostiles toward the caster, min-30 standoff (Sim.gd:350-356). The anti-cover-camping counter that pairs with the ult.
10. HAZARD ZONE — dmg/slow ground disc, LOS-gated cast (Abilities.gd:174-182).
11. SPREAD/RICOCHET — direction-mode projectile fans, `bounces` reflect off cover (Abilities.gd:212-232; step/bounce physics Sim.gd:27-62); WOBBLE stacking → stumble stun at 4 stacks (Sim.gd:15-25, mob-only tags).
12. Passive flags: kbImmune, frontalDR (flank check), stationary (turret), face (yaw fix), reflectMult, stun/slow/knockback/knockdown riders.
13. P7c PARTY SCALING — automatic for ANY phased boss (Server.gd:3624-3658): tracks peak force (bots ×0.5), locks HP to 0.30 + 0.175/extra attacker (clamped 1.0) once real damage passes 90% hp; upscales-only afterwards. New phased bosses inherit this with zero work (constants Server.gd:60-63).
14. GATES — portal "gate" field (World.gd:131,139; gate_for_map World.gd:413-418): "boss_ready" = level ≥16 AND gear score ≥800, visible-but-locked with a throttled explainer (Server.gd:93-96, 3370-3374); "secret_key" = hidden-in-snapshot until ALL quests done (Server.gd:95, 3384-3389).
15. Boss lifecycle: BOSS_RESPAWN_DELAY 1800s world-event cadence (Server.gd:36); phase/latch state lives in create_fighter's fresh dict so _revive fully re-arms the fight (GameData.gd:726-728).

SHIPPED EXEMPLAR COMBOS:
- Head Coach (entry raid) = phased + threshSummon(2) + campreset@P3 + coreCount4 (ult-weaken only, NO coreShield) + wallStun dash + pull + kbImmune + cover-ring + boss_ready gate + P7c.
- Head Coach PRIME (endurance raid) = all of the above intensified + coreShield 0.55 + hpMult 6 + dmgScale 0.55 + coreCount 6 + ult at P2/cd12 + secret hidden gate.
- Drill "boss" = NOT phased: every 5th wave the anchor spawns tier "elite" with wave-ramped level (clamp 20) + intensity 1+wave/3 (Server.gd:1680-1711) — the cheap mini-boss recipe for wave/objective content.

=== (c) RECOLORED-GLB FEASIBILITY ===

Mechanism: def fields "recolor":true + "color":"#hex" → at spawn the client writes dye_applied and calls _apply_dye (Client.gd:1428-1431). _apply_dye = ONE flat translucent unshaded StandardMaterial3D overlay, alpha 0.45, applied to every MeshInstance3D recursively (skips BoneAttachment3D-held props) (Client.gd:2343-2355, 2375-2379). Hit-flash shares the material_overlay channel and RESTORES the dye at fade end (Client.gd:2357-2373) — this rewiring was the e8d4900 review fix. CAN do: strong whole-model hue shift (any hex), + rescale via `h`, + rename, + different anim profile, + per-spawn `skins` alternation. CANNOT do: per-part colors, emissive glow, mesh/silhouette changes. Recolor is visually un-verifiable headlessly — eyeball on relaunch (e8d4900 commit message).

Boss-viable recolor candidates (existing GLBs → "new" bosses when recolored + rescaled + renamed + new kit):
- head_coach.glb (currently h4.6, unused for variants) → the Away-biome coach ("Rival Coach"/"Away Coach") — same silhouette reads as a faction rival with a strong wash + different phase names.
- boss2.glb (h6.0, unused for variants) → capstone boss.
- sled_juggernaut.glb rescaled h~5 → a siege-engine boss (wallStun/frontalDR identity built in).
- ball_machine.glb rescaled h~4.5 → a stationary artillery boss (spread/ricochet/wobble identity) — pair with cores/adds since it can't chase.
- tackle_brute.glb h~5 → a brute boss.
- drill_sergeant (RIGGED, has a cast clip) h~4 → a humanoid commander boss with real skeletal animation.
- power_core recolors are N/A (procedural mesh, color hardcoded Client.gd:484-490 — a variant would be a small client edit, not a dye).
CAUTION 1: player-class rigged GLBs (baseball/football/soccer/volleyball_rigged.glb, models/meshy/) are NOT reachable by mob defs — static mobs load from models/meshy/mobs/ (Client.gd:428) and rigged mobs only from the RIGGED_MOBS const whitelist {foam_dummy, foam_dummy2, drill_sergeant} (Client.gd:506-510) — using a player GLB as a boss needs new client wiring (or add the id to RIGGED_MOBS + copy/optimize the GLB into mobs/rigged/ + bake clips).
CAUTION 2: the boss nameplate hardcodes "☠ HEAD COACH" and the 4 phase names for ANY tier=="boss" (Client.gd:2294-2301) — a new boss needs a small client change to read the def's name (else every boss displays "HEAD COACH").
The "boss" procedural animator is generic and phase-reactive (agitation scales with f.phase; ult wind-up pose) (Client.gd:2237-2248) — free for any static-GLB boss.
NEW MESHY: none strictly required — 8 static + 3 rigged mob GLBs + 4 player rigs cover the plan; flag ONE optional new capstone-boss GLB only if the owner wants a distinct silhouette (costs credits + approval).

=== (d) MOB-SIDE TUNING SURFACE FOR NEW ZONES ===

_scale_mob (Server.gd:3596-3613), the single lever — per-mob, server-only, zero sim impact:
  HP  = class base maxHP × 0.35 × (1+(lvl−1)×0.3) × tier{minion 1 / elite 2.2 / boss 22} × def hpMult × 1.6^(intensity−1) × affixHp
  DMG ×= 0.28 × (1+(lvl−1)×0.2) × tier{1 / 1.6 / 2.1} × def dmgScale × 1.13^(intensity−1) × affixDmg
  (constants Server.gd:46-53; intensity fns :745-750; weekly affix :725-733 — instance-only, defaults 1.0). FORMAT_MODS[5] applies to players AND mobs but mobs have no entries → untouched (GameData.gd:408-410).
World.MOBS entries carry only {class, level, tier, x, y[, objective]} — "no new stat blocks" is the explicit design (World.gd:168-175). Phase 8 needs only NEW level numbers: shipped band is mob lvl 1-8 (GY1-5), boss 8, PRIME 10; the ~9-16 chain and ~18-28 capstone just continue the linear formulas.
XP: MOB_XP_BASE 15 × level × tier mult {1/4/6} (Server.gd:48,51,64; _mob_xp :3664+); con-scaling ±4 grace / 12 span / 0.4 floor, open-world only (Server.gd:68-70) — :70's comment explicitly says the floor keeps GY5 viable "until Phase 8 adds 9-28 zones". Drops: DROP_CHANCE minion 0.15 / elite 0.40 / boss 0.90 (+0.03/Intensity tier) (Server.gd:129-130); 15% of boss drops are uniques (:165).
Density/leash grammar of the live zones: 4-5 camps per zone, camps > AGGRO_RANGE 320 apart, west→east +1-2 level gradient, ONE elite anchoring the far east end beside the forward portal (World.gd:168-208); zone sizes grow along the chain 1500×850 → 2000×1100 (World.gd:58-62); cover panels (barrier/rack/bag) split lanes + flank each elite, heavier along the gradient (World.gd:353-395); portal drop points placed > AGGRO 320 from any camp (World.gd:118-135 comments). AGGRO 320 / LEASH 1600 / MAX_LEASH 1600 are global consts (Server.gd:43-45). Mob respawn 6s, boss 1800s (Server.gd:35-36).
P7c on bosses: automatic for phased defs (see (b).13) — solo-first live population is already served (solo = 30% pool, bots count 0.5, Server.gd:60-62).
Residents: roster is GY-zone-hardcoded (Server.gd:80-86, routes :78-79 never include boss/PvP arenas) — Phase 8 zones need new RESIDENTS entries/routes if companions should populate the new band.
Quest coupling: kill objectives match {tier, map, class, min_level} (Quests.gd:11-12, 189-199); a standing comment warns mob min_level filters above 8 are unfarmable today (Quests.gd:98-100) — Phase 8's higher mob levels relax that ceiling.
Deploy note: every new mob def is a shared/GameData.gd change → server redeploy + client re-export in the SAME commit (stale clients render new ids as gray capsules — 2b4f714 commit message; capsule fallback Client.gd:455-457). Determinism-safe: new CLASSES keys never enter the harness (playable_ids filter, GameData.gd:626-633), and phased/summon/campreset paths are structurally inert for players (Sim.gd:230-233, 410).

---

## Client theming + assets + deploy

LANE REPORT: CLIENT THEMING + ASSETS + DEPLOY (repo /home/e/legends-mmo @ v1.1.1, project.godot:14)

========================================================================
(a) WHAT MAKES A ZONE LOOK DISTINCT TODAY — every per-map client hook
========================================================================

1. GROUND TEXTURE + TINT + TILE SIZE — client/Client.gd:566-591. `_make_field_material(map)` picks the tiled albedo by MAP-NAME PREFIX: `map.begins_with("glitchyard") or begins_with("camp") or == World.DRILL` → scrapyard_albedo.png tinted Color(0.74,0.74,0.72) @ 7.0 world-units/repeat; everything else → turf_albedo.png tinted Color(0.74,0.88,0.66) @ 5.0 (Client.gd:574-580). Textures live in res://models/meshy/props/ground/ (only 2 exist: turf_albedo.png, scrapyard_albedo.png). Re-themed on map change via `_apply_field_theme()` sig-guard (Client.gd:583-591, called Client.gd:1553). PHASE-8 KNOB: this is a hardcoded binary branch — new biome needs (i) new tileable albedo(s) and (ii) extending this function's map-name mapping. Textures are SELF-GENERATED, zero Meshy cost: tools/gen_ground_textures.py (procedural, tileable-by-construction, "no license/approval concern" per its docstring) — the sanctioned way to mint e.g. sand/clay/snow/hardwood variants. Committed .import files for ground textures are TRACKED (publish_client.sh:32-33) — keep sidecars.

2. DECALS (pure-visual set dressing; rings/cones/props) — source priority: live F4 editor copy → res://data/decals/<map>.json → World.DECALS const (client _decals_for Client.gd:755-772; server mirrors the same priority in World._decals_source shared/World.gd:342-351). World.DECALS const at shared/World.gd:426-485 (all 12 live maps have entries). Authored JSONs exist for home (63 entries), arena (8), glitchyard_1 (19) in data/decals/. Kinds: "ring" (painted circle), "cone" (procedural traffic cone, Client.gd:~1595-1606), "prop" {model,x,y,h,yaw,oy} → GLB instantiated scaled-to-height h (Client.gd:1607-1615). NOT sent over the wire — client renders from ITS OWN bundled copy (World.gd:423-425) ⇒ decal changes require client re-export to reach players. CAVEAT: decals are not purely client-side if collidable — the server derives collision circles from the SAME decal list via PROP_FOOTPRINT (shared/World.gd:300-339); a model absent from PROP_FOOTPRINT (World.gd:309-321) is walk-through flat décor. Authoring tools: F3 coord overlay (Client.gd:681-730), F4 in-game decorator saves data/decals/<map>.json (Client.gd:732-813; docs/map-authoring-guide.md §"fast path").

3. COVER OBSTACLES (gameplay + visual) — shared/World.gd OBSTACLES const :353-409, entries {x,y,prop,len,yaw}; expanded to collision-circle rows server-side (circles_from :271-295), sent IN THE SNAPSHOT and rendered client-side as the named GLB scaled to len with a navy pad + yellow safety stripe (Client.gd:1617-1620, _render_obstacles :1654+). Only 3 cover props have PROP_DIM entries (World.gd:262-266): barrier, rack, bag. PHASE-8 KNOB: new zones reuse these; promoting an existing decor GLB (e.g. straight_cover_barrier, glitchyard_wall, championship_arena_wall — already in models/meshy/props) to a cover prop = add a PROP_DIM entry (shared/ change) — zero new assets.

4. MOB LOOK — GameData class def keys consumed by client/Client.gd:_make_character (:370-411) + _make_mob_character (:449-472): `model` (basename under models/meshy/mobs/), `skins` (alt-GLB array, stable per fighter id :450-453), `h` (scale-to-height), `anim` (procedural animator profile: cone/brute/turret/boss/sergeant/core, Client.gd:2150+), `face` (yaw fix), `rig` (skeletal path, RIGGED_MOBS :506-510), `isCore` (procedural crystal fallback :474-501), and the Phase-3 remix knob `"recolor": true` + `"color": "#hex"` → applied via the cosmetic-dye channel so hit-flash restore keeps it (Client.gd:1428-1431). 12 mob GLBs exist (models/meshy/mobs/): ball_machine, boss2, cone, head_coach, power_core, sled_juggernaut, tackle_brute, shooting_dummy(+2), rigged/{drill_sergeant, foam_dummy, foam_dummy2}. Phase 8 bosses = recolor head_coach/boss2 + h/anim changes, exactly the shipped P3/P3b pattern (GameData.gd:274-362).

5. PORTALS + LABELS — shared/World.gd PORTALS :94-166 (labels like "▶ Agility Grid" travel in the snapshot via portals_for :499-503); `gate` key for gated entries (:131,:139; gate_for_map :413-418); `instance`/`auto` for instanced entries (:100-107).

6. MAP SIZE/FEEL — MAPS const shared/World.gd:56-74: per-map w/h (ground plane resizes, Client.gd:670-679), type safe/combat, regen, aggro, pvp, spawn.

7. ZONE NAME SURFACES — NetClient._zone_name(map) hardcoded match at client/NetClient.gd:6411-6424 (fallback = map.capitalize(); note glitchyard_boss/secret/locker already rely on the fallback). Feeds (i) the HUD zone chip (:6402-6408, red + "⚔ …PVP" when pvp) and (ii) the "Now Entering" hero banner on zone change (:6076-6081).

8. MUSIC/AMBIENCE — the ONLY per-zone audio hook: `AudioManager.play_music(map)` crossfade on zone change (NetClient.gd:6084) loading res://audio/music/<map-id>.ogg (client/AudioManager.gd:12,121-132; audio/README.md). audio/music/ is currently EMPTY — the system ships silent; dropping correctly-named files + client re-export enables per-zone tracks with no code change. Portal SFX on zone change (NetClient.gd:6078).

9. LIGHTING/SKY — NO per-map hook: one global DirectionalLight + WorldEnvironment (BG_COLOR 0.05/0.07/0.11, fog, ambient) built once in Client._build_world (Client.gd:1066-1083). A per-map environment tint/fog would be a NEW client-only knob (flag as an optional Phase-8 addition; cheap, no protocol impact).

========================================================================
(b) AVAILABLE PROP/TEXTURE LIBRARY (no new Meshy) + GAPS
========================================================================

Prop loader search order (bare basename, first hit wins): models/meshy/props/ → models/kits/nature/ → models/kits/city/ (Client.gd PROP_DIRS :1626; same list used by decals + obstacles). All ids below are placeable via F4 once listed in DECO_PROPS (Client.gd:736-752).

INTEGRATED Meshy props (29 GLBs in models/meshy/props/, optimized, in DECO_PROPS): sports/training — bag, barrier, rack, stadium, sideline_stand, gear_forge, quest_board, power_core; locker set — single_locker, player_bench, equipment_shelf, sports_ball_rack, championship_trophy; arena tech — bounty_terminal, leaderboard_kiosk, zone_terminal, boundary_pylon; arena structure — player_tunnel_gate, arena_service_door, equipment_transport_crate, straight_cover_barrier, spectator_safety_rail; environment walls — championship_arena_wall, glitchyard_wall; glitchyard utility (batch_005) — cable_spool_cart, coolant_pump_station, industrial_ventilation_unit, maintenance_tool_cart, scrap_sports_equipment_pile.

FREE Kenney CC0 kits (31 GLBs, zero credits): nature — tree_oak/default/thin/pineRoundC/palmDetailedTall, rock_largeA/C/E, rock_tallC, stone_largeB, plant_bush(Large), grass_large, flower_redA/yellowB, log_stack, fence_simple/planks/corner; city — building-a/c/e/h/k/n/q/t, chimney-small/medium/large, detail-tank. Biome levers already here: PALMS (beach/away-game venue), PINES (mountain/north venue), rocks/stones (badlands), buildings+chimneys (urban away stadium district).

APPROVED, GENERATED, BUT NOT YET INTEGRATED (in too_add_models/approved/, 6-9 MB raw — need the §A.1 optimize pass in docs/props-textures-handoff.md:71-80, no new Meshy spend): founders_commons batch_006 — championship_fountain, community_team_table, covered_market_stall, plaza_light_column, public_plaza_bench, vendor_service_kiosk; reward_progression batch_007 — championship_reward_chest, loot_drop_capsule, open_salvage_hopper, portal_anchor, season_reward_vault. (batch_008_locker_personalization exists in batches/ — couch, strategy_table, trophy display, etc. — but has NO approved/ folder yet = pending owner approval.) portal_anchor + covered_market_stall + plaza_light_column are directly useful as away-hub dressing.

TEXTURES: 2 ground albedos (turf, scrapyard). New biome ground variants are FREE via tools/gen_ground_textures.py (self-authored procedural, per-owner precedent).

GAPS → candidates for AT MOST ONE small Meshy batch (flag for approval): the library is training-camp/arena/commons-flavored; a distinct "away" biome identity has no (i) biome terrain landmark (e.g. desert mesa / snow drift / swamp stump — partially coverable with Kenney rocks+palms+pines recolor-by-lighting), (ii) rival-team venue signage (away-stadium banner/scoreboard/goal structure), (iii) a distinct capstone-region wall (championship_arena_wall + glitchyard_wall are the only two enclosure walls). Recommended single batch if the owner approves: 4-6 "away venue" pieces (rival banner/flag, away scoreboard, one biome landmark, one capstone wall variant). Everything else (7-8 zones' dressing) is achievable from the ~65 existing GLBs + new procedural ground textures + mob recolors.

========================================================================
(c) PER-NEW-ZONE SURFACES NEEDING ENTRIES
========================================================================
Per new zone id, the client/deploy touchpoints are:
1. NetClient._zone_name match — client/NetClient.gd:6411-6424 (HUD chip + "Now Entering" banner both read it; without an entry the raw id gets capitalize()d).
2. Client._make_field_material map-name branch — Client.gd:573-581 (else new zones render as generic turf).
3. World.DECALS entry or data/decals/<zone>.json — shared/World.gd:426-485 / data/decals/ (plus PROP_FOOTPRINT World.gd:309-321 for any collidable décor — shared/, needs redeploy).
4. Admin F1 Teleport buttons — client/NetClient.gd:4834 (hardcoded list Home/Arena/GY1-5/BOSS; new zones need goto entries for testability; server side `goto` handler Server.gd:4530 is map-generic).
5. CI prop-load guard — tools/smoke_prop_loads.gd:8-12 hardcodes the prop list + the 2 ground textures; ADD any newly integrated props/textures (this suite exists because of the v1.1.0 packed-unimported regression).
6. DECO_PROPS palette — Client.gd:736-752 for any newly integrated prop id.
7. Music (optional) — drop audio/music/<zone-id>.ogg (AudioManager.gd:12,121; no code change).
8. NO WORK NEEDED: minimap — fully snapshot-generic (frame/portals/fighters/arrow, NetClient.gd:5864-5911; home service pads are already null off-home); leaderboards — fixed 5 categories drill/gear/intensity/circuit_time/boss_time (Server.gd:1807, SEASONAL_CATS :1789), no per-zone boards. CAVEAT: boss_time is submitted only on `classId == "head_coach"` kills (Server.gd:3511-3520) — if Phase-8 NEW bosses should post to boss_time, that trigger needs their classIds (server-only change).
9. Server side is data-driven: static worlds boot from every MAPS key, skipping INSTANCE_MAPS (Server.gd:246,457,471; World.is_instance_template :32-33) — no per-zone server code.

========================================================================
(d) DEPLOY CHECKLIST — shared/-heavy content drop at v1.1.1
========================================================================
PROTOCOL: Protocol VERSION is 2 (shared/Protocol.gd:21). Pure content (new MAPS/PORTALS/MOBS/OBSTACLES/DECALS keys, new GameData mob defs) changes NO RPC signature and adds no required snapshot field → NO version bump (bump rules Protocol.gd:6-14: "purely additive optional fields the old client ignores do NOT need a bump"). BUT: an OLD client in a NEW zone would miss that zone's World-const decals/obstacle GLBs/zone-name — the same-commit re-export rule below is what actually keeps clients coherent, since the client renders zones from its OWN copy of shared/World.gd (decals never travel the wire, World.gd:423-425; obstacles do travel but reference GLBs+PROP_DIM in the client bundle).

EXACT SEQUENCE:
1. LOCAL: author + verify. Compile check (docs/map-authoring-guide.md §5): `godot --headless --path . --import` then grep 'SCRIPT ERROR'. Run local server (`godot --headless -- --server` with SUPABASE_SERVICE_KEY) + local client; walk EVERY new portal FORWARD AND BACK (full round-trips; drop points must be > PORTAL_RADIUS from the reverse pad and > AGGRO_RANGE 320 from elites — patterns at World.gd:117-119,:127-135); use admin F1 goto for spot checks (needs the new buttons from (c)-4).
2. ONE COMMIT containing shared/ + client + data/decals + tools/smoke_prop_loads.gd updates ("Any shared/ edit ships a server redeploy AND a client re-export in the same commit" — docs/gameplay-length-handoff.md:75-80; Phase-8 note "deploy discipline is heaviest here" :199-200; CLAUDE.md Operational).
3. CI (auto on push, .github/workflows/tests.yml): godot-tests job runs ~25 headless suites — stab_* (auth/authority/economy/econ_atomic/sessions/protocol/trust/hop), smoke_p2/p4/p5, test_instancing, test_residents(+chat/party/reports), smoke_prediction, smoke_snapshot_meta, smoke_collision, smoke_prop_loads, smoke_builder_p0-2, hud_layout_test — plus migration-check (clean-Postgres migration replay). CI COVERS: prop/texture loadability, collision math, snapshot meta shape, protocol handshake, instancing. CI DOES NOT COVER: portal round-trips, zone visual theming, mob camp placement/aggro spacing, music, or any rendered output — those are the MANUAL local test in step 1 plus the post-deploy live connect.
4. RELEASE: `deploy/release.sh minor "note"` (deploy/release.sh) — guards main/clean/up-to-date, bumps config/version in project.godot, prepends CHANGELOG, atomic-pushes main+tag (:88-93), CI builds ghcr.io/voullume/legends-mmo:vX.Y.Z, then auto-runs publish_client.sh.
5. CLIENT EXPORT (deploy/publish_client.sh): the NEW CLEAN-IMPORT STEP (:27-37) deletes all GITIGNORED *.import files + .godot/imported and re-imports from scratch before export — this exists because a stale cache after a project.godot bump shipped valid=false imports and props load()ed to null (the v1.1.0 empty-world regression); COMMITTED .import files (ground textures) are preserved. Then exports Linux+Windows (macOS best-effort) → `gh release create/upload` (NOTE :10-11 — gh release publish is blocked under agent auto-mode; the user runs it or grants permission). Retry standalone: `deploy/publish_client.sh vX.Y.Z`.
6. SERVER DEPLOY: `curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash` on the droplet (159.89.132.86). setup.sh pulls the CI-BUILT image (:60-69) — the Godot import ran in CI, NOT on the droplet, so the normal path has no droplet-import OOM exposure. The OOM RISK is the FALLBACK: if the ghcr pull fails, setup.sh builds ON-BOX (:70-74) and the Dockerfile's import layer (Dockerfile:38-42) is keyed on project.godot + models/ — release.sh ALWAYS bumps project.godot, so every fallback build re-runs the full import on the 1 GB droplet (mitigations: swapfile in place per setup.sh:72 + handoff:78, and docker image/builder prune before pull/build :61-66). Mitigation for Phase 8's larger asset set: confirm the CI image built (https://github.com/voullume/legends-mmo/actions) BEFORE running setup.sh so the fallback never triggers.
7. VERIFY LIVE: "verify each deploy via a real client connect, not just a build" (handoff:79) — connect with the freshly exported client, re-walk the new portal chain on live, confirm zone banner/ground/props/mobs render (an un-imported-asset regression shows as an empty world with per-frame errors).
ORDERING RULE: server first, then clients (Protocol.gd:15-16) — though with no protocol bump, old clients keep connecting; they just must not be pointed at the new zones until they update, which the same-commit release makes moot.
