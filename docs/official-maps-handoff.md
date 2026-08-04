# The Official Maps — building the first real world

**v2 — 2026-08-03.** v1 was the owner-agreed plan; v2 incorporates an external architecture review
plus additions from re-measuring the codebase. Nothing is built. Each phase stops for owner approval.

Companions: `docs/world-expansion-handoff-v2.md` (zone-design grammar), `docs/world-expansion-p2-report.md`
(what P1–P5 shipped), `docs/APPROVAL_QUEUE.md`.

---

## 0. What changed in v2, and why

**Adopted from the review — all correct:**
- **Locale graph and a greybox slice come before the asset pass.** A primitive box proves navigation
  as well as a finished tower does; a beautiful zone that connects badly is the expensive mistake.
- **Prove a *slice*, not a zone.** The untested claim is not "can a zone be big" — it is *"can several
  portal-connected simulations feel like one continuous place."* One zone cannot test that.
- **3600×2800 becomes an archetype, not a default.** A uniform big-rectangle rule swaps corridors for
  large empty rooms. Varied shape is what produces a sense of scale.
- **The POI budget was internally inconsistent** — a zone crossed in 26 s cannot hold 6–10 discoveries
  at a 20–40 s cadence. Budget against route length including detours, and separate *readable
  locations* from *mechanically substantial activities*.
- **A POI taxonomy** so "10 POIs" cannot quietly become ten prop piles.
- **An instance policy written before building**, not after.
- **Client cost was underweighted.** This is the review's strongest catch — see §10.
- **Persistent discovery state**, or players reduce the locale to its shortest XP path after one visit.
- **Scope cut** to 5–7 surface zones + 2–3 pockets + 1 boss per locale.

**Modified from the review:**
- The review's layer table assigns *pockets* (culverts, tower climbs, dens) to **party instances**.
  I would **default pockets to shared** and instance only when the policy in §5 actually triggers.
  With a small population, instancing the most atmospheric places removes the rare chance of meeting
  someone precisely where it would matter most, and adds lifecycle complexity for near-zero contention
  relief. The review's own policy rules are the right test; its table is stricter than its rules.

**New in v2 (not in v1 or the review):**
- **§1.1 the small-playerbase paradox** — bigger world + a 450 su interest radius means players see
  each other *less*. Growth can make the world feel deader, which is the opposite of the goal.
- **§9 an explicit aliveness model** — the review lists exploration features; the "static and dead"
  problem also needs *motion, sound and change*, and the residents system is the cheapest lever we own.
- **§10 quantified budgets** from real numbers rather than adjectives.

---

## 1. The problem, measured

At `FOV 60°` / `SCALE 0.05` (1 world unit = 20 sim units):

| Zoom | Visible ground span |
|---|---|
| Default (`_dist` ≈ 26 wu) | ~600–900 su |
| Max (`DIST_MAX` 70 wu) | **~1600 su** |

| | Width | Depth (`h`) |
|---|---|---|
| Typical zone | 1500–2000 | **820–1100** |
| Largest (away_1) | 2600 | **950** |

**Every zone is shallower than one camera view.** You can see both walls at once, so no amount of
props fixes it. Causes: depth never grew (only width); the topology is a corridor; nothing occludes.

The **empty-zone sleep** (v1.15.0) is what makes growth affordable — static zones with no players skip
their whole tick (`avg 0.1 ms` idle, 18 zones asleep). Zones are ~free at rest.

### 1.1 The small-playerbase paradox — design against this from day one

`INTEREST_RADIUS` is 450 su. In a 3600×2800 zone, two players 1000 su apart cannot see each other at
all. Today's whole population is 14 characters. **Making the world 4× larger makes encountering
another human ~4× rarer.** Left unaddressed, this plan trades "small and boxy" for "vast and lonely" —
still dead, just further apart.

Three mitigations, all cheap, all designed in rather than bolted on:
1. **Convergence points.** Routes should funnel: a bridge, a gate, a service point, one good camp
   everyone farms. Players meeting *anywhere* is unlikely; players meeting at the one crossing is not.
2. **Residents are the population.** See §9 — the AI residents are the only reason the world will feel
   inhabited at this population, and they already exist.
3. **Density over sprawl.** A dense 7-zone locale beats 12 thin ones (the review's scope point, for
   this reason as much as for build cost).

---

## 2. Progression model (owner-decided, unchanged)

```
Home base
  └─ Glitchyard  ........ L1–5    TUTORIAL (existing geometry, new purpose)
       └─ Locale 1 ...... L5–12   ┐
            └─ Locale 2 . L12–19  ├─ THE OFFICIAL REGION (new)
                 └─ Loc 3 L19–25  ┘
                      └─ Wildlife Expanse ... L25–40  (existing, re-levelled)
                           └─ Finals + beyond .... L40+
```

The official region is **the only route on from base**. The Home → "▶ Wildlife Expanse" pad is
removed; `wild_gate` moves to the far end of Locale 3. **Cap 30 → 50**, raised once Locale 1 and the
tutorial exist. **40→50 is a deliberate prestige band.**

### AI residents as pace-setters
Residents should progress so a solo player has someone to race. Their levels are fixed constants today
(`RESIDENTS`, `server/Server.gd`).

⚠ **Progression must be wall-clock, not tick-based.** The empty-zone sleep freezes residents whenever
no real player is in their zone — tick-based progress would stall exactly when nobody is playing,
which is when the race fiction matters most. Persist a timestamp; advance on login/heartbeat.
Residents must not consume loot, credits or leaderboard rewards that would otherwise reach players.

---

## 3. The XP curve — analysed, DEFERRED by owner decision

Current: `_xp_to_next(level) = 50·level + 7.5·level²`, tuned for cap 30. Extended to 50 unchanged:

| Band | XP | Share of 1→50 |
|---|---|---|
| 1→5 tutorial | 724 | 0.2% |
| 5→25 **official region (3 new locales)** | 51,020 | **14.0%** |
| 25→40 wildlife (existing content) | 141,296 | **38.8%** |
| 40→50 prestige | 171,385 | 47.0% |
| **Total 1→50** | **364,425** | |
| *(today's whole game, 1→30)* | *85,905* | |

1. **The top end already behaves as wanted** — 47% of the climb sits in 40→50 with no new mechanism.
2. **The middle is inverted** — three new locales earn 14% while existing wildlife content earns 39%.
   Players would blow through everything new and wall on old content.

**Owner decision (2026-08-03): defer.** *"That curve isn't intense enough, but it would be better
adjusted later when more of the game is fleshed out and the grind wouldn't be dead boring."* This is
right: you cannot tune a curve against content that does not exist, and steep-over-thin produces
exactly the grind it is meant to prevent.

So the curve reshape, cap raise and world re-level are **one tuning pass (Phase 6)** once Locale 1 and
the tutorial exist. Locale 1 is built at **provisional levels** — cheap, because levels live in
`World.MOBS` rows, not defs, so re-levelling leaves the mob-def golden untouched.
Carry forward: **steeper at the top than today**, and **steeper must not mean duller** — the grind is
carried by content and competition, not by a slower number.

---

## 4. Locale 1 — identity

**A gradient: worn-down Glitchyard industrial decay giving way to nature reclaiming the complex.** It
is the bridge that makes the wildlife's arrival at L25 feel earned. Sub-regions:

- **Overgrown practice fields** — nearest the Glitchyard; equipment rotting where it stood, grass
  through hardpan, faded lane markings.
- **Flooded pitches** — standing water, silt, reeds; drainage failed years ago.
- **Parking / logistics sprawl** — lots, loading, fencing, pylons; the service side of a complex.

**Scope constraint (owner): fields and open areas only** — no arenas, no interiors yet. That keeps the
Reclaimed Stadium the world's one interior and pushes verticality outdoors, which suits big zones anyway.

---

## 5. World architecture — shared by default, instanced by exception

| Layer | Purpose | Server model |
|---|---|---|
| **Shared locale zones** | travel, camps, gathering, social encounters, exploration | static shared zones + empty-zone sleep |
| **Pockets** (culverts, climbs, dens, overlooks) | texture, discovery, traversal | **shared by default** — instance only if §5.1 triggers |
| **Finales** | bosses, tightly scripted set pieces | existing party-instance model |

Both halves already exist and are proven: static zones sleep when empty; party instances are created
from templates and **torn down when the last player leaves** (`_maybe_teardown_instance`).

**Instancing everything would not reduce load.** Ten parties in ten copies of a locale costs more than
ten parties spread through one. Instancing pays when it limits concurrency, isolates scripted state,
or lets an expensive area be destroyed afterwards.

### 5.1 Instance policy — decide per location, before building

**Instance it** if any of these are true:
- party-unique story state · resettable puzzle state · scripted boss sequencing · destructible or
  heavily changing geometry · a hard population limit · fighter/collision density that must not mix

**Keep it shared** if it benefits from:
- seeing unfamiliar players · spontaneous cooperation · public events or rare spawns · world
  continuity · ambient residents · cheap mostly-static exploration

Instances stay **party-keyed and ephemeral** for now. Population shards (`locale1_fields#shard3`) are
**deferred until telemetry demands them** — at 14 characters that is far off, and sharding would
actively worsen §1.1.

---

## 6. Zone shape palette — rhythm, not uniform size

`3600×2800` is the **broad-hub archetype, not the default**. A locale should mix:

| Archetype | Rough size (su) | Role |
|---|---|---|
| **Broad hub** | 3200–4000 × 2400–3000 | the "wow, this is big" moment; landmark host |
| **Dense connector** | 1800–2600 × 1600–2200 | pace change, higher prop density, combat texture |
| **Long reveal route** | narrow but bent / heavily occluded | conceals the destination until you arrive |
| **Discovery pocket** | 800–1600 either axis | one idea, one reward, quick in and out |
| **Set piece** | large only when the encounter needs it | boss approach, vista, landmark |

**The depth floor still holds where it matters:** any zone meant to feel *open* needs `h ≥ 2400`, i.e.
1.5× the max-zoom view. Connectors and pockets are deliberately below it — that contrast is the point.
**A broad hub feels enormous after a cramped culvert, and merely large after another broad hub.**

---

## 7. POIs — what they are and how many

v1's "6–10 POIs per zone at a 20–40 s cadence" was internally inconsistent: a zone crossed in ~26 s
cannot hold ten discoveries. Corrected on two axes.

**Classify them:**

| Type | Examples |
|---|---|
| **Navigation** | tower, bridge, scoreboard, water tank — things you steer by |
| **Combat** | camp, ambush, elite patrol |
| **Discovery** | cache, lore, rare spawn, overlook |
| **Traversal** | culvert, climb, broken fence, shortcut |
| **Rest / social** | safe overlook, resident stop, service point |
| **World-state** | a location or object that changes after an action |

**Budget against route length, not area.** A player's actual path through a broad hub — with detours —
is 2–4× the straight crossing. Target roughly:

- **6–10 readable locations** per broad hub (most are navigation/rest, and cheap)
- **only 2–4 mechanically substantial activities** per zone (combat, discovery, world-state)
- connectors and pockets: **1–2 substantial each**

That is sustainable across ~20 zones; "10 real activities per zone" is not.

---

## 8. Transitions as terrain

Portal pads announce themselves and break the illusion of one continuous place. Where a transition is
*geographic*, disguise it as traversal:

- a bent culvert whose far end is the next zone · a treeline passage · a fenced service lane ·
  a ridge crest that hides the destination during the crossing · a flooded underpass · a climb or lift

Keep explicit pads for **service, fast-travel and gated** transitions, where the game-y read is honest.

**Engine constraints to respect** (these are why this needs care, not just art):
- Transitions fire from pad geometry with a **TP grace window**; a player must be able to *tell* where
  the seam is, or they will walk through it by accident and feel teleported rather than travelled.
- The **arrival point must clear every camp's aggro radius** (320 su) — the shipped grammar, enforced
  in `stab_away`. A disguised seam still obeys it.
- **Matched horizon composition on both sides** is what actually sells continuity: same landform, same
  landmark bearing, consistent approach direction. P5 composed each zone's backdrop independently —
  this region must not.

---

## 9. Making it feel alive — the anti-"static and dead" model

The v1 plan and the review both address *space*. Neither addresses **motion, sound and change**, which
is most of what makes a world feel inhabited. Ranked by value-per-effort:

**1. Residents are the population (highest value, mostly built).**
Eleven server-side AI players already route between zones, fight camps, chat with personas and can be
recruited. At 14 real characters they are the only reason the world will feel inhabited. Extend them
into the new region and make their activity *visible*: travelling between zones, actually fighting a
camp when you arrive, resting at a service point, calling out a rare spawn. This is the single
strongest lever and it is largely tuning existing systems.
*Caveat:* the sleep freezes them until a player arrives, so they will always be "just starting" when
you walk in. Their wake is same-sub-step, so the artifact is subtle — but scripted "already in
progress" arrival states would sell it better.

**2. Ambient audio — a real gap.** `AudioManager` has music and SFX but **no environmental ambience
system**. Wind through a chain fence, water in the flooded pitches, distant birds, a loose PA speaker
crackling. Sound does more for aliveness per byte than any visual. This should be its own small phase.

**3. Persistent discovery state** (from the review). Without it, players explore once and thereafter
run the shortest XP path:
- named discoveries recorded per character · a landmark/vista journal · one-time caches with modest
  rewards · **shortcut unlocks persisted per character** · optional cartography that fills in after
  visiting landmarks

**4. Things that move on their own.** Rare *patrol routes* instead of stationary rare camps; wildlife
that flees rather than fights; small rotating events among predefined sites. A world where every
creature stands still until aggroed is the definition of static.

**5. Change over time.** The procedural sky and per-zone fog already exist — per-visit or slow-cycle
mood variation is nearly free client-side and makes revisits feel different. (Client-only, so it
cannot touch determinism.)

**6. World-state POIs.** A gate that stays open, a pump that drains a pitch, a light that comes back
on — small persistent changes prove the world reacts to players.

---

## 10. Budgets — client cost is the underweighted risk

**The client instantiates a zone's *entire* decal set and backdrop set on entry** (`_render_decals`,
`_render_backdrops`), signature-cached but wholesale — there is no spatial streaming. So physical size
is cheap for networking and expensive for rendering.

Quantified from what ships today:

| | away_1 (2600×950) | a 3600×2800 hub at the same density |
|---|---|---|
| Area | 2.47M su² | **10.08M su² (4.1×)** |
| Decal records | 115 | **~470** |
| Backdrop records | 34 | **~140** |

~470 mesh instances built in one rebuild on zone entry, times 5–7 zones, is a genuine hitch and
draw-call risk — and **prop density per unit area must therefore fall as zones grow**. That reinforces
§6: big zones sparse with clustered detail; small pockets prop-rich.

**Measure in the proof slice, then enforce per zone:**

*Client* — decal/mesh instance count · rendered triangles · draw calls · **zone-entry hitch (ms)** ·
memory after several transitions · FPS on the weakest target machine.
*Server* — collision circles per zone · active fighters and projectiles · tick avg/p95/worst with
parties **clustered vs spread** · snapshot bytes in ordinary and boss fights.

v1.17.0's telemetry already reports per-zone `f=`/`c=`, tick avg/p95/worst and snapshot bytes — the
instrumentation for the server half is in place. The client half needs measuring by hand in the slice.

**Note on the real pressure point:** interest output is filtered, but the server still *iterates* the
world's fighter and projectile collections to build each snapshot. Large *populations*, not large
coordinates, are what bite. Bigger rectangles alone are close to free server-side.

---

## 11. Phases

Reordered per the review: structure is proven before art, and a *slice* is proven before a locale.
Everything before Phase 6 is built at provisional levels (`World.MOBS` row data — cheap to change).

| # | Phase | Deliverable | Gate / verification |
|---|---|---|---|
| **1** | **Locale graph on paper** | Zone list with archetypes, the loop, shortcuts, landmark chain, instance policy applied per location, traversal budget | **Owner approves the graph before anything is built** |
| **2** | **Greybox slice** | 2 surface zones + 1 alternate route + 1 pocket/layer + 1 return shortcut + a landmark visible before and visitable after, horizons matched across the seam. Primitive shapes only | Does it feel like **one place**? Traversal timings; client + server budgets from §10 established here |
| **3** | **Asset pass** | `speaker`, `tower`, `propcone` optimized + integrated, admin/builder-only, non-purchasable | `smoke_prop_loads`; footprint matches rendered mass; size table |
| **4** | **Locale 1** | 5–7 surface zones + 2–3 pockets + 1 boss instance + 1 loop + 2 far-side shortcuts + 1 landmark chain | Full suite; geometry sweep; POI-budget audit against §7; per-zone budgets held |
| **5** | **Tutorial rework** | Glitchyard → L1–5, teaching chain, guide resident, **visual shop tutorial** | A fresh character completes it unaided |
| **6** | **The tuning pass** | XP curve + `LEVEL_CAP` 50 + world re-level together | Band-share table; `bal_identity` byte-identical; golden unchanged |
| **7** | **Aliveness pass** | Ambient audio; resident activity + wall-clock progression; persistent discovery state | Subjective owner review + a "does it feel inhabited" playtest |
| **8** | **Locales 2 and 3** | L12–19, L19–25 | As Phase 4 |
| **9** | **Perf** | Spatial index / decal streaming **only if** budgets are breached | Preserve iteration order; re-prove `bal_identity` |

Phases 1 and 2 are the whole bet. If the greybox slice does not feel like one continuous place, the
plan changes before a single finished asset is placed.

---

## 12. Risks, in order

1. **The tuning pass (Phase 6) is the largest, riskiest piece** — every `World.MOBS` row, wildlife
   8–17 → 25–40, Finals → 40+, quest gates, XP rewards, gear ilvl bands, shop catalogs, drop tables,
   bounty bands, ability unlocks, talents, Paragon. *Mitigations:* mob levels are row data so the
   golden survives; `bal_identity` guards combat math; it lands after there is a world to tune against.
2. **Content volume.** ~20 zones at real POI density is the true cost. Locales ship one at a time.
3. **Client rendering** (§10) — the most likely place this plan hits a wall in practice.
4. **The loneliness paradox** (§1.1) — the failure mode where the plan technically succeeds and the
   world still feels dead.
5. **Client package size** — ~300 MB PCK, no streaming; every prop costs every player forever.
6. **Leash (1600) and aggro (320) at scale** — leash becomes reachable in normal play; camp spacing
   needs deliberate design.
7. **Resident progression stalling** under sleep (§2).

---

## 13. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-08-03 | Progression **Option A** — insert the region, shift everything after | New maps are the only route on from base; wildlife at their end |
| 2026-08-03 | Theme: abandoned sporting complex, **fields and open areas only** | Keeps scope open-air; Reclaimed Stadium stays the one interior |
| 2026-08-03 | Locale 1 is a **gradient** from Glitchyard decay into nature reclaiming it | Makes the wildlife's arrival feel earned |
| 2026-08-03 | Bands 1–5 / 5–25 / 25–40 / 40+, **cap 50** | Cap raised once Locale 1 + tutorial exist |
| 2026-08-03 | Integrate `speaker`, `tower`, `propcone` — **admin/builder only, not purchasable**; quest board and the other six left alone | propcone is a *second* cone for variety, not a replacement |
| 2026-08-03 | **Defer** curve + cap + re-level into one later tuning pass | Cannot tune against content that does not exist |
| 2026-08-03 | **v2:** graph → greybox slice → assets; shape palette replaces the uniform size rule; pockets shared by default; explicit instance policy; client budgets | External review; adopted with the pocket-instancing rule relaxed |

---

## 14. Open questions — mostly about *fun*

Structure and performance are now well specified. What is still undefined is what a player **does**.

1. **Is combat the only verb?** Right now a zone offers: fight camps, collect loot, walk to the next
   zone. Exploration needs something to *do* that is not fighting — gathering, salvaging wrecks,
   climbing for vantage, opening drainage, finding caches. Even one non-combat verb changes a locale
   from a corridor of camps into a place. **What fits the fiction here?**
2. **What is exploration's reward currency?** Gear and XP push players to the optimal farm route.
   Cosmetics, shortcuts, lore, map knowledge, or account-persistent unlocks reward *going somewhere new*.
3. **Should the world change over time** — rotating events, weather, day/night — or stay stable and
   learnable? Stable is cheaper and more readable; change is what makes a place worth revisiting.
4. **Solo or group?** This drives density, camp sizing and how much of the region is instanced. Given
   the resident companions, a solo-first region with group-optional pockets seems likeliest.
5. **What happens when a player dies out here?** Stakes are part of aliveness — a world with no
   consequence for wandering somewhere dangerous is a theme park.
6. **How much should residents carry?** They can be background colour, or a genuine social layer —
   naming you, remembering you, competing on the ladder, showing up where you are headed.
7. **Is there anything to come back *to*?** A camp, a base, a service point that becomes *yours* in
   the locale gives travel a shape. The Locker Room precedent exists.
