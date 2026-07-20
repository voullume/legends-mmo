# Wildlife Expanse — Zone 2 Build Plan

Owner-approved 2026-07-20 (this doc = the executable spec; one phase ≈ one chat/session).
Research basis: 5-agent read-only sweep of World/Server/GameData/Quests/Supabase + asset audit
(citations inline). Source assets stay in `too_add_models/approved/wildlife_expanse/` (owner
workspace — enter only for the specific staging copies each phase names).

## Owner decisions (locked 2026-07-20)

1. **Zone 2 = the Away Circuit biome** (`away_1/2/3` + `away_boss`), re-themed Wildlife Expanse.
   The recycled Glitchyard roster (tackle_brute / sled_juggernaut / field_medic / drill_sergeant
   rows in `World.MOBS` away zones) is replaced by the wildlife mobs. Zone **ids never change**
   (`away_1` etc. — persistence/portals/quests depend on them); display names/labels re-theme.
2. **Arrowbound Howler REPLACES Rival Coach** as the away_boss phased boss. `rival_down` quest
   matcher retargets to it (per-quest progress carries — boss kill is 0/1). Howler inherits the
   "teaching boss" role: telegraphs stay generous. Rival Coach retires from the spawn table
   (def may remain in GameData initially; remove its `World.MOBS` row).
3. **Entrance**: physical portal at the far end of `glitchyard_5` → `away_1`, gated on
   **`gy5_command` quest completion** (durable in character_quests — **zero migration**). The
   HOME away pad stays as a shortcut and carries the SAME gate, and every deeper away pad keeps
   carrying it (the S1 login-restore rule, World.gd:180-184). The old L8 `away_gate` level check
   is superseded by the quest gate.
4. **Textures: 1024px for all 7** (standard gltf-transform pipeline, boss included).
5. **rallywing_magpie pass-2 APPROVED by owner 2026-07-20** ("the most recent magpie should be
   ready, just needs optimized like the rest") — joins W3. **HOLD remaining**: splinterback_elite
   pass-1 — NOT confirmed final; hold its integration (W4 ships warfrog alone if unresolved).
   Rebound Croaker is permanently excluded (unapproved preview).

## Roster + kits (all existing engine primitives — no new sim code, no new RNG)

| Mob | Tier / zone | Kit (ability types are the AI-proven set, GameData.gd:230) |
|---|---|---|
| netvine_skink | normal, away_1 (L9-10) | Vine Lash (melee basic) + Net Snare (projectile, slow rider) |
| tacklehorn_grazer | normal, away_1/2 (L10-12) | Horn Jab (melee basic) + Tacklehorn Charge (dashAttack + knockback; wall-bait like sled_juggernaut) |
| scrapmask_forager | normal, away_2 (L12-13) | Claw Rake (melee basic; paired claws = ONE damage window) + Scrap Guard (selfbuff DR) |
| rallywing_magpie *(HOLD)* | normal, away_2/3 (L13-15) | Beak Peck (melee basic) + Rally Screech (allybuff dmg to pack; support_tick). Flutter/hop = client accent ONLY — never server movement (verticality gate stays closed) |
| emerald_warfrog | elite, away_2 | Swipe (melee basic) + Ground Slam (meleeAoe + knockback) + Croak Wave (slow hazard zone) |
| splinterback_elite *(HOLD)* | elite, away_3 | Head Slam (melee basic) + Quill Barrage (spread projectile fan) |
| arrowbound_howler | boss, away_boss | Bite (melee basic) + Pounce (dashAttack) + **Signature Howl** ult = summon skink pack (SUMMON_CAP 3; adds give no loot by design) + boss chrome (`plate`/`phases`/`ultWarn` "The Howl", `phased:true`) |

Damage timing: engine-authoritative, never animation-driven — attack clips key off the snapshot
`cds` rising edge, hit off `flash`/dmg events, death off `alive:false` (the shipped
foam_dummy/drill_sergeant pattern, Client.gd:2277-2314, 2454-2461). Manifest impact frames
(bite f23, howl release f55, pounce f31, etc.) are pacing references for cooldown/clip tuning only.

## Architecture facts each phase relies on (verified 2026-07-20)

- A mob = `GameData.CLASSES` def with `mob:true` (schema GameData.gd:225-231; minimal example
  cone_swarmer :232-240; richest head_coach_prime :375-398) + `World.MOBS` rows ({class, level,
  tier, x, y}); Server spawn/scale/AI/loot/XP fully generic (_spawn_world_actors Server.gd:458-478,
  _scale_mob :3651-3668). Tune ONLY via level/tier + per-def hpMult/dmgScale/respawnS — never
  FORMAT_MODS (mobs deliberately have no entries, GameData.gd:596-608).
- Rigged client path precedent: `models/meshy/mobs/rigged/<id>.glb` + merged clip `.res`
  (idle/walk/run/attack/hit/death), RIGGED metadata render_h/foot_y measured via
  `tools/smoke_rigged.gd` (Client.gd:526-580). Wildlife GLBs embed clips → convert with
  `tools/extract_clips.gd`. Multi-attack (howler) = small extension of the ability→clip map
  (_clip_for_ability Client.gd:2242).
- Non-melee basics MUST carry `range` (AI.gd:70-72). Camps > AGGRO_RANGE 320 apart and away from
  pads (chained-pull rule, World.gd:239-241). Mobs never get casted projectiles (Sim.gd:330).
  reflect buffs need reflectMult (GameData.gd:231).
- Respawns: default 6s, phased boss 1800s, per-def respawnS override (Server.gd:3283-3296;
  rival_coach ran 600s — pick howler's in W5 tuning).
- Gates: enforced in `_portal_unlocked` (Server.gd:3430-3444) + login-restore re-validation via
  `World.gate_for_map` (Server.gd:2073-2083). New gate kind "wild_gate" = quest-completion check
  (pattern: secret_key checks quest state, Server.gd:3434-3435; per-quest lookup, NOT the ORDER
  aggregate).
- Quest governance: NEVER append to `Quests.ORDER` (it is the PRIME secret-boss gate,
  Quests.gd:268-271); never gate on AWAY/FINALS order aggregates (:277-286). Away quest matcher
  class updates are safe mid-flight (progress keyed by quest id).
- Shared-engine changes (GameData/World/Quests) ⇒ droplet redeploy + client relaunch. Old clients
  render unknown classIds as warning capsules (graceful, Client.gd:397-401).
- Economy guardrail: tier-2 shop ilvl ~16-18 max — an ilvl-26 epic catalog rivals away quest
  epics and trivializes the IP-800 gates (away epics bonus 88 @ ilvl 20, Quests.gd:205-219).
- Second-hub generalization surface: ~10 `map == World.HOME` RPC guards (shop 2745/2762/2777,
  vendor 2610, salvage 2864, forge 2918/2992, craft 3070, build 1554, key 1018), quest giver
  _at_questgiver 4227-4233, META pads 4788-4797, HOME-singleton pad consts World.gd:101-110.
  Missing ONE guard silently breaks/widens a service — sweep all of them in W7.

## Phases (each: compile-check → headless tests → connect test → adversarial review → release)

- **W1 — asset prep (local only, ships nothing).** Optimize 7 GLBs (gltf-transform resize 1024 +
  simplify, NEVER Draco; splinterback 82.6MB→~4MB expected). Extract clips to `.res`, map
  move→walk/run. Measure render_h/foot_y (smoke_rigged). Output to a repo staging dir
  (`models/meshy/mobs/rigged/`), originals untouched in owner workspace. In-engine playback review
  of all clips (first-pass algorithmic anims — verify before gameplay).
- **W2 — Netvine Skink vertical slice (ships DARK).** GameData def + rigged render wiring + NO
  World.MOBS rows; admin-F1 spawn only. Local + online (two-client) validation per the wildlife
  handoff §7 checklist. This phase resolves clip conversion, ground-fit, quadruped rendering once.
- **W3 — normals roster swap (ships).** Replace away_1-3 minion rows with skink/grazer/forager
  (magpie iff approved by then); update away quest kill-matchers; camp spacing audit; re-theme
  zone display labels (ids frozen); Difficulty-Pass-consistent stat envelopes (mirror
  tackle_brute/sled tier bands).
- **W4 — elites (ships).** warfrog → away_2 elite slot; splinterback → away_3 elite slot iff its
  pass-1 hold is resolved (else warfrog alone, splinterback follows).
- **W5 — boss swap (ships).** Howler replaces rival_coach in away_boss: phased def + chrome +
  Howl summon ult; `rival_down` matcher retarget; respawn choice; boss-scaling verification
  (P7c pool logic); teaching-boss telegraph tuning.
- **W6 — entrance re-plumb (ships).** GY5→away_1 portal + `wild_gate` (gy5_command complete) on
  ALL away-chain pads incl. the HOME shortcut; remove/supersede L8 away_gate; locked-gate SYSTEM
  chat message; login-restore re-validation verified (tampered last_map test).
- **W7 — Base Camp hub (ships; may split a/b).** New safe zone branching off away_3 (World.MAPS
  type:safe + spawn; fixed-point login spawn is free). Tier-2 shop: parameterized `_catalog(ilvl)`
  + per-zone price table + per-zone recv_shop_info (ilvl 16-18, rarities common..epic). Forge:
  same salvage/reforge + new higher-ilvl `GameData.RECIPES` rows; MAX_UPGRADE stays 10 (no
  migration). Quest giver #2: per-map giver table replacing the HOME hardcode; new WILD side
  chain as its own list (append-only governance). 1-2 new RESIDENTS rows homed there (verify
  safe-zone idle behavior — untested). Bounty claims: decide claim-at-either-pad. Sweep ALL HOME
  guards listed above.

## W1 COMPLETE (2026-07-20) — results for W2

Staged (all UNCOMMITTED by design — inert until W2 wires them; reproducible via the tools below):
- `models/meshy/mobs/rigged/<id>.glb` ×7, optimized 171MB→28MB (all textures exactly 1024,
  extensionsUsed none). Simplify only trimmed 2-13% (error-bound dominated) — elites/boss stay
  ~26-29k tris; ACCEPTED (size goal met by textures; silhouettes preserved); revisit only if W2
  profiling objects. Godot-extracted texture PNGs/JPGs beside them are tracked-deps when committed.
- `models/meshy/mobs/rigged/clips/` — **48** wildlife clips (6/6/6 skink/grazer/forager, 7 magpie,
  8 howler, 8 warfrog, 7 splinterback), verified name/length (manifest frames÷30, to 6 decimals)/
  loop flags (LINEAR only idle/walk/run); primary attacks saved AS `attack.res` (bite/swipe/
  head_slam), specials keep full names. move → identical walk.res + run.res. Locomotion net loop
  drift 0.000 on all mobs (warfrog's 0.055 XZ is in-cycle hop-bob). Death/hop displacement =
  intentional visual root, preserved.
- Tools (new): `tools/extract_wildlife_clips.gd`, `tools/smoke_rigged.gd` (recreates the harness
  Client.gd:528 references; validated — reproduces drill_sergeant 1.73 vs known 1.71),
  `tools/wildlife_review_gallery.gd/.tscn`. Review renders: `too_add_models/wildlife_review/`
  (7 clip sheets + lineup_idle.png).
- **RIGGED_MOBS values for W2** (Blender true-scale rigs → mesh-AABB is the truthful measure;
  the bone-extent method only applies to Meshy 0.01-armature exports): netvine_skink 0.927,
  tacklehorn_grazer 1.774, scrapmask_forager 1.116, rallywing_magpie 1.867 (wingtips),
  arrowbound_howler 1.413, emerald_warfrog 1.765, splinterback_elite 1.723 — **foot_y 0.0 for
  all seven**.
- Verification: 3-audit adversarial workflow — contract pass_with_notes, ship-nothing pass (zero
  tracked-file modifications, zero wildlife refs in game code, practice boot clean, suites green),
  visual pass_with_notes.
- **Animation-quality notes for the owner (first-pass algorithmic anims)**: warfrog death nearly
  static (weakest of the set); howler death ends in a crouch, never lies down; splinterback death
  a subtle sag; skink+forager final death frames sink mostly below the floor (reads as a despawn
  dissolve in-game — check live in W2 before judging). Consider pass-3 death anims for
  warfrog/howler before W4/W5 if the owner wants real collapses.

## Open items / holds

- Magpie pass-2 owner review (blocks its W3 inclusion only).
- Splinterback pass-1 confirm-or-redo (blocks its W4 inclusion only).
- W5 detail decisions: howler respawn (600s legacy vs 1800s boss default), retire rival_coach def
  fully or keep dormant.
- W7 detail decisions: bounty claim location, resident personas/lines for the new setting,
  base-camp zone name (display).
- Doc drift to fix opportunistically: CLAUDE.md says 6 AI residents (code has 9, Server.gd:80-92);
  CLAUDE.md still lists Phase 8 as unbuilt.

## Rollback grammar

Every phase is data-additive or row-swap: W3/W4/W5 revert = restore prior World.MOBS rows /
quest matchers (git revert of the shared files + redeploy); W2 dark content is invisible without
spawn rows; W6/W7 revert = remove portal/zone entries (no migrations anywhere in this plan, so no
DB rollback at all).
