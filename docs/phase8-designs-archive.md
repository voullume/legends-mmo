# Phase 8 Path Designs — Planning Archive (2026-07-14)

Full design blueprints from the Phase-8 planning workflow (4 miners → 3 designers → 3 skeptic judges;
all scored 8/10, all pricing judged optimistic). **The approved synthesis is
`docs/phase8-away-circuit-plan.md` — read that first.** These are the raw alternatives, kept as the
extension pack (more zones/venues if players want more geography) and for their judge-verified detail.

---

## Design A — "The Away Tour" (theme-first, 8 zones)
**Judge: 8/10 · desert=mostly · pricing=optimistic**

**Judge verdict:** The most repo-honest Phase-8 design one could ask for: essentially every one of its ~60 file:line citations verified, including exact XP math, the head_coach-hardcoded nameplate and leaderboard triggers, the phased→P7c/30-min-respawn automatics, and the real gear-inversion numbers (World.gd:211/219). It respects every constraint — zero new sim mechanics (all mob abilities are proven types), no P7a stat surfaces, zero Meshy credits for the core, correct same-commit deploy discipline — and its slices are genuinely shippable in isolation. It kills the desert 'mostly': 9-16 and 18-28 get directed place-based play, but the 16-18 seam depends on a solo player actually clearing the Head Coach raid, XP overshoot is worse than the claimed 120-140% (required quest kills alone roughly double the 9-16 band, making zone 4-5 skipping likely), and the design's own fold-to-4-zones and 3-larger-zones alternatives read as live possibilities it argues past. Pricing is optimistic rather than dishonest: 11-13 sessions is believable for the data-entry core because the templates really exist as claimed, but the tail (Slice 6 at 1-2 sessions for 8 zones of dressing + full review, 0.5 session for the IP800 simulation, +1 embedded-boss contingency that MAX_LEASH=1600 makes near-certain to trigger) points at 13-16. Steal its Slice 0, its boss primitive-subset escalation, the boss_ready-as-graduation tuning target, and its owner-question discipline even if the final synthesis shrinks the zone count.

**Judge — glossed over:**
- Quest-item item_power trap: _grant_quest_item normalizes legacy-shaped quest items to ilvl 1 → item_power ≈ bonus_amt+1 (~27 for an epic trinket; Server.gd:4290-4300), so the '4 quest epics' contribute almost nothing toward the IP800 gate unless the new quest defs explicitly set ilvl/item_power — the design's stated correction lever ('adjust quest-item counts') doesn't work as written
- XP overshoot understated: mandatory quest kills alone (~54 minions at 135-240 XP + 8 elites at 540-960) plus 8,500 quest XP total roughly 2× the 11,968-XP 9→16 band, not the claimed ~120-140% — zone-skipping of away_4/5 is the likely outcome, and the design's '5 distinct venues' premise depends on it not happening
- Server capacity on the 1GB droplet: init_worlds boots an independent 30Hz sim for EVERY static MAPS key (Server.gd:242-250) — 8 new always-on worlds with ~25 new camps roughly doubles the static sim/mob load, and the design never estimates tick-CPU/RAM headroom despite citing the droplet's OOM fragility for imports
- Embedded-boss leash mechanics: MOB leash is the global MAX_LEASH=1600 (Server.gd:45-46), nearly the full width of away_5 (2000×1100) — an accidentally-aggroed Rival Coach chases a level-15 quester across most of the zone; the design's '>320 from pads/elites' placement grammar addresses aggro, not chase, and the flagged fallback doesn't name this as the specific failure mode
- The ult-warning nameplate is ALSO hardcoded: '⚠ FULL CAMP RESET … BREAK LINE OF SIGHT!' renders for any boss with ultCast>0 (Client.gd:2288-2291) — the Commissioner's 'Final Whistle' would display the wrong ability name; Slice 0 covers the boss name and phase names but not the ult string
- Slice-4 ships champ_2 with a forward pad to a finals_arena that doesn't exist until Slice 5 — _portal_teleport safely no-ops on a missing world (Server.gd:3418-3420) but a visible dead pad ships live for one slice unless the pad itself is deferred
- Approved batch_006 props are 12-18 MB raw each (verified du on too_add_models/approved/founders_commons), not the claimed '6-9 MB' — the Slice-6 optimize pass is bigger than priced
- The 16→18 seam assumes a solo player clears the Head Coach raid on schedule; a player who can't (even with P7c + residents) has directed play dead-ending at two consecutive gates (boss_ready, then champ_ready requiring headcoach_down) — no fallback path is analyzed for the design's own solo-first constraint

**Judge — ideas stolen into the synthesis:**
- Slice 0 as a standalone client-only prerequisite: genericize the boss nameplate (Client.gd:2292-2301 hardcodes '☠ HEAD COACH' + its 4 phase names for ANY tier=='boss') with fallback strings so GY bosses render byte-identically — any multi-boss plan needs this and the design is the only place it's correctly identified
- Boss mechanical differentiation by primitive SUBSET: Rival Coach deliberately omits campreset/cores so it needs no cover-ring and is safe to embed in a leveling zone, and plays differently from the Head Coach the player fights immediately after — escalating primitive stacks (subset → +wallStun/frontalDR → full campreset+coreShield ring) across the three bosses
- Tune the chain's END to the existing boss_ready gate (L16 + IP800, Server.gd:93-94): the new 9-16 chain 'graduates' players into the already-shipped raid, turning today's dead gate into the biome's exit exam — with a Slice-3 headless XP+item_power simulation as the lock-gate before numbers ship
- Correctly NOT submitting new bosses to the boss_time leaderboard — verified the trigger is hardcoded to classId 'head_coach' (Server.gd:3511-3520) and mixing incomparable bosses on one seasonal board is wrong; flag a separate category as an owner call
- Bounty additions as zero-client-re-export content — verified: bounty pools are server consts pushed via HOME snapshot META (Server.gd:4306-4330 comment says exactly this), so away/champ bounty rotation ships server-only
- Free mid-spine synergy: MIDGAME_ORDER's map-agnostic objectives (mid1/2/4/5/7/8 empty-match or tier-elite, Quests.gd:102-158) auto-count kills in the new zones with zero edits; cross-chain prereq rooting CHAMP_ORDER at headcoach_down works because the prereq check is just the session quest dict (Server.gd:4199-4201)
- The theme does structural work: a tour SCHEDULE diegetically justifies the toolkit's only proven topology (linear west→east portal chain), venue-per-sport makes recolored dummies read as venue staff instead of palette swaps, and 'the Championship' names the capstone and its final boss for free
- Slice-2 recolor-readability eyeball checkpoint as the explicit decision gate for the optional Meshy batch — spend credits only after seeing the cheap version fail
- Procedural self-authored ground textures per venue (tools/gen_ground_textures.py pattern — docstring confirms tileable-by-construction, no license/approval) as the zero-cost zone-identity lever
- Visible-but-locked gates with the throttled explainer prompt (NOT in HIDDEN_GATES, Server.gd:95) for champ_ready/finals_ready — known goals, matching the shipped boss_ready UX
- Exact XP-band accounting from the real formula (verified to the int-truncation digit) with min_level accept-gates as the pacing lever rather than starvation

### Claimed cost
11-13 sessions total. Slice 0: 1 · Slice 1: 2 (first template application + decals + full local round-trip discipline) · Slice 2: 2 (3 zones + first new boss + embedded-boss pattern testing) · Slice 3: 1.5 (quest data is cheap; the XP/IP headless validation is the real work) · Slice 4: 1.5 · Slice 5: 2 (full-primitive boss + two gates + quest chain + LOS/core verification) · Slice 6: 1-2 (prop optimize pass + 8 zones of F4 dressing + phase-wide adversarial review). Add +1 contingency if the embedded-boss pattern (away_5/champ_2) misbehaves and needs splitting into separate mini-arenas.

### New assets
- ZERO Meshy credits required for the core design: 4 new tileable ground albedos (asphalt, clay, sand, court) self-generated via tools/gen_ground_textures.py (procedural, no license/approval concern per its docstring); all 9 new mob/boss defs are recolors of existing GLBs (head_coach.glb, boss2.glb, sled_juggernaut.glb, cone.glb, foam_dummy.glb, shooting_dummy.glb — the two boss GLBs have zero recolor variants yet); zone dressing from the ~65 already-integrated/free GLBs.
- No-credit but needs a work session + already owner-approved: integrate too_add_models/approved/ batches 006 (founders_commons: covered_market_stall, plaza_light_column, public_plaza_bench, championship_fountain, vendor_service_kiosk) and 007 (reward_progression: season_reward_vault, championship_reward_chest, loot_drop_capsule, portal_anchor) via the docs/props-textures-handoff.md §A.1 optimize pass (they are raw 6-9 MB).
- OPTIONAL, flagged for owner approval, at most ONE small Meshy batch (4-6 props, decide after the Slice-2 readability checkpoint): rival-team banner/flag stand, away scoreboard, a team bus (dressing for the Away Tour portal pads), one beach/dune landmark for away_4, one finals-wall variant. The design ships complete without it.

### Zone table
| # | Zone id — name | Venue / theme | Mob lvls | Size (w×h) | Camps (class lvl ×count) | Gates / portals | Quest hooks | Visual dressing (existing library) | Structural analog |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `away_1` — **Tailgate Grounds** | Parking-lot fan camp outside the first rival venue; tour hub with the "Road Manager" quest pad in the safe west band | 9-10 | 1500×850 | 4 minion camps: rowdy_fan 9 ×2, tire_dummy 9, rowdy_fan+tire mix 10; elite **tackle_brute 10** "Lot Marshal" far east | HOME north pad "▶ Away Tour" (x≈300,y=200, ungated) ↔ back pad west; forward pad east → away_2 | away1_opener (kill 8), away1_marshal (elite) | NEW asphalt ground tex (procedural); Kenney city buildings backdrop, detail-tank (grills), fence_simple, equipment_transport_crate, cable_spool_cart; batch_006 covered_market_stall + public_plaza_bench (needs optimize pass) | GY2 (first-elite zone) + hub pad |
| 2 | `away_2` — **Rival Ballpark** | Baseball: outfield wall, pitching machines, umpires | 11-12 | 1650×900 | 4 camps: pitching_rig 11 ×2, whistle_cone 11 "Umpire", pitching_rig+whistle 12; elite **gatling_machine 12** "Batting Cannon" east | back ↔ away_1; forward east → away_3 | away2_roadgame (kill 10), away2_cannon (elite) | NEW clay ground tex; fence_planks outfield wall, stadium, sideline_stand, boundary_pylon, bag (bases) | GY2 |
| 3 | `away_3` — **Gridiron Fortress** | Football: walled practice fortress, sleds and liners | 12-13 | 1800×980 | 4 camps: scout_dummy 12 ×2, pop_dummy 12, chalk_liner 13; elites **iron_sled 13** mid + **sled_juggernaut 13** east | back ↔ away_2; forward east → away_4 | away3_fortress (kill 12), away3_sleds (2 elites) | Turf albedo re-tinted dark (albedo_color, zero assets); glitchyard_wall + championship_arena_wall enclosures, player_tunnel_gate, rack cover, spectator_safety_rail | GY3/GY4 (two-elite density bump) |
| 4 | `away_4` — **Cove Court** | Beach volleyball: sand, palms, serve cannons, a healer camp | 14-15 | 1900×1040 | 4 camps: spring_cone 14, beach_server 14 ×2, mascot_runner 15; elites **field_medic 14** mid (focus-fire lesson) + **ball_machine 15** "Serve Cannon" east | back ↔ away_3; forward east → away_5 | away4_cove (kill 12), away4_trainer (2 elites) | NEW sand ground tex; Kenney palmDetailedTall/palm, rocks, plant_bush; boundary_pylon net posts, sideline_stand | GY4 |
| 5 | `away_5` — **The Grand Pitch** | Soccer cathedral: floodlights, referees, the Rival Coach's pitch | 15-16 (+boss 16) | 2000×1100 | 3 camps: net_keeper 15, whistle_cone 15 "Referee", chalk_liner 16; elite **blitz_captain 16** mid; **BOSS rival_coach 16** in an east barrier pocket (no cores — safe to embed) | back ↔ away_4; NO forward chain pad; "▶ Team Bus — Home" QoL pad NE (>320 from boss) → HOME | away5_pitch (kill 12), away5_rival (boss) → completion text points at the existing boss_ready Head Coach gate (L16+IP800) | Turf default, brighter tint; stadium, championship_arena_wall, plaza_light_column floodlights (batch_006), player_tunnel_gate, spectator_safety_rail | GY5 + embedded world boss (NEW pattern — test leash/reset; fallback = split a mini-arena) |
| 6 | `champ_1` — **Championship Row** | Rival-city stadium district streets, all-star squads | 18-21 | 2000×1100 | 5 camps (highest density): rowdy_fan 18, pitching_rig 19, spring_cone 19, pop_dummy 20, mixed 21; elites **tackle_captain 20** + **gatling_machine 21** | HOME north pad "▶ Championship Row" gated **champ_ready** (headcoach_down + L18, visible-but-locked + explainer); back → HOME; forward east → champ_2 | champ1_arrival (kill 15), champ1_allstars (2 elites) | Asphalt/concrete ground tex (shared w/ away_1); dense Kenney buildings + chimneys, plaza_light_column, leaderboard_kiosk, zone_terminal, banners (optional Meshy) | GY5 density, city-dressed |
| 7 | `champ_2` — **Trophy Concourse** | Rival HQ concourse: vaults, trophies, the parade sled | 22-25 (+boss 24) | 2100×1150 | 4 camps: mascot_runner 22, net_keeper 23, mixed 23-24 ×2; elites **field_medic 23** + **iron_sled 24**; **BOSS playoff_juggernaut 24** east pocket | back ↔ champ_1; forward east → finals_arena gated **finals_ready** (champ2_juggernaut done + L26, visible-but-locked) | champ2_concourse (kill 15), champ2_trainers (2 elites), champ2_juggernaut (boss) | NEW court/hardwood ground tex; championship_arena_wall, gear_forge, equipment_shelf, batch_007 season_reward_vault + championship_reward_chest + loot_drop_capsule (needs optimize pass) | GY5 + embedded boss |
| 8 | `finals_arena` — **The Finals Arena** | The championship game: boss room | boss 28, cores 24 | 1300×860 | **BOSS the_commissioner 28** central + power_core 24 ×4 ring; no other camps; spawn far west | back → champ_2 only | finals_contender (20 elites anywhere, min 26) then finals_title (kill the boss) | Court ground tex; full GY_BOSS cover-ring (W/E barriers + N/S racks, World.gd:381-395 pattern), championship_trophy, championship_fountain (batch_006), stadium walls | GY_BOSS (small room + cores + cover ring + 30-min respawn) |

Placement grammar throughout (per the shipped template): camps >320 apart (AGGRO_RANGE, Server.gd:43), west→east level gradient, elite(s) anchoring the east, two lane y-values with barrier/rack/bag cover panels, portal drops >42 from reverse pads and >320 from elites (World.gd:117-135 comments); every zone: type combat, regen 0.012/6.0, aggro true, pvp false (MAPS shape World.gd:56-74).

### Slice plan
# Build order — 7 slices, each independently shippable (compile check → headless boot → local portal round-trip via ./play.sh server + online → adversarial review → deploy → live client verify)

**Slice 0 (S) — Client groundwork.** Genericize the boss nameplate (Client.gd:2294-2301) to read def name + optional per-def phase names (GY bosses byte-identical via fallback); generate 4 procedural ground textures (tools/gen_ground_textures.py — asphalt/clay/sand/court) + extend `_make_field_material` mapping (inert until zones exist); add textures to tools/smoke_prop_loads.gd. **Deploy: client re-export only** (no shared/, no droplet redeploy needed). Verify: GY boss plates unchanged, textures load.

**Slice 1 (M) — Chain part 1: away_1 + away_2.** 🔴 shared/+client SAME COMMIT: World.gd MAPS/SPAWN/PORTALS (incl. HOME "▶ Away Tour" pad)/MOBS/OBSTACLES for 2 zones; GameData defs rowdy_fan + pitching_rig (+ mascot_runner); `_zone_name` + F1 goto entries; starter F4 decals. Verify: HOME↔away_1↔away_2 round-trips both directions, camp spacing/aggro, L9-12 con-band XP spot check. Deploy: confirm CI image built BEFORE droplet setup.sh (OOM-fallback avoidance), then live connect + re-walk.

**Slice 2 (M) — Chain part 2: away_3/4/5 + RIVAL COACH.** 🔴 shared/+client: 3 zones + scout_dummy/beach_server/net_keeper + the rival_coach boss def (phased/threshSummon/wallStun/pull/hazard, no cores) + east barrier pocket + Team Bus pad. Verify: full 5-zone walk, boss pull/leash/phase-reset (leashed phased boss re-arms, Server.gd:3254-3262), P7c solo scaling observed, nameplate reads "RIVAL COACH". **Checkpoint: eyeball recolor readability — if venues don't read distinct, trigger the optional Meshy batch decision now.**

**Slice 3 (M) — Directed play: AWAY_ORDER + bounties + tuning.** 🔴 shared (Quests.gd new list + display_order concat; road_crimson dye) + server (Road Manager giver pad in `_at_questgiver`; away bounty pool entries — those alone need zero re-export; Rival Coach 30-Pages hook). Headless math validation: chain quest+kill XP vs the 11,968-XP 9→16 band AND simulated item_power at chain end vs BOSS_GATE_IP 800; adjust quest numbers/items. Verify: accept→progress→turn-in loop at both givers, bounty rotation shows away entries.

**Slice 4 (M) — Capstone part 1: champ_1 + champ_2 + PLAYOFF JUGGERNAUT + champ_ready.** 🔴 shared/+client: 2 zones, boss def, new `champ_ready` gate arm in `_portal_unlocked` (visible-but-locked + throttled explainer; NOT in HIDDEN_GATES) + HOME "▶ Championship Row" pad; away-band residents (server-only, rides along). Verify: gate locked for a fresh char / open for a headcoach_down char, login gate re-validation (relog inside champ_1 under-level → relocated HOME), round-trips, boss pocket.

**Slice 5 (M/L) — Finals: finals_arena + THE COMMISSIONER + CHAMP_ORDER.** 🔴 shared/+client: boss room + cover ring + cores; full-primitive boss def (campreset/coreShield 0.45/coreCount 4/hpMult 3.5); `finals_ready` gate arm; CHAMP_ORDER quests + championship_gold dye; capstone bounties + Pages consts; capstone residents. Verify (heaviest): core-shield DR on/off with cores alive/dead, campreset LOS-spare behind each cover panel, no passively-safe spot, threshSummon per phase, quest finale grants exactly-once.

**Slice 6 (S/M) — Dressing + polish + phase review.** Optimize+integrate approved batch_006/007 props (docs/props-textures-handoff.md §A.1 pass — no Meshy spend), F4 decal passes on all 8 zones (data/decals/*.json), PROP_FOOTPRINT rows for solid décor (🔴 shared portion), DECO_PROPS + smoke_prop_loads updates, optional audio/music/<zone>.ogg drops. Full-phase adversarial review + live end-to-end: L9 quester run-through and L18+ capstone run-through on the live server.

Rules applied throughout: every shared/ slice = server redeploy + client re-export in the same commit (CLAUDE.md); never test with --practice (map-authoring-guide §5); new mutating RPCs — none are added (quest/bounty/portal paths are existing rate-limited surfaces).

### Designer's risks
- Gear inversion vs shipped endgame: drop ilvl = mobLevel(+5/+12) means away/capstone content yields ilvl 28-40 while Head Coach/PRIME (mob lvl 8/10) drop ilvl 20/22 — Phase 8 obsoletes the shipped raid loot and undercuts low-Intensity Circuit drops. Needs explicit owner acceptance (boss hooks shift to Pages/uniques/unlocks) or a decision to raise GY boss levels (World.gd data, harness-inert but touches shipped content).
- Sequencing vs the handoff's own rule (gameplay-length-handoff.md:201-202): Phase 8 is designed to land AFTER the vertical systems so 9-28 leveling is meaningful; if level-gated kits/talents are not final when the tuning slice locks quest XP / mob-band numbers, the band retunes later — schedule the Slice-3 validation only once player-power per level is stable.
- IP800 delivery: the chain must hand a solo quester item_power >= 800 by L16 or the directed run dead-ends at a visible-but-locked gate (worse UX than today's undirected grind); the item_power formula (primary+affixes+ilvl per slot) makes this estimate-only until the Slice-3 headless simulation — treat quest-item grants as the correction lever.
- Embedded world bosses (rival_coach in away_5, playoff_juggernaut in champ_2) have no shipped precedent — GY bosses live in dedicated rooms; leash-reset, 30-min respawn timing next to respawning quest camps, and aggro adjacency need local testing; fallback (+1 session) is splitting each into a GY_BOSS-style mini-arena, growing the zone count to 9-10.
- XP pacing overshoot: the GY precedent (quest XP alone exceeds its band) suggests quest+directed-kill XP will exceed the 11,968-XP 9-16 band, so players may outlevel zones 4-5 and skip them; min_level accept-gates and symmetric con-fade mitigate, but if playtests show skipped zones the design's '5 distinct venues' premise weakens — consider folding to 4 chain zones.
- Recolor readability: the dye overlay is one flat 0.45-alpha wash (no per-part color, no emissive) — if venue mobs read as 'same dummy, different tint', the theme fails to justify 8 zones; the Slice-2 eyeball checkpoint is the kill-gate, with the optional Meshy prop batch and per-venue ground textures as the recovery levers.
- Population thinning: 8 more always-on static worlds on a low-population server spreads the few concurrent players thinner; residents + solo-first tuning mitigate, but if the owner values incidental player encounters over venue variety, 3 larger zones would be the better shape (a legitimate kill-reason for this 8-zone layout).
- Deploy surface: this is the largest shared/-heavy content drop since Glitchyard — every slice is a same-commit server+client release, and the droplet's OOM exposure exists on the ghcr-pull-failure fallback path (on-box import rebuild, 1 GB RAM); mitigations are slice-sized releases and confirming the CI image exists before running setup.sh, but a mid-phase botched release leaves live clients rendering new mobs as gray capsules.
- Owner-question boundary: the jump/verticality named-moment test (docs/jump-verticality-phase1-decision.md §4) is explicitly an owner sign-off item — this design adds no z-axis anything, but the capstone's 'stadium' theming may invite that conversation; do not let it leak into implementation.

### Full design doc

# Phase 8 — "The Away Tour" (second biome + capstone) — THEME-FIRST design

## 1. Theme: the away season, and why it beats alternatives
The biome is a **road trip through rival teams' home venues** — the away half of a sports season. Five tour stops (one per sport identity + a tailgate opener), then a Championship capstone region. The theme is doing real work, not decoration:
- **It reuses the game's 4-sport class fantasy** (CLAUDE.md: Baseball/Football/Volleyball/Soccer): each venue zone themes its mobs/props around one sport, so the 6 new recolor minions + reused P3/P3b roster (GameData.gd:277-381) read as *venue staff/equipment*, not palette swaps in a vacuum.
- **It makes the toolkit's only topology diegetic**: the code-as-maps toolkit ships exactly one proven chain shape — linear west→east zones linked by portal pads (World.gd:94-144). A tour *schedule* IS a linear chain; the theme explains the structure instead of fighting it.
- **It motivates the Home-hub branch** (required by the handoff, docs/gameplay-length-handoff.md:195): the new HOME north-row pad is the **Team Bus** — you board at home, the tour brings you back. HOME's north gate row has open slots (existing pads at x=600/900/1180, y=200; World.gd:98-102).
- **The capstone names itself**: an away season ends at **the Championship** — a rival-city stadium district (champ_1/champ_2) and the Finals Arena, whose gatekeeper boss "The Commissioner" is the natural final authority figure after Head Coach/Head Coach PRIME.
- **Rivalry = directed play**: every quest beat is "win the road game at venue X," which is exactly a kill-by-map objective — the ONLY objective type quests support (Quests.gd:10-12, 190-203). The theme needs zero new quest machinery.

## 2. Progression architecture (the numbers the design must hit)
XP curve (recomputed from `_xp_to_next(L)=int(50L+7.5L²)`, server/Server.gd:204-207): reach L9 = 3,328 cum; reach L16 = 15,296 (band 9→16 = **11,968 XP**); reach L18 = 21,033; band 18→28 = **49,835**; to cap 30 = 85,905.
- **Chain band 9-16, mob levels 9→16 in ~1-2-level steps per zone** (9-10 / 11-12 / 12-13 / 14-15 / 15-16), mirroring GY's gradient — the ±4 con-grace / 12-span / 40%-floor scaling (Server.gd:68-70, 3674-3683) then routes players automatically; the :70 comment explicitly reserves this fix for Phase 8. Mob XP = 15 × level × tier{1/4/6} (Server.gd:48,51,64) → away minions pay 135-240 XP, elites 540-960.
- **The chain's exit = the existing `boss_ready` gate** (level ≥ 16 AND item_power ≥ 800, Server.gd:93-94, 3401-3403). Today NOTHING delivers a player to that gate between the ~L10 quest-chain end and L16 — the away chain is tuned to end at L16-17 with elite/quest gear reaching IP ≥ 800 (elite drops ilvl 16-21 via ilvl = mobLevel+5, Server.gd:3869-3870; plus 4 quest epics). **Validated in the tuning slice with a headless math pass** — if the IP curve misses 800, adjust quest-item counts, not the gate.
- **Capstone band 18-28 sits after `headcoach_down`** (the ORDER quest for beating Boss1, Quests.gd:88-95), feeding L30 + paragon Overtime overflow automatically (Server.gd:3559-3563).
- Pacing lever = quest `min_level` accept-gates (Server.gd:4187-4201 pattern), not starvation: like the GY precedent (6,860 quest XP vs 4,385-to-finish-L10 band), quest+directed-kill XP may overshoot ~120-140% — that's *smooth directed play*, and symmetric con-fade self-corrects over-leveling.

## 3. Zones — shared static, not instanced
All 8 new maps are **shared static zones exactly like GY1-5/GY_BOSS** (booted per MAPS key by `init_worlds`, Server.gd:242-250): they need respawning camps (con-band farm), last_map resume, quest map-matches, 30-min world-event bosses (BOSS_RESPAWN_DELAY, Server.gd:36), and on a low-pop server the leveling world should be where players/residents are visible. Instancing stays what it is — the Circuit keeps its con-exemption premium-farm role (Server.gd:3668-3671); no new templates. Full per-zone spec in the zone table.

Zone-id families **`away_*`** and **`champ_*`/`finals_arena`** are chosen so client prefix-branches stay one-liners (`_make_field_material` branches on `begins_with`, Client.gd:573-581).

## 4. New mob defs — 9 GameData dicts, all recolors, all proven ability types
Six new minions (recolor:true on existing GLBs, per the shipped P3 pattern GameData.gd:277-325; mob-proven types only — melee/dashAttack/meleeAoe/projectile/zone/selfbuff/summon/spread/campreset/allyheal-buff):
1. **rowdy_fan** — cone.glb, #E06A2E; melee + dashAttack (tailgate crowd). away_1, champ_1.
2. **pitching_rig** — shooting_dummy.glb, #3E6FA8, stationary turret; projectile + slow shot. away_2, champ_1.
3. **scout_dummy** — foam_dummy.glb (rigged), #2F4A6E; melee + selfbuff brace. away_3.
4. **beach_server** — shooting_dummy.glb, #F2D091; projectile + hazard zone. away_4.
5. **mascot_runner** — cone.glb, #4AC8FF; fast melee + dashAttack-slow. away_4, champ_2.
6. **net_keeper** — foam_dummy.glb, #1FA05A; melee + selfbuff DR + knockback shove. away_5, champ_2.
Everything else is **reuse** of the lightly-used shipped roster (mined bestiary): tire_dummy, whistle_cone ("umpire"/"referee"), spring_cone, pop_dummy, chalk_liner, tackle_brute, sled_juggernaut, ball_machine, iron_sled, gatling_machine, field_medic, blitz_captain, tackle_captain — the capstone's fiction ("all-star squads from every venue") justifies the full mixed roster at levels 18-25 with zero new defs.

## 5. Three NEW bosses — primitive combos only (menu = mined §(b); fields verified GameData.gd:220-270)
**Boss A — RIVAL COACH** (`rival_coach`, lvl 16, tier boss, embedded east pocket of away_5):
- GLB: **head_coach.glb recolored** rival-blue #2E86D0, h 4.8, anim "boss" (head_coach.glb has zero recolor variants yet — the biggest untapped asset).
- Primitives: #1 phased + #2 threshSummon{whistle_cone×2} + #8 wallStun dash bait ("Counter Press", wallStun 1.4) + #9 pull 200 ("Offside Trap") + #10 hazard zone ("Set-Piece Drill") + #12 kbImmune + #13 P7c party scaling (automatic for phased, Server.gd:3624-3658). **Deliberately NO campreset/cores** → no cover-ring dependency, safe to embed in a leveling zone, and mechanically distinct from Head Coach (which the player fights NEXT).
- Gate: none (end-of-chain placement is the gate). Reward hook: 30 Pages on kill (new const mirroring BOSS_PAGES, Server.gd:3511-3512), boss drops ilvl 28, existing 15% unique roll, AWAY chain finale quest target; 30-min world event.

**Boss B — PLAYOFF JUGGERNAUT** (`playoff_juggernaut`, lvl 24, tier boss, east pocket of champ_2):
- GLB: **sled_juggernaut.glb recolored** championship-gold #D9A21A, rescaled h 5.2, anim "brute", face 90 — the siege-engine identity is built into the base kit.
- Primitives: #1 phased + #2 threshSummon{spring_cone×3} + #8 wallStun charge 1.5 ("Championship Drive") + frontalDR 0.5 + kbImmune (#12) + meleeAoe slam + #10 hazard ("Torn Turf") + #13 P7c. No campreset.
- Gate: reached inside champ_2 (which is behind `champ_ready`). Reward hook: 40 Pages, ilvl 36 boss drops, unique roll, CHAMP quest target.

**Boss C — THE COMMISSIONER** (`the_commissioner`, lvl 28, tier boss, Finals Arena center):
- GLB: **boss2.glb recolored** #F2C14E, h 6.4, anim "boss" (phase-reactive animator is generic, Client.gd:2237-2248).
- Primitives: the full stack — #1 phased + #2 threshSummon{pop_dummy×2} + #4 campreset ult "Final Whistle" (dmg 140, cd 13, cast 3.0, phase 2) + #5 coreCount 4 (power_core lvl 24 ring — power_core is fully reusable, GameData.gd:382-387) + #6 coreShield 0.45 (client shield-aura + "DESTROY THE CORES" plate are automatic, Client.gd:1392-1411, 2292-2296) + #7 hpMult 3.5 / dmgScale 0.8 + #8 wallStun dash + #9 pull 240 + #12 kbImmune + #13 P7c + the GY_BOSS cover-ring OBSTACLES pattern (World.gd:381-395).
- Gate: `finals_ready` (below). Reward hook: 60 Pages, ilvl 40 boss drops, unique roll, "championship_gold" dye finale, feeds paragon. **boss_time board: NOT submitted in v1** — the trigger is hardcoded to classId "head_coach" (Server.gd:3511-3520) and mixing incomparable bosses on one seasonal board is wrong; a separate "finals_time" category is a flagged optional follow-up (owner call).

**Required client prerequisite (Slice 0):** the boss nameplate hardcodes "☠ HEAD COACH" + its 4 phase names for ANY tier=="boss" (Client.gd:2294-2301) — genericize to read the def's `name` (+ optional per-def phase-name array, defaulting to the shipped strings so GY bosses render byte-identically).

## 6. Gates — three arms, all shipped precedents (Server.gd:3395-3404)
- **HOME → away_1**: ungated pad "▶ Away Tour" (chain difficulty + quest min_levels pace it, like GY1-5).
- **HOME → champ_1**: new gate id **`champ_ready`** = completed `headcoach_down` (session quests dict check, same shape as `_all_quests_done`, Server.gd:3386-3393) AND level ≥ 18. **Visible-but-locked** with the throttled explainer prompt (NOT added to HIDDEN_GATES, Server.gd:95) — a known goal, per the boss_ready UX.
- **champ_2 → finals_arena**: new gate id **`finals_ready`** = completed `champ2_juggernaut` AND level ≥ 26. Visible-but-locked. (An IP component is deliberately omitted until live telemetry exists at that band; the const stays tunable.) Gate re-validation on login is automatic via `gate_for_map` (World.gd:413-418; Server.gd:2061-2069).
- Optional, NOT v1: a Pages-forged "Championship Ticket" second key (progression_craft_key pattern) — extra Pages sink but needs a client forge-UI addition; owner call.

## 7. Quest + bounty spine (kill-only — zero new objective machinery)
Two NEW separate order lists (the MIDGAME_ORDER precedent; NEVER touch ORDER — it is the secret-boss gate, Quests.gd:18-21, 169-176), concatenated into `display_order()` (Quests.gd:183-184).

**AWAY_ORDER** (10 quests, min_level 9→16, ~8,500-10,000 XP total, per-number tunable at the tuning slice):
1. `away1_opener` "The Season Opener" (min 9, prereq ""): kill 8 {map:away_1} — the HOME giver points at the new Team Bus pad. XP 250, cr 400, tokens 20.
2. `away1_marshal` (min 9): 1 elite {map:away_1, tier:elite}. XP 400 + rare trinket.
3. `away2_roadgame` (min 10): kill 10 {map:away_2}. XP 500.
4. `away2_cannon` (min 11): 1 elite {map:away_2}. XP 650 + epic trinket.
5. `away3_fortress` (min 12): kill 12 {map:away_3}. XP 750, pages 15.
6. `away3_sleds` (min 13): 2 elites {map:away_3}. XP 900 + epic main_hand.
7. `away4_cove` (min 14): kill 12 {map:away_4}. XP 1,000.
8. `away4_trainer` (min 15): 2 elites {map:away_4} (the field_medic healer camp teaches focus-fire). XP 1,150 + epic chest.
9. `away5_pitch` (min 15): kill 12 {map:away_5}. XP 1,300, pages 20.
10. `away5_rival` (min 16): kill 1 {map:away_5, tier:boss} = Rival Coach. XP 1,600, cr 1,500, pages 40, **dye "road_crimson"**, epic trinket. Completion text explicitly directs to the Head Coach Arena gate ("You're ready for the qualifier").
Mob min_level match filters become usable above 8 for the first time (the standing Quests.gd:97-99 ceiling comment) but aren't needed — map matches suffice.

**CHAMP_ORDER** (7 quests, min_level 18→27, prereq chain rooted at `headcoach_down` — prereq is any completed qid, cross-chain works): `champ1_arrival` (kill 15 champ_1) → `champ1_allstars` (2 elites) → `champ2_concourse` (kill 15 champ_2) → `champ2_trainers` (2 elites) → `champ2_juggernaut` (kill Playoff Juggernaut; unlocks finals_ready) → `finals_contender` (min 26, 20 elites anywhere — deliberately Circuit-synergistic) → `finals_title` (min 27, kill 1 {map:finals_arena, tier:boss}; XP 7,000, cr 6,000, pages 60, **dye "championship_gold"**). Total ≈ 24-27k XP ≈ 50% of the 18→28 band; kills/Circuit/bounties/rested fill the rest.

**Giver:** extend `_at_questgiver` to accept proximity to EITHER the HOME pad (World.gd:83-84) OR a new **"Road Manager"** pad in away_1's safe west entry band — all quests accept/turn in at both (no per-quest giver mapping; smallest possible change). The Team Bus return pad in away_5 keeps turn-in travel short.

**Bounties** (server-only consts, ZERO client re-export, Server.gd:4306-4330): append to BOUNTY_DAILY — "Road Win" (15 kills in a specific away zone, rotating entries per zone), "Away Elites" (3 elites in away_*, per-zone entries since map match is exact), "Championship Sweep" (12 kills champ_1/champ_2); to BOUNTY_WEEKLY — "Upset the Rival" (kill rival_coach), "Playoff Run" (kill playoff_juggernaut). Rewards stay currencies-only per the shipped rule.

**Mid-spine synergy, free:** MIDGAME_ORDER's map-agnostic objectives (mid1/2/4/5/7/8 — "anywhere"/tier-elite matches, Quests.gd:102-158) auto-count away/champ kills; mid3/mid6 still point home to GY5 as return-visit beats. No edits.

## 8. Rewards — nothing new, everything scaling (P7a veto respected)
- **Gear**: drop ilvl = mobLevel(+5 elite/+12 boss) (Server.gd:3869-3870) → the biome organically spans ilvl 9→40, finally out-ranging SHOP_ILVL 8 and the craft bands (12/18/26/30, GameData.gd:563-568) with zero new item mechanics. Boss tables inherit the existing 15% unique roll.
- **Pages**: boss chunks 30/40/60 (BOSS_PAGES precedent) + quest/bounty grants; sinks unchanged (Master Key, Audibles).
- **Credits**: kill formula scales with level automatically (8+5×lvl, Server.gd:2428-2435).
- **Dyes**: 2 new quest-exclusive dyes (road_crimson, championship_gold) — pure data, the azure/gold/obsidian precedent (Quests.gd:129,157,165).
- **Practice Tokens**: recommendation — keep the kill-drop flag Glitchyard-only (the `begins_with("glitchyard")` check, Server.gd:~3495-3504); the rookie_camp vendor set is obsolete by L16 anyway. Away quests grant small explicit token amounts. (One-line server change if the owner disagrees — flagged.)
- **Titles**: do not exist in the codebase — not used.
- **Residents**: 4-5 new roster entries (server-only, Server.gd:80-87 + routes) so solo players can recruit level-appropriate companions: e.g. Scout (away_2, L12), Duke (route away_1→3, L11), Coral (support, away_4, L15), Ace (champ_1, L20 high), Champ (route champ_1↔2, L23). P7c makes solo+1-2 bots the tuned norm for all three phased bosses (bots ×0.5 force, Server.gd:60-63).

## 9. Wiring checklist (from the mined lane reports; per-zone)
shared/: MAPS+SPAWN+PORTALS+MOBS+OBSTACLES entries; Quests.gd lists; GameData 9 defs + 2 dyes; PROP_FOOTPRINT rows for solid décor. server/: 2 gate arms; giver pad check; Pages consts; bounty entries; residents. client/: `_zone_name` ×8 (NetClient.gd:6411-6424); `_make_field_material` branches (Client.gd:573-581); F1 goto buttons (NetClient.gd:4834); boss nameplate fix; DECO_PROPS + tools/smoke_prop_loads.gd additions; data/decals/<zone>.json via F4. Minimap, leash/aggro, persistence, gate re-validation, admin goto server-side, P7c: all automatic.

## 10. Owner sign-off questions (not decided here)
1. Gear-inversion acceptance: lvl-16-28 bosses drop ilvl 28-40, obsoleting Head Coach (ilvl 20) / PRIME (ilvl 22) gear — their hooks become Pages/uniques/secret-unlock/boss_time. Optionally raise PRIME's World.gd level (world data, harness-inert) — owner call.
2. The jump/verticality §4 named-moment test (docs/jump-verticality-phase1-decision.md) — owner question at sign-off, per the constraint.
3. Optional Meshy batch (see new_assets_needed) and the optional "finals_time" leaderboard category.
4. Sequencing: handoff:201-202 wants Phase 8 *after* the vertical systems so leveling is "meaningful, not speed-run on a finished build" — confirm the vertical stack is final before the tuning slice locks numbers.

---

## Design B — "Systems-first" (band engineering, 9 zones)
**Judge: 8/10 · desert=mostly · pricing=optimistic**

**Judge verdict:** This is an unusually honest, deeply repo-grounded design — of ~40 load-bearing file:line claims I verified, essentially all are accurate, including the crucial thesis fact (the MIDGAME spine is prereq-locked behind headcoach_down at Quests.gd:105, so 9-16 truly has zero quests today) and every claimed primitive, prop, texture tool, and approved batch. All four hard constraints are respected: bosses are pure recombinations of shipped def flags (verified player-inert in Sim.gd:233-245), rewards stay on existing surfaces (dyes/Pages/tokens/ilvl — no P7a), zero required Meshy spend (every named asset exists on disk), and deploy discipline is baked into each slice with the OOM guard named. Slice safety is the design's strongest property: additive dict rows + auto-booting MAPS keys + generic gate re-validation make every prefix a coherent live game. It loses points for: (a) optimistic pricing — 9 dressed zones + 3 bosses + 16 quests + 5 full deploy/QA loops in ~9 sessions assumes the F4 decal-dressing and recolor-eyeball loops go right first try, when the existing 9 zones took multiple polish passes; (b) two 'free' claims that aren't (gate explainer is hardcoded to boss_ready at Server.gd:3371-3374; the ult warning label hardcodes 'FULL CAMP RESET' at Client.gd:2344-2347); (c) a sharper-than-admitted silhouette problem — the Commissioner is a recolor of the secret raid boss's exact body (boss2 = PRIME, GameData.gd:248) and Rival Coach is the 4th def on the drill_sergeant rig, so BOTH marquee new bosses collide with the game's most memorable existing enemies; and (d) 'kills the desert' hinges on two self-admitted unverified numbers (IP800/IP1400 feasibility, Circuit XP/hour dominance) plus 16 kill-only quests that risk reading as directed grind. The designer's own risk list is the best part — it names every real failure mode including the ones that would invalidate the design. Synthesize from this as the structural backbone; budget 11-12 sessions, pre-commit to the two client display generalizations as slice-B scope, and force a silhouette answer (scale/prop/aura deltas or the flagged Meshy batch) for the two body-collision bosses before slice C.

**Judge — glossed over:**
- The 'visible-but-locked + throttled explainer' UX is NOT free for new gates: the sealed-pad chat prompt is hardcoded to gate=="boss_ready" (Server.gd:3371-3374) — away_ready/champ_ready/final_ready pads would be silently inert until that branch is generalized (small, but claimed as shipped UX)
- The 'generic LOS-warning UI is free (Client.gd:2289-2291)' claim is wrong in detail: the ult-cast label hardcodes '⚠ FULL CAMP RESET ⚠' for ANY boss with ultCast (Client.gd:2344-2347), so the Commissioner's 'Final Whistle' would announce the Head Coach's ult by name — needs the same per-def treatment as the nameplate fix
- 'boss2 has ZERO variants' obscures that boss2 IS Head Coach PRIME's model (GameData.gd:248): the championship capstone boss is a blue recolor of the secret raid boss's exact silhouette, and Rival Coach is the FOURTH def on the drill_sergeant rig (drill_sergeant/field_medic/blitz_captain already use it) — the recolor-readability risk is acknowledged generically but this specific marquee-boss collision is not
- Every static world sims at 30Hz whether or not anyone is in it (Server.gd:3152-3155 ticks all _worlds every step) — roughly doubling static zone count (~40 more always-on mobs + more residents) adds permanent idle CPU on the droplet; unmentioned, though the HEALTH_INTERVAL monitor exists to watch it
- Quest-XP arithmetic is asserted, not derived: the ~6.5k/~9k chain totals and the '1.8x routing pressure' figure appear nowhere in the repo and were not shown — they cover only ~half the L10-16 band's ~12.4k XP, so kill-grind still carries the rest (the design flags the IP gates as unverified but presents the XP/routing numbers as settled)
- The 16-18 seam between the two new chains: after Rival Coach (L16) the player must clear Head Coach and level to 18 for champ_ready on OLD content (MIDGAME mid1-3 + GY farms) — a brief hand-back to the desert the design was built to remove
- The 'Away Set' token-vendor line cites a rookie_camp vendor-set precedent (GameData.gd:555-557) that I did not verify at that line — the Practice vendor pad exists (World.gd:85-86) so the pattern is plausible, but the new set's stat budget is a balance surface the doc waves through in one clause
- Session pricing folds all F4 decal dressing polish into slice E + contingency, but the existing 9 zones needed dedicated prop batches and multiple texture passes (docs/props-textures-handoff.md, batches 001-008) — dressing 9 new zones to parity is the likeliest 2-3-session overrun, making the 8-11 range optimistic at the low end

**Judge — ideas stolen into the synthesis:**
- Away-jersey thesis: in a sports game, same-silhouette-in-rival-colors makes the MANDATED recolor pipeline diegetic instead of cheap — the only theme where the asset constraint reads as intent (verified pipeline: Client.gd:2341-2357, GameData.gd recolor:true defs)
- Con-band overlap engineering: place zone mob levels so zone N's con fade-out (-5%/lvl past +-4, Server.gd:68-70) crosses zone N+1's higher base XP (15*level*tier, Server.gd:48) — soft multiplicative routing pressure with no hard walls, and every zone stays a viable farm for ~8 player levels
- Tune the away chain's drop ilvls (mobLevel+5 elite/+12 boss, Server.gd:3869-3870) + quest epics to organically deliver EXACTLY the existing boss_ready gate (L16+IP800, Server.gd:93-94) — converts a currently-unfed dead gate into the chain's destination; with the mandatory equip-real-drops numeric pass as a named slice deliverable
- The keyed-coupling audit: a concrete checklist of every place 'boss' is hardcoded to head_coach (nameplate+phase names Client.gd:2290-2301, ult warning text Client.gd:2344-2347, BOSS_PAGES + boss_time Server.gd:3511-3521) that ANY new boss must extend — most designs would ship a boss that displays the wrong name
- Server-only 'trailer' changes per slice (bounty rows via snapshot META Server.gd:4306-4310, token prefix, classId adds) that push new content with zero client re-export — the cheapest renewability lever in this codebase
- Rival Coach as a deliberate teaching boss: one primitive tier below Head Coach (phases+adds+hazard, NO campreset/cores) placed just before the real raid gate — difficulty curve via primitive subsetting, zero new mechanics
- Franchise Cannon fight shape: stationary + coreShield + respawning cores + 7-shot spread/ricochet + cover-ring OBSTACLES court — a genuinely novel positional artillery fight assembled purely from shipped def flags (all verified in GameData.gd:329-343, 218-270)
- The 'structural analog' column: mapping each new zone to a proven GY zone's grammar (elite-east placement, portal drops >AGGRO 320 / >PORTAL_RADIUS from reverse pads, World.gd:118-135) — encodes hard-won layout QA lessons as a design template
- Slice plan with a named 'highest-value stopping point' (A+B = complete 9-16 chain + boss_ready feed) so owner rejection of the capstone degrades gracefully
- Quest/bounty min_level>8 mob matches becoming usable for the first time — the machinery exists but is documented as uncompletable at the current lvl-8 ceiling (Quests.gd:98-99, Server.gd:4316 comment); raising the ceiling unlocks a dormant content dimension for free

### Claimed cost
8-11 focused sessions (best estimate 9): Slice A = 2 (zone authoring + textures + first full portal-walk QA is the fiddly one), Slice B = 2 (boss + gate + nameplate fix + IP feasibility pass + review), Slice C = 2 (two big zones + in-zone boss + prop integration pass), Slice D = 1.5 (small arena but two numeric passes + dyes/vendor set), Slice E = 1.5 (template + residents + bounty pools + decal polish). Add ~1 of contingency for the recolor-readability eyeball loop and any live-deploy retry (5 shared-heavy releases at ~0.5-1 hr of verification each are already folded into the slice numbers). Excluded: the optional Meshy batch (+0.5-1 session if approved) and the optional "visit" objective type (+0.5).

### New assets
- ZERO required Meshy generations — all 9 zones, 6 remix mobs, and 3 bosses use existing GLBs (recolor pipeline) + the ~65 already-owned props (29 Meshy + 31 Kenney CC0 + batch_005).
- 3 procedural ground textures (away_clay, away_snow, away_asphalt) via tools/gen_ground_textures.py — self-authored, free, no approval concern per the tool's own precedent; committed with .import sidecars and added to smoke_prop_loads.gd.
- Integration pass (optimize + DECO_PROPS + PROP_FOOTPRINT) on the ALREADY-APPROVED batch_006 founders_commons + batch_007 reward_progression props sitting in too_add_models/approved/ — work but zero new Meshy spend.
- OPTIONAL, flagged for owner approval, at most ONE small Meshy text-to-3D batch (4-6 props, only if slice-A/B eyeball says recolor+kit dressing reads thin): rival-team banner/flag, away scoreboard, one biome landmark (mesa or snow drift), one championship gate/wall variant, optional bleacher section. Explicitly deferred until the free assets are proven insufficient.

### Zone table
| # | Map id | Name / venue (theme) | Mob lvls | Size | Camps (class lvl, >320 apart; elite far-east GY grammar) | Gates in/out | Portal wiring | Quest hooks | Visual dressing (existing library) | Structural analog |
|---|--------|----------------------|----------|------|-----------------------------------------------------------|--------------|----------------|-------------|--------------------------------------|--------------------|
| 1 | away_1 | **Dustbowl Diamond** — rival baseball park, desert clay | 9-10 (E11) | 1550×880 | foam_dummy 9 ×2, shooting_dummy 9 ("pitching machine"), cone_swarmer 10; elite **sandlot_slugger** 11 (NEW: tackle_brute #C97A3D) | none / none | HOME north pad (300,200) "▶ Away Circuit" → spawn (200,440); back↔HOME, fwd→away_2 | away1_roadtrip (min 9, 12 kills), away1_slugger (10, elite) | NEW away_clay ground; Kenney rock_largeA/C/E, stone_largeB, sparse palms; fence_planks outfield; barrier/bag cover; sideline_stand | GY1 (entry lane) |
| 2 | away_2 | **Frostline Gridiron** — northern football field, snow | 11-12 | 1650×920 | frost_cone 11 ×2 (NEW: cone #BFE8FF slow-dasher), tire_dummy 11, foam_dummy 12; elite iron_sled 12 (reuse) | none | back→away_1, fwd→away_3 | away2_coldfront (11), away2_sledline (12, elite) | NEW away_snow ground; tree_pineRoundC clusters, log_stack, fence_simple; rack cover; equipment_transport_crate | GY2 (first elite) |
| 3 | away_3 | **Boardwalk Court** — beach volleyball rival, sand | 12-13 | 1800×980 | spring_cone 12, chalk_liner 12 (turret), pop_dummy 13, cone_swarmer 13; elite ball_machine 13 ("serve machine", reuse) | none | back→away_2, fwd→away_4 | away3_serve (12), away3_ace (13, elite) | away_clay retinted sand; palmDetailedTall, plant_bush; boundary_pylon, spectator_safety_rail, covered_market_stall (batch_006) | GY3 |
| 4 | away_4 | **Union Pitch** — urban soccer streets | 14-15 | 1900×1040 | street_striker 14 ×2 (NEW: cone #FF8A4C), whistle_cone 14, chalk_liner 15; elites **net_judge** 15 mid (NEW: drill_sergeant #EDEDED summoner) + gatling_machine 15 east (reuse) | none | back→away_3, fwd→away_5 | away4_streets (14), away4_judges (15, 2 elites) | NEW away_asphalt ground; Kenney building-a/c/e/h + chimneys, detail-tank; plaza_light_column (b006); straight_cover_barrier | GY4 (2-elite density bump) |
| 5 | away_5 | **The Rival's Gate** — away-stadium approach, mixed | 15-16 | 2000×1100 | pop_dummy 15, street_striker 15, whistle_cone 15, foam_dummy 16; elites **rival_enforcer** 16 east (NEW: tackle_brute #B03A3A) + field_medic 16 mid (reuse — teaches focus-fire) | out: `away_ready` (L14, visible-locked) | back→away_4, fwd→away_final (gated) | away5_gatecrash (15) | away_asphalt dark tint; championship_arena_wall segments, player_tunnel_gate, stadium, sideline_stand, boundary_pylon rows | GY5 (pre-raid gauntlet) |
| 6 | away_final | **Rival Stadium** — boss room | boss 16 | 1240×820 | **RIVAL COACH** boss 16 central (NEW: rigged drill_sergeant #B03A3A h4.2; phased+threshSummon+summon+hazard, no ult/cores) | in: `away_ready` | back→away_5; no forward (quest text → Head Coach gate) | away_final_whistle (16, boss) → dye + epic + 40 Pages; hands player L16/IP≈800 for boss_ready | turf crimson tint (rival field); arena walls, tunnel gate, safety rails; light cover panels | GY_BOSS (minus ult ring) |
| 7 | champ_1 | **Contenders' Row** — championship district | 19-21 | 1900×1040 | champ_veteran 19 ×2 (NEW: foam_dummy #D9A21A), spring_cone 20, chalk_liner 20, shooting_dummy 21; elites tackle_captain 21 east + field_medic 20 mid (both reuse) | in: `champ_ready` (headcoach_down + L18, visible-locked) | HOME north pad (1480,200) "▶ Championship Series" → spawn west; back↔HOME, fwd→champ_2 | champ1_contender (18), champ1_row (19, 2 elites) | away_asphalt + gold tint; dense Kenney city, plaza_light_column, vendor_service_kiosk, leaderboard_kiosk, public_plaza_bench (b006) | GY4 grammar at champ scale |
| 8 | champ_2 | **The Undercroft** — stadium service tunnels | 22-25 (boss 24) | 2000×1100 | pop_dummy 22, whistle_cone 23, champ_veteran 23, chalk_liner 24; elites blitz_captain 24 + iron_sled 25 (reuse); **FRANCHISE CANNON** boss 24 in far-east cover-ring court + power_core ×3 lvl 21 | out: `final_ready` (L26 + IP1400, visible-locked) | back→champ_1, fwd→champ_boss (gated) | champ2_undercroft (22), champ2_cannon (24, boss-class kill) | glitchyard_wall, arena_service_door, batch_005 utility set (cable_spool_cart, coolant_pump_station, vents); scrapyard ground retinted | GY5 + in-zone world boss (one structural novelty; mechanically just a MOBS row, tier boss) |
| 9 | champ_boss | **Championship Field** — final arena | boss 28 | 1340×880 | **THE COMMISSIONER** 28 central (NEW: boss2 #2E6BD6 h5.2; full menu incl. campreset@P2 + coreShield 0.45) + power_core ×5 lvl 25 ring | in: `final_ready` | back→champ_2; spawn far west | champ_series (26), champ_crown (26, boss) → gold dye + 60 Pages; feeds paragon | turf gold tint (the championship pitch); championship_arena_wall ring, trophy, season_reward_vault (b007); mandatory cover-RING obstacles | GY_SECRET (endurance raid) |

### Slice plan
Each slice is independently shippable and follows the full loop: compile check (`godot --headless --import` + SCRIPT ERROR grep) → local server+client with EVERY new portal walked forward AND back → balance-harness + CI green → adversarial review → `deploy/release.sh minor` → confirm CI image built BEFORE droplet setup.sh (OOM-fallback guard) → live client connect re-walk. 🔴 = shared/+client re-export in the SAME commit.

**Slice A (M) — "Away Season, legs 1-3"** 🔴
away_1/2/3: MAPS+SPAWN+PORTALS+MOBS+OBSTACLES rows; HOME north pad (300,200); new defs sandlot_slugger + frost_cone; AWAY_ORDER quests 1-6 (new list, display_order concat); client: _zone_name entries, _make_field_material per-map table + 2 generated ground textures (clay, snow) with committed .imports, F1 goto buttons, smoke_prop_loads additions; minimal F4 decals. Ships a complete, ungated 9-13 leveling arc on its own.

**Slice B (M) — "Road to the Final"** 🔴
away_4/5 + away_final room; defs street_striker, net_judge, rival_enforcer + RIVAL COACH boss; `away_ready` gate arm (visible-locked); AWAY quests 7-10 + Away Crimson dye; client boss-nameplate fix (read def name, Client.gd:2294-2301); asphalt texture; server-only trailers: token prefix extension (Server.gd:3485), boss_time/BOSS_PAGES classId adds (Server.gd:3511-3520), first away bounty rows (zero client re-export). Includes the IP800-feasibility numeric pass (equip a full chain-drop set on a test char, read gear score, tune drops/quest items until the gate is organically reachable).

**Slice C (M) — "Championship Series"** 🔴
champ_1/2; champ_veteran def + FRANCHISE CANNON boss + its cover-ring court + cores; `champ_ready` gate arm; HOME pad (1480,200); CHAMP_ORDER quests 1-4; batch_006/007 optimize+integrate pass (DECO_PROPS, PROP_FOOTPRINT for solids, smoke_prop_loads) + district dressing.

**Slice D (S/M) — "The Commissioner"** 🔴
champ_boss arena + cover RING; THE COMMISSIONER def; `final_ready` gate arm + IP1400 numeric pass; CHAMP quests 5-6 + Commissioner's Gold dye; away token-vendor set (rookie_camp precedent); remaining boss_time/Pages ids; champ bounty rows (server-only).

**Slice E (S/M) — "Renewability pass"** 🔴 (template data is shared)
"Away Gauntlet" instanced Circuit room (4th template: MAPS+INSTANCE_MAPS+MOBS+objective rows + server _circuit_template rotation) — inherits Intensity/affix/fastest-clear/Pages/con-exempt XP; 3-4 new RESIDENTS rows lvl 12-24 with away/champ routes (server-only); complete daily/weekly bounty pools; F4 decal polish across all 9 maps (client-shippable); optional per-zone music drops.

Order rationale: A alone fixes the worst band (9-13); A+B completes the 9-16 chain and the boss_ready feed (the single highest-value stopping point); C+D are the capstone; E converts corridor → repeatable mid-game. Any prefix of the sequence is a coherent live game.

### Designer's risks
- Circuit dominance: instanced Camp Circuit is con-exempt full-XP (Server.gd:3668-3671) with 1.5x/tier reward multipliers — if its XP/hour beats the new open zones, the biome becomes scenery you quest through once. Mitigation is concentrating quests/bounties/tokens/ilvl in the zones, but run an honest XP-per-hour comparison before slice C; if Circuit still wins, the design needs the owner to accept re-tuning Circuit rewards (out of current scope).
- Gear-score gate feasibility is unverified math: the whole chain exists to deliver boss_ready's L16+IP800 organically, and final_ready's IP1400 is a guess — if a full set of chain drops (ilvl 9-28) doesn't actually sum to the gate, the design recreates the exact dead-end it was built to remove. The slice-B/D numeric passes (equip real drops on a test char, read item_power) are mandatory, not optional.
- Recolor readability: the dye channel is one flat 0.45-alpha overlay on the whole model (Client.gd:2343-2379) — three 'new' bosses may read as cheap tints of Head Coach-era enemies, and this is un-verifiable headlessly (eyeball-only). Fallback is the flagged optional Meshy batch or stronger silhouette-by-scale (h) deltas; if the owner rejects palette-swap bosses on sight, the asset budget assumption collapses.
- Low population vs 9 more static maps: a small live server spread across 18+ shared worlds feels emptier per zone. Residents + three 30-min world-boss timers mitigate, but if the owner's priority is felt-liveliness, 3 bigger zones may beat 8 corridors — a legitimate reason to reject this shape (the slice plan degrades gracefully: stop after B).
- Deploy exposure: 5 shared-heavy release events, each requiring same-commit client re-export and each exposed to the droplet OOM-fallback if the ghcr image isn't confirmed built first (deploy checklist step 6); CI covers none of the portal-walk/theming surface, so every slice carries mandatory manual live verification.
- Kill-only quest fatigue: all 16 new quests are kill objectives because that's the only shipped type (Quests.gd:10-12) — 8 zones of 'kill N here' may read as the grind it replaces, just directed. The priced escape hatch (a 'visit zone' objective, ~0.5 session of NEW machinery) violates the no-new-mechanics preference and needs an explicit owner call.
- Economy inflation: credits scale 8+5×mobLevel (Server.gd:2428-2435) — lvl 22-28 farming roughly triples credit income against sinks tuned for the old ceiling (shop ilvl 8, 50k respec); flag a sink review to the owner rather than silently retuning.
- Owner-boundary items deliberately left open: the jump/verticality §4 named-moment test at sign-off (this design is flat-2D everywhere and forecloses nothing, but the capstone has no marquee vertical moment), the Practice-Token prefix extension (economy decision), and any re-pointing of MIDGAME quests at the new zones (kept byte-identical here).

### Full design doc

# Phase 8 — "The Away Circuit" Design Doc (systems-first draft)

## 0. Thesis: the theme IS the systems argument

The "away game" hook is kept, and it is load-bearing, not decoration:

1. **Away jerseys make palette-swaps diegetic.** The entire mob/boss roster is recolors of shipped GLBs (`recolor:true`+`color` → dye-channel overlay, Client.gd:2343-2379, shipped P3 pattern GameData.gd:277-380). In a sports game, the SAME silhouette in RIVAL COLORS is not asset reuse — it's literally what an away game looks like. This is the only theme in which the mandated recolor pipeline reads as intentional.
2. **Each away venue justifies a different sport's mob mix + ground texture** from one roster: baseball diamond (shooting_dummy = pitching machine), football frost-field (sleds), volleyball boardwalk (ball machines/serve), soccer streets — 4 distinct-feeling zones from zero new sim content.
3. **The capstone gate is "making the playoffs."** A visible-but-locked level+quest gate (`boss_ready` UX, Server.gd:93-96, 3370-3374) is diegetically "you haven't qualified yet" — the shipped explainer-chat pattern becomes flavor for free.

## 1. The leveling math (why these bands, exactly)

- XP curve: `_xp_to_next(L) = int(50L + 7.5L²)` (Server.gd:204-207). Cum-to-L10 ≈ 5,635; L10→16 ≈ 12.4k; L18→28 ≈ 50k; 1→30 ≈ 86k total (comment Server.gd:205).
- Con-scaling: full XP within ±4 levels of the mob, fading 5%/level over 12 more to a 40% floor (XP_CON_GRACE/SPAN/FLOOR, Server.gd:68-70, 3674-3683). The :70 comment names Phase 8 as the fix ("until Phase 8 adds 9-28 zones").
- Today's ceiling: **no open-world mob exceeds level 8** (drill_sergeant, World.gd:208); bosses 8/10 (World.gd:211,219). Phase 8's single most important number is raising that ceiling; con-scaling then routes players automatically.
- **Band placement** (mob levels): away_1 9-10(+E11) → away_2 11-12 → away_3 12-13 → away_4 14-15 → away_5 15-16 → Rival Coach 16; champ_1 19-21 → champ_2 22-25 + Franchise Cannon 24 → Commissioner 28. Every player level 5→29 has ≥2 zones at full XP (±4 grace); zone N cons out (−5%/lvl) exactly as zone N+1's higher base XP (`15 × level × tier`, Server.gd:48, 3672) compounds the forward incentive — e.g. a L17 player gets 127/kill in away_1 (0.85 con) vs 233/kill in away_5 (full): a 1.8× multiplicative routing pressure with no hard walls.
- **Gate delivery**: the chain tops out at mob 16 / elite drops ilvl ~21 / Rival Coach drops ilvl 28 (drop ilvl = mobLevel +5 elite/+12 boss, Server.gd:3869-3870) + quest epics — tuned to hand the player exactly `boss_ready`'s L16 + IP800 (Server.gd:93-94) at chain end. Today that gate has NO content feeding it (mid-spine starts at prereq `headcoach_down`, Quests.gd:105 — i.e. AFTER the gate); the chain removes the game's worst dead band.
- **Capstone slotting**: champ_ready opens post-Head-Coach at L18; champ_2's 22-25 minions give full XP through player 29, feeding the L30 paragon overflow (Server.gd:3559-3563) permanently.

## 2. Topology & gates

- Both new chains branch off the **HOME north gate row** (World.gd:97-102; pads at x=600/900/1180, y=200): add "▶ Away Circuit" @ (300,200)→away_1 and "▶ Championship Series" @ (1480,200)→champ_1 (gated). Linear back/forward pads per zone, GY pattern (back @x≈120, forward @x≈w−80, drops >AGGRO 320 from elites, >PORTAL_RADIUS 42 from reverse pads — World.gd:118-135 comments).
- **3 new gate ids**, each one match arm in `_portal_unlocked` (Server.gd:3395-3404), NONE added to HIDDEN_GATES (all visible-but-locked + throttled explainer, the shipped "known goal" UX, Server.gd:95):
  - `away_ready` (away_5→away_final): level ≥ 14.
  - `champ_ready` (HOME→champ_1): quest `headcoach_down` completed AND level ≥ 18.
  - `final_ready` (champ_2→champ_boss): level ≥ 26 AND item_power ≥ 1400 (mirror of boss_ready; number needs the same numeric pass as §7-risk-2).
- Login gate re-validation is automatic for any new `to`+`gate` pad (World.gate_for_map :413-418; Server.gd:2061-2069). last_map persistence/restore is automatic (Server.gd:2113-2128, 4637-4660). Static worlds boot from every MAPS key (init_worlds, Server.gd:242-250). Zero per-zone server code.
- The chain does NOT get a second physical entrance into GY_BOSS — quest text at away_final completion directs players to the existing Head Coach gate (keeps GY topology byte-identical).

## 3. The 3 new bosses (primitive combos only — menu #s from the shipped primitives)

**RIVAL COACH** — away_final, lvl 16, tier boss. GLB: `drill_sergeant` RIGGED (whitelisted, Client.gd:506-510; recolor-on-rigged is shipped via field_medic/blitz_captain, GameData.gd:351-370), crimson #B03A3A, h4.2 — the first skeletally-animated boss.
- Primitives: #1 phased · #2 threshSummon {whistle_cone ×2} · #3 summon (spring_cone ×3, SUMMON_CAP 3) · #10 hazard zones ("Chalk the Lines") · #12 kbImmune · #13 P7c auto-scaling · #15 1800s world-event respawn. Deliberately NO campreset/cores — one tier below Head Coach; teaches phases/adds/telegraphs before the real raid.
- Gate: `away_ready` (L14, visible-locked). Rewards: 40 Pages (BOSS_PAGES pattern, Server.gd:3511-3512, extended to this classId), ilvl 28 drops, existing unique pool (15%, Server.gd:165), quest epic + "Away Crimson" dye.

**FRANCHISE CANNON** — in-zone world boss, champ_2 far-east court, lvl 24. GLB: `ball_machine` recolor #C4A02E gold, h4.5, stationary, face 90.
- Primitives: #1 phased (+#13 P7c) · #5 power cores ×3 (lvl 21, respawn 6s so counterplay recurs) · #6 coreShield 0.40 (auto shield-aura + "DESTROY THE CORES" plate, Client.gd:1392-1411, 2292-2296) · #11 spread 7-shot + ricochet bounces 2 + wobble stacking · #10 hazard zone · #3 summon (spring_cone ×2) · #12 stationary+kbImmune. A positional artillery fight: kill cores under fan/ricochet pressure. Cover-ring OBSTACLES court around it (World.gd:381-395 pattern), placed >320 from camps.
- Gate: none (quest-targeted). Rewards: 40 Pages, ilvl 36 drops, unique pool, boss_time entry.

**THE COMMISSIONER** — champ_boss "Championship Field", lvl 28. GLB: `boss2` recolor #2E6BD6, h5.2 (boss2 has ZERO variants today — the biggest untapped asset).
- Primitives: full menu — #1 phased · #4 campreset ult "Final Whistle" (dmg 135 / cast 3.0 / phase 2 / cd 14 — between Head Coach P3/cd15 and PRIME P2/cd12; generic LOS-warning UI is free, Client.gd:2289-2291) · #5 coreCount 5 (power_core ×5 lvl 25 ring) · #6 coreShield 0.45 · #2 threshSummon {pop_dummy ×2} · #8 wallStun bait dash · #9 pull 240 · #7 hpMult 3.0 / dmgScale 0.8 (~half-PRIME endurance) · #12 kbImmune · #13 P7c · #14 `final_ready` gate · #15 1800s. Mandatory cover-RING arena (no passively-safe spot).
- Rewards: 60 Pages, ilvl 40 drops, unique pool, "Commissioner's Gold" dye (quest), seasonal boss_time race → Champion-dye pipeline rides free (Server.gd:1807, 1815-1847).

Required companion fixes: (a) boss nameplate hardcodes "☠ HEAD COACH" + phase names for ANY tier=="boss" (Client.gd:2294-2301) — change to read the def's `name` (+ optional per-def phase-name array, fallback generic); client-only, ships with the first new boss. (b) boss_time submission + BOSS_PAGES grant are keyed `classId=="head_coach"` (Server.gd:3511-3520) — add the three new ids; server-only.

## 4. New mob defs (9 dicts total, all additive, harness-inert)

6 minion/elite remixes (recolor:true on existing GLBs, ONLY mob-proven ability types: melee/dashAttack/meleeAoe/projectile/zone/selfbuff/summon/spread+bounces/allyheal-buff):
sandlot_slugger (tackle_brute #C97A3D, elite), frost_cone (cone #BFE8FF, slow-rider dasher), street_striker (cone #FF8A4C, fast dasher), net_judge (drill_sergeant #EDEDED, elite summoner: whistle_cone ×3 + hazard), rival_enforcer (tackle_brute #B03A3A, elite), champ_veteran (foam_dummy #D9A21A). Plus 3 bosses (§3). Heavy reuse of the 14 lightly-used shipped mobs at new levels (iron_sled, ball_machine, gatling_machine, field_medic, tackle_captain, blitz_captain, tire_dummy, whistle_cone, pop_dummy, chalk_liner, spring_cone…) — `_scale_mob` needs only new level numbers (Server.gd:3596-3613; World.MOBS rows carry only {class,level,tier,x,y}).
Determinism safety is structural: `mob:true` defs never enter `playable_ids()` (GameData.gd:628-633); phased/summon/campreset paths are player-inert (Sim.gd:230-233, 410). FORMAT_MODS, player classes, existing zones/quests: untouched.

## 5. Directed play: quests + bounties

- **AWAY_ORDER** (10 quests, min_level 9→16, kill-only, chain-internal prereqs, NO coupling to ORDER/MIDGAME — the Quests.gd:19-21 warning + MIDGAME_ORDER precedent :175-176; concat into display_order() :183-184): away1_roadtrip (12 kills map:away_1) → away1_slugger (elite) → away2_coldfront → away2_sledline (elite) → away3_serve → away3_ace (elite) → away4_streets → away4_judges (2 elites) → away5_gatecrash → away_final_whistle (tier:boss map:away_final). Rewards ladder ≈6.5k XP total + credits + Pages 10-50 + rare→epic items at elite beats + "Away Crimson" dye; finale text points at the Head Coach gate.
- **CHAMP_ORDER** (6 quests, 18→26): champ1_contender → champ1_row (2 elites) → champ2_undercroft → champ2_cannon (class:franchise_cannon) → champ_series → champ_crown (class:the_commissioner). ≈9k XP + Pages 30-60 + "Commissioner's Gold".
- Mob min_level quest filters become usable above 8 for the first time (ceiling noted at Quests.gd:98-99).
- Giver: the single HOME NPC (World.gd:83-84) — shipped pattern; portal-density makes hub returns cheap and drives shop/forge visits. (A second giver pad in away_1 is a priced OPTION: pad const + `_at_questgiver` variant, ~0.25 session — deferred.)
- **Bounties = the zero-re-export renewability layer** (server-defined, shipped via snapshot META, Server.gd:4306-4310): append ~6 daily + 2 weekly defs targeting away/champ maps and min_level 9+ ("Road Game: 15 in Boardwalk Court", "Title Contender: any boss min_level 16"…). Deployable/retunable with server-only pushes.
- **No new objective types.** If the owner wants variety, the smallest addition is a "visit zone" objective (zone-enter hook + one quest kind): ~0.5 session, server+shared. Priced, not included.

## 6. Renewability (the anti-corridor design)

1. Con-band overlap engineering (§1) — every zone stays a viable farm for ~8 player-levels; the 40% floor + rested XP (Server.gd:741-743) keep older zones as fallbacks.
2. Bounty rotation across the biome (daily/weekly deterministic picks, Server.gd:4340-4352) — server-only content pushes.
3. **Slice E: one instanced "Away Gauntlet" Circuit room** (a 4th template: MAPS+INSTANCE_MAPS+MOBS keys + `_circuit_template` rotation — the camp_b/camp_c precedent) — inherits Intensity ladder, weekly affix, fastest-clear boards, Pages, and the con-exempt full-XP rule (Server.gd:3668-3671) for free.
4. Three 30-min world bosses (BOSS_RESPAWN_DELAY 1800s, Server.gd:36) spread across the biome → recurring sweep loops.
5. Seasonal boss_time races for all three bosses + weekly Champion dye (free once classIds are added).
6. **Token economy extension**: Practice-Token drops are gated on `begins_with("glitchyard")` (Server.gd:3485) — extend the prefix check to away/champ (server-only) and add an "Away Set" token-vendor gear line (rookie_camp vendor-set precedent, GameData.gd:555-557 — existing stat surface, no P7a violation).
7. Residents: add 3-4 RESIDENTS rows lvl 12-24 homed/routed through away/champ zones (Server.gd:80-91 pattern; current roster caps at lvl 10 and is GY-only) — solo-first companionship in the new bands; server-only.

## 7. Rewards under the no-new-stat-surfaces rule

Gear identity comes free from mob level: open-world drop ilvl rises from today's ~8/13/20 cap to ~25 minion / ~30 elite / ~40 boss (Server.gd:3869-3870) — a real open-world-vs-crafting identity (recipes cap ilvl 30, GameData.gd:563-568) with zero new item mechanics. Plus: existing unique pool on new bosses, 2 biome-exclusive dyes (quest-grant precedent Quests.gd:129,157,165), Pages chunks (boss 40-60), credits, the token vendor set, seasonal Champion dye, paragon overflow. NO sockets/gems, NO new affixes, NO titles (system doesn't exist).

## 8. Theming (client) — per-zone cost

- Ground: extend `_make_field_material`'s prefix branch (Client.gd:573-581) to a small per-map-id table; 3 NEW procedural textures via tools/gen_ground_textures.py (free, self-authored precedent): away_clay (away_1; retinted for away_3 sand), away_snow (away_2), away_asphalt (away_4/5, champ_1/2); champ_boss = existing turf with gold `albedo_color` tint (zero-asset). Add to smoke_prop_loads.gd (:8-12) + commit .import sidecars (publish_client.sh:32-33 preserves them).
- Dressing from the ~65 existing GLBs (Meshy props + Kenney CC0 nature/city kits) via F4 → data/decals/<map>.json (client-shippable; collidable props need PROP_FOOTPRINT rows = shared). Integrate the ALREADY-APPROVED batch_006/007 props (optimize pass only, docs/props-textures-handoff.md:71-80 — no new spend): portal_anchor, covered_market_stall, plaza_light_column, season_reward_vault etc.
- Per-zone client wiring: `_zone_name` entries (NetClient.gd:6411-6424), F1 goto buttons (NetClient.gd:4834), optional music drops (audio/music/<map>.ogg, AudioManager.gd:121-132).

## 9. What stays byte-identical

FORMAT_MODS, all player classes/abilities, all 9 live zones' MAPS/MOBS/OBSTACLES/PORTALS rows, ORDER + MIDGAME_ORDER, existing gates. All Phase-8 changes are additive dict/const entries + 3 small keyed extensions (gate match arms, token prefix, boss_time/Pages classIds) + 2 client display fixes. Balance harness + full CI run every slice as proof.

---

## Design C — "Lean Capstone" (5+2 zones — CHOSEN as the synthesis backbone)
**Judge: 8/10 · desert=mostly · pricing=optimistic**

**Judge verdict:** The best-verified design I could ask for: essentially every file:line citation checked out against the repo, every claimed primitive/asset/system exists as claimed (coreShield-without-phased, P7c def-driven hook, META-pushed bounties, recolor dye channel, approved batch_006/007 props), and all four hard constraints are genuinely respected — zero new sim mechanics (all boss kits are recombinations of shipped data params), zero new stat surfaces, zero required Meshy credits, and correct shared/+client same-commit discipline with the OOM/ghcr guard. The lean 5+2 cut is an honest, argued reframe of the brief's 7-8 zones, self-declared as its own top kill-reason. Slices are shippable-after-every-slice (the server even silently tolerates the dangling forward pads the plan forgot to mention). Docked from 9-10 for: a misquoted XP curve (L9-15 costs ~1,057-2,437, not the quoted 2,700-7,800 — so early-zone pacing is asserted, not computed), unstated dangling-pad handling in S1/S3, unstated dye-exclusivity wiring, tripled 30-min boss-respawn contention on count-1 quest chokepoints, fudged world/ilvl counts, and the self-admitted unverified IP800 bridge math on which the whole midpoint hinges. 'Mostly' kills the desert: direction density (12 quests + rotating bounties + gear-ilvl ladder + con-fixed XP) is real and verified-cheap, but per-band XP volume was never summed and the L16 Head Coach event remains a soft wall by design. Cost is optimistic-but-honest: the data-driven surfaces are as small as claimed, yet S1's task list is long for 2 sessions and boss tuning historically demanded dedicated harnesses (tools/tune_boss.gd, tune_boss2.gd).

**Judge — glossed over:**
- XP-per-level range misquoted: _xp_to_next = 50L+7.5L^2 gives ~1,057-2,437 for L9-15 (quoted 2,700-7,800 only holds L16+), so the '2-3 levels of play per zone' pacing for away_1/away_2 is asserted, never computed — no per-band sum of quest+bounty+kill XP exists anywhere in the design
- Forward pads to unshipped zones dangle mid-plan: S1 ships away_2 with a pad to away_3 (S3 repeats with finals_boss); _portal_teleport no-ops on a missing world so it is safe, but a visible dead pad ships unless each slice withholds the forward pad — unstated
- New dye exclusivity wiring unstated: 'non-buyable' Rival Crimson / Championship Gold need the Champion-dye pattern (kept OUT of DYE_IDS, GameData.gd:621-624) plus grant/render wiring — a real edit the wiring bill omits
- rival_down and commissioner_down are count-1 kill quests on 1800-s world-event bosses that the whole chain funnels through — respawn contention/wait for solo questers is precedented once (headcoach_down) but now tripled and never discussed
- grand_gallery's open-world coreShield dynamics untested: power cores respawn at the 6-s minion delay, giving tight burn windows, and cores in a shared zone can be cleared/held by other players
- If the owner declines the token-prefix extension, the entire 9-28 band drops zero Practice Tokens and the rookie_camp vendor set dead-ends — the decision is flagged but its consequence is not
- Count fudges: '14 to 21 static worlds' (live static count is 9 to 16) and 'away zones yield ilvl ~14-28' (lvl-9 minions drop ilvl 9)
- Quest-XP sizing at the low band: away1_roadgame's 700 XP is ~two-thirds of a level at L9 under the real curve — the chain may overshoot the away_1 band rather than under-fill it (opposite risk to the one the design lists)

**Judge — ideas stolen into the synthesis:**
- Standalone prereq:"" on the first away quest — the single cheapest fix to the 9-16 void, since everything today chains off headcoach_down which is L16+IP800-locked (Quests.gd:105, Server.gd:93-94)
- finals_gate keyed on level+IP rather than the Head Coach KILL — a stalled raid never hard-blocks the capstone branch
- The MIDGAME braid: 6 of 9 mid-spine quests are map-agnostic (Quests.gd:107-160) and auto-progress inside new zones with zero edits — free direction density
- Away-game fiction as diegetic cover for the recolor pipeline: rival teams train on the same equipment in team colors, so palette-swaps read as faction identity
- Con-grace coverage math (±4 grace, Server.gd:68) to size the zone count: 5 field zones double-cover 9-30, exposing the brief's 7-8 as over-built for a low-pop server
- Bounties as server-only META-pushed direction (Server.gd:4306-4310) — re-aimable at new zones between releases with zero client re-export
- Boss-nameplate generalization (Client.gd:2290-2301 hardcodes '☠ HEAD COACH' + phase names for ANY boss tier) as a tiny prerequisite that unlocks all future bosses
- Elite-plus farmable miniboss recipe: elite tier (6-s respawn) + def hpMult + coreShield = a repeatable skill-check instead of a portal-blocking 30-min event
- The 'never gate on AWAY_ORDER completion' governance rule from S1, making per-slice quest appends retroactively safe (the ORDER lesson, Quests.gd:18-21)
- head_coach.glb and boss2.glb have zero recolor variants today — the two untapped boss silhouettes for new bosses at near-zero asset cost
- dmgScale as the explicit solo-viability knob because P7c scales HP only, never damage (Server.gd:55-63) — with the exact 0.475-pool solo+2-bots arithmetic

### Claimed cost
Core (S1-S4): 7-8 sessions (S1: 2, S2: 2, S3: 1.5-2, S4: 1.5 — each slice = author + local round-trip test + adversarial review + release/deploy/live-verify). With optional S5 polish: 8-9 sessions. For comparison, the full 8-zone brief at the same grammar is honestly ~11-13 sessions with mid-phase abandonment risk; every slice here leaves the live game coherent if work stops.

### New assets
- ZERO Meshy credits required for the core plan. Itemized new assets, all free/self-authored: (1) 1-2 procedural tileable ground albedos ('rival clay' for away_*, 'championship court' for finals_*) via tools/gen_ground_textures.py — self-generated, no license/approval concern per its docstring; the finals texture is skippable at zero cost by reusing turf_albedo with a gold albedo_color tint (Client.gd:578). Committed .import sidecars kept per publish_client.sh:32-33; add both to tools/smoke_prop_loads.gd.
- No-new-spend integration (already generated + owner-approved, needs only the §A.1 optimize pass): batch_006 founders_commons (plaza_light_column, championship_fountain, covered_market_stall) and batch_007 (season_reward_vault, portal_anchor) as finals/away dressing — slice S5.
- OPTIONAL, flagged for owner approval, at most ONE small Meshy batch (defer until after S2 eyeball test of the recolor look): 4-6 'away venue' props — rival team banner/flag, away scoreboard, one biome landmark, one capstone wall variant — closing the theming lane's identified gaps (no rival signage, only 2 enclosure walls). Core plan ships without it.
- Optional zero-code music: audio/music/<zone-id>.ogg drop-ins (audio/music/ currently empty; AudioManager.gd:12,121-132).

### Zone table
| Zone id — name | Theme / venue | Mob levels (serves) | Size | Camps (class lvl tier) | Gates in / out | Portal wiring | Quest hooks | Visual dressing | Structural twin |
|---|---|---|---|---|---|---|---|---|---|
| `away_1` — Rival Practice Field | First away game: rival team's training pitch | 9-10 (players 5-14 full XP) | 1700×950 | 4 minion camps: rally_cone(NEW recolor) 9 ×2, foam_dummy 9, tire_dummy 10; elite tackle_brute 10 far E | IN: `away_gate` (lvl≥8, visible-locked) from HOME / OUT: none | NEW HOME north pad (300,200) "▶ Away Games" → spawn (200,475); back pad x120→HOME; fwd pad (1620,475)→away_2; camps >320 apart per GY grammar (World.gd:168-175) | away1_roadgame (12 kills), away1_blocker (elite); daily bounty | NEW "rival clay" procedural ground (gen_ground_textures.py) + away albedo_color; Kenney fences, sideline_stand, boundary_pylon; navy/crimson cover barriers | GY2 (World.gd:183-190) |
| `away_2` — Visitors' Gauntlet | Hostile rival drills, first healer camps | 12-13 (players 8-17) | 1850×1000 | away_blocker(NEW) 12 ×2, whistle_cone 12, line_judge(NEW) 13; elites: sled_juggernaut 13 mid + field_medic 12 (healer-camp dynamic, proven support_tick) | none / none | back x120→away_1; fwd (1770,500)→away_3 | away2_gauntlet (15 kills), away2_medics (2 field_medics); daily bounty away_patrol | same ground; player_tunnel_gate + spectator_safety_rail + equipment_transport_crate; heavier lane cover | GY4 (2-elite density bump, World.gd:197-204) |
| `away_3` — Rival Stadium | The rival's home stadium floor | 15-16 (players 11-20) | 2000×1100 | rally_cone 15, away_blocker 15, spring_cone 15; elites: ball_machine 15 + drill_sergeant 16 E anchor (summoner at the boss door) | none / none (boss walk-up) | back x120→away_2; fwd (1920,550)→away_boss | away3_stadium (18 kills, epic ilvl-20 IP push), away3_elites (2 elites); daily bounty rival_elites | stadium + championship_arena_wall segments + boundary_pylons; crowd-side dressing via sideline_stand rows | GY5 (World.gd:205-208) |
| `away_boss` — Rival Sideline | Rival Coach's sideline, cores on the bench | boss 16 + power_core ×4 lvl 12 | 1240×820 | THE RIVAL COACH (NEW def, head_coach.glb #C43C2E) central @~(620,410); cores in square | none in / back only | back pad→away_3; spawn far W beyond aggro | rival_down (kill boss) → routes to existing Head Coach raid; weekly bounty rival_slain | cover-RING obstacles (GY_BOSS pattern World.gd:381-395); rival banners (optional Meshy batch) | GY_BOSS (World.gd:209-212) |
| `finals_1` — Contenders' Quarter | Championship city district | 19-21 (players 15-25) | 1900×1040 | pop_dummy 19 ×2, chalk_liner 20, whistle_cone 20; elites: iron_sled 20 + gatling_machine 21 (open-world debut of instance elites) | IN: `finals_gate` (lvl≥17 AND IP≥800, visible-locked) from HOME / OUT: none | NEW HOME north pad (1500,200) "▶ The Finals" → spawn (200,520); back x120→HOME; fwd (1820,520)→finals_2 | finals1_contenders (20 kills), finals1_machines (3 elites); daily bounty finals_patrol | NEW "championship court" ground (or turf + gold tint at zero cost); Kenney city buildings-a/c/e + chimneys as skyline décor; plaza_light_column (approved batch_006, no new spend) | GY4 |
| `finals_2` — Champions' Gate | The gate to the final venue | 23-25 (players 19-29 → cap) | 2000×1100 | away_blocker 23, spring_cone 23, line_judge 24; elites: blitz_captain 24 + field_medic 23; ELITE-PLUS: grand_gallery(NEW, ball_machine #D4AF37, hpMult 3.0, coreShield 0.35 + 2 cores lvl 20) far E guarding fwd pad approach | none / OUT: `commissioner_ready` (lvl≥24 AND IP≥1200, visible-locked) | back x120→finals_1; fwd (1920,550)→finals_boss, gated | finals2_gate (20 kills), finals2_gallery (kill grand_gallery); daily bounty gallery_break | championship_arena_wall enclosures + championship_fountain/covered_market_stall (approved batch_006 after optimize pass) | GY5 + Drill elite-plus recipe (Server.gd:1680-1711) |
| `finals_boss` — The Commissioner's Box | The final: the league itself | boss 27 + power_core ×6 lvl 22 | 1440×940 | THE COMMISSIONER (NEW def, boss2.glb #FFD24A, hpMult 3.0/dmgScale 0.6, coreShield 0.5) central; cores in ring | IN: commissioner_ready / back only | back pad→finals_2; spawn far W | commissioner_down (kill boss) → Championship Gold dye + 50 Pages + boss_time board; capstone world event (1800 s) | cover ring; championship_trophy + season_reward_vault (approved batch_007) + gold-tint ground | GY_SECRET (World.gd:213-226) |

### Slice plan
Every slice: author → `godot --headless --import` + SCRIPT ERROR grep → local server+client full portal round-trip walk (every new pad BOTH directions; drops >42 from reverse pad, >320 from camps) → adversarial review → release. Every slice touching shared/ ships server redeploy + client re-export in the SAME commit (docs/gameplay-length-handoff.md:75-80); before running droplet setup.sh, confirm the CI ghcr image built so the on-box OOM-prone fallback (Dockerfile:38-42, 1 GB droplet) never triggers. DEPLOY EVENT marked ▲.

S1 — "The Road Opens" (M, ~2 sessions) ▲shared+client
away_1 + away_2 (MAPS/SPAWN/PORTALS/MOBS/OBSTACLES keys), HOME "▶ Away Games" pad, `away_gate` arm in _portal_unlocked (NOT in HIDDEN_GATES), 3 new minion recolor defs (rally_cone/away_blocker/line_judge), _zone_name entries, "rival clay" procedural ground texture + `begins_with("away")` branch in _make_field_material, admin F1 goto buttons, smoke_prop_loads additions, AWAY_ORDER quests 1-4 (+ the never-gate-on-AWAY_ORDER rule documented in Quests.gd comment), token-prefix extension (owner decision), F4 decal pass, 2 daily bounty defs (server-only). SHIPPABLE STATE: 9-13 desert dead, directed; game coherent if Phase 8 stops here.

S2 — "Beat the Rival" (M, ~2 sessions) ▲shared+client
away_3 + away_boss, rival_coach boss def, boss-nameplate client fix (read def name, fallback to current strings — Client.gd:2290-2301), +40-Pages-on-kill server line, quests 5-7 incl. rival_down bridging into the existing Head Coach raid, "Rival Crimson" dye def, weekly bounty rival_slain, MEASURE: does the chain deliver IP800 by L16 (tune quest-item ilvls if not). SHIPPABLE STATE: full 9-16 band directed end-to-end into boss_ready.

S3 — "The Finals District" (M, ~1.5-2 sessions) ▲shared+client
finals_1 + finals_2, `finals_gate` arm, grand_gallery elite-plus def + cores, "championship court" ground texture (or zero-cost gold tint) + `begins_with("finals")` branch, quests 8-11, daily bounties, zone names/goto/smoke additions, F4 decals. MEASURE: real item_power at L22-24 to set commissioner_ready IP number. SHIPPABLE STATE: 17-25 covered.

S4 — "The Final Whistle" (S-M, ~1.5 sessions) ▲shared+client
finals_boss room, the_commissioner def, `commissioner_ready` arm, boss_time classId trigger extension + +50-Pages line (server), quest 12, "Championship Gold" dye, weekly bounty. PLAYTEST GATE: solo + 2 bots vs Commissioner (P7c ~48% HP, full damage) must be tight-but-winnable at gear; tune dmgScale/hpMult. SHIPPABLE STATE: complete 9-28 arc + capstone world event + seasonal-board hook. CORE DONE.

S5 — optional polish (S, ~1 session) ▲shared+client (or client-only if no PROP_FOOTPRINT rows)
Integrate approved batch_006/007 props (gltf-transform optimize pass per docs/props-textures-handoff.md §A.1, DECO_PROPS, PROP_FOOTPRINT for solids, smoke guard), decor v2 via F4, optional music drop-ins, optional 2-3 away residents (server-only RESIDENTS rows).

Between-slice lever: new bounty defs are server consts pushed via snapshot META (Server.gd:4307-4308) — direction can be re-aimed with a server-only redeploy, no release.

### Designer's risks
- Scope-goal mismatch: the lean cut (5 field zones + 2 boss rooms) optimizes desert-removal per session, not total geography. If the owner wants the brief's full 7-8-zone biome feel, this under-delivers — the extension pack is the hedge, but confirm the goal at sign-off.
- IP-800 bridge math is unverified: the whole chain funnels into the existing Head Coach raid at L16+IP800 (Server.gd:93-94); item_power = primary+affixes+ilvl per item (Server.gd:2505-2515) suggests away drops (ilvl 14-28) clear it, but it must be MEASURED in S2 — if it stalls, the shipped wall returns at the narrative midpoint. Quest epic-item ilvls are the tuning valve.
- Solo boss tuning above lvl 10 is uncharted: P7c locks HP to 30% solo but NEVER reduces damage (Server.gd:55-63); a lvl-27 boss's damage scale (~6.2x base before dmgScale) could be solo-unwinnable on a low-pop server that can't form parties. dmgScale 0.6 is an analogy to PRIME's 0.55, not a measurement — S4 has a hard playtest gate.
- Recolor fatigue: 6 new defs ride 4 existing silhouettes through a 0.45-alpha color overlay (Client.gd:2343-2355) that cannot change shape or add glow. The away-game fiction covers it narratively, but if the S2 eyeball test reads as 'same mobs again', the optional Meshy batch stops being optional.
- Circuit remains the max-XP/hr farm: instanced Camp Circuit is con-exempt with intensity reward multipliers (Server.gd:3661-3671), so the new zones win on direction/gear-ilvl/variety, not raw XP — if the owner expects open-world to become the optimal farm, that is an economy rebalance this design deliberately does not attempt.
- Population dilution + tick cost: +7 static worlds (14→21) in the 30 Hz loop and thinner visible population on an already low-pop server; lean zone count is the mitigation, and away-band residents (extension pack, RESIDENTS is GY-hardcoded at Server.gd:80-87 with lvl 5-10 bots too fragile for finals_*) are the follow-up if zones feel dead.
- Deploy cadence: 4-5 releases, each bumping project.godot, each exposing the droplet's on-box fallback build (OOM risk on 1 GB, Dockerfile:38-42) — discipline required: confirm the CI ghcr image exists before every setup.sh run, and keep shared/+client in the same commit (stale clients render new mob ids as gray capsules, commit 2b4f714).
- Quest-list governance: AWAY_ORDER grows across slices, which is only safe because nothing gates on its completion — if any future gate ever references it (the ORDER lesson, Quests.gd:18-21), mid-slice appends retroactively lock players out. The rule must be enforced in a code comment from S1.
- Owner sign-off unknowns: the jump/verticality §4 named-moment test (docs/jump-verticality-phase1-decision.md) is an owner question that could reshape zone layouts post-design, and the token-drop prefix extension (Server.gd:3495-3504) plus dye/board additions are owner-visible economy decisions flagged, not made.

### Full design doc

# Phase 8 — "The Away Circuit" (LEAN cut)

## 0. Thesis: the desert is one number, and 5 field zones kill it

The 10-28 desert has exactly two causes, both verified in code:

1. **The mob-level ceiling is 8** (drill_sergeant elite, World.gd:208; bosses lvl 8/10 at World.gd:211,219). Con-scaling (±4 grace, fade over 12 to a 40% floor, Server.gd:68-70, 3674-3683) makes everything above L12 progressively worse XP; the :70 comment itself says the floor exists "until Phase 8 adds 9-28 zones."
2. **The 9-16 band has zero acceptable quests.** The mid-spine's first quest `mid1_proving` has `prereq: "headcoach_down"` (Quests.gd:105), and killing the Head Coach requires the `boss_ready` gate — level 16 AND item_power 800 (Server.gd:93-94, 3401-3403). So from ~L9 (end of the GY chain) to L16 the quest log is empty and the only directive is "grind toward a gate."

The brief asks for ~7-8 zones (5-zone chain + 2-3 capstone). I'm arguing that is over-built for a solo dev on a live low-pop game. Con-grace is ±4 levels: a zone whose mobs are level L serves players L−4…L+4 at **full** XP. Coverage math:

- **away_1** (mobs 9-10) → full XP for players 5-14
- **away_2** (mobs 12-13) → players 8-17
- **away_3** (mobs 15-16) → players 11-20
- **finals_1** (mobs 19-21) → players 15-25
- **finals_2** (mobs 23-25) → players 19-29 (to cap)

**Five field zones cover 9→30 with double-overlap everywhere.** GY needed 5 zones for levels 1-8 because early levels are minutes long; at 2,700-7,800 XP/level (Server.gd:204-207) each Phase-8 zone hosts 2-3 levels of play anyway. The two extra chain zones in the brief add authoring, testing, deploy and *population-dilution* cost (7 more statics on a low-pop server already look empty) without adding coverage. What actually fixes the desert is **direction density** — quests and bounties per zone — which is cheap data (bounties are even zero-client-re-export, Server.gd:4306-4310). So: **5 field zones + 2 small boss rooms, maximum quest/bounty density, 3 new bosses from shipped primitives, everything recolor-reuse.** An extension pack (§8) lists exactly what to add if players eat it up.

## 1. Fiction: the Away Games — and why it makes reuse diegetic

The sports-fantasy "away game" hook is not just flavor, it is the **cover story for the recolor pipeline**: rival teams train on the *same equipment in their team colors*. A crimson tackle_brute isn't a palette-swap cop-out — it's the rival's linebacker sled. The shipped recolor mechanism (`recolor:true` + `color:"#hex"` via the dye channel, Client.gd:1428-1431, 2343-2379) becomes the faction system. Arc: your team goes on the road (away_1-3, rival practice fields → their stadium), beats **The Rival Coach**, returns home to settle the score with your own Head Coach (the existing L16+IP800 raid becomes the *narrative midpoint* instead of a wall), then enters **The Finals** (finals_1-2, a championship district) and faces **The Commissioner**. Every shipped system is recontextualized, none is modified.

## 2. Zones

See zone_table. Grammar is copied from the shipped chain (World.gd:168-208 comments): 4-6 camps/zone, >AGGRO_RANGE 320 apart, west→east gradient, elite(s) anchoring the far east by the forward pad, back pad x≈120 / forward pad x≈w−80, spawn far west (>42 from pads, >320 from camps), cover panels (barrier/rack/bag — PROP_DIM at World.gd:262-266) splitting lanes. Boss rooms clone GY_BOSS/GY_SECRET (small room, cover ring per World.gd:381-395, boss central, cores in a ring, spawn west beyond aggro, 1800 s respawn Server.gd:36).

Map ids share biome prefixes — `away_*` and `finals_*` — so the ground-theming branch (Client.gd:573-581) needs exactly two new `begins_with` arms.

**Mob roster: 6 new GameData defs, 0 new sim mechanics.** Levels are stamped by World.MOBS + `_scale_mob` (Server.gd:3596-3613), so 12 existing defs are reused directly at new levels for free — including the lightly-used ones the roster lane flagged (tackle_brute, sled_juggernaut, ball_machine, drill_sergeant, tire_dummy, whistle_cone, field_medic) and the instance-only elites getting an open-world debut (iron_sled, gatling_machine, blitz_captain). New defs (all `recolor:true`, proven mob ability types only — melee/dashAttack/meleeAoe/projectile/zone/selfbuff/summon/spread/campreset/allyheal per the roster lane):
- `rally_cone` — cone.glb, rival orange #FF7A1A; melee + dashAttack swarmer
- `away_blocker` — foam_dummy.glb, rival navy #2E4A8F; melee + knockback shove
- `line_judge` — shooting_dummy.glb, #3355FF; projectile + slow + reflect selfbuff
- `grand_gallery`, `rival_coach`, `the_commissioner` — see §3

## 3. Bosses (primitive combos only — menu numbers from the roster lane §(b))

**B1. THE RIVAL COACH** — lvl 16 boss, `away_boss` room. GLB: **head_coach.glb recolored crimson #C43C2E** (zero recolor variants exist of it today — the biggest untapped asset), h 4.8, anim "boss".
Primitives: **phased** (#1) + **threshSummon**{rally_cone×2} (#2) + **campreset ult @P3** with **coreCount 4** (#4+#5, power_core×4 lvl 12 ring) + **wallStun bait dash** (#8) + **pull 220** (#9) + **kbImmune** (#12) + **P7c auto-scaling** (#13, free for any phased def, Server.gd:3624-3658). No coreShield — this is the "entry raid" tier, deliberately a Head Coach difficulty clone one band up.
Gate in: none (walk-up from away_3; difficulty + P7c is the gate). Rewards: boss drops ilvl 28 (16+12, Server.gd:3869-3870), 15% unique (Server.gd:165), 60 tokens, credits ×4, **+40 Pages on kill** (new server line mirroring BOSS_PAGES at Server.gd:3511-3512), quest `rival_down` target, exclusive dye. 30-min world event (Server.gd:36).

**B2. THE GRAND GALLERY** — lvl 24 **elite-plus miniboss** (no room; far-east anchor of finals_2, guarding the finals_boss pad approach). GLB: **ball_machine.glb recolored gold #D4AF37**, h 4.5.
Primitives: **stationary** (#12) + **spread fan + ricochet bounces + wobble stacking** (#11) + **hazard zone** (#10) + **coreShield 0.35** (#6 — works without phased, Combat.gd:71-79) with 2 flanking power_cores lvl 20 + **hpMult 3.0 / dmgScale 0.9** (#7). Tier **elite** on purpose: 6-s respawn (Server.gd:35) makes it a farmable skill-check rather than a portal-blocking 30-min event — the Drill elite-plus recipe (Server.gd:1680-1711 precedent). Since it can't chase, the cores+cover make the fight (roster lane's own pairing note). Rewards: elite drops ilvl 29, quest `finals2_gallery` + daily-bounty target.

**B3. THE COMMISSIONER** — lvl 27 boss, `finals_boss` room. GLB: **boss2.glb recolored championship gold #FFD24A** (also zero variants today), h 6.0.
Primitives: **phased** + **coreCount 6 + coreShield 0.5** (power_core×6 lvl 22) + **threshSummon**{whistle_cone×3} + **totalreset-style arena ult @P2, cd 14** (recurring LOS check, the PRIME pattern GameData.gd:247-270) + **wallStun on two dashes** (#8) + **pull 260** (#9) + **kbImmune** + **hpMult 3.0 / dmgScale 0.6** (#7 — PRIME's 0.55 analogy; solo faces full damage under P7c so dmgScale is the solo-viability knob) + **P7c**. Gate in: `commissioner_ready` = level ≥ 24 AND item_power ≥ 1200 (tunable; visible-but-locked with explainer chat — the boss_ready UX, Server.gd:95-96, 3370-3374). Rewards: drops ilvl 39, 15% unique, **+50 Pages**, credits ×4, exclusive non-buyable "Championship Gold" dye via quest, and **posts to the seasonal boss_time board** — requires extending the `classId == "head_coach"` trigger at Server.gd:3511-3520 with `"the_commissioner"` (server-only; feeds the weekly Champion-dye loop for free).

Client prerequisite (S2): the boss nameplate hardcodes "☠ HEAD COACH" + its 4 phase names for ANY tier=="boss" (Client.gd:2290-2301) — change it to read the def's name (and an optional per-def phase-name array with the current strings as fallback). Small, generalizes to all future bosses.

## 4. Quest / bounty spine — what sends you, what you do, what sends you on

**New chain `AWAY_ORDER`** in Quests.gd — a third separate list per the MIDGAME precedent (Quests.gd:169-176; never touch ORDER, per the :18-21 warning) + concat into `display_order()` (:183-184). **Design rule, enforced from day 1: nothing may ever gate on AWAY_ORDER completion** — that is what makes per-slice appends safe. All quests use shipped kill-only objectives `{map, tier, class, min_level}` (Quests.gd:10-12, 190-203) at the existing HOME quest giver (World.gd:83-84) — **no new objective types, no second NPC** in the core. Phase-8 mob levels >8 also un-strand the `min_level` match field for future use (Quests.gd:98-99).

Chain (prereq-linked; XP/rewards tunable, sized to the GY-chain precedent where quest XP alone carries the band):
1. `away1_roadgame` (min 9, prereq "" — **standalone**, because everything chained off headcoach_down is L16-locked): kill 12 in away_1 → 700 xp, 900 cr. *Sent by:* the new HOME pad + giver. *Onward:* quest text names the elite.
2. `away1_blocker` (10): kill 1 elite in away_1 → 900 xp, rare item ilvl 15, 15 Pages.
3. `away2_gauntlet` (11): kill 15 in away_2 → 1,200 xp, 1,400 cr.
4. `away2_medics` (12): kill 2 `class=field_medic` in away_2 → 1,400 xp, 20 Pages. (Teaches kill-the-healer; farmable, 6-s respawn.)
5. `away3_stadium` (14): kill 18 in away_3 → 1,800 xp, 2,000 cr, **epic trinket ilvl 20** (the deliberate IP-800 push).
6. `away3_elites` (15): kill 2 elites in away_3 → 2,000 xp, 25 Pages.
7. `rival_down` (16): kill 1 boss in away_boss → 2,600 xp, 3,000 cr, epic ilvl 26, **"Rival Crimson" dye**, 30 Pages. Completion text: *"You beat their coach. Now go beat yours — the Arena is open."* → routes into the **existing** Head Coach raid, whose L16+IP800 gate the chain was tuned to deliver exactly.
8. `finals1_contenders` (18, prereq rival_down): kill 20 in finals_1 → 3,000 xp, 3,500 cr.
9. `finals1_machines` (20): kill 3 elites in finals_1 → 3,400 xp, 30 Pages.
10. `finals2_gate` (22): kill 20 in finals_2 → 4,200 xp, 4,000 cr, epic ilvl 30.
11. `finals2_gallery` (24): kill 1 `class=grand_gallery` → 4,800 xp, 35 Pages.
12. `commissioner_down` (26): kill 1 boss in finals_boss → 6,000 xp, 6,000 cr, **"Championship Gold" dye**, 50 Pages.

**Free synergy discovered in verification:** 6 of the 9 MIDGAME quests are map-agnostic (`{}` or tier-only matches — mid1/2/4/5/7/8, Quests.gd:107-160), so once a player clears Head Coach mid-arc, the shipped mid-spine auto-progresses **inside the new zones** with zero edits. The two chains braid instead of competing.

**Bounties** (server-only consts, ship with ZERO client re-export, Server.gd:4306-4310 — deployable even between slices): append to BOUNTY_DAILY — `away_patrol` (15 kills map away_2), `rival_elites` (3 elites map away_3), `finals_patrol` (15 kills map finals_1), `gallery_break` (1 `grand_gallery`); to BOUNTY_WEEKLY — `rival_slain` (1 boss map away_boss, ~220 Pages). The deterministic (id|period) rotation (Server.gd:4340-4352) then points every player's dailies at the new biome automatically.

**Practice Tokens decision (owner-visible):** token drops are gated on `begins_with("glitchyard")` (Server.gd:3495-3504). Recommend a one-line server-only extension to `away`/`finals` prefixes so the token vendor set stays relevant band-wide; keeping it GY-only is the alternative if GY relevance is preferred.

## 5. Gates (3 new ids, one match arm each in `_portal_unlocked`, Server.gd:3395-3404; none in HIDDEN_GATES — all visible-but-locked with the boss_ready explainer UX)

- `away_gate` (HOME→away_1): level ≥ 8. Stops fresh L3s wandering into lvl-10 camps; the GY chain relied on linearity for this, a hub-branch can't.
- `finals_gate` (HOME→finals_1): level ≥ 17 AND item_power ≥ 800 — i.e. "you cleared (or could clear) the Head Coach." Capstone branches off HOME, not off away_3, so L18+ players never re-walk the chain (and the mined lane's topology recommendation).
- `commissioner_ready` (finals_2→finals_boss): level ≥ 24 AND item_power ≥ 1200 (tunable — verify against real drop IP in S3 playtest; item_power = primary+affixes+ilvl per item, Server.gd:2505-2515).
Gate re-validation on login is automatic via `gate_for_map` (World.gd:413-418, Server.gd:2061-2069).

## 6. Rewards (all inside the no-new-stat-surfaces rule; P7a veto respected)

- **Gear ilvl bands, organically:** drop ilvl = mobLevel + (elite +5 / boss +12) (Server.gd:3869-3870) → away zones yield ilvl ~14-28, finals ~24-39, vs today's open-world cap of ~8/13/20. The biome gets a real gear identity vs crafting recipes (ilvl 12-30, GameData.gd:563-568) and SHOP_ILVL 8 with **zero new item mechanics**.
- **Pages:** boss chunks (40/50, BOSS_PAGES precedent Server.gd:3511-3512), quest chunks 15-50, bounty 25-260 — feeding the shipped Audible/Master-Key sinks.
- **Uniques:** existing 7-def pool via the 15% boss roll (Server.gd:165) — no new defs needed.
- **Dyes:** 2 new exclusive quest dyes (Rival Crimson, Championship Gold) — pure data, the azure/gold/obsidian precedent (Quests.gd:129,157,165).
- **Leaderboard:** Commissioner posts to seasonal boss_time (trigger extension) → weekly Champion dye loop covers the capstone for free.
- **Paragon:** finals_2/finals_boss remain full-XP con at L30 sources feeding Overtime overflow (Server.gd:3559-3563) automatically.
- **Credits/tokens:** standard kill formulas (Server.gd:2428-2435) + the token-prefix decision above. **No titles** (system doesn't exist), no sockets, no new currencies.

## 7. Explicit wiring bill (from the theming lane's checklist, all verified surfaces)

Per-release: MAPS/SPAWN/PORTALS/MOBS/OBSTACLES/DECALS keys (shared/World.gd); mob defs (shared/GameData.gd); quests (shared/Quests.gd); gate arms + Pages/boss_time/token lines + bounty defs (server/Server.gd); `_zone_name` entries (NetClient.gd:6411-6424); ground branch (Client.gd:573-581) + 1-2 procedural textures from tools/gen_ground_textures.py (self-authored, tileable, zero Meshy — per its docstring); admin F1 goto buttons (NetClient.gd:4834); smoke_prop_loads.gd texture/prop additions (tools/smoke_prop_loads.gd:8-12); boss nameplate def-name fix (Client.gd:2290-2301); data/decals/<zone>.json via F4 + PROP_FOOTPRINT rows for solid décor (World.gd:300-339). Minimap, leash/aggro/respawn, persistence, interest management, P7c: **zero work** (all data-driven per Server.gd:242-250, 449-466, 2113-2128).

**Residents:** core plan adds none — bonded GY residents already follow the leader into any non-instance zone (`_try_follow`, Server.gd:2377-2399), so companion support works day 1. Honest limitation: the roster is lvl 5-10 (Server.gd:80-87) and will be fragile in finals_*; away-band residents are extension-pack (§8).

## 8. Extension pack (only if players eat it up — each independently shippable later)

1. **away_2.5 + finals_1.5 field zones** — restores the brief's 7-8-zone density; pure World.gd data using the same roster.
2. **2-3 away residents** (lvl 14-24, RESIDENTS const + routes — server-only) to populate the band.
3. **"Away token vendor" set** — rookie_camp-precedent gear set (GameData.gd:555-557), same stat surface.
4. **A 4th Camp-Circuit template themed "Away Scrimmage"** — camp_d key + `INSTANCE_MAPS` + rotation entry; inherits Intensity/affix/con-exemption (the deliberate premium-farm lever, Server.gd:3668-3671).
5. **Music** — drop-in `audio/music/<zone>.ogg` files (AudioManager.gd:12,121-132), no code.
6. **The one Meshy batch** (§new_assets) if the biome needs a stronger silhouette identity.
7. **Rival Coach on boss_time** — add its classId to the trigger if a second seasonal board target is wanted.

## 9. Kill-reasons — what would make this design wrong

1. **If the owner's real goal is max content-hours, not desert-removal** — the lean cut optimizes playtime-per-authoring-session; a player who wants 8 distinct zones' worth of geography will finish this in fewer hours. The extension pack is the hedge, but if "big second biome" is the point, build the brief instead.
2. **If Circuit XP/hour dominance is unacceptable** — instanced Circuit stays con-exempt with intensity rewards (Server.gd:3661-3671); at high intensity it out-XPs any open-world zone. This design accepts that: the biome wins on *direction + gear ilvl + variety*, not raw XP/hr. If the owner wants open-world to be the optimal farm, that's an economy rebalance, not a zone count.
3. **If recolors read as cheap** — 6 new defs on 4 existing silhouettes; the 0.45-alpha overlay (Client.gd:2343-2355) can't change shapes. The away-game fiction covers this narratively, but if eyeball tests on relaunch say "same mobs again," the Meshy batch stops being optional.
4. **If the L16 Head-Coach bridge stalls** — the whole chain funnels into the shipped boss_ready raid; if away drops don't reliably deliver IP800 by L16 (unverified math, Server.gd:2505-2515), the midpoint becomes the old wall again. Must be measured in S2, with the epic-item quest rewards as the tuning valve.
5. **If solo boss tuning misses** — P7c cuts HP to 30% but never damage (Server.gd:55-63); lvl-27 boss damage is ~6.2× base scale before dmgScale. If dmgScale 0.6 still one-shots a solo L26, the capstone is party-locked on a game whose population can't form parties. Playtest gate in S4.
6. **If population dilution hurts more than the desert** — 7 more static worlds on a low-pop server (14→21) spreads visible players thinner. The lean count is itself the mitigation; if even 7 feels empty, prefer extension-pack item 2 (residents) before more zones.
