# The Official Maps — building the first real world

**Status:** plan agreed with the owner 2026-08-03. Nothing built. This doc is the source of truth
for the workstream; each phase below stops for owner approval the way the world-expansion phases did.

Companion docs: `docs/world-expansion-handoff-v2.md` (the zone-design grammar this builds on),
`docs/world-expansion-p2-report.md` (what P1–P5 actually shipped), `docs/APPROVAL_QUEUE.md`.

---

## 1. The problem, measured

The owner's report: *"the sense of exploration is about 0… it still feels like you're stuck in a box."*
That is measurable, not vibes. With `FOV 60°` and `SCALE 0.05` (1 world unit = 20 sim units):

| Zoom | Visible ground span |
|---|---|
| Default (`_dist` ≈ 26 wu) | ~600–900 su |
| Max (`DIST_MAX` 70 wu) | **~1600 su** |

Against the shipped zones:

| | Width | Depth (`h`) |
|---|---|---|
| Typical zone | 1500–2000 | **820–1100** |
| Largest (away_1) | 2600 | **950** |

**Every zone in the game is shallower than a single camera view.** At default zoom you can nearly see
from your position to both the north and south walls; at max zoom you can see the entire depth of
every zone and most of its width. There is no "over there". Props inside a 950-deep rectangle cannot
fix that.

Three compounding causes:

1. **Depth, not width.** Zones grew wide (away_1 at 2600) and stayed ~1000 deep. Wide + shallow = a
   corridor. away_1's width is why it is the best zone in the game; its depth is why it still reads flat.
2. **Linear topology.** gy1→gy2→gy3→gy4→gy5→boss. One way forward, one back. A corridor cannot feel
   exploratory at any size, because there are no choices.
3. **Nothing is hidden.** Sight lines run wall to wall. Exploration requires occlusion.

**The enabling change is already shipped.** The empty-zone sleep (v1.15.0) means static zones with no
players skip their entire tick — measured `avg 0.1 ms` against a 33 ms budget with 18 zones asleep.
Zones are effectively free at rest, so the world can grow to 40+ zones without idle cost. This plan is
how that capacity gets spent.

---

## 2. Progression model (decided — Option A)

```
Home base
  └─ Glitchyard  ........ L1–5    TUTORIAL (reuses existing geometry)
       └─ Locale 1 ...... L5–12   ┐
            └─ Locale 2 . L12–19  ├─ THE OFFICIAL REGION (new)
                 └─ Loc 3 L19–25  ┘
                      └─ Wildlife Expanse ... L25–40  (existing content, re-levelled)
                           └─ Finals + beyond .... L40+
```

- The official region is **the only route onward from the main base**. The Home → "▶ Wildlife
  Expanse" pad is removed; `wild_gate` **moves to the far end of Locale 3**.
- **Level cap 30 → 50**, raised once Locale 1 + the tutorial are done.
- **40→50 is deliberately a prestige band** — slow by design, so being max level means something and
  reads as a race among the most dedicated.

### AI residents as pace-setters
The owner wants the 11 AI residents to **progress over time** so a solo player has someone to race.
Today their levels are fixed constants (`RESIDENTS` in `server/Server.gd`); progression is a new feature.

⚠ **Critical design constraint:** the empty-zone sleep freezes residents whenever no real player is in
their zone. So resident progression **must be wall-clock based, not tick based** — otherwise it stops
entirely whenever nobody is playing, which is exactly when the race fiction matters most. Persist a
"last progressed at" timestamp and advance on login/heartbeat, never in `_tick_world`.

Secondary rules: residents must not consume loot, credits or leaderboard rewards that would otherwise
reach players, and their pace should be tunable per-resident so some are ahead and some behind.

---

## 3. The XP curve — analysed now, DEFERRED by owner decision

Current: `_xp_to_next(level) = 50·level + 7.5·level²` (`server/Server.gd`), tuned for cap 30.
Extended to cap 50 unchanged, the bands fall out like this:

| Band | XP on the current curve | Share of 1→50 |
|---|---|---|
| 1→5 tutorial | 724 | 0.2% |
| 5→25 **official region (3 new locales)** | 51,020 | **14.0%** |
| 25→40 wildlife (existing content) | 141,296 | **38.8%** |
| 40→50 prestige | 171,385 | 47.0% |
| **Total 1→50** | **364,425** | — |
| *(today's entire game, 1→30)* | *85,905* | — |

Two conclusions:

1. **The top end already behaves as the owner wants.** 40→50 is 47% of the whole climb on the current
   shape. The prestige band needs no special mechanism — the quadratic does it.
2. **The middle is inverted.** The biggest content investment in this plan — three brand-new locales
   spanning twenty levels — would earn **14%** of the XP, while the existing wildlife content earns
   **39%**. Players would blow through the new region and then wall hard on old content.

### ⚠ OWNER DECISION (2026-08-03): defer the curve work

My original recommendation was to reshape the curve first, so content is never tuned twice. **The
owner overruled that, and the reasoning is better:**

> *"that curve isn't intense enough, but that actual curve would be better to be adjusted later on
> when more of the game is fleshed out and the grind wouldn't be dead boring"*

You cannot tune a curve well against a spreadsheet. A steep curve laid over content that does not yet
exist produces exactly the failure it is meant to prevent — a long grind through too little material.
Tuning against a real, walkable Locale 1 beats tuning against arithmetic, and it dodges the
"tune twice" problem from the other direction: **don't tune at all until there is something to tune.**

**Therefore:**
- The curve reshape, the cap raise to 50, and the world re-level are **one combined tuning pass**,
  scheduled after Locale 1 and the tutorial exist (Phase 5 below).
- Locale 1 is built against **provisional levels (L5–12)**. This is cheap to change later: mob levels
  live in `World.MOBS` rows, not in defs, so re-levelling is row data and leaves the mob-def golden alone.
- Two owner intents to carry into that pass, so they are not lost:
  1. **The top end should be steeper than the current curve** — 47% of the climb in 40→50 is not
     intense enough for the "race among the dedicated" the cap is meant to be.
  2. **Steeper must not mean duller.** The grind has to be carried by content and competition
     (see the resident race, §2), not by the number going up more slowly.

The analysis above stays in this doc as the evidence that pass will start from — in particular the
inversion, which is the thing to fix whatever shape is chosen.

---

## 4. Locale 1 — identity

**A blend: the worn-down Glitchyard industrial decay giving way to nature taking the complex back.**
It is the visual and fictional bridge that makes the wildlife's arrival at L25 feel earned rather than
abrupt. Three sub-regions, per the owner:

- **Overgrown practice fields** — the closest to the Glitchyard; equipment rotting in place, grass
  through the hardpan, faded lane markings.
- **Flooded pitches** — standing water, silt, reeds; drainage failed years ago.
- **Parking / logistics sprawl** — the service side of a complex: lots, loading, fencing, pylons.

**Scope constraint (owner):** *fields and open areas only* — no stadium arenas, no indoor spaces yet.
That keeps the Reclaimed Stadium (away_3 + concourse + roof) as the one interior thing in the world,
and it pushes verticality toward open-air structures, which suits big outdoor zones better anyway.

---

## 5. Scale rules

| | Now | Target |
|---|---|---|
| Field zone | ~1900 × 1000 | **3600 × 2800** |
| Set-piece zone | 2600 × 950 | up to **5000 × 3000** |
| Zones per locale | 5–7, linear | **8–12 + 4–6 layers, looped** |
| Cross a locale | ~1 min | **4–6 min of pure travel** |

**The depth rule:** `h` ≥ 2400 su, i.e. at least 1.5× the max-zoom view. At default zoom the player
then sees roughly a quarter of the depth and can never take in both edges at once.

At ~140 su/s, a 3600×2800 zone is ~26 s wide and ~20 s deep.

**The density rule (the real budget):** a point of interest every 20–40 s → **6–10 POIs per zone**.
Big and empty is worse than small. Content, not code, is the constraint on this whole plan.

---

## 6. Structure: build a locale, not a map

Monster Hunter's sense of scale comes from a **locale** — many distinct areas with strong identity,
heavy layering, routes that loop, shortcuts unlocked from the far side, and long sight lines to other
parts of the same locale. That maps directly onto this engine: portal-connected flat zones *are* the
area system, and the P4 stacked layers *are* the verticality. No sim-z, no engine risk.

**Topology requirements** (this is what fixes the corridor problem):
- 2–4 exits per zone, not 1 forward + 1 back
- at least one **loop** per locale — return somewhere known from a new direction
- **shortcuts unlocked from the far side** (the away_1 checkpoint is the precedent)
- dead ends that pay: a cache, a rare spawn, a vista, a lore point

### The outdoor vertical toolbox
| Direction | This locale's vocabulary |
|---|---|
| **Up** | floodlight and comms towers, bleacher decks, press platforms, water towers, scaffolds, maintenance catwalks |
| **Down** | drainage culverts, service trenches, ditches, storm channels |
| **Aside** | collapsed sections, thickets, flooded underpasses reachable one way only |
| *(parked)* | *concourses, interiors, arenas — deliberately not yet* |

Chain them 3–4 deep in one landmark, and give at least one layer **two entrances in different zones** —
nothing teaches "this world is connected" faster.

### Making it feel open
1. **The visitable landmark** — the strongest signal available, already proven (away_1 sees the
   Reclaimed Bowl; away_3 is inside it). Every zone should see at least one place the player will go.
2. **Continuous landform across zones** — zone A's east horizon should match zone B's west, or crossing
   a portal reads as teleporting between dioramas. P5 composed each zone's backdrop independently;
   this locale should not.
3. **Multi-band backdrops** — near ridge / mid massif / far horizon at genuinely different distances.
4. **Vista layers** — a climb whose summit reveals the locale *and* the next one.
5. **Fog tuned to dissolve the bounds**, with edges framed as cliffs, treelines, flood or collapse
   rather than an invisible wall behind an apron.

---

## 7. Assets

Source: `/home/e/Documents/map1obj/` — 10 props, Meshy profile (**4× 2048² PNG, ~22 MB, ~33k verts each**).

| Prop | Status | Action |
|---|---|---|
| `speaker`, `tower` | **new** | **integrate** |
| `propcone` | **owner-made, a DIFFERENT cone** — not a replacement | **integrate** — see the variety note below |
| `playbookboard` | the quest board is already in the game | **leave alone** (owner) |
| `scoreboard`, `bag`, `barrier`, `rack`, `gear_forge`, `sideline_stand` | already in the game | **leave alone for now** (owner) |

**On `propcone` — this one is about variety, not replacement.** Cones are placed everywhere (drill
gates, lane markers, ladders) and currently every one in the world is the same model, which makes
zones look copy-pasted. A second cone means a placement can pick between them so no two zones read
identically. Note that the decal schema's `kind: "cone"` is a *flat painted marker* with no collision
and is a different thing entirely — `propcone` is a solid prop and needs its own `PROP_FOOTPRINT`
entry. Both should stay available; they do different jobs.

**Owner rules for the new props:** optimized to the shipped standard, **not purchasable**, and exposed
as **admin / builder-mode items only** for now.

**Optimization** (per `CLAUDE.md`): `~/.npm-global/bin/gltf-transform` resize 1024 + simplify.
**Never Draco** — Godot 4.6 cannot import it. Expect ~22 MB → ~3–5 MB each. This matters: the client
ships as one ~300 MB PCK with no streaming.

**Integration checklist per prop** (each one is a real trap if skipped):
- `PROP_FOOTPRINT` entry, or it renders with **no collision** (walk-through scenery)
- long/thin props need `PROP_DIM` + `DECAL_PANELS` instead, or one circle leaves ~75% of the model
  walk-through — the collision-pass-2 lesson
- `smoke_prop_loads` guard (it verifies the id loads and its textures resolve)
- `CREDITS.txt` if sourced rather than generated
- a decal or backdrop change means a **`Protocol.VERSION` bump** — now enforced by the
  `decal-protocol-guard` CI job

⚠ **Parked trap, for when the six replacements are revisited:** swapping a shipped prop's GLB changes
its look in *every* existing zone, and `PROP_DIM`'s long/depth ratios drive collision-row expansion —
a new model with different proportions silently desyncs collision from the visual.

**`tower` and `speaker` are landmark-grade, not set dressing.** A dead PA horn on a pole and a
climbable comms tower are exactly the vocabulary that makes an abandoned complex read; place them as
navigation anchors, and let `tower` be a stacked-layer landmark.

---

## 8. Phases

Each phase stops for owner approval. Nothing deploys without it.

Ordering reflects the owner's call to defer all levelling work until there is content to tune against
(§3). Everything before Phase 5 is built at **provisional levels**, which is cheap because levels are
`World.MOBS` row data.

| # | Phase | Deliverable | Verification |
|---|---|---|---|
| **1** | **Asset pass** | `speaker`, `tower`, `propcone` optimized + integrated, admin/builder-only, non-purchasable | `smoke_prop_loads`; collision footprint matches the rendered mass; before/after size table |
| **2** | **Proof zone** | ONE zone at 3600×2800: enclosure, a tower layer, a vista, 6–10 POIs | Owner visual approval — *does the box feeling go away?*; traversal timings; per-zone `f=`/`c=` telemetry under load |
| **3** | **Locale 1** (provisional L5–12) | 8–12 zones + 4–6 layers, looped, landmark hierarchy, boss | Full suite; `stab_away`-style geometry sweep extended; POI cadence audit |
| **4** | **Tutorial rework** | Glitchyard → L1–5, teaching quest chain, guide resident, **visual shop tutorial** | New tutorial suite; a fresh character completes it unaided |
| **5** | **The tuning pass** — XP curve + `LEVEL_CAP` 30→50 + world re-level, together | Curve reshaped against real content; wildlife → 25–40; Finals → 40+; `wild_gate` moves; Home pad removed | Band-share table; `bal_identity` byte-identical; mob-def golden unchanged; ability unlocks re-spaced across 50 |
| **6** | **Resident progression** | Wall-clock resident levelling + leaderboard presence | Must not stall during sleep; must not divert player rewards |
| **7** | **Locales 2 and 3** | L12–19, L19–25 | As Phase 3 |
| **8** | **Perf** | Spatial index **only if** telemetry demands it | World-expansion Phase 6; must preserve iteration order + re-prove `bal_identity` |

Phase 1 is small, self-contained and unblocks the rest — the right first sitting.
Phase 2 is deliberately one disposable zone: the current world was built by extending a grammar that
turned out to have a flaw, and it is cheaper to find the next flaw on one zone than across twelve.
Phase 5 is the riskiest work in the plan (§9) and now lands with a real, walkable world to tune against
rather than a spreadsheet.

---

## 9. Risks, in order of severity

1. **The tuning pass (Phase 5) is the largest and riskiest piece — bigger than building the maps.** It
   touches shipped, balanced, working content: every `World.MOBS` row, wildlife 8–17 → 25–40, Finals
   19–24 → 40+, quest `min_level` gates and XP rewards, gear item-level bands, shop catalogs, drop
   tables, bounty bands, ability unlocks, talent points, Paragon's start.
   *Mitigations:* mob levels live in `World.MOBS` rows, not defs, so **the mob-def golden should survive
   untouched**; `bal_identity` remains the guard that per-hit combat math never moved; do it after
   Locale 1 exists so there is somewhere for players to actually be.
2. **Content volume, not code.** 20 levels of new region at 6–10 POIs per zone across ~30 zones is the
   real cost of this plan. Locales ship one at a time for exactly this reason.
3. **Client size.** ~300 MB PCK, no streaming. Reuse props; backdrops are nearly free (silhouettes).
   Every new prop costs download for every player, forever.
4. **Server scaling.** Big zones with heavy wall massing multiply collision circles, and collision /
   separation / LOS scans are brute force per fighter. v1.17.0's telemetry reports per-zone `f=` and
   `c=` precisely to watch this. If it bites, Phase 8 is already specced.
5. **Leash (1600) and aggro (320) at scale.** In zones this large the leash becomes reachable in normal
   play for the first time (P3 already hit this); camp spacing needs deliberate design.
6. **Resident progression stalling.** See §2 — wall-clock, not tick.

---

## 10. Open items

- **Curve shape** — deferred to Phase 5 by owner decision (§3). Carry forward: steeper at the top
  than today, without making the grind duller.
- **Locale 1's zone graph** — drawn and approved before any zone is built (the Phase 3 gate)
- Whether Locale 1's boss is a new creature or reuses an existing def (a new def rebases the golden)
- When the six prop replacements get revisited, and whether that global visual change is wanted
- Whether the cap goes past 50 later — worth knowing before Phase 5 shapes the curve

## Decision log

| Date | Decision | Owner rationale |
|---|---|---|
| 2026-08-03 | Progression **Option A** — insert the official region and shift everything after it | The new maps are the only route on from base; wildlife sits at their end |
| 2026-08-03 | Theme: abandoned sporting complex, **fields and open areas only** — no arenas or interiors yet | Keeps scope on open space; leaves the Reclaimed Stadium the one interior |
| 2026-08-03 | Locale 1 is a **gradient**: worn-down Glitchyard industrial → nature reclaiming the complex | Makes the wildlife's arrival at L25 feel earned |
| 2026-08-03 | Bands: tutorial 1–5, official region 5–25, wildlife 25–40, finals 40+, **cap 50** | Cap raised once Locale 1 + tutorial are done |
| 2026-08-03 | Integrate `speaker`, `tower`, `propcone` only — **admin/builder items, not purchasable** | Quest board and the other six already in the game; leave them |
| 2026-08-03 | **Defer the XP curve + cap + re-level** into one later tuning pass | Cannot tune a curve against content that does not exist yet; steep over empty content is a dead-boring grind |
