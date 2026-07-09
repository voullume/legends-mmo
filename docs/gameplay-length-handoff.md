# Gameplay-Length Expansion — Guided Handoff

**Created:** 2026-07-09 · **Status:** APPROVED, not started (Phase 1 is the next session) ·
**Predecessor state:** all systems through the Glitchyard endgame program, item roadmap, AI residents,
Builder Mode, UI overhaul, and combat-feel pass are **shipped + live** (droplet `159.89.132.86`, image on
commit `e16cd41`). This effort is the next work-stream: **make the game last longer to play.**

> This handoff was produced from a full parallel audit of progression, content, endgame, and the reward
> loop (4 subsystem mappers → 3 design strategies → 1 synthesis). Every claim below is cited to
> `file:line` and was spot-verified against live code on 2026-07-09.

---

## 1. The diagnosis — one line

**The game runs out of _character_ long before it runs out of _hours_.**

Nearly every *system* an MMO needs is already shipped (Intensity ladder, 7-phase item treadmill,
leaderboards, Pages/Master-Key attunement, AI residents, cosmetics). What is starved is **character
growth, content variety, and renewability.** Concretely:

| Bottleneck | Evidence |
|---|---|
| **The build is COMPLETE at level 1.** The whole 1→30 climb adds **only +1,740 max HP** — no new abilities, no stat points, no talents, no choices. | `create_fighter` zeroes cooldowns for **all** abilities at creation (`shared/GameData.gd:431`); `derive()` never reads level (`shared/GameData.gd:405` — verified no `level` ref in body); `_recompute_player_stats` applies level to maxHP alone, +60/level (`server/Server.gd:53`, cap 30 at `:54`). |
| **Content ends at ~level 8 = 8% of the XP bar.** The 9-quest Glitchyard chain (last quest min_level 7) is the only authored progression. Levels ~10→30 (~80k of 86,274 XP) are **questless grind**. | `shared/Quests.gd:17-93` (9-quest linear chain); XP curve `_xp_to_next=100·L·(1+0.05L)` at `server/Server.gd:171`. |
| **One biome, 8 fightable mob types, 2 bosses.** No new enemy is introduced past GY5's level-8 elites; levels 9-30 + all endgame reuse the same roster scaled by Intensity. | `shared/World.gd:52-228` (9 static maps, ~24 open-world spawns); `shared/GameData.gd:136-279` (10 mob defs; 8 combat archetypes). |
| **XP has no level-difference scaling → the GY5 funnel.** A level-1 mob yields the same 15 XP to a level-29 player, so all mid/late farming funnels onto GY5's 5 mobs + the Circuit. | `_mob_xp = MOB_XP_BASE·lvl·mult·intensity` reads the **mob's** level only (`server/Server.gd:2669-2673`); `_award_xp(credit_pid,…)` credits a **single** killer (`:2580`) — parties don't share XP; the Two-Minute Drill grants **0** XP (`:1099`). |
| **The gear chase dead-ends at the balance wall.** Full epic already reaches `EQUIP_STAT_CAP=60`/stat, so legendary/mythic/upgrades past that add **only a leaderboard number**, not power. | aggregate cap in `_apply_equipment` (`server/Server.gd:2916-3020`, cap const `:129`). |
| **The one endless loop is a single reused room.** The flagship Camp Circuit is numerically infinite but experientially identical — the planned multi-room run was never built. | `shared/World.gd:62` literally: *"P0 = a single proving room; P1 expands it into the condensed multi-room Circuit."* |
| **Nothing renews.** 9 one-time quests, a one-time 300-Page Master Key (Pages then dead currency), XP parked-and-discarded at cap, leaderboards that never reset. | `server/Server.gd:516` (Master Key), `:2617-2618` (parked XP), `:1181-1197` (3 personal-best boards, no seasons). |

**Estimated current first-playthrough length:** ~1-2 h guided campaign, ~6-8 h to exhaust all authored
content + the chase to the secret boss, then open-ended-but-repetitive Intensity/gear grind.

---

## 2. Locked decisions (owner-approved 2026-07-09)

1. **Direction: vertical depth first.** Fix the "build complete at level 1" flaw before adding breadth —
   it multiplies the value of all existing *and* future content.
2. **Kit pacing: AGGRESSIVE — basic attack only at level 1.** Gate every special + ult behind levels.
   Mitigations baked into Phase 2: **first special unlocks at level 2** (barren window = one level only),
   and **existing characters auto-unlock retroactively** so no live player loses access. The early-game
   feel is the #1 playtest risk — tune the low unlock bands hard.
3. **Talent power: hybrid.** Talent trees carry **real combat power** (symmetric per-class budgets +
   mandatory AI-duel harness re-run); the post-cap **paragon** track stays **QoL/cosmetic** (zero balance
   risk) in v1.
4. **Heavy tail: renewability + endgame-depth first, second biome is the capstone (last).** Re-monetize
   shipped content before authoring a new biome.

---

## 3. Guardrails (non-negotiable — every phase respects these)

- **Server-authoritative + dupe-safe.** Every new mutating RPC (talent-spend, respec, socket/gem forge,
  bounty turn-in, daily reset, paragon spend) **must** own its lock pair *before any `await`*, deduct
  before write, and persist via atomic security-definer fns mirroring `progression_add_pages`/`craft_key`.
  *(The 2026-07-01 security audit caught a sell-dupe money-printer from omitting exactly this.)*
- **Determinism.** Keep new systems **out of the mulberry32 sim.** Ability-gating lives in the intent
  layer (`submit_ability`, `server/Server.gd:2234`), never the sim. Talents/paragon/gems feed the
  `_recompute_player_stats` `bonus` funnel (`server/Server.gd:3022-3045`), not new combat code. Verify
  byte-identical Sim output when a feature is inactive.
- **Balance is measured, not guessed.** Any change that raises player power (talents, gems, power-paragon)
  re-runs the `FORMAT_MODS[5]` AI-duel round-robin (`create_fighter` + `Sim.sim_tick`, force
  `team_size=5`) and must hold the ~50% class win-rate spread.
- **`EQUIP_STAT_CAP=60` is the balance chokepoint.** Gems/sockets/any new stat source route through
  `_apply_equipment`'s aggregate cap. Set bonuses stay the only sanctioned above-cap stack.
- **Minimal `shared/` combat churn.** New mobs/bosses/zones reuse existing ability **types** + recolored
  GLBs (no new sim RNG; the Meshy character re-rig is a proven dead-end). The **only** sanctioned combat
  edit in the whole plan is the new proc triggers (Phase 7): deterministic-hash, `PROC_DPS_CAP`-bounded,
  verified byte-identical when no proc is equipped. **No player-to-player trading** (dupe surface).
- **Deploy discipline.** Any `shared/` edit ships a **server redeploy AND a client re-export in the same
  commit** — the client renders zones/geometry/mobs from its own copy, so divergence desyncs
  walls/decals/spawns. Watch the 1 GB-droplet import-cache OOM when `project.godot` changes (swapfile is
  in place). Verify each deploy via a real client connect, not just a build. **Phases 1, 5, 6 are
  server-only** (no client re-export). Phases 2-4, 7-8 touch `shared/` and/or the client.

---

## 4. The roadmap (8 phases)

Effort: S/M/L/XL. Payoff = effect on gameplay length. Phases 1-6 front-load the highest length-per-effort
with the least risk; 7-8 are the heavy net-new content, gated behind the systems that make them worth
playing.

### Phase 1 — XP-economy foundation · **M · server-only · zero sim risk** — *START HERE*
Retune the reward layer so every zone and mode is a viable farm and the curve is ready for the deeper
systems.
- **(a)** Con / level-difference multiplier in `_mob_xp`: full value within ±4 levels of the killer, decaying
  toward a 40% floor for mobs far from your level in **either** direction (anti-trivial-farm *and* anti-free-carry;
  the symmetric form also bounds party-share power-leveling) — **open-world only**; instanced Circuit runs (any
  tier) keep full XP. Un-funnels all 5 zones.
- **(b)** Share/tag XP to same-zone party members on a credited kill (`:2580`, mirroring how loot already
  distributes at `:2583`) — grouping accelerates leveling instead of being XP-neutral.
- **(c)** Capped end-of-run XP payout for the Two-Minute Drill (`_end_drill` ~`:1150`; isDrill zeroes XP
  today at `:1099`) — the most replayable loop finally feeds the level bar.
- **(d)** Rested-XP bucket (accrues logged-out, spends ×1.5) via a new dupe-safe security-definer
  progression fn — a return hook.
- **(e)** Pre-reshape `_xp_to_next` (`:171`) for the incoming per-level payoffs.
- **Done when:** all 5 zones + the Drill are worth farming at every level band; a duo levels faster than
  two solos; balance harness untouched (no `shared/`/Sim change). **Playtest-tune 1→30 pacing before
  Phase 2 lands on top.**

### Phase 2 — Level-gated ability kits (the kit *assembles*) · **L · shared/ + client** — *the flagship*
Add `unlock_level` to each ability in `GameData.CLASSES`; enforce server-side in the intent layer — reject
a still-locked key in `submit_ability` (`server/Server.gd:2234`), gray locked keys on the client hotbar.
- **Aggressive gating (locked decision):** basic attack only at level 1; **first special at level 2**;
  drip the rest of the specials + ult across levels ~2→18. **Retroactively auto-unlock** for characters
  already past a band so no live player loses access.
- **Why balance-safe:** the gate is intent-acceptance, and the AI-duel harness builds fighters via
  `create_fighter` + `Sim.sim_tick` and **never calls `submit_ability`** → determinism + the ~50% spread
  stay byte-identical.
- **Risk:** early-game feel (basic-only L1). Keep the L1→L2 window tight and juicy; lean on the shipped
  combat-feel work. Full playtest + adversarial review before shipping.
- **Done when:** every early level delivers a new tool; a fresh character feels a steady drip 1→18;
  `bal_identity` byte-identical.

### Phase 3 — Roster remix + multi-room Camp Circuit · **L · shared/ + client · content ROI**
- **(a)** ~10 new mob defs in `GameData.CLASSES` reusing existing GLBs/recolors + **existing ability types
  only** (no new sim RNG), seeded into GY3-5 and the Drill pool (`:1105`).
- **(b)** Expand the single-room `CAMP` template (`shared/World.gd:62-63,215-227`) into a 3-5-room
  condensed run, selected per-run, with a rotating **weekly affix** riding the mob-only `_scale_mob` lever
  (`:2651`) beside the existing `intensity` field. `_spawn_instance_actors` already iterates
  `World.MOBS[tmpl]` generically (`:534`) → new templates just work.
- **Done when:** the Intensity treadmill has real content variety + a weekly-refreshed modifier; every
  existing zone feels fuller; `bal_identity` byte-identical (affix is mob-only). This finally ships the
  endgame P1 that `World.gd:62` promised.

### Phase 4 — Talent / mastery trees (the build you *choose*) · **XL · shared/ + client + DB** — *deepest fix*
Grant a talent point per level into a per-class tree (a new declarative `GameData` dict in the
`SET_DEFS`/`PROC_CATALOG` style). Bounded, class-symmetric budgets feed the existing
`_recompute_player_stats` `bonus` funnel (`server/Server.gd:3022-3045`) — no new combat code. Persist via a
new atomic security-definer spend RPC (rate-limited + serialized); add a credits/Pages **respec** sink.
- **Hybrid power (locked):** talents carry real power under symmetric budgets → **must re-run the
  `FORMAT_MODS[5]` harness** with a representative allocation (higher absolute PvE power is fine; only the
  relative ~50% spread must hold). Keep per-point deltas small, total budget bounded with an
  `EQUIP_STAT_CAP`-style ceiling.
- **Done when:** the 1→30 climb assembles a *chosen* build; 8 classes × build variety gives genuine
  alt-replay over the same world; harness confirms parity.

### Phase 5 — Paragon + repeatable Pages sink (nothing dead-ends) · **M · server + DB**
- **(a)** Redirect XP that parks-and-discards at cap (`:2617-2618`) into open-ended **paragon** points
  (atomic progression fn). **QoL/cosmetic only in v1** (locked) → zero balance risk.
- **(b)** Repeatable **Pages** sinks so Pages stop dying after the one-time Master Key (`:516`): fund
  talent respecs (Phase 4), multi-rank attunement, cosmetic dyes.
- **Done when:** the kill-XP loop and Pages currency stay meaningful forever.

### Phase 6 — Bounty Board + mid-level quest spine · **L · server + DB · daily return**
- **(a)** A repeatable daily/weekly **Bounty Board** (2nd home NPC) on the already-generic
  `Quests.kill_matches` matcher (`shared/Quests.gd:102-115`): rotating "clear Circuit I-N / reach Drill
  wave-N / kill N GY5 elites" objectives that reset on a UTC boundary, paying shipped currencies.
- **(b)** Fill the level ~10→30 questless desert with a mid-level chain rewarding talent respecs, gems,
  tokens, and attunement ranks.
- **Risk:** the repeatable reset is the only novel dupe-surface — reuse the audit-hardened rewarded-flag +
  own-lock-before-await pattern (`server/Server.gd:3178-3186`).
- **Done when:** there's a daily reason to log in and the 93% questless stretch has directed play.

### Phase 7 — Endgame build-depth + seasons · **XL · shared/ + server + DB · long-tail retention**
*(Renewability-first: this lands before the biome.)*
- **(a)** Ship the deferred item **P4d** — sockets + gems that **share** the `EQUIP_STAT_CAP` pool
  (`docs/item-system-handoff.md §4d`) — so gear becomes a build-collection hunt past the stat-cap wall.
- **(b)** Implement the reserved `on_kill`/`on_lowhp` proc triggers + more uniques/procs/sets
  (`shared/GameData.gd:354-376`). **This is the ONLY sanctioned `shared/Combat.gd` change** — scope
  tightly, deterministic-hash, `PROC_DPS_CAP`-bounded, verify byte-identical when no proc equipped.
- **(c)** Per-party-size boss HP scaling + 1-2 rotating world bosses via `_scale_mob` (`:2651`) → ends the
  2-boss ceiling; solo/duo (aided by AI residents) can engage.
- **(d)** Leaderboard **seasons** with resets + season-exclusive cosmetics (migration `20260702210000`);
  open the Drill to parties; wire the two skipped clear-time boards.
- **Done when:** gear has a summit past the cap, bosses are a rotation, and competition renews seasonally.

### Phase 8 — The Away Circuit: second biome + capstone region + new bosses · **XL · shared/ + client · the capstone**
Author the locked "two new zones" via the code-as-maps toolkit (`docs/map-authoring-guide.md`; server
auto-boots from each `MAPS` key at `:196-200`): a 5-zone chain for the empty ~9-16 band branched off the
Home hub, plus a 2-3-zone capstone region (~18-28), populated by the Phase-3 remix roster and capped by
NEW gated/rotating bosses reusing the phased/coreShield/summon primitives (`GameData.gd:214-270`) on
recolored existing boss GLBs.
- **Deploy discipline is heaviest here:** `shared/` + client re-export in the same commit; watch the
  droplet import-cache OOM on `project.godot` change; test full portal round-trips locally.
- **Done when:** the questless ~10-28 desert is directed play across ~7-8 new zones, sequenced *after* the
  vertical systems so leveling there is meaningful, not speed-run on a finished build.

---

## 5. First session — exact starting task

**Phase 1a-c in `server/Server.gd` (pure reward-math, no `shared/` or Sim change, no client re-export):**

1. **`_mob_xp`:** add a symmetric con/level-difference multiplier (full within ±4 levels, decaying to a 40%
   floor either way; open-world only, Circuit instances exempt) — un-funnels all 5 zones.
2. **Kill credit (`:2580`):** share/tag XP to same-zone party members on a credited kill, mirroring how
   loot already distributes at `:2583`.
3. **Two-Minute Drill (`_end_drill` ~`:1150`):** capped end-of-run XP payout (isDrill zeroes XP today
   at `:1099`).

Then add the rested-XP bucket (Phase 1d) via a new dupe-safe security-definer progression fn, and
**playtest-tune the 1→30 pacing before layering Phase 2's ability-gating on top.**

Because Phase 1 is server-only: after the change, `git push` → redeploy the droplet
(`curl -fsSL …/deploy/setup.sh | sudo -E bash`) → verify with a real client connect. No client re-export.

---

## 6. Housekeeping surfaced by the audit (not blocking, worth doing)

- **`CLAUDE.md:29-32` "▶ Next up" is STALE** — it lists PvP / zones / quests / bosses as unbuilt, but all
  shipped. Update it to point here.
- **Party want/need/pass loot (`git 431cb3b`) is undocumented** and absent from the memory index — its
  "hard drop-rate cut" directly lengthens the gear grind; document it and factor it into any drop-economy
  retune (Phases 6-7).
- **Standing open item:** Head Coach PRIME fight-length is still untuned (per `legends-mmo-glitchyard-plan`
  memory) and bosses are fixed-5-tuned — resolve both when Phase 7c adds per-party-size boss scaling.

---

## 7. Appendix — per-subsystem opportunity ledger (for reference)

**Progression:** con-scaled XP · party XP · Drill XP · level-gated abilities · talent trees · paragon ·
rested XP. **Content:** remix roster (break the 8-mob ceiling) · multi-room Circuit · second biome ·
capstone region · more bosses · 3-act quest spine · idle authored PvP venues
(rooftop/centerfield/sandcourt/trenches, `GameData.gd:312-324`) as rotating Arena maps. **Endgame:**
weekly Circuit affixes · daily/weekly bounties · leaderboard seasons · Pages second-chase ·
sockets/gems · boss rotation + per-party scaling · party Drill + missing clear-time boards. **Reward/
social:** grow the tiny chase pool (3 uniques / 3 procs / 5 sets / 8 dyes) · achievements/collections/
titles/bestiary · transmog (rides the equip pipeline) · more cosmetics as the balance-safe infinite chase.
