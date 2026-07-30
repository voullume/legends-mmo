# World Expansion P2+P3 (SHIPPED v1.14.0) + P4 (BUILT, awaiting owner)

P2+P3 shipped as v1.14.0 on 2026-07-26 (droplet redeployed, live-verified). **§10 below is the P4
"Reclaimed Stadium climb" — BUILT + VERIFIED, uncommitted, awaiting owner evaluation, with an
explicit CAPACITY SHIP GATE the owner must decide before deploy.**
Plans: `docs/world-expansion-handoff-v2.md` §Phase 2/3/4 + §4.

## 1. What away_1 became

**2600×950** (was 1700×950 — the game's widest zone, deliberately out-sizing the 2000-wide late
zones), composed as one west→east pilgrimage, ~15–19 s gate-to-Bull at base speeds:

- **Act 1 — THE RELICS (x 200–900, P2):** entrance gate wings + pylons, cone drill-gates, L9 skink
  camps, the west relic plaza, facility wall fences, Home Towers on the west horizon.
- **Act 2 — THE OVERGROWTH (x 900–1560, P2):** grazer camps, fallen-log walls, the overgrowth
  threshold, Half-Time Oak (1100,185), the Season Monument beacon + render-only wildflower meadow
  at the away_2 return drop (1080,475), the Coach's Last Stand nest pocket (rare L10 skink pair,
  r60 ring, cache + quest-board lore point), the mid rack cover (1230,475). Act 2 ends at **THE
  BROKEN GOAL** (P3): two fallen log posts astride the lane at x1560 between the kept P2 corner
  pylons — the old field ends here.
- **Act 3 — THE WILD YARDS (x 1560–2600, P3):** decaying fence remnants, a L10 lane column
  (skink N @1840,335 / grazer S @1850,620, rings r110), then the hush; a grass trail creeping
  north at x~2085 — breadcrumb to **THE NEST WOOD**: the **Nest Broodmother** (netvine_skink
  **L11 elite** @2080,80), the off-route champion the P2 pocket foreshadows, in a tree-flanked
  single-south-mouth lair (r80 ring, dragged-gear cache, stone flank cover). On-route climax: the
  **Old Bull relocated with his whole arena kit to (2320,475)** — dragged-rack blockade @2130,
  wallow ring, horn stones, flank bags, clean recovery arena — exactly 200 from the forward pad
  (the shipped guard grammar). Then the funnel and the summit: forward pad **(2520,475)** and the
  **FIELD ENTRANCE CHECKPOINT** — the game's first intra-map portal pad @(2250,860), a SE plaza at
  the Sideline Walk terminus (Return Anchor marker, Watcher's Bench vista toward the Bowl),
  outside EVERY camp's aggro; walk on → arrive (210,475) beside the west spawn. The Sideline Walk
  now runs the full south edge (Last Bleacher @1780, vista bench @2180, turn pylon) and rejoins at
  the 2250 cone ladder.
- **Horizon compass:** N Grandfather Pine, E the Reclaimed Bowl (stadium h30, now sim 4000 —
  foreshadows away_3), W Home Towers, SW Glitchyard smokestacks. East backdrop band shifted +900
  with the zone; 8 new north/south band trees cover the new apron.

## 2. Changed files (combined P2+P3)

| File | Change | Ship class |
|---|---|---|
| `data/decals/away_1.json` | 22 → **115 records** (P2 +61; P3 +32 adds & 13 moves/edits) | **SERVER+CLIENT** (feeds `collision_from_decals`) |
| `data/backdrops/away_1.json` | **NEW**, 34 silhouette records (client-only; intent-to-add staged) | client-only |
| `shared/World.gd` | MAPS w 2600; fwd pad → 2520; **+checkpoint pad (intra-map)**; Bull → 2320; MOBS +5 (P2 nest pair, P3 Wild-Yards pair + Broodmother); OBSTACLES +4 / 2 moved | **SERVER+CLIENT** |
| `shared/Quests.gd` | `away1_blocker` match gains `"class": "tacklehorn_grazer"` (the Broodmother must not cross-credit the Bull) | **SERVER+CLIENT** |
| `client/Client.gd` | `_render_decals` rebuild sig now includes dims (latent re-anchor trap closed); ELITE_LOOKS gains the Broodmother (`netvine_skink` minLevel 11 — viridian tint ×1.12, **tint hex owner-swappable**) | client |
| `tools/stab_away.gd` | pins 10 spawns / 6 skink / 4 grazer; walks → 2520; class-filtered elite select; fixed stale 1500→1420→2320 chain; **+checkpoint round-trip walk + arrival-aggro asserts (×10 camps)** | test |
| `tools/test_wildlife_normals.gd` | roster dict {skink 6, grazer 4} | test |
| `tools/smoke_prop_loads.gd` | scans `data/backdrops/*.json` too (65 ids guarded) | test |

No new mob defs (golden untouched), no new quests (XP-band test math unchanged), no DECAL_PANELS
walls, no new assets, no MAPS h change, no new server systems (the checkpoint is plain PORTALS
data — the normal teleport path handles to==self).

## 3. Traversal (recorded before each phase)

Pre-P2 baseline (1700-wide): spawn→fwd pad 1420 su ≈ 10.2–11.1 s; spawn→elite 8.8–9.5 s;
perimeter ≈ 35–38 s. Post-P3 (2600-wide): spawn→fwd pad ~2320 su straight / ~2440 weave =
**14.7–19.1 s**; Bull at 13.2–17.2 s; Broodmother side-trip ~350 su (2.1–2.7 s) off-route;
Sideline Walk loop +3.5 s over direct; checkpoint return **0 s vs 14–19 s walk-back**. Max
route gap 330 su (~2.0–2.6 s) — far inside the 20–40 s POI rule and at P2's ≤~300 su de-facto
cadence. Leash (1600) becomes reachable in a field zone for the first time: east camps past
x~1800 can never chase to the west arrival (spawn-protective by construction).

## 4. Verification (combined)

- Headless import 0 errors. **bal_identity byte-identical through BOTH phases** (matches=336,
  sig_w=158545831, sig_d=343688940 — identical before P2, after P2, after P3).
- **stab_away 170/170** (pass-2 r+16 sweep over all 115 decal records + 10 camps + 9 obstacle
  rows + 4 pads + 4 drops; NEW: intra-map checkpoint round-trip walk + arrival >320 from every
  camp), test_wildlife_normals 64/64, test_class_kits 223/223 (**golden unchanged**),
  stab_basecamp 32/32, smoke_prop_loads 65/65.
- Python checkers gated both JSON writes (P2: `build_p2_away1.py`; P3: `build_p3_away1.py` — adds
  ring EDGE math, obstacle segment distances, leash margins, backdrop near-face rule vs the new
  clamps; the edge rule caught and fixed one real lair-tree intrusion pre-write).
- Design provenance: each phase ran a 3-design judge panel (P2: A won 93/86/90 + B/C grafts;
  P3: split verdict — A's composition 86 player / C's checkpoint+asserts 92 compliance — merged
  exactly as both judges' synthesis prescribed, incl. B's ring-edge standard and the thin-margin
  nudges: Broodmother↔N-camp 350, arrival (210,475) at 342 from the L9 camps, checkpoint plaza
  outside all aggro).
- Adversarial reviews: P2 — 10 agents, 3 majors all resolved, geometry clean. P3 — run on the
  delta (results in the session log; confirmed items resolved before this report).
- Screenshots (`docs/world-expansion-p2-shots/`): 5 BEFORE + 14 P2-AFTER + 6 P3 views (hinge
  default/horizon, checkpoint plaza, west-look, Nest Wood with the Broodmother visible in her
  lair, monument-east comparison). Live-capture recipe + combat-lottery notes in §7.

## 5. Ship plan — ⚠ ONE server+client release + droplet redeploy

Decal JSON feeds server collision at boot; MAPS/PORTALS/MOBS/OBSTACLES/Quests are shared. When
approved: commit everything (incl. the intent-to-add `data/backdrops/away_1.json`) →
`deploy/release.sh` (verify `gh release view`) → wait for CI (check `:latest` image age) →
droplet redeploy via `deploy/setup.sh`. A client-only publish would desync collision, hide the
new camps/pads, and strand the enlarged map bounds server-side.

## 6. Owner-decision items (none blocking)

1. **Zone-size gradient**: away_1 (2600) now out-sizes every late zone (2000). Intentional
   (exploration flagship) — flag if the gradient fiction matters.
2. **Leash visibility**: a leashed mob snap-teleports home + full-heals (shipped mechanic, first
   time visible in a field zone). Soften only if playtest complains.
3. **Broodmother cadence**: default 6 s elite respawn (per-row rarity doesn't exist; a def edit
   would rebase the golden). Instant re-farm of an L11 elite — gated by kill difficulty at-level.
4. **away1_blocker re-key**: in-flight quests keep stored progress; the matcher only affects
   future kills. The desc still reads true ("the east lot").
5. P2 items that still stand: wallow-ring vocabulary, nest respawn, discovery affordances,
   monument/flora scale, stadium.glb weight (578k verts — now 1450 su past the clamp again),
   entrance-frame/loop tuning at playtest.
6. **Reclaimed Bowl legibility**: at sim 4000 the Bowl is ~42% fog transmittance from mid-zone —
   a fainter "distant destination" read than P2's. Deliberate; judge from the captures.
7. **Broodmother tint** (from the P3 adversarial review — she'd have shipped as a baseline skink,
   regressing the A4 elite-look standard): fixed with `#3A5230` brood-queen viridian ×1.12,
   minLevel-11-guarded so no other skink can ever match. **The hex is yours to swap** — one dict
   value in Client.gd ELITE_LOOKS, same approval flow as the A4 palette.

## 7. Capture ops notes

Solana (smoke bot) ended the combined sessions at L5 / 393 xp / 280 credits (legitimately earned;
the `characters_guard_progression` trigger is service_role-only and correctly refuses SQL
boosts/rollbacks). Position restored to home (574.41, 607.63); settings.cfg byte-verified after
every session. Static captures in away_1 are a combat lottery (residents drag camps/elites across
arrival points): fresh server + full-HP login + shoot immediately + retake-on-vignette. The
checkpoint pad teleports a logged-in idle bot after TP grace — never park a capture bot ON a pad.

---

# §10 — P4: The Reclaimed Stadium Climb (BUILT 2026-07-26, uncommitted)

The portal-stacked landmark (handoff §Phase 4): vertical progression as flat maps, no sim height.
away_3 is the exterior layer; **two new zones** stack above it:

- **The Superstructure Gate** (away_3, north-central @1270,140, beside the gold bowl): arch + service
  door + light columns; walk north through it.
- **`away_3_concourse`** (1200×700, combat): the under-stand gallery — gloom palette, stadium-deck
  concrete (new `stadium_deck_albedo` texture), window-rail north band with the **bowl backdrop
  looming h60+ through it**, interior walls with service bays, locker/shelf rows, the ransacked kit
  shelf (Hoard foreshadow), **4 rallywing_magpie** (3 L15 roosts w/ nest-scrap dressing + the L16
  **Rafter** elite — the shipped silvered ELITE_LOOKS applies). Fog 0.0085 (the plunge).
- **`away_3_roof`** (900×560, combat/**aggro-false**, NO mobs): the capstone overlook — sun-washed
  deck, fog 0.003 (the burst), the **h78 crown bowl** over the north rails, the magpies' **Hoard**
  (stolen trophy + pried chest in a nest ring), benches, and the world-below miniature south vista.
  **No rim ring + apron pulled to fog** (review fix): the deck edge drops into haze. Resume-at-logout
  preserved (ARENA pattern).
- **Transitions**: concourse NE stair ▲ roof; roof stairhead ▼ concourse; **west gantry express ▼**
  straight to the gate base (1345,140) — the P3-checkpoint precedent, saves the whole reverse walk.
  Every inbound pad carries wild_gate (S1). Compass held at every layer (bowl N, field S).

## Changed files
`shared/World.gd` (+2 MAPS/spawns/consts, +5 PORTALS, +MOBS[AWAY3C]) — **SERVER+CLIENT**;
`data/decals/away_3.json` 24→32 + 2 NEW layer decal files + 2 NEW layer backdrop files (all
intent-to-add staged) — decals are **SERVER+CLIENT** (collision), backdrops client-only;
`client/Client.gd` (theme branches ×2 before the away-prefix check, per-layer fog, roof rim
early-out); `client/NetClient.gd` (zone names, F1 CONC/ROOF); `models/.../stadium_deck_albedo.png`
+ sidecar (tracked, mipmap parity); `tools/gen_ground_textures.py` (originals byte-stable);
`tools/stab_away.gd` (sweep lists + P4 pins + climb walk + tamper-restore);
`tools/test_wildlife_normals.gd` (+concourse roster).

## Verification
Import 0 errors. **stab_away 183/183** (climb round-trip walk, phantom-wall sweeps over both
layers, gate pins, tamper-restore→HOME, mob budget ≤5). wildlife 69/69, kits 223/223 (**golden
unchanged**), basecamp 32/32, props 65/65. **bal_identity byte-identical** (336/158545831/
343688940 — the same signature through P2, P3, and P4). Builder checker caught 4 gate-orientation
bugs + the panel-height/phantom-wall class pre-write (engine conventions probed: row axis =
(cos yaw, sin yaw); panels need shipped heights for anchor-centered circle rows). 3-design judge
panel (A's ascent illusion + C's compliance chassis + B's Hoard); 7-agent adversarial review →
3 confirmed (roof illusion fixed + re-captured; this report section; memory), 0 refuted.
Shots: `docs/world-expansion-p2-shots/P4_*.png` + `BEFORE_p4_*.png`.

## ✅ CAPACITY GATE RESOLVED — the owner picked option 1; the sleep is BUILT and rides this release
Context: the droplet idled past its tick budget (`peak_tick` spikes **36.2/49.1 ms vs 33 ms at
ZERO players**, 16 zones, 1 vCPU) — the unresolved Phase-8 watch-item — and P4 adds 2 zones.
**The Phase-6 §1 empty-zone sleep is now implemented** (`server/Server.gd`, server-only):
- A static zone with **zero real players skips its whole `_tick_world`**. Occupancy re-derived
  every sim sub-step from peer sessions (every entry path updates the session synchronously →
  a fresh arrival wakes its zone before first sim contact, no wake hooks). Instances always tick.
- **12 s drain window** after the last player leaves (combat settles: leash-heal, projectiles/
  hazards/DOTs expire) — nothing sleeps mid-fight.
- **Respawns need zero catch-up**: the respawn queue was already global — the 6 s/45 s/120 s/
  1800 s cadences count through sleep and revive inside sleeping zones (test-proven).
- **Bonded residents' zones never sleep** (party frames are the only cross-zone surface);
  the RP4 stall scan is gated for sleeping zones (no fabricated `no_progress` reports);
  the heartbeat lockstep read fixed; `[health]` now shows `asleep=N/M`.
- **Measured: idle `peak_tick` 1.9 ms with `asleep=18/18`** locally vs the droplet's 19.8–49.1 ms
  baseline (~10–25×). New suite `tools/stab_sleep.gd` **14/14** (boot-sleep, frozen clocks,
  login/portal wake, drain, through-sleep respawn, bonded exemption, RP4 gate); full battery
  re-green (stab_away 183, basecamp 32, wildlife 69, kits 223 golden unchanged, props 65);
  bal_identity **byte-identical** (server-only — 4th consecutive identical signature).
- Adversarial review (3 lenses): zero code findings confirmed; an instance-key leak in the drain
  map was caught as a minor and fixed. Post-deploy: capture before/after `[health]` and expect
  `asleep=18/18` at idle.

## Ship plan (when gated + approved) — 3rd consecutive SERVER+CLIENT release
Commit everything incl. the 4 intent-to-add layer JSONs + texture/sidecar → `deploy/release.sh`
(verify `gh release view` — both binaries) → CI (`:latest` image age) → droplet redeploy →
before/after `[health]` capture → live climb smoke. Also at ship: update CLAUDE.md's "16 zones"
(becomes 18) and the away_3 stale drill_sergeant comments if desired.

## Accepted tradeoffs + owner-taste items (on record as decisions, not oversights)
1. Layer kills credit **nothing** map-matched (away3_* quests/bounties key `away_3` exactly);
   the class-matched wild3 magpie quest gains a faster completion spot (quantified: not a
   degenerate farm). A future "Concourse/Roof" quest is a separate owner call.
2. Old clients on the new server: the layers render with the away-family wildrange fallback +
   capitalized zone names + invisible walls at layer decor — the accepted skew class (same as
   P2/P3; heals on client update; server-first deploy order).
3. The Rafter's aggro margin to both new arrivals is 338 (18 over the 320 line) — inside shipped
   grammar but the tightest P4 margin. The concourse is the smallest aggro-true map (engaged
   roosts never drop aggro in-map — a fight is a fight).
4. Roof AFK audit clean (no accrual/services; regen 0.012). Roof stairhead arch is decorative
   (not walked through) — grammar nit. Moss patch mask reads slightly banded — texture-polish
   candidate. Concourse reads "gloomy under-structure yard" more than hard interior (no ceiling
   plane exists in the engine) — accepted.
5. S4 reserved surface untouched (verified: no finals ids/gates/order contact).
6. **The sleep's design cost (owner sign-off)**: with zero players online, all 18 zones sleep —
   so the 11 AI residents freeze and their RP4 automated-playtest report stream is suspended
   wherever no real player is. This is the point of the patch (residents would otherwise pin
   11/18 zones hot and gut it). When a player enters, the zone wakes that same sub-step — the
   visible artifact is residents idling at spawn (possibly part-damaged) rather than mid-grind.
   If the 24/7-playtest fiction matters more than the CPU, the alternative is a low-rate tick
   (every Nth step) instead of a full stop — say the word and I'll switch the mechanism.
7. Ship note: the sleep is server-only but rides the P4 **server+client** train as one release;
   commit `server/Server.gd` + `tools/stab_sleep.gd` with the P4 files.

---

# §11 — P5: The Zone-Distinction Pass (BUILT 2026-07-27, uncommitted)

The broader distinction pass (handoff §Phase 5): every remaining zone gets its family's skyline,
landmark hierarchy, and motif — so a screenshot of any zone is identifiable by palette + silhouette
alone. **15 backdrop files** (client-only) + **4 GY leveling-zone decal upgrades** (server+client).
Quiet zones stayed quiet. No new maps/mobs/quests/textures.

## The four family languages (all judged 90–93, zero fatal flaws)
- **THE GLITCHYARD — the Command Tower escalation.** One warm sodium-amber tower (`#4A3B28`, the
  only tinted mass on a smog-slate horizon) carries the whole leveling arc: **gy2 first-sighting**
  (a faint distant spike down the lane) → gy3 grows + resolves detail → gy4 dominates → **gy5 LOOMS**
  (the zone named for what fills its east sky, directly behind the Head Coach pad). At the boss
  arenas (gy_boss/gy_secret) the tower is *gone because you're inside it* — low industrial masses
  pressed close on all four edges, oppressive but sparse. Captures confirm the escalation: gy2 spike
  → gy5 looming mass.
- **THE AWAY REMAINDER — the Bowl gradient.** The Reclaimed Bowl (`#6B5426`) that away_1 sees at
  h30/sim-4000 is **closer and larger on away_2's horizon**, framed by treelines; away_3 gets the
  horizon band around its in-zone gold bowl (a deliberate x650–1350 north gap so the bowl decal
  silhouettes against open sky); away_boss is **ember-den dread** (`#452718`) — a low jagged ridge
  and sparse dead trees, not clutter.
- **THE FINALS — the championship city at night.** Violet-tinted city masses (`#3B3366`/`#2A2450`/
  `#1C1838`, 3-step depth) loom monumentally to the **west** (the district you came from) and thin
  toward the **east**, where the horizon stays **deliberately dark and empty — the S4 sealed gate
  promises something beyond, and nothing implies structures there.** Verified via `--biome` on a
  dims-matched host: indigo night + violet skyline, unmistakably distinct.
- **THE HUBS — calm.** home/basecamp/arena get low, mostly-untinted green masses (a town band at
  home, forest treelines at basecamp, spectator grandstands + green-teal floodlights at the PvP
  arena). Restraint was the deliverable — 6–8 records each; home reads as the safe town center.

## GY decal upgrades (gy2–5 — the only server-collision change)
Each new `data/decals/glitchyard_X.json` reproduces its const rings/cones **verbatim** (shadowing
is total), then adds the gy1-pilot grammar: entrance rack framing, a ruined `glitchyard_wall` north
boundary, service clutter, and per-zone lane motifs serving each fiction (Agility Grid pylon grid /
Impact Lanes crash bumpers / Target Court supply racks / Command Tower command-avenue). 13–14 new
props per zone; every new collision circle clears every spawn/pad/drop/camp by r+16 (checker-proven)
and sits outside every const camp ring.

## Changed files
| File | Change | Ship class |
|---|---|---|
| `data/backdrops/*.json` | glitchyard_1 re-seated + 14 NEW skyline files (161 records) | client-only |
| `data/decals/glitchyard_2/3/4/5.json` | NEW — const-verbatim + GY-motif props | **SERVER+CLIENT** (collision) |
| `shared/Protocol.gd` | **VERSION 2 → 3** + decal-data added to the bump criteria (review fix 1) | **SERVER+CLIENT** |
| `client/NetClient.gd` | `_zone_name` for glitchyard_boss/secret | client |
| `tools/stab_away.gd` | phantom-wall sweep: every panel-carrying map, sampled to the true ends; **+const-verbatim parity; +camp engageability** | test |
| `tools/stab_sleep.gd.uid` | NEW — the v1.15.0 P4 leftover | tracked artifact |

## Verification
Import 0 errors. **stab_away 233/233** (the phantom-wall sweep now covers every panel-carrying map
— incl. the previously-unchecked away_boss/finals_1, a latent gap closed with no bug behind it —
and samples the true wall ENDS; plus the NEW const-verbatim parity and camp-engageability asserts,
both added by the review below). wildlife 69/69, kits 223/223 (**golden unchanged**), basecamp
32/32, smoke_prop_loads 66/66, stab_sleep 14/14. **bal_identity byte-identical**
(336/158545831/343688940 — 6th consecutive). A python checker gated every write (gy decal r+16
keep-clears, const-verbatim reproduction, backdrop near-face; auto-nudged 2 marginal gy1 masses,
15 su and 35 su). 4-designer + 2-judge panel (90–93, zero fatal flaws). Captures:
`docs/world-expansion-p2-shots/AFTER_p5_*.png`.

### Claim corrections (from the 4-lens adversarial review, 2026-07-29)
Three numbers in the pre-review draft of this section were wrong or overstated. Recorded rather
than quietly edited, because this report is the recovery anchor:
- **Near-face is NOT "≥1150 su" for all records.** That bar holds for TALL masses only: all 63
  records with `h ≥ 12` sit ≥1180 su outside playable. 112 of 161 records sit closer — the
  mid-ground band (trees/chimneys at ~210–500 su) is the shipped P1B/away_1 grammar, not a
  violation. The in-repo checker's §D rule as coded fails 158 records including shipped away_1.
- **The old phantom-wall sweep did not prove full-length blocking.** It sampled ±0.7 of half-length
  against `r+6`, never touching the outer 30% of any wall. The walls DO block full-length (block
  radius reaches ±145 vs a rendered ±139.5); the test now samples ±1.0 against `r + OBSTACLE_PAD`.
- **The gy1 auto-nudges were 15 su and 35 su**, not "≤18 su". "13–14 new props per zone" is really
  11–12 props + 2 flat cones.

### Review findings fixed in this ship
1. **MAJOR — `Protocol.VERSION` 2 → 3.** gy2-5 had NEVER had decal collision (their consts are
   ring/cone only, which `collision_from_decals` skips); P5 gives them their first, 21/25/22/22
   circles. The client never computes decal collision and the snapshot carries no obstacle list, so
   an old client renders nothing where the server blocks — **invisible walls in the level 2–8
   chain**. Nothing forced an update: the bump criteria enumerated RPCs/snapshot/intents/handshake/
   read models, so shared world *data* divergence structurally could not trip the gate. (This class
   already shipped unnoticed in v1.14.0's away_1.json 22→115.) The criteria list now includes
   "a `data/decals/<map>.json` add/edit"; backdrops stay exempt (render-only).
2. **Two prop clusters welded to const OBSTACLES cover barriers** — a keep-clear class the build
   checker never tested (it checked spawns/pads/drops/camps, not prop-to-const-obstacle). gy2's
   boundary pylons touched at **−0.1 su** and gy4's ball racks left a 3.9 su slit, silently
   extending authored balance geometry's blocked/LOS mass. Pylons x655→630, racks x760→785; the
   min block gap to any const obstacle is now **+23.9 su** across all four maps.
3. **`away_3` backdrop [12] `rock_largeE`** sat **36.6 su** past the invisible wall (shipped away_1
   floor: 197 su) — close enough to occlude the player at default camera. Moved (2270,1330) →
   (2390,1440) ≈ 200 su. *(away_boss[0] at 61 su and finals_1[15] at 76 su are left as owner-taste
   — farther out and less occluding.)*
4. **No test pinned the const-verbatim invariant.** Shadowing is total (`_decals_source` returns
   the file, it does not merge), so a future drift would change live geometry with every suite
   green. `stab_away` now asserts each gy file reproduces `World.DECALS` as an exact ordered
   prefix. *(`data/decals/home.json` is deliberately out of scope: a fully-authored 63-record
   builder-mode file that replaces its const outright.)*
5. **Combat geometry was untested** (traversal was not). The new props join the world obstacle set,
   so they block shots + LOS. `stab_away` now samples 24 firing positions at the 250 su ranged band
   around every gy2-5 camp and requires ≥half to hold LOS — all 20 camps pass.
6. Hygiene: dropped the vacuous `away_2` sweep entry (that file has 0 panel decals); added the
   missing `tools/stab_sleep.gd.uid` (a v1.15.0 P4 miss — every other `tools/*.gd.uid` is tracked);
   rounded two solver-noise coordinates.

**Not fixed, on record:** `World.DECALS[GY1..GY5]`/`HOME` are unreachable in the shipped config
(the JSON always wins) while the block comment still says "purely cosmetic — no collision" and
"tune to taste" — both now false, since `collision_from_decals` derives SERVER collision from that
data. Left as a nit. Also unchanged: elongated props get one `PROP_FOOTPRINT` circle, so e.g.
`sports_ball_rack` renders 88 su long but blocks at r22 — a shipped game-wide property, not a P5
regression.

## Ship plan — SERVER+CLIENT (the gy decal collision)
The 4 gy decal files feed server collision, so this is a server+client ship (not client-only despite
the bulk being backdrops). Commit all 18 new files (intent-to-add staged) + the 2 modified →
`deploy/release.sh` → verify `gh release view` → CI → droplet redeploy. Empty-zone sleep means the
new backdrops cost nothing while zones are unoccupied.

## Owner-taste items (none blocking)
1. **6 new tint hexes** (`#4A3B28` tower, `#452718` ember den, `#3B3366`/`#2A2450`/`#1C1838` finals
   city, `#617F70` arena floodlight) + 2 reused from the away/P4 palette for material quantization
   (`#6B5426` bowl, `#8A7A66`) — all owner-swappable per the A4 / Broodmother precedent; one
   dict-value each in the JSON.
2. **gy2 first-sighting is faint** (the tower at ~3400 su is a subtle fogged spike — intentional
   "distant destination," confirmed in captures). If you want it bolder, the gy2 tower can move
   ~400 su closer or gain height; the escalation still lands (gy5 looms unmistakably).
3. **gy1 re-seat** height-compensated ×1.4 when pushing the pilot masses past the 1150 bar
   (preserving the from-spawn apparent size). Pure-move revert available if you prefer strict scope.
4. **Finals east horizon** left dark for your S4 boss — the city thins there by design; nothing to
   pre-build until the Commissioner arrives.
