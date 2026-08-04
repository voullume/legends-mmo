# Locale 1 — the locale graph (Official Maps Phase 1)

**Status: PROPOSED — nothing is built.** This is the Phase 1 deliverable of
`docs/official-maps-handoff.md` §11: the locale graph on paper, for owner approval **before any
World.gd row exists**. The decision block at the bottom (§10) is the gate — answer it in one sitting
and Phase 2 (the greybox slice) can start.

Companions: `docs/official-maps-handoff.md` (the design), `docs/world-expansion-handoff-v2.md` §4
(zone grammar), `docs/world-expansion-p2-report.md` §1 (the away_1 composition method this copies).

---

## 1. Identity recap (owner-decided, from the handoff)

Locale 1 is **a gradient: worn-down Glitchyard industrial decay giving way to nature reclaiming the
complex** — the bridge that makes the wildlife's arrival at L25 feel earned. Sub-regions: overgrown
practice fields, flooded pitches, parking/logistics sprawl. **Fields and open areas only** — no
arenas, no interiors (the Reclaimed Stadium stays the world's one interior). Provisional band
**L5–12** (row data — Phase 6 re-levels for free).

The gradient is spatial and legible: the **west** end sits under the Glitchyard's smokestack skyline
(decay, hardpan, rusting equipment); the **east** end is green, wet and overgrown, with the Reclaimed
Bowl on the horizon (foreshadowing the wildlife biome). Mob rosters follow the same west→east mix
(glitchyard equipment classes → wildlife classes), which expresses the theme with ~no new defs.

## 2. The zone set

**5 surface zones + 2 pockets + a base (the service pocket) + 1 boss** — the low end of the
handoff's scope cut (5–7 surface; 2–3 pockets counting the base; 1 boss). Sizes follow the §6 shape
palette with two deliberate departures: **only the two broad hubs** get the h ≥ 2400 depth floor
(connectors sit below it — the contrast is the point), and the three pockets sit below the palette's
800-su pocket floor on their short axis for the same cramped-contrast reason.

| Zone id | Working name | §6 archetype | Size (su) | Band | Sub-region / role |
|---|---|---|---|---|---|
| `loc1_fields` | Overgrown Practice Fields | **Broad hub** | 3600×2800 | L5–7 | practice fields; the "wow, this is big" moment; landmark host |
| `loc1_lots` | Logistics Sprawl | Dense connector | 2200×1800 | L7–9 | parking/loading/fencing; combat texture, higher prop density |
| `loc1_pitch` | Flooded Pitches | **Broad hub #2** | 3200×2400 | L8–10 | standing water, reeds, silt; the locale's heart |
| `loc1_lane` | Service Lane | Long reveal | ~2600×700, bent | L7–9 | fenced service corridor; quiet alternate route (lower threat by *density and aggro spacing*, not level) |
| `loc1_ridge` | The Embankment | Long reveal / set-piece approach | ~2400×900 | L10–11 | drainage ridge; conceals the boss approach until the crest |
| `loc1_culvert` | The Culvert | Discovery pocket | ~1000×700 | L8 | bent drainage tube; the return shortcut |
| `loc1_press` | Press Box Overlook | Rest pocket (aggro:false) | ~900×560 | — | quiet overlook above the pitches; tape anchor (AWAY3R pattern) |
| `loc1_base` | (base hub — name TBD) | Service pocket (safe) | 1200×640 | — | the locale's §9.3 base; shop/forge/questgiver. Basecamp-width on purpose: the global resident spawn offsets (+520 east of spawn) must stay in-bounds — the World.gd:108-110 trap |
| `loc1_boss` | (finale — name TBD) | Set piece (instance template) | ~1300×850 | L11–12 | the locale boss; Phase 4.4 |

**Instance policy, applied per §5.1:** everything is **shared** — no pocket meets an instancing
trigger (no scripted state, no destructible geometry, no population cap; the culvert and press box
are exactly the atmospheric places the handoff argues to keep shared at this population). The single
instance is **`loc1_boss`** (trigger: scripted boss sequencing), on the existing party-keyed
ephemeral model.

## 3. Topology

```
                                                     [loc1_press] press box
                                                          ↑ gantry/stair climb (disguised)
   GY5 ──gate──> ┌─────────────┐   ┌──────────────┐   ┌────────────┐
   (loc1_gate)   │ loc1_fields │──>│  loc1_lots   │──>│ loc1_pitch │──> ridge crest
                 │  BROAD HUB  │ NE treeline      │ flooded        │    (disguised)
                 │             │ (disguised)      │ underpass      │        │
                 │  ⌂ checkpoint pad (intra-map)  │ (disguised)    │  ┌────────────┐
                 │             │                  └──────────────┘  │ loc1_ridge │
                 │             │──> SE fence gap ──> [loc1_lane] ──>│  approach  │
                 └─────┬───────┘    (disguised)    bent corridor    └─────┬──────┘
                       │ pads (explicit)           rejoins pitch S        │ boss door
                 ┌─────┴──────┐                    (disguised)            ▼ (explicit,
                 │ loc1_base  │                                     ⟨loc1_boss⟩ instance)
                 │  SAFE HUB  │    [loc1_culvert]: pitch W mouth ──bent tube──> fields
                 └────────────┘     entry plaza (disguised BOTH ends — the return shortcut)
```

- **The loop:** fields → lots → pitch → ridge → boss approach, returning pitch → culvert → fields.
- **The alternate route (branch-and-rejoin):** fields → lane → pitch. Lane is the quiet, bent,
  low-threat path; lots is the busy, camp-dense path. Two different reasons to cross.
- **The shortcuts** (the handoff Phase 4 deliverable asks for "2 far-side shortcuts"; the honest
  reading here is **one cross-zone shortcut + one intra-zone checkpoint**, and the owner approves
  that reading in §10 item 2):
  1. the **culvert** — pitch's west edge back to fields' entry plaza, disguised at both ends (the
     true cross-zone loop-closer);
  2. the **fields checkpoint** — an intra-map pad collapsing the hub's return walk (the shipped
     away_1 Field-Entrance precedent, World.gd:229-231);
  3. *(reserved, not built in Phase 4)* a **lane↔ridge crossing** as a second cross-zone shortcut —
     a natural candidate for the Phase 7 persisted **shortcut unlock** (handoff §9 item 3), so the
     locale has somewhere for that mechanic to live.
- **⚠ Culvert level-flow, fields→pitch direction:** the fields-side mouth opens onto the entry
  plaza — the locale's highest-traffic L5 convergence point — and the tube is L8 with L8–10 on the
  far side. The mouth must **telegraph threat** (a visible L8 guard at the outfall, corpse/wreck
  dressing) so a fresh L5 walking in is a warned decision, not an ambush. Part of the §10 item 2
  approval.
- **`loc1_base`** hangs off fields at the loop junction (south edge, near the GY5 entrance) —
  short walk-backs from anywhere on the loop once §9.3 respawn lands (Phase 7A), and the natural
  "out from base, loop, back" shape.
- **`loc1_press`** hangs off pitch via a gantry/stair climb **disguised as traversal** (the §8 rule
  lists "a climb or lift" as a geographic transition to disguise; the top is concealed until the
  crest) — a no-aggro vista over the flooded pitches; the locale's premier tape anchor. Uses the
  AWAY3C/R stacked-zone mechanics, but with the seam dressed as the climb itself.

### Landmark chain and the horizon compass

One dominant silhouette per view, consistent bearings from every zone (§4.3 grammar + the §8
matched-horizon rule — composed as one region, NOT per-zone like P5):

| Bearing | What sits there | Seen from |
|---|---|---|
| **W** | Glitchyard smokestacks + Command Tower (existing gy family skyline, receding) | fields (large), lots (mid), pitch (faint) — continuity with where you came from |
| **E** | the **Reclaimed Floodlight Tower** (the Phase 3 `tower` prop's home, standing IN `loc1_pitch`) | fields' east horizon (visible-before), pitch (visitable-after) — the chain's spine |
| **Far E** | the Reclaimed Bowl gradient (existing away-family language, distant) | pitch, ridge — foreshadows the wildlife biome |
| **N** | treeline mass thickening west→east (the decay→nature gradient told by the skyline) | all surface zones |

The Floodlight Tower is the **visible-before / visitable-after** landmark the greybox must prove:
first sighted from fields at ~2 zones' distance, walked to and touched in pitch.

## 4. Seams (§8 — transitions as terrain)

| Seam | Class | Treatment | Both-sides horizon match |
|---|---|---|---|
| GY5 → fields | **explicit, gated** | the region gate (`loc1_gate`) — honest game-y read | GY skyline behind you on arrival |
| fields ↔ lots | disguised | treeline fence-break, bent so the far side is concealed | smokestacks W, tower E, same bearings |
| lots ↔ pitch | disguised | flooded underpass beneath a collapsed roadway | tower grows E→ arrival |
| fields ↔ lane | disguised | fenced service-lane gap, immediately bends | lane walls occlude; tower glimpsed at bends |
| lane ↔ pitch | disguised | collapsed gate where the lane emerges into reeds | tower now dominant |
| pitch ↔ ridge | disguised | ridge crest that hides the destination during the crossing | Bowl gradient rises E |
| pitch ↔ culvert ↔ fields | disguised ×2 | bent drainage tube; neither mouth reveals the far zone | outfall frames the fields plaza |
| pitch ↔ press | disguised | gantry/stair climb whose top is concealed until the crest (§8 lists a climb as a geographic transition to disguise) | overlook composes the whole pitch |
| fields ↔ base | explicit | service pads (service transitions stay game-y per §8) | — |
| ridge → boss | explicit | the boss door (instance pad) | — |

Engine constraints every seam obeys (CI-enforced in the new suite): pad trigger radius 42, TP grace
1500 ms, **arrival > 320 su from every camp**, drop points clear collision r+16, disguised seams
still legible as *seams* (the player must be able to tell where the crossing is — fence posts,
tube mouth, crest line). **The S1 gate rule: every pad into or within the locale — including the
fields intra-map checkpoint — carries `loc1_gate`**, which is what makes both the tampered-`last_map`
login defence and the §9 inert-on-interim claim actually true.

## 5. POI budget (§7 — budgeted against route length, not area)

| Zone | Readable locations (budget 6–10 hub / fewer elsewhere) | Substantial activities (2–4 hub / 1–2 else) |
|---|---|---|
| fields | 8 — entry plaza, base gates, checkpoint shelter, shed ruin, sled row, treeline break, lane gap, tower sightline | 2 — main camp chain, minor cache |
| lots | 5 — bus wreck, loading dock, pylon row, fence maze, underpass mouth | 2 — camp cluster, minor cache |
| pitch | 8 — floodlight tower, PA stack, islet, reed shallows, culvert mouth, press climb, ridge trail, drowned goal frames | 3 — **major cache**, tower camp, rare-patrol route |
| lane | 4 — gatehouse, equipment cage, bend shelter, collapsed gate | 2 — ambush camp, minor cache |
| ridge | 5 — crest marker, drainage vault, boss door forecourt, bowl vista, spillway | 2 — **major cache #2** (drainage vault), elite patrol |
| culvert | 2 — tube mouths, junction chamber | 1 — one idea, one reward (tape anchor + discovery) |
| press | 3 — press box, gantry, vista point | 1 — tape anchor / vista discovery |

Locale totals: ~35 readable locations, **13 substantial activities** — sustainable at the handoff's
"~20 zones" horizon, honest about which POIs are cheap. **Contested-site candidates (§6) are
counted as *reservations layered on existing POIs*, never as additional activities** — consistent
with §9.2's one-active-site-per-day rotation, at most one of them is live at a time.

## 6. Guarded caches and tape anchors (§9.1 reservations)

**Major caches (2)** — never on the through-route, prize visible from outside the pack's 320 aggro,
arena built for skilled play (cover walls breaking LOS, a chokepoint, kite room inside the 1600
leash, sub-clusters ~320 apart so a careful player can separate the pack):
1. **pitch north islet** — reached by a shallow-water detour off the main route; the chest sits
   raised and visible from the reed line.
2. **ridge drainage vault** — off the boss approach; commits you sideways right before the finale.

**Minor caches (3)** — route camp + 1–2 bodies, soloable at level. **The §9.1 placement rule
applies to minors too: ≥1 detour segment off the through-route** — fields (shed ruin, off the north
edge), lots (the fenced back-lot *behind* the loading dock — the dock itself is on the main path),
lane (equipment cage, up a dead-end spur off the second bend).

**Tape anchor sites (5+, no mechanic yet — reserved so maps never need rework):** press box
(premier), fields groundskeeper-shed ruin, pitch PA stack (`speaker` prop's home), lots crashed team
bus, culvert junction chamber.

**Contested-site candidates (§9.2, Phase 7E — reserved now):** one per surface zone — fields camp
chain, lots dock, pitch islet approach, lane gatehouse, ridge spillway (+1 TBD in Phase 4) → the ~6
predefined sites the daily rotation needs, with zero rework later. Reservations only (see §5):
they overlay existing POIs and add no activity count of their own.

## 7. Convergence points (§1.1 — designing against the loneliness paradox)

Routes funnel through: the **GY5 gate plaza** (everyone enters here), the **base hub** (services),
the **lots→pitch underpass** (the loop's waist), the **culvert mouths** (the shortcut everyone
learns), and **one designated good camp per hub** (the farm spot). Residents route through the same
points (Phase 4 resident rows; Phase 7 makes their activity visible).

## 8. Traversal budget

At the P2-calibrated effective travel speed (~120–160 su/s including combat drag):

| Route | Distance (derived from the §2 sizes) | Time at 120–160 su/s |
|---|---|---|
| fields straight crossing | 3600 su | ~23–30 s |
| fields with ordinary detours (2–4× per §7) | ~7–14k su | ~1–2 min |
| GY5 gate → base | ~1.5–2k su | ~10–15 s |
| full loop, pure travel (fields 3600 + lots 2200 + pitch 3200 + ridge 2400 out; ridge 2400 + pitch ~1600 + culvert 1000 back) | **~16–18k su** | **~1.7–2.5 min** |
| the same loop *played* (hub detours at the §7 2–4× convention, fights, cache attempts) | — | **~5–10 min** — the intended session lap |
| culvert shortcut vs re-walking lots + fields NE | ~3.5–5.5k su avoided | **~30–45 s saved** |
| lane vs lots (alternate vs main) | similar length, different texture | ~parity by design |

Greybox Phase 2 records the *measured* table against this budget; drift is a finding, not a failure.

## 9. Graphs: interim vs end state

**Interim (Locale 1 ships, before Phase 8):** GY5 → Locale 1 exists alongside ALL current routes —
the Home→Wildlife and GY5→Wildlife pads stay (they are the 25+ cohort's access until Locale 3
exists). **`loc1_gate` = strictly `gy5_command` completed.** Note this is *narrower* than wild_gate,
which also passes pre-W6 grandfathered characters (`wild_ungated` + L8, Server.gd:3607-3609) — so a
grandfathered vet who never did `gy5_command` would have Wildlife access but NOT Locale 1 access
until they clear that quest. Deliberate (Locale 1 is new content; the quest takes minutes at their
level) — but it is an owner-visible cohort difference, surfaced in §10 item 4.

Until the Locale 1 release the gate is **dev-locked + hidden**: `"loc1_gate"` joins `HIDDEN_GATES`
(pad never renders, Server.gd:111) and the `_portal_unlocked` branch returns admin-only (the same
admins-table check the F1 tools use; F1 `goto` also works regardless of gates). The login
re-validation path must honour the same admin bypass, and non-admin logout inside the locale is
impossible by construction (they can never enter). Combined with the §4 S1 rule (every pad into or
within the locale carries the gate), merged batches are inert on any interim release.

**End state (after Phase 8):** Home → Glitchyard (L1–5 tutorial) → Locale 1 (5–12) → Locale 2
(12–19) → Locale 3 (19–25) → Wildlife (25–40, `wild_gate` relocated to Locale 3's far end) →
Finals (40+). The Home→Wildlife and GY5→Wildlife pads are removed **in the Locale 3 release, same
tag** — never before the new route exists. Recommended owner call: keep Home→Base Camp as honest
fast-travel for graduated characters.

---

## 10. THE DECISION BLOCK (the Phase 1 gate — answer per item)

1. **Zone set** — the §2 table: **5 surface zones + 2 pockets + base + boss** (low end of the 5–7
   surface cut; the base counts as the third pocket), names, archetypes, sizes. Approve / edit
   (cut or resize any row; the two hubs must keep h ≥ 2400).
2. **Topology + landmarks** — the loop, the lane alternate route, the shortcut reading (**1
   cross-zone culvert + 1 intra-zone checkpoint**, with lane↔ridge reserved as a future unlockable),
   the **culvert's telegraphed L8 mouth on the L5 entry plaza** (§3 ⚠), press-box and base
   attachment points, and the **landmark chain** (the Floodlight Tower standing in pitch as the
   region's spine, GY skyline W, Bowl E). Approve / redraw.
3. **Naming** — the `loc1_` / `loc2_` / `loc3_` id prefix (client themes dispatch on it), and the
   working display names. Approve / rename.
4. **Attach + gate** — new GY5 pad → `loc1_fields`; `loc1_gate` = **strictly `gy5_command`** (note:
   pre-W6 grandfathered vets who skipped that quest get Wildlife but not Locale 1 until they clear
   it — see §9); dev-locked + hidden until the Locale 1 release. Approve / change the trigger (e.g.
   copy wild_gate's grandfather branch instead).
5. **Old-route timing** — Home→Wildlife + GY5→Wildlife pads stay until the Locale 3 release.
   Keeping Home→Base Camp permanently is recommended but is a **knowing carve-out from the logged
   Option A decision ("the official region is the only route on from base")** — it becomes
   fast-travel for graduated characters rather than a route. Approve / change.
6. **Base** — `loc1_base` off fields at the loop junction; services = tier-1 shop + forge +
   questgiver #3 (practice/build/master-key stay HOME-only). Approve / move / change services.
7. **Instance policy + reward reservations** — everything shared except the `loc1_boss` party
   instance (§2); 2 major + 3 minor cache sites, 5+ tape anchors, 6 contested-site candidates as
   placed in §6 (sites are reservations — exact tuning lands in Phases 4/7). Approve / adjust.
8. **The greybox slice (Phase 2 scope)** — proposed subset: `loc1_fields` + `loc1_pitch` +
   `loc1_lane` (alt route) + `loc1_culvert` (pocket + shortcut) + the Floodlight Tower stand-in +
   the **pitch-islet major cache** as the proven §9.1 encounter. Approve / swap zones.
9. **Per-zone level gradient** — the L5–12 band is already owner-decided (handoff §2); what needs
   approval is its **distribution across the §2 rows** (fields 5–7 → boss 11–12, lane levelled with
   lots at L7–9). Approve / shift.

**No Phase 2 branch until all nine are recorded here and in the decision log.**

## 11. Decision log

| Date | Item | Call |
|---|---|---|
| 2026-08-04 | Items **2–9** (topology+landmarks, naming, gate, old-route timing, base, instance policy+reservations, greybox slice scope, level gradient) | **APPROVED** by owner, as written |
| 2026-08-04 | Item **1** (zone set — names, archetypes, sizes) | **PENDING** — owner needs to see it; a to-scale map artifact was produced ("Locale 1 — the zone set, to scale"). Options offered: approve as drawn / edit rows / approve provisionally and judge in the Phase 2 greybox (whose gate explicitly allows reshaping) |
