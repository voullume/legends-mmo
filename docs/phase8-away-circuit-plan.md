# Phase 8 — The Away Circuit: APPROVED PLAN

**Date:** 2026-07-14 · **Status: APPROVED by the owner — Slice 1 in progress.** This is the synthesis of
three judged designs (`docs/phase8-designs-archive.md`, all 8/10; lean backbone + steals from the other
two). Implementation reference with file:line citations: `docs/phase8-system-reference.md`. Predecessor:
gameplay-length Phases 1–7 + Difficulty Pass shipped; v1.1.1 live.

## Owner decisions (recorded 2026-07-14)
1. **Shape:** lean 7-zone plan (5 field zones + 2 boss arenas, ~8–10 sessions). The 8–9-zone variants
   stay archived as the extension pack.
2. **Jump gate:** the verticality §4 *named-moment test* was run — answer **NO**. Phase 8 ships flat-2D
   everywhere; the gate STAYS CLOSED (recorded in `docs/jump-verticality-phase1-decision.md`).
3. **Economy:** **YES** — extend Practice-Token drops to the new bands + an "Away Set" token-vendor line
   (existing stat surfaces only; P7a sockets/gems remains owner-vetoed).
4. **Loot curve:** gear inversion **accepted** — new zones carry the ilvl curve; the GY raid keeps its
   skill-gate/Pages/attunement/prestige role. No re-leveling of shipped bosses.

## The zones

| Zone id — name | Theme | Mob lvls | Size | Camps / elites | Gates |
|---|---|---|---|---|---|
| `away_1` — **Rival Practice Field** | first away game, ballpark-flavored | 9-10 | 1700×950 | rally_cone(NEW) 9 ×2, foam_dummy 9, tire_dummy 10; elite tackle_brute 10 E | IN `away_gate` (lvl≥8, visible-locked) from a new HOME pad "▶ Away Games" |
| `away_2` — **Visitors' Gauntlet** | hostile drills, winter-gridiron dressing | 12-13 | 1850×1000 | away_blocker(NEW) 12 ×2, whistle_cone 12, line_judge(NEW) 13; elites sled_juggernaut 13 mid + field_medic 12 (healer-camp lesson) | — |
| `away_3` — **Rival Stadium** | the rival's home floor | 15-16 | 2000×1100 | rally_cone 15, away_blocker 15, spring_cone 15; elites ball_machine 15 + drill_sergeant 16 at the boss door | — |
| `away_boss` — **Rival Sideline** | boss arena | boss 16, cores 12 | 1240×820 | **THE RIVAL COACH** — head_coach.glb recolor #C43C2E; phased + threshSummon + hazard + coreShield/4 cores, **NO campreset ult** (the teaching subset — one primitive tier below the real raid) | back only |
| `finals_1` — **Contenders' Quarter** | championship city district | 19-21 | 1900×1040 | pop_dummy 19 ×2, chalk_liner 20, whistle_cone 20; elites iron_sled 20 + gatling_machine 21 | IN `finals_gate` (**lvl≥17 AND IP≥800 — deliberately NOT the raid kill**, so a stalled raid never blocks the capstone) from a 2nd HOME pad "▶ The Finals" |
| `finals_2` — **Champions' Gate** | gate district | 23-25 | 2000×1100 | away_blocker 23, spring_cone 23, line_judge 24; elites blitz_captain 24 + field_medic 23; **GRAND GALLERY** elite-plus (ball_machine #D4AF37, hpMult 3.0, coreShield 0.35 + 2 cores, elite 6-s respawn → a *farmable* skill-check, not a world-event) | OUT `commissioner_ready` (lvl≥24 AND IP≥1200, visible-locked) |
| `finals_boss` — **The Commissioner's Box** | the final | boss 27, cores 22 | 1440×940 | **THE COMMISSIONER** — boss2.glb recolor #FFD24A gold, h-scale delta; FULL menu: phased + threshSummon + campreset + coreShield 0.5 / 6 cores + cover-RING obstacles (GY_SECRET pattern); hpMult 3.0 / dmgScale ~0.6 (S4 playtest gate) | IN `commissioner_ready`; back only |

Boss escalation by primitive subset (judge-endorsed): Rival Coach (cores, no ult) → *existing* Head Coach
raid (adds the LOS ult dance) → Commissioner (full menu at scale). GY grammar throughout: camps >320
apart, west→east gradient, elites east, portal drops >42 from reverse pads / >320 from camps.

## Directed play
- **AWAY_ORDER** (7 quests) + **FINALS_ORDER** (5) — first away quest has **`prereq: ""`** (the one-line
  fix: today every mid-game quest chains off `headcoach_down`, which is L16+IP800-locked — hence the
  desert). `rival_down`'s completion text routes players into the existing Head Coach raid gate.
  **Governance rule (comment in Quests.gd from S1): nothing may ever gate on AWAY/FINALS_ORDER
  completion** — keeps per-slice quest appends retroactively safe.
- **Bounties**: daily/weekly rows per zone — server consts pushed via snapshot META = re-aimable with a
  server-only redeploy, zero client re-export.
- **Rewards**: credits, gear (ilvl 14–28 band), Pages hooks (Rival +40, Commissioner +50), Practice
  Tokens (extended prefix) + "Away Set" vendor line, 2 exclusive quest dyes (Rival Crimson, Championship
  Gold — kept OUT of DYE_IDS, quest-granted), `boss_time` leaderboard id for the Commissioner (own
  category — never mixed onto the head_coach board).
- 6 of 9 shipped MIDGAME quests are map-agnostic and auto-progress in the new zones — free density.

## Judge-mandated hardening (deliverables, not suggestions)
1. **Client boss chrome (S2):** generalize the boss nameplate (hardcodes "☠ HEAD COACH" + its phase
   names for ANY tier=boss, Client.gd ~2290-2301) **and** the ult-warning string (hardcodes "⚠ FULL CAMP
   RESET", Client.gd ~2344-2347) to read per-def strings with byte-identical GY fallbacks.
2. **Gate explainer (S1):** the sealed-pad chat prompt is hardcoded to `gate=="boss_ready"`
   (Server.gd ~3371-3374) — generalize so `away_gate`/`finals_gate`/`commissioner_ready` explain
   themselves.
3. **Numeric passes are merge gates:** S1 = computed XP-band sum (headless; the real curve is
   `_xp_to_next = 50L + 7.5L²` — the lean doc misquoted it); S2 = equip-real-drops **IP800 measurement**
   (quest-item defs MUST set explicit ilvl/item_power — `_grant_quest_item` normalizes legacy-shaped
   items to ~IP 27); S3 = measured IP at L22-24 → set the `commissioner_ready` IP number; S4 = solo+2-
   residents Commissioner playtest (P7c scales HP only, never damage — dmgScale is the solo knob).
4. **No dangling pads:** each slice withholds its forward pad until the destination zone ships.
5. **Droplet capacity check (after S1 deploy):** compare `[health]` peak_tick/RSS before/after adding
   the always-on worlds (every static MAPS key sims at 30 Hz).
6. **Rival Coach respawn (S2 decision):** 1800-s world-event respawn on a leveling-chain quest boss
   risks contention; decide per-def respawn override (~600 s) vs precedent after local playtest.
7. **Recolor readability eyeball (end of S2):** if venues/bosses read as palette swaps, trigger the
   owner-approval decision on ONE small Meshy batch (rival banners, away scoreboard, landmark) — until
   then, zero Meshy spend.

## Slices (each independently shippable; 🔴 = shared/+client SAME COMMIT + confirm CI ghcr image before droplet setup.sh)
- **S1 — "The Road Opens" (M, ~2 sessions)** 🔴 — ✅ **SHIPPED v1.2.0 (2026-07-14, `a008fa7`)**. All planned
  content + 13 adversarial-review fixes, notably: **interior chain pads carry the gate** (a tampered
  `last_map` restore bypassed the level-8 gate — new S2 rule: every deeper pad carries its chain's gate);
  **mob support made camp-local** (≤320; players exempt — bal_identity byte-identical before AND after);
  data-driven `smoke_prop_loads`; `stab_away` (48 asserts) in CI. XP numeric pass: directed path ≈ sane
  coverage of the 8→13 band, away_1 hands off inside away_2's con grace. **⚠ CAPACITY WATCH-ITEM:** idle
  `peak_tick` rose from ~21-24ms (9 zones) to ~37-65ms spikes (11 zones) while load/RSS stayed flat
  (0.2/197MB) — watch the `[health]` line with players on; if peaks stay >33ms, consider a vCPU bump or
  zone sharding BEFORE S3/S4 add three more worlds. *(Forward pad to away_3 withheld — ships in S2.)*
- **S2 — "Beat the Rival" (M, ~2 sessions)** 🔴 away_3 + away_boss, rival_coach def, boss-chrome client
  generalizations, quests 5–7 (`rival_down` → raid bridge), Rival Crimson dye (exclusivity wiring),
  +40-Pages hook, weekly bounty, IP800 measurement, respawn + readability decisions.
- **S3 — "The Finals District" (M, ~1.5-2)** 🔴 finals_1 + finals_2, `finals_gate` arm, grand_gallery
  elite-plus, championship-court ground (or gold-tint fallback), quests 8–11, bounties, IP@22-24 pass.
- **S4 — "The Final Whistle" (S-M, ~1.5)** 🔴 finals_boss + the_commissioner def, `commissioner_ready`
  arm, quest 12, Championship Gold dye, +50 Pages, boss_time category, **solo-viability playtest gate**.
- **S5 — optional polish (S, ~1)** batch_006/007 prop integration (optimize pass), decor v2, away-band
  residents, music drop-ins.

## Standing risks (accepted at sign-off)
Circuit stays the max-XP/hr farm (new zones win on direction/gear/variety — by design, not competing);
population spreads across +7 static worlds (lean count + residents mitigate); recolor fatigue (S2
eyeball is the kill-gate); 5 shared-heavy deploy events (slice-sized releases + CI-image-first
discipline); kill-only quests (the only shipped objective type — a "visit" objective is a flagged
future owner call, NOT in scope).
