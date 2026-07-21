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

## W2 COMPLETE (2026-07-20) — commit `ac66b35`, shipped dark in v1.8.4

- netvine_skink def (GameData), RIGGED_MOBS + ANIM_OVERRIDE (Client), F1 "Spawn Skink" button
  (NetClient). Zero World.MOBS rows — dark. Mob-def golden rebased 26→27 (prior 26 proven
  byte-identical: hash-minus-skink == 578105494). bal_identity signature unchanged vs main
  (sig_w 158545831 / sig_d 343688940) — player sim provably untouched.
- Commit scope: ONLY the skink asset set; the other 6 mobs' W1 staging stays untracked until
  their phases (splinterback pass-1 still on hold; magpie approved 2026-07-20).
- `tools/test_wildlife_skink.gd` (16 checks): abilities cast, Net Snare slow lands, terminal
  death, deterministic replay. Full regression sweep green.
- Live local-server validation: admin F1 spawn in away_1 → aggro → melee dmg landed ("15"
  floaters, HP dip) → killed, credits paid; Lv 3 · MINION target frame + minimap + plates all
  correct; two clients agree on the same skink (snapshot sync); late-join clean; interest
  radius (450) confirmed excluding far mobs; settings.cfg byte-identical after (35a5fdc3).
- Adversarial review (3 lenses + skeptics): 0 blockers; the 1 confirmed minor (F1 button vs
  un-redeployed server silently falls back to tackle_brute) resolved by shipping droplet+client
  together in v1.8.4.
- **W3 notes**: skink orbits/strafes in melee (AI hysteresis) — reads lively, keep; verify
  facing under movement in W3 zone testing (frozen-home skink faced its target correctly; add
  `face` correction only if away-zone locomotion moonwalks). smoke_rigged hardening: print
  mesh min-Y and assert ≈0 for wildlife rigs. h:1.7 chosen for readability (0.927m rig ×1.83)
  — owner eyeball during W3.

## W3 COMPLETE (2026-07-20) — roster swap live

- 11 away_1-3 minion rows → wildlife (positions/levels/tiers preserved; medic joint-pull intact;
  elites/boss untouched for W4/W5). 3 new defs (grazer dashAttack charge, forager dr selfbuff,
  magpie field_medic-shaped allybuff shield). Re-theme: banner "Wildlife Expanse · Overgrown
  Practice Field / Overrun Gauntlet / Reclaimed Stadium", portal labels, gate message, quest +
  bounty flavor (quest matchers are map/tier-keyed — progress carries; W3 added antecedent
  bridges to the elite quests' "Their…" text). rally_cone now DORMANT (def kept, noted).
- Golden rebased 27→30 (W2-27 subset hash-proven == 4135971324). bal_identity unchanged AGAIN.
- Tests: test_wildlife_normals (40 checks — incl. deterministic Rally-Screech-shields-hurt-ally
  scenario; the engine only shields packmates < 85% HP), stab_away 145 (9 pins updated), class
  kits 223, full UI sweep. Hardening: flutter added to RIGGED_ROLES (curated .res now loads);
  smoke_rigged min-Y warning.
- Live smoke: all 4 models rendered in-zone, camps aggro/respawn correctly, residents farm the
  wildlife exactly as the old roster (polite-assist credits flow), banners/labels live.
- Review: 0 blockers; 3 confirmed minors all fixed pre-ship (assets staged, pronoun bridges,
  orphan noted).
- **Owner-eyeball items from W3**: (a) away_1 east camp is now a joint pull of TWO grazers
  (heavier than the old foam/tire pair — deliberate but worth a feel check); (b) the away zones
  still render the rival-clay ground texture under wildlife banners — the terrain/props re-skin
  is NOT yet scheduled: added below as an open item; (c) epic reward items keep rival-era names
  ("Away Captain's Badge", "Rival Playmaker's Glove") — granted copies keep old names forever if
  renamed later; decide at W4/W5.

## W4 COMPLETE (2026-07-20) — warfrog anchor live (splinterback still HELD → W4b)

- emerald_warfrog replaces sled_juggernaut in away_2's east-anchor slot (same position/level/
  tier; field_medic KEPT — the healer lesson is the medic's). Kit: Swipe melee + Ground Slam
  meleeAoe(kb) + Croak Wave pure-slow zone (ladderlock shape; opens pulls from range — the
  drill_sergeant zone precedent). kbImmune, NO frontalDR (controller identity, not a wall).
  Review-driven END 78→86 for raw-pool parity with the old sled.
- Golden 30→31 (subset-proven); bal_identity unchanged (5th ship); stab_away 145; normals test
  46 (warfrog shape checks). Multi-attack clip roles (attack_ground_slam/attack_croak) added to
  RIGGED_ROLES exists-guarded.
- **Owner feel-pass items**: the anchor is deliberately softer front-on than the sled
  (frontalDR gone: ~-58% effective frontal HP, DPS -33%, offset by +11% ms + slow control +
  burst) — away2_medics/d_gauntlet complete faster; confirm the trade feels right. Warfrog
  death anim is the weakest of the set (W1 note) — pass-3 candidate.
- W4b when the splinterback hold lifts: away_3 ball_machine slot; MUST also add
  attack_quill_barrage to RIGGED_ROLES + ANIM_OVERRIDE (same for howler's howl/pounce at W5).

## W4b COMPLETE (2026-07-20) — splinterback live; ALL 6 approved wildlife mobs shipped

- Owner accepted the pass-1 animation set; splinterback_elite replaces ball_machine in away_3
  (ball_machine keeps GY4/GY5). Head Slam melee + Quill Barrage spread (scatter shape, wobble
  rider deliberately dropped — no-control bruiser identity); kbImmune mobile chaser. Golden
  31→32 (chain-proven); identity unchanged (6th ship). Commit `b00510a`, shipped v1.9.2.
- **Owner feel-pass notes (from review)**: away_3 elite TTK +30% but facetank DPS −24% and ALL
  control pressure gone (the turret's wobble/stun riders); the zone loses its dodging-turret-fire
  teaching texture (splinterback is slower than every class — ranged players kill it risk-free);
  a chaser at 1000,720 can now be dragged ~720u east into the drill_sergeant door guard for a
  double-elite pull (the turret never could). All deliberate identity trades — confirm in play.
- Stray-fire note (pre-existing, unchanged exposure): missed quills fly up to ~1720u like the old
  turret's scatter did from the same seat.

## W5 COMPLETE (2026-07-20) — THE ROSTER IS DONE: all 7 wildlife mobs live

- The Arrowbound Howler holds the sideline ("Wildlife Expanse · Howler's Sideline"). BODY parity
  with rival_coach byte-exact (stats/hpMult 0.6/dmgScale 0.6/coreShield 0.40/coreCount 3); the
  KIT is re-seated (hotter P1: Hunting Ground zone + Pounce + Signature Howl skink-summon;
  4 phases PROWL/HUNT/FRENZY/LAST STAND). Teaching subset preserved and pinned (no campreset,
  no respawnS, hazard zone, threshSummon→skinks). RIVAL_PAGES hook retargeted; quest "Fell the
  Howler" (id/matcher/dye untouched); rival_coach def dormant. First RIGGED phased boss — shield
  aura/scoreboard def-keyed and confirmed live via a zero-input --shot capture (SHIELDED cue up).
- Golden 32→33 (chain-proven), identity unchanged (7th consecutive ship), stab 145, normals 55.
- Engine notes recorded: SUMMON_CAP 3 clamps phase-wave(2)+Howl(2) to 3 live adds (anti-snowball
  working as designed); per-phase emissive is procedural-boss-only (rigged boss skips it,
  cosmetic); boss_time stays head_coach-only (deliberate).

## W6 COMPLETE (2026-07-21) — the land connects: zone 2 is entered THROUGH zone 1

- Physical GY5→away_1 portal (SE corner past the Command Tower, geometry review-verified vs
  camps/pads/bounds) + return pad. away_gate (L8) → **wild_gate**: gy5_command completed, OR
  pre-W6 grandfather (WILD_GATE_EPOCH 2026-07-21T06:00Z) **kept at the old L8 floor** (review
  caught the bare-created_at version letting level-1 legacy chars taxi into L9-16 zones).
  All 6 inbound biome pads carry the gate (S1 rule); login-restore re-validation intact, with a
  new quests_unknown blip-guard mirroring gear_unknown (a quest-fetch failure no longer bounces
  legit players home). stab_away 149 (post-epoch quest-passer real-login-path coverage added).
- Deploy-before-epoch ordering satisfied (shipped ~01:00 UTC, epoch 06:00 UTC).
- **Owner notes**: (a) completion requires the HOME turn-in — a player who beats the Tower's
  elites must round-trip home before the far gate opens (message says so; cheap via the Home
  pads) — flag if you'd rather gate on kill-progress; (b) pre-existing, unchanged: gear_unknown
  skips re-validation for ALL gates on an inventory blip — tightening that is a separate,
  owner-approvable hardening.

## W7 COMPLETE (2026-07-21) — THE WORKSTREAM IS DONE: the Base Camp hub is live

- New `basecamp` safe zone (1200×640, turf theme via id-prefix design) off away_3's south edge +
  a wild_gated HOME shortcut (moved off the pad walk-line — review find). World.SERVICE_PADS
  per-map registry replaces the map==HOME guards for shop/forge/questgiver; vendor, build shop,
  master-key craft, camp pad, locker portal stay HOME-only BY DESIGN. Client `_home_pad` is
  registry-driven (locker prompt stays home).
- **Tier-2 shop**: catalog ilvl 17 (clean, IP ~95), T2 prices ~2.2×; rolls carry affixes so the
  T2 gamble is CAPPED at ilvl 13 (IP ~106 — review caught ilvl-17 rolls at IP 127 beating the
  biome's own quest epics). Server prices by the buyer's LIVE map; dual catalog rides the auth
  push; Home tier untouched. Review verdicts: gold does NOT buy past the IP-800 gates
  (rejected finding — quantified), forge_epic2 does not undercut them.
- **WILD_ORDER** 5-quest chain (class-matchers on the wildlife; "kill the support first" magpie
  teaching quest; capstone re-fells the Howler for the wildveil dye — catalog-only, never
  buyable). Quest giver #2 + bounty claims co-located at the camp pad; d_wilds daily (650cr
  after review retune). Wildforge recipes rare2@24/epic2@30 usable at any forge.
- 2 residents (Warden Brook patrols the biome; Naturalist Fen keeps camp). stab_basecamp suite:
  32 checks (T2 buy/roll charged+ilvl-verified through the real paths, guard sweep both
  directions, governance, grandfather resume, in-bounds residents, dye governance).
- Identity unchanged (9th consecutive ship). Zero-input live capture: banner, three service
  pillars, Home pad, minimap — all up.
- **Owner notes**: (a) wild5_alpha + rival_down share the away-boss matcher — one Howler kill
  can complete both capstones (both once-only, distinct dyes; deliberate-ish, flag if you want
  a prereq chain instead); (b) basecamp has NO decor/props yet — pairs with the open rival-clay
  ground re-skin as the art pass.

## PURE-WILDLIFE PASS (2026-07-21, v1.11.1) — owner direction: only imported mobs in zone 2

- The last three legacy elites swapped at their exact positions/tiers (placement tuning deferred
  to the map flesh-out per the owner): tackle_brute → **the Old Bull** (grazer elite, away_1);
  field_medic → **the Elder Rallywing** (magpie elite, away_2 — the shield-camp lesson, support
  first); drill_sergeant → **Warfrog door guard** (away_3). Legacy defs keep GY/finals homes.
- **The rival power cores STAY** around the Howler — boss mechanic (destructible objectives),
  not creatures. If the owner wants them re-skinned to something wild (nests? quill mounds?),
  that's an art-pass item alongside the ground/decor work.
- Feel-pass note: the Elder Rallywing is squishier than the medic it replaced (support-stat
  body × elite scaling) — the lesson reads, the elite dies faster; tune with the map pass.
- Zero def changes → mob golden untouched; identity unchanged (10th consecutive ship).

## PACK-BOSS REDESIGN (2026-07-21, v1.11.2) — owner: no cores; distinct boss-2 mechanics

- The Howler's cores + core-shield REMOVED (they're Boss1's signature; rival_core def dormant).
  The fight's identity is THE PACK: phase waves + Signature Howl (skinks), and from P2 **Pack
  Call** — a rallywing magpie whose Rally Screech shields the alpha and pack (the zone's
  kill-the-support-first lesson at boss stakes; SUMMON_CAP 3 bounds everything) — plus **Blood
  Frenzy** (P2 ms-surge; kite it). hpMult 0.6→0.7 (~40k flat, replacing the DR windows); the
  parity pin re-bounded ≤1.25× the Head Coach pool (no ult keeps it the easier boss).
- **Feel-pass flag (important)**: one live shield-bird heals-by-shield ~4.8k/9s on the boss —
  a solo undergeared player might deadlock in P2 until they learn to kill the bird instantly.
  Intended teeth, but if playtest shows a wall, the fix is a "packbird" variant def with a
  smaller shieldPct (new def = golden move).

## Open items / holds

- ~~Magpie pass-2 owner review~~ — approved 2026-07-20, shipped in W3.
- Splinterback pass-1 confirm-or-redo (blocks its W4 inclusion only).
- **Away-zone terrain/props re-skin** (new, from W3 review): the zones still render rival-clay
  ground + sports props under Wildlife Expanse banners. Needs an owner-directed art/decor pass —
  candidate W3b (client-only ground texture swap is cheap; props are a bigger call).
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
