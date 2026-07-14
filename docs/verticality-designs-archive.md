# Verticality Path Designs — Phase-1 Archive (2026-07-13)

Full design blueprints produced for the **Phase-1 decision gate** of `docs/jump-verticality-handoff.md`
(11-agent mine → design → judge workflow). **The gate memo + verdicts live in
`docs/jump-verticality-phase1-decision.md` — read that first; these are the raw blueprints, archived so a
future revisit (e.g. a Phase-8 ride-along) doesn't start from zero.** Each was adversarially judged; all
three scored WEAK (3–4/10) as build-now standalone work-streams. Judge criticisms are in the memo.

---

## Path A — Combat Verticality ("Jump the Shockwave")
**Judge: 3/10 · value weak · playtime barely · identity-fit workable**

### Claimed cost
7-10 sessions risk-adjusted for the full pillar (Slice A MVP 2-3, Slice B class hooks 2, Slice C Upper Deck instance 2-3, Slice D Away Game boss 1-2), vs 9-14 for the handoff's full P2+P3+P4 continuous-z path — the saving comes from avoided work that is provable per §5-ledger item (no gravity integrator, no vertical predictor, no height-aware dist/LOS, no map height, no global re-tune). Plus a deferred, conditional +2-3 sessions (handoff Phase 4 FORMAT_MODS[5] re-measure/re-tune) that becomes MANDATORY only if a tripwire is crossed: vertical enabled in the PvP Arena, in any of the 9 live zones, or in the harness venues. For gate comparison: the whole build is priced at roughly the same budget as length-roadmap Phases 1-3 (the approved work attacking the audited playtime flaw), and only Slices C+D (~3-5 sessions) yield any playtime at all.

### MVP slice
Slice A — "Jump the Shockwave" (L, 2-3 sessions incl. adversarial review). The smallest sim-true verticality worth shipping: (1) server-authoritative air state — `airT`/`jumping` fields initialized in create_fighter (shared/GameData.gd:699), decremented like existing timers; jump intent rides the shipped Phase-0.5 `submit_hop` RPC (already session/rate/alive-gated) with added grounded/not-casting/not-stunned validation; snapshot `hopT` upgraded from cosmetic echo to authoritative airT → Protocol VERSION 2→3, server-first redeploy. Fixed arc: JUMP_DUR 0.8 s (24 ticks @30 Hz), clear window 0.57 s, jump cd 2.0 s. No vertical predictor — z is a derived function of a timestamped event; client keeps its shipped instant-local/snapshot-remote rendering. (2) Dodge adjudication at exactly TWO sites, behind a per-map `vertical` flag (default false everywhere live): hazard-zone DOT ticks (shared/Sim.gd:144-152 — airborne hostiles skip the tick) and a new `groundwave` tag on casted meleeAoe (resolution at shared/Sim.gd:338-349 — airborne at resolve = spared). No apex casts, no launch, no spread-dodge, no class hooks, no homing changes. (3) One teaching room: a new CAMP-family instance ("Upper Deck: Practice Squad") with a tackle_captain-family miniboss using a 0.7 s-telegraph groundwave slam (Hurdle-Shockwave-pattern, shared/GameData.gd:235) plus churn-style hazard zones (GameData.gd:379); mobs get the deterministic zone-escape jump policy only. (4) Merge gate: full-round-robin byte-identity regression (per handoff guardrail 1, docs/jump-verticality-handoff.md:70-77) proving flag-off duel results reproduce bit-for-bit, plus stab_hop/stab_protocol/stab_authority regressions. This slice is worth shipping alone because it delivers one real encounter AND empirically answers the three make-or-break questions — determinism holds, the 30 Hz dodge window feels fair online, the dodge verb is fun — before another session is spent.

### Designer's own biggest risks
- Netcode feel: the server starts the jump 1-3 ticks after the client renders it (no vertical predictor by design); if at real RTT (60-120 ms) the 0.57 s telegraph-timed dodge window lands inconsistently for players while working perfectly for server-side AI, the pillar's core verb fails its fun test in exactly the environment that matters — this is kill-reason 2 and the MVP's primary question.
- Cosmetic-lie surface is structural: homing projectiles (every ranged class's basic, Sim.gd:166-191) and campreset stay un-jump-dodgeable by canon, and the jump stays purely cosmetic in all 9 live zones — players who learn 'jump dodges things' in the Upper Deck will read misses elsewhere as bugs despite seeker VFX and HUD affordances (guardrail-2 violation risk by another route).
- Byte-identity is binary and silent: any accidental float-op reorder, rng draw, or iteration change introduced by the new airT fields voids FORMAT_MODS[5] with no error (Geom.dist alone backs ~30 call sites); the regression harness must gate every merge, and a late-caught violation costs a full re-measure + re-tune (+2-3 sessions).
- Slippery slope to P3: the design's containment ('walls taller than jumps', no terrain, no LOS change) invites exactly the player asks it forbids — 'why can't I jump onto the crate / over the low fence?'; each concession pulls in height-aware LOS/collision, the VERY-HIGH-risk phase this architecture exists to avoid, and scope discipline is owner-enforced, not technical.
- Deterministic no-rng AI jump policy may only tune to 'psychic' (mobs dodge every player groundwave, gutting Batter grandslam / GK sweeper value in vertical maps) or 'helpless' (players trivialize the content); fixing the middle band with randomness is forbidden by the determinism invariant — kill-reason 4.
- Opportunity cost: 7-10 sessions ≈ the entire front half of the approved gameplay-length roadmap (Phases 1-3) which attacks the audited core flaw (build finished at level 1, ~93% questless grind); Slices A+B carry zero intrinsic playtime, so if content Slices C+D are cut for scope the whole investment is novelty — the design is only defensible sequenced after length Phases 1-2, ideally adjacent to the Phase-8 second biome.

### Full design

# COMBAT VERTICALITY — "The Air Game" (Phase-1 gate submission, combat-pillar path)

## 0. The architectural bet that makes this buildable

The handoff prices true verticality at P2 (XL/HIGH: continuous z + gravity + vertical predictor) + P3 (XL/VERY HIGH: map height + height-aware dist/LOS across ~30 call sites) + P4 (L, mandatory re-tune) — 9-14 sessions of the highest-risk work in the codebase (docs/jump-verticality-handoff.md:8,124-146). This design rejects that shape. Its load-bearing decision:

**Height lives in FIGHTERS as a discrete, timed AIR STATE — never in the map, never in continuous physics.**

- A fighter gains two flag-gated fields: `airT` (seconds remaining airborne) and `jumping`/`launched` provenance flags. Render-height is a *derived pure function* `z(airT) = 4·H·u·(1-u)` — there is no `z` variable, no `vz`, no gravity integration, no acceleration term entering the movement loop the handoff warns about (jump-verticality-handoff.md:130-132). `airT` decrements exactly like the ~20 existing timers (`evade`, `untarget`, `stun`, `barrierT` — e.g. shared/Sim.gd:308-320).
- The fighter **never leaves the 2-D plane for movement, collision, LOS, or targeting**. Planar movement continues at full speed while airborne. Canon rule: *every wall is taller than every jump* — so `Geom.has_los` (shared/Geom.gd:29-33), `seg_blocked` (:19-27), `Geom.dist` (:7-8), `clamp_arena` (:10-16), `step_toward`/`separation` (shared/AI.gd:75-148), projectile travel (shared/Sim.gd:31-62,170-195), interest culling (server/Server.gd:4718), mouse picking (client/Client.gd:713) and the camera (:1386) are all **untouched**. That is the entire P3 ledger avoided, by construction, not by deferral.
- Combat reads `airT` only at a handful of *damage-application sites*, each behind a per-map flag `map.vertical` (default false) — the exact shipped pattern of `frontal_mult`/`core_shield_mult`/`wobble`/`pull`/`kbImmune`: no-op-unless-tagged, documented byte-identical (shared/Combat.gd:49-81; Sim.gd:342 comment; Abilities.gd:91 comment; Sim.gd:127-129 comment).

What this genuinely avoids vs. the handoff's P2+P3 (§5-ledger accounting):
- **AVOIDED**: 3-D `Geom.dist` (ledger "very-hard"), floor/ceiling in `clamp_arena`, obstacle volumes (World.gd:271,327), height-aware LOS per call site, height-field map authoring (World.gd:56), 3-D AI pathing (AI.gd:75-118), stacked-height separation bug (AI.gd:121-148), height-aware mouse pick/camera (Client.gd:713,1386), and the **vertical predictor** — the part the handoff calls "the hard part" (:193). No predictor is needed because the arc is a fixed function of time since a server-timestamped event; the Phase-0.5 plumbing already renders remote hops from a snapshot `hopT` (handoff :19-31).
- **PULLED IN** (the honest bill): fighter dict fields (GameData.gd:699), a jump intent (rides the existing rate-limited `submit_hop` RPC, handoff :20-22) + server validation, snapshot `hopT` semantics upgraded from cosmetic to authoritative → **Protocol VERSION 2→3** (guardrail 4), `airT` branches at 3 damage sites + tagged-ability branches in Abilities/Sim/Combat, a knock-up displacement type beside knockback/pull (Sim.gd:333-356 ledger item), AI jump policy, and new content (map/mobs/boss).

## 1. Candidate mechanics — accept/reject

### 1a. High-ground range/damage modifiers — **REJECT** (v1 and recommended never)
Reasons: (i) requires map elevation + height-aware LOS = the full P3 VERY-HIGH bill; (ii) structurally favors the backline — `desired_range`/kite deadbands are tuned flat (AI.gd:63-72, Sim.gd:477-486) and FORMAT_MODS[5] (setter 1.42, pitcher 0.97, GameData.gd:408-419) was measured without it → mandatory global re-tune; (iii) elevation that sees over cover silently deletes the three tuned cover behaviors — pillar-hugging (Sim.gd:439-456), the campreset LOS-spare (Sim.gd:374-377), and the wallStun bait (Abilities.gd:239-246) — i.e. guardrail 5's exact failure; (iv) 0 of 14 maps have any authored vertical feature and both boss arenas are actively hostile to height. Height's positional value is replaced in this design by *safety verbs* (dodge, launch, ground) rather than *damage verbs*.

### 1b. Jump-dodge — **ACCEPT, constrained to three adjudication sites**
The game's first active-defense button. The sim already gates damage per-site, so a dodge is a per-site rule, not 3-D collision:
- **Ground-zone DOT ticks** (Sim.gd:144-152, routed through `deal_damage` opts.dot): skip a hostile whose `jumping` airT is inside the clear window. Zones are ground decals — this matches intuition exactly.
- **Casted meleeAoe with a new `groundwave` tag** (resolution at Sim.gd:338-349): airborne-at-resolution = spared. This is the flagship "jump the shockwave" moment; every boss teach-moment already has a real telegraph (Hurdle Shockwave cast 0.7 GameData.gd:235, Pancake Protocol 0.55 :238, Grand Slam 0.5 :46).
- **Direction-mode spread/ricochet shots** (Sim.gd:55-57): these already skip `evade`/`untarget` targets — the airborne check is one more term in an existing condition. Mob-only today (ball_machine :208-210, gatling :346-348) → naturally PvE.

**Explicitly NOT dodgeable — canon, not omission**:
- **Homing projectiles** (all ranged basics + specials, Sim.gd:166-191): they re-aim every tick and would track a jumper; making them z-miss requires the projectile-z policy this design refuses. Canon: "seeking balls can't be jumped." ⚠ **Cosmetic-lie flag**: players who learn "jump dodges things" will jump at fastballs. Mitigations: distinct "seeking" VFX trail on homing shots, tutorial line in the new content, and the dodge verb only *exists* in vertical maps. This is the design's largest readability risk (see kill-reason 3).
- **campreset/totalreset** (Sim.gd:361-377): stays a pure LOS verb; GY_BOSS/GY_SECRET are `vertical:false` forever under this design, so the cover rings, the pull-off-cover pressure (Sim.gd:350-356), and the bait (Abilities.gd:239-246) are never re-validated because they are never touched. The NEW boss gets an *airborne-spare* ult instead (§3), keeping one dodge grammar per encounter.

Deliberately **not** implemented as the existing `evade` (Combat.gd:96-97): evade is strictly broader (dodges melee, homing, everything) — the mined audit's "evade-hop" shortcut would be too strong and would collapse the verb into Slide/Pancake. Airborne is narrower and site-specific; that narrowness *is* the design.

**Timing spec** (tick-aligned, 30 Hz): `JUMP_DUR` 0.8 s (24 ticks); clear window = z ≥ 0.5·peak → u∈[0.146,0.854] ≈ **0.57 s (17 ticks)**; jump cooldown 2.0 s from takeoff; 0.2 s landing no-rejump. Max zone-tick evasion = 0.57/2.0 ≈ 28% uptime — zones keep ≥72% pressure vs a bunny-hopper. While airborne: planar movement 100%, cannot *begin* casts except apex-tagged ones; jump refused while `casting != null` or `stun > 0` (mirrors the shipped hop suppression, handoff :16-17). **Server adjudication**: the server owns `airT` from the tick the (rate-limited ≥250 ms, session/alive/grounded-validated) jump intent arrives; every dodge check is a deterministic read of server state — no client trust, no rng.
- *Touches*: tag data in GameData.gd mob/ability defs; branches at Sim.gd:144-152, :338-349, :55-57. *Showcase*: The Upper Deck rooms 1-2, Away Game boss. *Ledger items*: hazard-zones-flat-discs (Sim.gd:130-152), dir-projectile hit test. *Size*: **S-M** on top of the core verb. *Blast radius*: zero-rng, flag-gated; live zones/harness untouched.

### 1c. Knock-UP ("Launch") — **ACCEPT as forced air state**
Launch = `e["stun"] = max(stun, dur)` (all existing stun handling works unchanged — skip-turn Sim.gd:320, cleanse via Setter `rotation` GameData.gd:86 now also reads as "catching" a launched ally) **plus** `airT = dur` with the `launched` flag. Launched ≠ jumping: launched targets do **not** gain the zone/groundwave dodge (no free escape from your own DOT), and they remain fully hittable — no untarget, so no AI kill_score change needed (unlike the -2.0 untarget term, AI.gd:18). `kb_immune` ⇒ launch-immune (Combat.gd:50-51, same gate already consumed at Sim.gd:332,344,350, Abilities.gd:96) — bosses can't be juggled. **Juggle payoff**: Combat.gd step 4 (:107-109) gains a flag-gated victim-side read — an attacker with `airborneDmg` (Spiker) hitting a *launched* target also gets ×1.12: the volleyball "spike the set ball" fantasy, and the Setter→launch→Spiker team combo.
Conversions (named): `fourthgoal` knockdown 1.0 → launch 1.0 (identical act-lock duration ⇒ near-zero balance delta; flag-gated so flat zones keep knockdown); `powerswing` gains launch only via its Apex-Cast variant (§1d); new boss/mob abilities carry it natively. No other existing kit ability converts — the CC budget the ~50% tune was measured under stays intact in flat maps by definition.
- *Touches*: `fourthgoal`, `powerswing` (apex variant), new mob defs. *Showcase*: Upper Deck room 3, Away Game "Pop-Up Sled". *Ledger*: "knockback/pull/leap/dash have no knock-up" (Sim.gd:333-356). *Size*: **S-M**. *Blast radius*: reuses stun semantics wholesale; zero-rng; flag+tag-gated.

### 1d. Aerial casts ("Apex Cast") — **ACCEPT: the 8-class hook vehicle**
Rule: an ability with an `apex` tag, cast while the caster's `jumping` airT is in the apex window (u∈[0.35,0.65], ~7 ticks), applies its tagged bonus. One branch per tagged handler in Abilities.try_cast (:34-233), reading only `airT` — no rng, no reordering. All eight classes (ability keys from GameData.gd):
1. **Pitcher — "High Heat"**: apex `fastball` (:29) +20% projectile speed, +40 range. Plus zero-sim canon: `perfectgame` (:33) already ignores LOS (Abilities.gd:49-59) — re-skin the barrage visually as a lobbed mortar volley; retroactive vertical flavor for free.
2. **Batter — "Pop Fly"**: apex `powerswing` (:43) converts knockback 60 → launch 0.8 s.
3. **Quarterback — "Sack the Scrambler"**: `sack` (:59) vs an airborne/launched target *grounds* it (clears airT) and stuns 1.1→1.4 s. The anti-air interceptor.
4. **Linebacker — "De-Cleater"**: `fourthgoal` (:73) launch conversion (§1c); `tackle` (:70) also grounds airborne targets.
5. **Setter — "Perfect Toss"**: `set` (:83) cast on an airborne ally extends their airT +0.3 s and guarantees apex-window eligibility for the amped (×1.70) cast — the set→spike enabler.
6. **Spiker — "True Flight"**: `thunderspike` (:96) / `killshot` (:99) leaps become real arcs in vertical maps: the fighter is airborne during a short travel, `airborneDmg` ×1.12 (Combat.gd:107-109) keys off genuine air state, killshot's untarget 0.6 flag retained. ⚠ Determinism: the leap's 2 rng draws (Abilities.gd:124-125) stay at the cast call site; only *resolution timing* changes, and only behind the flag — the legacy instant-teleport path is preserved verbatim when `vertical:false`, so the harness stream is untouched. Class perk: jump cd 2.0→1.2 in vertical maps.
7. **Striker — "Bicycle Kick"**: apex `clinical` (:112) raises its execute threshold 40%→50% (existing execute machinery, Combat.gd:129-140, GameData.gd:106-107).
8. **Goalkeeper — "Scoop Save"**: `divingsave` (:124) also gives the ally a 0.4 s protective hop (skips zone ticks — saving an ally *out of* a hazard); `sweeper` (:125) grounds airborne enemies.
- *Showcase*: all vertical maps; the set→launch→spike triangle is the marquee party moment. *Ledger*: ability range-gate sites (Abilities.gd:36,50,61,81,108) get airT reads, not dist changes. *Size*: **M** for all eight. *Blast radius*: tags inert in flat maps and absent from harness venues; zero live-zone effect.

### 1e. Vertical boss — **ACCEPT as a NEW encounter; REJECT any GY_BOSS/GY_SECRET retrofit**
**"Head Coach: Away Game"** — an instanced rematch (attunement-gated, Camp-Circuit-family) in **The Upper Deck**, a new flat-floored stadium instance. Mechanics:
- **"Pop Fly" whistle**: an arena-wide ult reusing the shipped 3-s frozen-telegraph machinery (Abilities.gd:203-211) and the campreset resolution skeleton (Sim.gd:361-377) with **one substitution: spare-if-airborne instead of spare-if-LOS-blocked**. Same fixed iteration, opts.dot, zero rng. The vertical mirror of the game's best mechanic — jump at the whistle or eat 120+.
- **"Pop-Up Sled"**: primesled-family charge (GameData.gd:264) dealing launch instead of wallStun — sets up add burst windows.
- **Volley waves**: spread-projectile adds (ball_machine family, :208-210) whose fans are jump-dodgeable via the Sim.gd:55-57 check; one **homing "seeker" turret** provides undodgeable pressure so jumping is a timed decision, not a stance.
- *Touches*: new boss def + one new resolve branch beside campreset. *Showcase*: itself. *Size*: **M-L**. *Blast radius*: new content only; existing bosses byte-untouched.

### 1f. Terrain elevation (platforms/ramps) — **REJECT for v1**
Even "discrete platforms" reopen LOS policy, mouse-pick, and AI-pathing questions (the P3 bill in miniature). If verticality graduates, platforms belong in the length-roadmap Phase-8 second biome, designed vertical-native (per the world audit: new arenas, not retrofits).

## 2. Determinism, harness, and balance — the exact story
- **Byte-identity mechanism**: every combat read of `airT` is behind `state.map.get("vertical", false)`; harness venues (GameData.gd:423-435) never set it; no mechanic adds/reorders/removes an rng draw (jump/dodge/launch/apex/ground are all pure reads + timer writes; crit stays 1/hit Combat.gd:151, leap draws stay 2-at-cast Abilities.gd:124-125); fighter iteration stays fixed-array-order; new dict keys are additive with initializers in `create_fighter` (GameData.gd:699). **Merge gate** (per guardrail 1, handoff :70-77): a regression harness run — full round-robin, all seeds × maps — must reproduce pre-change duel results bit-for-bit before any slice merges. This is the same pattern the codebase already ships and documents at Sim.gd:127-129, :342 and Abilities.gd:91.
- **"Gateable ≠ balance-neutral" — answered by containment, not denial**: the mined audit is right that a player-only verb the harness never sees can silently divorce harness from live. This design's answer: the verb has *zero combat effect anywhere the FORMAT_MODS tune describes*. The 9 live zones, ARENA, and the harness stay `vertical:false`; there Space remains the shipped cosmetic hop (handoff Phases 0+0.5). Combat verticality exists only in new instanced PvE content, whose mob tuning is per-encounter (like the existing Intensity ladder) and was never part of the duel table.
- **PvE-only first**: yes — ARENA keeps `vertical:false`. PvP air-game is a named tripwire, not a v1 goal.
- **FORMAT_MODS re-tune tripwires** (any one ⇒ handoff Phase 4 becomes mandatory, budget +2-3 sessions): (1) `vertical:true` on ARENA or any of the 9 live zones; (2) vertical variants added to harness venues; (3) apex/launch tags made active in flat maps. **Graduation process if tripped**: extend venues (GameData.gd:9,422-435) with vertical variants, give the harness AI the same deterministic jump policy built for mobs (§3), full re-measure via the tools/bal_tune.gd round-robin, re-tune FORMAT_MODS[5] back to ~50% ± the 2026-07-10 spread — exactly the shipped 2026-07-10 procedure.

## 3. AI — so mobs and bots are not helpless
- **Deterministic jump policy, zero rng** (vertical-map mobs + AI residents only, keyed on a per-def `canJump`): (a) *zone escape* — grounded + inside a hostile dmg-zone (reusing the existing zone-repel scan, AI.gd:140-147) + jumpCd ready → jump; (b) *telegraph dodge* — scan hostile casters (fixed order) for a `groundwave` cast whose remaining time ≤ arc-rise and whose planar radius covers self → jump. Mob jumpCd 3.0 s + a fixed per-def reaction threshold (not rng) keeps them dodging *some* player grandslams, not all — tuned per encounter like HP/dmg.
- **Anti-air pressure**: grounding melee mobs and the homing seeker turret ensure a jumping player is making a trade, not exercising immunity.
- **No new movement brain**: no elevation pathing exists because no elevation exists; `kill_score`, focus centroid, peel, separation (AI.gd:16-148) are untouched. Launched targets stay hittable → no kill_score term needed. This is the single biggest AI saving vs. high-ground designs, which the audit correctly says need a new brain.

## 4. Netcode
Reuses Phase 0.5 wholesale: `submit_hop` RPC (session/rate/alive-gated, 250 ms limit — handoff :19-31) becomes the jump intent in vertical maps; snapshot `hopT` upgrades from cosmetic echo to authoritative `airT`; **Protocol VERSION 2→3**, server-first redeploy (CLAUDE.md shared-change rule). No vertical predictor: z is derived from a timestamped event; the local client renders instantly (as shipped), the server starts the arc ≤ RTT/2 (~1-3 ticks) later. Feel holds because dodging is *telegraph-timed* (0.55-3.0 s wind-ups) against a 0.57 s clear window — 30-100 ms of start-offset is ~6-18% of the window, and the MVP's explicit job is to verify this online (kill-reason 2).

## 5. Slices, sizes, costs
- **Slice A — "Jump the Shockwave" (MVP, §6)**: core air state + intent/snapshot/Protocol bump + zone-tick & groundwave dodge + one teaching room + byte-identity regression. **L (2-3 sessions)**.
- **Slice B — Class Air Game**: Apex Cast ×8 + Launch + Grounding + spread-dodge + juggle rule. **L (2 sessions)**.
- **Slice C — The Upper Deck**: 3-room instance (slam room / volley-turret room / juggle room), ~4-5 new mob defs (existing GLBs + existing ability types + new tags), AI jump policy. **L (2-3 sessions)**.
- **Slice D — Head Coach: Away Game** boss. **M-L (1-2 sessions)**.
**Total ≈ 7-10 sessions risk-adjusted**, vs 9-14 for the handoff's P2+P3+P4 — the saving is real and attributable: no gravity integrator, no vertical predictor, no height-aware LOS, no global re-tune. Deferred conditional: +2-3 sessions (P4) only if a tripwire in §2 is crossed.

## 6. Kill-reasons (discoveries that abort this path)
1. The byte-identity regression fails with the flag off (any float/order perturbation from the added fields) and cannot be root-caused within one session → revert to Phase 0.5.
2. Online feel test fails: at realistic RTT (60-120 ms) the telegraph-timed dodge lands inconsistently for players while working perfectly for server-side AI → the pillar's core verb is not fun in the environment that matters.
3. Playtest cosmetic-lie: despite seeker VFX + HUD affordance, players consistently jump at homing balls or at flat-zone AoEs and report misses as bugs → the dual-mode jump (cosmetic in 9 zones, mechanical in new ones) is incoherent.
4. The zero-rng AI jump policy can only be tuned to "psychic" (dodges every player groundwave — Batter/GK AoEs feel useless) or "helpless", and fixing it would require rng the determinism invariant forbids.
5. Owner cuts content slices C+D: A+B alone are a system with nothing to play — zero-playtime novelty; do not ship the system without its content.
6. Slice A discovers the `hopT` reuse can't carry authoritative semantics (e.g. players demand air control → real vz) → cost reverts toward true P2 → return to this gate.

## 7. Playtime — the honest statement
The active priority is playtime (docs/gameplay-length-handoff.md: build finished at level 1, ~93% questless grind). **Slices A+B add zero intrinsic playtime** — they are novelty/depth. Slices C+D add ~1.5-2 h of authored instanced content — roughly what the same sessions spent on length-Phase 3 (roster remix + multi-room Circuit, also L) would buy *without* sim risk. This design's real pitch is not hours; it is a **differentiating combat verb** that the sports fantasy is begging for (set→launch→spike, pop flies, bicycle kicks) and a **force multiplier for future content**: if it exists, length-Phase 8's second biome ("Away Circuit") ships vertical-native. **Sequencing recommendation to the gate**: (1) commit/deploy Phases 0+0.5 now — the only outstanding verticality work with unconditional positive ROI; (2) run length-roadmap Phases 1-2 first (they attack the audited flaw directly); (3) if combat verticality is greenlit, schedule this design adjacent to length-Phase 8 so the sim work amortizes across a biome that was already budgeted — that is the only sequencing in which the Air Game buys playtime rather than displacing it.

---

## Path B — Traversal Verticality ("Grandstand / Season Tickets")
**Judge: 4/10 · value weak · playtime barely · identity-fit workable**

### Claimed cost
MVP (T0+T1 Grandstand slice): ~1.5 sessions, zero sim risk. Full traversal path as designed: T0+T1 ≈ 2–3 sessions (zero determinism/balance exposure) + optional T2 discrete layers ≈ 3–5 sessions (shared/ + Protocol bump #3, medium risk, new-content-only) folded into length-Phase 8, +1–2 content-authoring sessions inside Phase 8's existing XL budget ⇒ ~5–8 sessions worst-case for everything traversal can actually use. For comparison, the continuous-z route the handoff priced (P2 XL + P3 XL + P4 L = 9–14 sessions) buys precision platforming that 30 Hz + 50–150 ms latency cannot deliver (landing tolerance must exceed ~35–45 units ≈ a portal pad), plus +4–6 more sessions if existing flat maps were retrofitted — traversal should never fund it.

### MVP slice
HOME "Grandstand" slice (~1–1.5 sessions, client+content+small server, ZERO sim/Protocol/balance exposure): (1) T0 terraced bleachers on HOME's south stadium rim — client heightmap raises model/nametag/shadow/ring/camera-focus; standing room enforced by real server-side collision-circle fences (merged obstacle list, Server.gd:435) with one ramp mouth; railings on every edge; placed outside the training dummy's 420-unit max ability range (World.gd:76-77, GameData.gd:60) so no cast can expose the flat sim. Remote players render correctly with no snapshot change because height is a pure function of replicated (x,y). (2) One T1 mechanic: 5 "Season Ticket" vantage pads (bleacher top + map corners), server-side 2-D radius checks in the _check_portals pattern (Server.gd:3346-3354), first-visit credits + a counter, added as a new rate-limited/serialized "visit" objective type (Quests.gd is kill-only today, :29-164). Sim-true in the sense that matters: the SERVER decides whether you reached the place (collision + pad radius), render height is presentation, and nothing on screen implies a combat interaction the sim won't honor. This slice is also the appetite test — kill-reason #1 reads its telemetry. (If the gate insists the MVP contain an actual sim field, the smallest is instead a T2 layer-pilot in a new private instance off CAMP_B: 1 ramp, 1 balcony, mob-free layer 1, ~2-3 sessions + Protocol bump — but that should wait for the second-biome decision.)

### Designer's own biggest risks
- Cosmetic-lie drift at T0: the whole zero-sim tier rests on authoring discipline (railings on every edge, no walk-under geometry, risers outside the 420u range band of any attackable entity); one careless riser near the training dummy or a future attackable makes 'I shot from the balcony and it hit through the floor' a live bug report, and there is no code guard — only content review.
- T2 scope creep silently converts it into full P2+P3+P4: its cheapness rests on three rules (same-layer-only combat, mob-free layers, flat harness); the first owner request to 'just let players shoot down from the ledge' re-triggers height-aware LOS, the FORMAT_MODS[5] full re-measure, and GY_BOSS/GY_SECRET re-validation — the exact bill this design exists to avoid. Kill-reason #4 must be enforced, not renegotiated.
- Opportunity cost vs the owner-locked length roadmap: even the 1.5-session MVP competes with length-Phase 1 (XP economy, queued next); traversal playtime is a dessert (~1-2h one-time + weekly minutes) while the audited core flaw (build finished at level 1, ~93% questless grind) remains the real playtime bottleneck — sequencing this before length-Phases 1-2 would be spending the budget on garnish.
- Player expectation of real platforming: bleachers, catwalks, and jump flavor may tease timed-jump challenge the engine cannot deliver (30 Hz quanta + 50-150 ms latency + WASD orbit-cam controls); if any T1 content is framed as a jumping challenge rather than generous traversal, it reads as broken controls and damages the shipped hop's goodwill.
- T1 server surface is new exploit surface: visit-objectives/collectible pads add mutating RPC/state paths that must follow the rate-limit + serialize convention (the sell-dupe precedent); a farmable credits faucet from pad re-triggering is the most likely adversarial-review finding.
- T2 residual determinism/netcode risk even inside its fences: a +1 field in the fighter dict and snapshot (Protocol bump #3) must not perturb float-op or iteration order (guardrail 1), and ramp-line layer prediction can still desync visibly at zone seams — far smaller than a vertical predictor, but not zero, and it lands on a live deployed game.

### Full design

# TRAVERSAL VERTICALITY — Phase-1 Gate Submission (lane: "height is about REACHING PLACES")

## 0. Premise checks that reprice the whole path

**0a. Precision platforming is dead on arrival at this netcode — so continuous z buys nothing traversal can use.** Server tick is 30 Hz (33 ms movement quanta); live latency is ~50–150 ms; class move speed is `95 + SPD*1.1` ≈ 130–165 u/s (shared/GameData.gd:645). At 150 ms RTT a player's true server position differs from their screen position by ~20–25 sim units; the server's own arrival tests are 2-D radius checks of 42 units (World.PORTAL_RADIUS, shared/World.gd:78; enforced in `_check_portals`, server/Server.gd:3346-3354). Any jump-landing target must therefore tolerate ≥~35–45 u of error — i.e. every "platform" degrades to a portal-pad-sized landing zone. Timed jump puzzles at 30 Hz with a WASD+orbit-camera scheme (client/Player.gd:32-47) read as bad controls, not challenge. Conclusion: the ceiling of traversal gameplay on this engine is GENEROUS traversal (walk ramps, reach marked spots, unlock shortcuts). Generous traversal does not require continuous z — which means Phase 2's hard parts (deterministic gravity + vz + the vertical predictor, jump-verticality-handoff.md:124-132, :193 "the predictor is hard") are the exact parts traversal cannot cash in.

**0b. Correcting a premise in the gate question: there is no mouse-click movement.** Movement is WASD, camera-relative (client/Player.gd:32-47); the y=0 mouse-pick (`_cursor_sim`, client/Client.gd:709-721) serves only the coords overlay, the F4 decorator, and Builder placement. Multi-floor mouse picking is an author-tool problem, not a player-movement problem — a large chunk of the feared P3 client work simply isn't on traversal's bill.

**0c. The world has zero authored vertical features and 8 combat spaces whose cover value IS flat LOS** (world-lane survey; GY_BOSS/GY_SECRET cover rings vs the campreset/totalreset LOS-spare, Sim.gd:361-377, World.gd:381-395). Traversal height must therefore live where combat isn't, or in new content only.

## 1. The design: three tiers — buy only what the fantasy needs

### T0 — "Terraced" render-height (hills, bleachers, mezzanines; NO overlapping floors) · **M · client+content · ZERO sim risk**
Per-zone client heightmap `h(x,y)` authored beside `data/decals/<map>.json`; the render layer raises model, nametag, shadow, target ring, and camera focus (Client.gd:1386) by `h`. The sim stays flat `{x,y}`; standing room is enforced by REAL server-side collision circles (fence rows in the merged obstacle list, Server.gd:435) with ramp mouths left open. Because height is a pure function of the already-replicated (x,y), remote players render correctly with **no snapshot field and no Protocol bump** (cheaper than the shipped Phase 0.5).
- **Abilities touched:** none in sim. Client render only: projectile/zone visuals currently spawn at y=0 (Client.gd:1084,1578,1585 per handoff §5) and should sample `h` along their path, or a cast from a riser looks wrong.
- **Maps:** HOME (stadium bleachers on the south rim by the Arena gate World.gd:104; plaza mezzanine), LOCKER (Builder-Mode riser furniture). GY1–5 get non-walkable scenery terraces at map edges only. All combat maps stay flat.
- **§5 ledger items pulled in:** client render/camera block ONLY (`_world()` Y at Client.gd:628,664,1385; camera focus :1386; pick :713 for author tools). Zero items from the sim/AI/abilities/netcode blocks.
- **Determinism/balance blast radius:** zero — harness byte-identity holds trivially.
- **Cosmetic-lie audit (mandatory):** three lies are possible and three authoring rules close them: (i) you can't hop/fall off an edge → EVERY riser edge gets a railing (visual grammar: raised = railed), optionally with authored one-way "drop pads" reusing portal machinery; (ii) nothing can walk UNDER a T0 riser (the sim has one plane) → risers sit against map edges/out-of-bounds scenery, never bridging playable ground; (iii) a cast from a riser resolves by flat 2-D LOS → keep risers outside the range band of any attackable entity (HOME's training dummy at 1240,790, World.gd:76-77; max ability range 420 = hailmary, GameData.gd:60). With those rules nothing looks like it should matter and doesn't.

### T1 — Traversal GAMEPLAY on T0: vantage collectibles, tour bounties, shortcut gates · **S–M · server+content · ZERO sim risk**
- **"Season Tickets" vantage collectibles:** pads on riser tops and far corners, server-side 2-D radius checks in the exact `_check_portals` pattern (Server.gd:3346-3354). First visit grants credits/cosmetic + a completionist counter. Requires a new quest objective type `"visit"` — Quests are kill-only today (every objective is `{"type":"kill"}`, shared/Quests.gd:29-164; matcher `kill_matches` :190) — a small additive server change that MUST follow the rate-limit/serialize convention (CLAUDE.md; the sell-dupe precedent).
- **Weekly "Stadium Tour" bounty:** deliberately rides the length-roadmap Phase-6 Bounty Board infra instead of competing with it (docs/gameplay-length-handoff.md:168).
- **Shortcut climbs that are really gated pads:** e.g. a GY3→GY5 "maintenance catwalk" — visually a ladder+catwalk, mechanically a gated portal pad (gate machinery exists: `"boss_ready"`/`"secret_key"`, World.gd:131,139), unlocked by quest/level.
- **Abilities touched:** none — and that is load-bearing. Dash/leap keys `slide`, `dribble`, `pancake`, `tackle`, `bullrush`, `fourthgoal`, `thunderspike`, `killshot` and knockback writers `powerswing`/`grandslam` cannot cross a traversal gap because the flat sim clamps them into the same collision field as walking (Abilities.gd:263-270; Sim.gd:692-709) — zero per-ability work.
- **Blast radius:** zero determinism; economy-only (size the credit faucet).

### T2 — Sim-true DISCRETE LAYERS (the only justified "true z" for traversal) · **L–XL · shared/+netcode+content · MEDIUM-HIGH risk · new-content-only**
Only if the second biome (length-roadmap Phase 8) genuinely wants overlapping floors (walk-under bridges, a two-story fortress). The correct sim model is a small int, not a continuous axis:
- `f["layer"] ∈ {0,1}` added to the fighter dict (GameData.gd:699-731). Transitions ONLY by walking authored ramp volumes — position-derived and deterministic; **no vz, no gravity, no jump physics; Space stays cosmetic.**
- **Same-layer-only combat policy:** `Geom.dist` untouched (the §5 "[very-hard]" item, Geom.gd:7-8, stays `Vector2`); `has_los` gains a layer pre-gate (cross-layer = blocked/refused like out-of-range); zones and projectiles carry the caster's layer. ONE policy replaces P3's ~30 per-call-site geometric decisions.
- **Mobs never change layers** (rule), ramps sit >AGGRO_RANGE 320 from camps (Server.gd:43-45); a perched player can't shoot down (cast refused) and an unreachable mob resolves via the EXISTING leash reset (teleport-to-spawn + full heal, Server.gd:3455-3468) — the perch-cheese loop is closed with shipped machinery.
- **Netcode:** +1 small int in the fighter snapshot (Server.gd:4721) + Protocol bump #3 (guardrail 4). Prediction: layer is a function of predicted (x,y) crossing ramp lines — the 2-D predictor extends; **no vertical predictor exists to build.** This is the decisive saving vs P2 (handoff :193: "snapshot z add itself is trivial; the predictor is hard").
- **Abilities touched (by key):** every displacement writer gets one seam rule ("displacement never changes layer"): `slide`, `dribble`, `pancake`, both `tackle`s, `bullrush`, `fourthgoal`, `thunderspike`, `killshot` (Abilities.gd:105-158,124-133,235-274; Sim.gd:692-709), knockbacks `powerswing`/`grandslam`/`sleddrive`/`primesled` (Sim.gd:332-349). Boss pulls `respull`/`primepull` untouched — bosses live on flat maps by rule.
- **Maps/encounters:** second-biome zones designed for it + at most one HOME "Commissioner's Box" teaser tower. All 14 live maps stay layer-0 everywhere; GY_BOSS/GY_SECRET explicitly excluded, so the LOS-spare/pull/wallStun chain (Sim.gd:361-377; Abilities.gd:235-246) is byte-identical by construction.
- **§5 items genuinely pulled in:** fighter dict (GameData.gd:699); snapshot/intent + Protocol (Server.gd:4721); has_los gate (Geom.gd:19-33); separation same-layer filter (AI.gd:121-148); aggro/leash layer check (Server.gd:3405-3424); dash/knockback seam rule (Sim.gd:333-356); camera/pick (Client.gd:713,1386).
- **§5 items genuinely AVOIDED, with why:** 3-D `Geom.dist` (layer is a gate, not a distance term); gravity/vz integration (no continuous z exists); the vertical predictor (layer is position-derived); 3-D hazard/buff volumes (layer-tagged flat discs); 3-D fan-aim/frontal-arc (same-layer only); **Phase-4 full re-measure** — harness venues have no ramps, so every harness fighter is layer 0 and every layer branch compares 0==0 → byte-identity, proven by the guardrail-1 z==0 regression test as the merge gate. P4 stays avoided ONLY while same-layer-combat + mob-free-layers + flat-harness all hold; break any one and the full P4 bill returns.
- **Determinism blast radius:** MEDIUM — the dict/snapshot additions must not perturb float-op or iteration order; no new RNG draws anywhere (leapAttack draws exactly 2, Abilities.gd:124-125; crit 1/hit, Combat.gd:151). PvE-only by construction (ARENA stays flat).

## 2. Where height lives, per zone
- **HOME:** T0 bleachers + mezzanine (best venue: safe, social, vertical décor already). Later, optionally, the one T2 teaser tower.
- **LOCKER:** T0 riser furniture in Builder Mode (private, zero combat).
- **GY1–5:** scenery terraces only + at most one T1 catwalk-shortcut pad. Their identity is lane-based flat drill-fields; camps are hand-spaced planar (World.gd:168-175) — no walkable height.
- **GY_BOSS / GY_SECRET:** never — the fights are built on flat LOS (World.gd:381-395; Sim.gd:361-377).
- **ARENA:** never — the only pvp:true map, deliberately a bare box; FORMAT_MODS[5] is flat-tuned.
- **DRILL:** never — any climbable point is a leaderboard-corrupting safe spot (center-spawn wave survival, World.gd:70-71,158-161).
- **CAMP/CAMP_B/CAMP_C:** flat; CAMP_B is the named T2 pilot venue if T2 ever lands (private instance = safest exposure).
- **Second biome (length-Phase 8):** the only place designed-for-height content should ever go.

## 3. Camera, picking, mob pathing (multi-level answers)
- **Camera:** the orbit camera survives; only focus height follows render height (Client.gd:1386). No redesign needed because T0 forbids walk-under geometry and T2 uses generous interiors.
- **Picking:** upgrade `_cursor_sim` (Client.gd:709-721) to a heightmap march for the F4 decorator/Builder only; players never click-to-move.
- **Mob pathing:** none exists for height (AI.gd:75-119 is planar) and none is built at any tier. T0/T1: mobs unchanged. T2: mobs layer-locked; aggro gains a same-layer test. "Mobs that climb" is explicitly the combat lane's Phase-4 jump-capable-AI bill (handoff :144), not traversal's.

## 4. Content re-authoring price
- **Retrofit the existing flat maps for walkable height: DON'T.** Priced for the record: 5 GY camp re-spreads + east-elite arena re-tunes + two boss-arena redesigns ≈ **+4–6 content sessions on top of any sim work**, spent making lane-based flat zones worse at their own identity. Negative ROI.
- **New-biome-only:** ramp volumes + layer tags + the railing grammar add **~+1–2 sessions** to Phase-8's existing XL budget — amortized into content that must be authored anyway. The only sane venue.

## 5. PLAYTIME (the active priority) vs novelty — honest split
- **T0:** ~zero playtime; expressiveness/novelty, same class as the shipped hop. Do not sell it as playtime.
- **T1:** small but real playtime: a one-time completionist layer (~1–2 h), a recurring weekly tour bounty, shortcut unlocks as quest rewards. Dessert, not a meal — it does not touch the audited core flaw (build finished at level 1; ~93% questless grind).
- **T2:** zero intrinsic playtime — sim capability ships no quests/mobs/zones; playtime arrives only via second-biome content already budgeted in the length roadmap. T2 has no standalone justification; it is at most a line-item inside length-Phase 8.
- **Lane verdict for the gate:** traversal does NOT justify P2+P3+P4. The two XLs price continuous z; continuous z exists to enable precision the netcode cannot deliver (§0a). Everything traversal CAN deliver at 30 Hz/50–150 ms is reachable at T0+T1 (zero sim) or T2 (a strictly smaller sim change than P2+P3, with proofs of avoidance above).

## 6. Scoping strategies (blast-radius containment)
New-content-only (T2 never touches the 14 live maps) · mob-free layers · same-layer-only combat · PvE-only (ARENA flat) · per-map opt-in (a map with no authored ramps cannot express a layer change) · flat-harness byte-identity regression as the merge gate (guardrail 1) · server-first Protocol rollout (the Phase-0.5 playbook) · instanced pilot (CAMP_B) before any shared-zone exposure.

## 7. Kill-reasons (abandon the path if…)
1. **Appetite test fails:** HOME dwell/collectible telemetry after T0+T1 shows players ignoring the bleachers/Season Tickets → the "jump desire" was feel, already satisfied by Phases 0+0.5. Stop forever.
2. **The second biome doesn't need overlapping floors:** if its design reads fine terraced (T0-style cliffs/hills), T2 dies — terracing needs no sim change.
3. **Byte-identity regression can't pass:** any float/iteration-order perturbation from the layer field that survives a fix attempt kills T2 immediately (guardrail 1 is non-negotiable).
4. **Same-layer combat reads as a lie in playtest:** if "you can't shoot down from the balcony" feels broken rather than legible, T2's cheapness premise is false; the honest alternative is the combat lane's full P2+P3+P4 — which this lane has argued against. Kill rather than creep.
5. **The visit/collectible surface can't be secured:** if adversarial review finds an un-serializable farm/dupe on the new RPC surface, cut the collectible mechanic, keep pads-only.
6. **Standing priority veto:** any session spent here before length-roadmap Phases 1–2 ship is mis-spent; T1 slots after length-Phase 6 (bounty infra), T2 inside Phase 8.

## 8. Recommendation
Commit + deploy the finished Phases 0+0.5 (the only outstanding verticality work with positive ROI). Adopt T0+T1 as a small, deferrable content garnish sequenced behind the length roadmap. Park T2 as a design line-item inside length-Phase 8 with the DISCRETE-LAYER model as the mandated approach if overlapping floors are wanted. Never retrofit GY/boss/ARENA/DRILL. Do not fund P2+P3+P4 for traversal — the netcode caps traversal below what continuous z is for.

---

## Path C — Minimal / Middle Slices ("Hop-Dodge & Skins")
**Judge: 4/10 · value weak · playtime barely · identity-fit workable**

### Claimed cost
Recommended package ~3.5-5 sessions total: Tier 0 commit+deploy shipped Phases 0+0.5 (~0.5); Tier 1 knock-up-as-skin + hop-cosmetic credit sinks + safe-zone jump pads (~1.5-2, client-mostly, zero sim risk); Tier 2 MVP hop-dodge (~1.5-2.5 incl. regression suite + adversarial review + live PvE tune). Deferred, not in this total: heightfield-as-render +2-3 sessions amortized inside the second-biome build (length Phase 8). For comparison: scoped true sim-z (per-map flag) ≈ 6-10 sessions, full P2-P4 ≈ 9-14 — both rejected at this gate.

### MVP slice
PvE "Hop-Dodge" (mob-telegraph-scoped) — the smallest sim-true jump worth shipping, 1.5-2.5 sessions. Server stamps `airborneT ≈ 0.2s` (mid-arc window, NOT the full 0.45s arc) on the already-shipped `submit_hop` RPC; exactly two shared call sites read it, both gated by a new ability-def tag `"hopDodge": true` carried ONLY by mob attacks: (1) the dir-projectile hit test (Sim.gd:56-57 — alongside the existing evade/untarget skip, so precedent already ships) for ball_machine/gatling scatter + bankshot volleys (GameData.gd:209-210, :346-348); (2) the hazard-zone tick (Sim.gd:151-152) for drillzone/churn/dustline (GameData.gd:187, :379, :304) — EXCLUDING boss zones ladderlock/primeladder (:234, :261) so GY_BOSS/GY_SECRET tuning is untouched. No z scalar (a z buys nothing — it degenerates to this timer), no homing-projectile change (player projectile classes keep full integrity, PvP untouched), no LOS/map/AI/camera change, no Protocol bump (hop wire + 250ms rate limit shipped in 0.5). Player-facing: jump the turret volley in GY4/CAMP_B "Gauntlet", hop the ground-hazard ticks in GY5/CAMP — taught by recoloring tagged telegraphs. Kit evades stay strictly stronger (slide/pancake dodge everything via Combat.gd:96-97 incl. campreset; the hop dodges only tagged mob shots/ticks). Merge gates: byte-identity round-robin replay + harness-content lint proving no player class emits dir-projectiles or damaging zones + stab_hop/protocol/authority regressions. Known costs accepted: DRILL leaderboard scores inflate slightly (waves use tagged mobs — note for a season reset), and PvE gets ~one notch easier (schedule with the owner-flagged §3b difficulty pass).

### Designer's own biggest risks
- Invisible-rule / partial cosmetic-lie in any hop-dodge: the hop looks identical everywhere but only dodges tagged mob attacks — never melee, dashAttack, or campreset (Sim.gd:374-377). Mitigation is telegraph recoloring + strict tag discipline; kill the feature if playtests show players can't predict what a jump dodges (guardrail-2 mirror violation).
- Free-dodge uptime: HOP_DUR 0.45s vs the 250ms server rate limit allows ~continuous hopping; a full-arc dodge window = near-100% immunity to tagged attacks. The 0.2s mid-arc window is a guess — if even that trivializes turret elites (GY4 ball_machine, CAMP_B gatling) or inflates the live DRILL leaderboard unacceptably, the mechanic needs a dodge-cooldown (new tuning surface) or death.
- Harness contamination from the shared/ change: airborneT field + guarded decrement + two gated call sites must be PROVEN inert (byte-identity round-robin replay + a lint asserting no player class emits dir-projectiles or damaging zones) — any drift silently voids FORMAT_MODS[5] and triggers the mandatory full re-measure this path exists to avoid.
- The FORMAT_MODS-survives claim is domain-scoped, not absolute: the duel harness never contained mobs or hops, so mob-only scoping preserves the measurement's meaning for PvP — but live PvE difficulty (hand-tuned, already owner-flagged broken via the §3b fresh-char-beats-boss bug) shifts easier and needs a deliberate pass, not an assumption.
- Scope-creep gravity: once the hop has teeth, players will ask for ledges and true jumps; this package deliberately has no ledge answer (heightfield-as-render is deferred to the biome, true z is killed at this gate). Without an explicit owner decision recorded, Tier 2 becomes a wedge toward the 6-14-session P2-P4 bill.
- Opportunity cost discipline: even 3.5-5 sessions ≈ length-roadmap Phase 1 (M) plus half of Phase 2 (L) — the phases fixing the audited core flaw (build finished at level 1, ~93% questless 10→30 grind). The package only makes sense interleaved as garnish; run as a work-stream it inverts the project's stated priority.
- Knock-up-skin trigger inference: deriving launch arcs from snapshot deltas (stun onset + displacement) can misfire on portals/admin teleports, reading as phantom launches; the fallback is a cosmetic event on the wire — an unplanned second Protocol bump.

### Full design

# Minimal / Middle Verticality Slices — Phase-1 Gate Contribution (lane: cheapest coherent options between "stop at 0.5" and P2–P4)

All claims cited to live code (spot-verified 2026-07-13) or to docs/jump-verticality-handoff.md ("handoff"). Prior facts assumed: Phases 0+0.5 are DONE but uncommitted (handoff :3-31); hop = client parabola HOP_H 1.2 / HOP_DUR 0.45 (client/Client.gd:64-65, :1214), networked via `submit_hop` + snapshot `hopT` with a 250ms server rate limit (server/Server.gd:180-181; handoff Phase-0.5 note); the sim is flat 2-D everywhere (shared/Geom.gd:7-33; handoff §5).

---

## CANDIDATE 1 — JUMP-DODGE-ONLY ("z exists only during a hop; only projectile/zone damage checks read it")

**Verdict: REJECT as specified; ACCEPT a narrower kernel (mob-telegraph-scoped hop-dodge — see MVP).**

Why the literal spec is incoherent: a real z scalar buys nothing here. Projectiles have no z to compare against — homing shots re-aim at the target's live x/y every tick and impact on planar distance (Sim.gd:170-174), dir-projectiles hit on planar proximity <16 (Sim.gd:55-57), zone ticks are a planar radius test (Sim.gd:144-152). Any "z test" at those sites degenerates to "is the target currently airborne" — i.e. a typed evade timer, not an axis. The sim already has exactly this primitive: `evade`/`untarget` early-return at the top of deal_damage (Combat.gd:96-97) plus the dir-projectile skip (Sim.gd:56). So candidate 1 is really "a free, universal, Space-bar evade window," and evaluated as that it fails:

- **Balance trap, exactly as the prompt suspects.** The harness stays byte-identical only because it has no `state.controlled` (Sim.gd:383-387) and AI never hops — FORMAT_MODS[5] survives as a number while ceasing to describe the live game. Uptime math kills it: HOP_DUR 0.45s vs the 250ms rate limit → re-hop cadence 0.45s → if the whole arc grants dodge, that is ~100% ranged/zone immunity for zero resource. Even a mid-arc window (~0.2s) is ~44% uptime, free, on every class.
- **Class-identity damage.** It hard-counters the three projectile-identity classes in Arena PvP (pitcher keys 1/2/4/5, GameData.gd:29-33; setter key 1 :82; striker keys 1/4/5 :109-113) and dilutes the two paid kit evades (batter `slide` key 3, evade 0.4s :44; spiker `pancake` key 4, 0.35s :98).
- **No counterplay exists.** AI has zero projectile perception (nothing scans state.projectiles; the only reactive behavior is pillar-hug, Sim.gd:439-456) — bots can neither dodge back nor hold fire vs an airborne target. Asymmetric by construction and un-measurable by the duel harness.
- **Partial cosmetic-lie (guardrail-2 mirror problem).** The hop looks identical in every context but would dodge a fastball while NOT dodging melee (synchronous in try_cast, Abilities.gd:67), dashAttack (instant, Abilities.gd:247-257), or the boss ult `campreset` (LOS-gated resolve, Sim.gd:374-377). An invisible, unteachable rule boundary is a guardrail violation, not a feature.

**§5 ledger pulled (as specified):** projectile collide sites (Sim.gd:31-62, 170-195), zone discs (Sim.gd:130-152), fighter dict (GameData.gd:699), plus an unbudgeted live PvE + PvP balance pass. **Size:** implementation S-M; honest cost M-L once tuning is priced. **FORMAT_MODS:** byte-survives, semantically invalidated for PvP.

**Salvageable kernel:** scope the dodge to TAGGED MOB ATTACKS ONLY (Monster-Hunter dodge, not a PvP layer). FORMAT_MODS was measured on class-vs-class duels with no mobs and no player hops — a mob-only tag keeps both the byte-identity AND the measurement's meaning (PvE difficulty is hand-tuned, already owner-flagged for a §3b pass). Precedent already ships: dir-projectiles ALREADY skip evading targets (Sim.gd:56-57), so batter slide already "jump-dodges" turret volleys. Kit evades stay strictly stronger (they dodge everything via Combat.gd:96, including campreset). This kernel is the MVP slice below.

---

## CANDIDATE 2 — KNOCK-UP AS A SKIN (cosmetic launch arc on existing stuns/knockbacks; no sim z)

**Verdict: ACCEPT — guardrail-safe, cheap, but it is an animation pass, not a verticality step.**

The CC is real: stun timers skip the fighter's turn (Sim.gd:320), knockback is a real displacement (Sim.gd:332-337, :344-349), so the visual promise ("this unit is CC'd and flying") is true — the opposite of a cosmetic lie. Render exactly like the shipped hop: drive `model.position.y` only, arc duration clamped to the CC duration, shadow/footprint grounded (Phase-0 pattern, handoff guardrail 2).

- **Abilities by key:** linebacker `tackle` key 2 (knockdown 0.8s, GameData.gd:70) and `fourthgoal` key 5 (knockdown 1.0s, :73) = pop-up arcs; batter `powerswing` key 2 (kb 60, :43) and `grandslam` key 5 (kb 80, :46) = low launch-back arcs; QB `sack` key 5 (stun 1.1s, :59) = knock-DOWN tumble; boss/mob `sleddrive`/`primesled` wallStun crash (GameData.gd:237, :264; Abilities.gd:239-246) = self-stun tumble — the bait-into-wall counterplay finally READS. Skip pitcher `beanball` (flinch, not launch).
- **Showcase:** GY3/GY4 sled fights (wallStun bait), any linebacker player, Arena PvP.
- **§5 ledger pulled:** NONE — client/ only. **FORMAT_MODS:** byte-identical, fully survives. **Size:** S-M (S if launch triggers can be inferred client-side from snapshot deltas — stun-onset + displacement in the same snapshot; M if inference misfires on teleports/portals and a cosmetic event needs a Protocol bump).
- **Residual lie risk (LOW, flag it):** a "launched" mesh still takes zone ticks and hits (sim-grounded) — acceptable convention (juggled units are hittable in every action game); and do NOT render spiker leapAttacks (keys 2/5) as slow arcs — the sim teleports instantly (Abilities.gd:124-126), so a mesh-in-flight longer than ~0.2s makes the fighter hittable "where it already is." Keep any leap arc ≤0.2s or skip.
- **Kill-reasons:** trigger inference proves unreliable (false launches on portal teleports) AND the owner declines a protocol event; arcs drift past CC duration implying phantom i-frames.
- **Playtime:** zero. Pure combat-feel juice, consistent with the shipped combat-feel pass.

---

## CANDIDATE 3 — SCOPED VERTICALITY (per-map sim-z flag)

**Verdict: SPLIT. 3a (heightfield-as-RENDER, derived z, no sim state): ACCEPT, deferred into the second biome. 3b (true per-map sim z): REJECT for now — the flag contains determinism but not the engineering bill.**

**3b honest containment analysis:** a per-map `vert` flag CAN contain determinism — gate with branches (`if state.vert: dist3 else: Vector2.length()`) so flat maps execute the identical instruction path, and prove it with the byte-identity regression the handoff already mandates (guardrail 1, handoff :70-77). Flat shipped zones + flat harness venues (GameData.gd:423-435) ⇒ FORMAT_MODS survives by measurement domain; GY_BOSS/GY_SECRET never set the flag ⇒ no cover-ring re-validation (World.gd:381-395 untouched). What the flag does NOT contain: you still build ALL of P2's hard core — z/vz/deterministic gravity in a loop that has only ever done position accumulation, the vertical client predictor ("the predictor is hard," handoff :193), a second Protocol bump — plus P3's height authoring, height-aware collision/LOS for the flagged maps, terrain mouse-picking (Client.gd:713), camera unforce (:1386), and at least ramp-competent mob AI (AI.gd moves strictly in-plane, AI.gd:75-148). Scoped cost ≈ P2 whole (3-5) + P3 partial (2-3) + regression/hand-tune (1-2) = **6-10 sessions**, vs 9-14 unscoped — cheaper, still XL, still the highest-risk code in the repo, and still with no named gameplay to justify it (the combat lane found all three candidate mechanics weak or unpriceable). The handoff's own gate applies: "if you can't [name the gameplay], stop at Phase 0.5" (handoff Phase 1). **Kill-reason already met.** Re-gate only if the second-biome design (gameplay-length Phase 8) names a concrete vertical combat pillar.

**3a — the genuinely cheap middle slice this lane found:** if walkable areas never vertically overlap (a heightfield with ramps — terraces, not towers), then z is a pure function of (x,y) and needs NO sim state at all. The server sim stays 100% flat; the client renders terrain meshes and places models at `terrain_height(x,y)`; snapshots stay `{x,y}`; determinism untouched by construction. Cliffs are mirrored as ordinary obstacle circles (World.gd:271-295) so movement/LOS/projectiles behave consistently — with one enforceable **authoring rule: every height discontinuity above step height must be covered by obstacle circles** (lintable), which makes the sim's blocking geometry a superset of the visual cliffs and provably reduces the heightfield to decoration. Residual soft lies: planar range slightly under-measures slope distance (industry-standard 2.5-D cheat, invisible in practice); projectile/zone renders need height interpolation along terrain. Ledger pulled: client-render items only (mouse pick :713, ground meshes :673/:1084, model grounding :447/:468, projectile/zone render height) — zero sim/netcode/balance items. **Size L (2-3 sessions), amortized into the biome build where new zones must be authored anyway.** This is how the second biome gets to LOOK and traverse vertical (ramped terraces up to a turret plateau, a command-tower hill for a GY5-style zone) at zero sim risk. **Kill-reasons:** the lint can't guarantee the cliff-wall rule; terrain picking degrades click-targeting; slope renders of shots/decals look broken. **Playtime:** none intrinsic, but it multiplies the perceived freshness of the biome content the length roadmap already budgets.

---

## CANDIDATE 4 — EXPRESSIVE EXTENSIONS OF 0.5

**Verdict: ACCEPT (cherry-picked), the only items with any playtime attachment.**

- **Hop cosmetics as credit sinks** (trails, landing FX, per-class flip variants — spiker gets a spike-jump, batter a bat-twirl): S, client + a cosmetics catalog row on the existing shop/dye machinery (Server.gd `_cos_busy` serialization already exists, :1894). Adds a small new kills→credits→cosmetics loop; the economy currently dead-ends and the length roadmap wants sinks. FORMAT_MODS untouched; zero ledger items.
- **Landing squash/dust polish + emote hops**: S, pure client juice on the shipped `_drive_local_hop`/`hopT` path (Client.gd:1189-1232).
- **Jump pads = teleports, SAFE ZONES ONLY** (HOME 1800×1200, LOCKER 700×460 — the two zero-combat maps, World.gd:57,:72-73): a pad that plays the hop arc then uses the existing portal machinery. S. **REJECT combat-zone pads** — a mid-combat teleport interacts with 2-D aggro/leash (Server.gd:3431-3469) and homing projectiles that never miss (Sim.gd:170-191), and the AI can't use pads: exploitable positioning tech, and an arc-over-a-wall pad in combat is a cosmetic lie about LOS. Also note: without 3a there is nowhere elevated for a pad to land — "roof decks" would render at y=0 (Client.gd:447,:468-469) — so pads stay horizontal flavor until the biome.
- **Kill-reasons:** cosmetics don't sell (measurable in credits sunk); pad flavor reads as a broken portal.
- **Playtime:** marginal-but-real for the sinks; zero for the rest.

---

## RECOMMENDED MINIMAL PATH (if the owner wants more than 0.5 without P2–P4)

Tiered, each independently shippable, stop anywhere. Sequenced as garnish BETWEEN length-roadmap phases, never displacing one (active priority: docs/gameplay-length-handoff.md, Phase 1 XP-economy is queued next).

- **Tier 0 (do regardless, ~0.5 session):** commit + deploy Phases 0+0.5 (server-first redeploy — Protocol 1→2 — then client re-export). This is the only outstanding verticality work with unconditional positive ROI.
- **Tier 1 (S-M, zero sim risk):** knock-up-as-skin (candidate 2) + hop-cosmetic credit sinks (candidate 4). ~1.5-2 sessions.
- **Tier 2 (the sim-true MVP, 1.5-2.5 sessions):** mob-telegraph hop-dodge (below). Only tier that gives the hop teeth; gate it behind Tier 1 landing well, and ideally schedule WITH the owner-flagged §3b PvE difficulty pass since both move the same hand-tuned dial.
- **Deferred:** heightfield-as-render (3a) into the second-biome build (length Phase 8). True sim z (3b/P2-P4) stays killed unless the biome design names a vertical combat pillar — re-run this gate then, with 3a's biome as the pilot venue.

**Phase-1 gate answer from this lane: true verticality is NOT currently worth building — but "stop at 0.5" and "P2-P4" is a false binary. A ~3.5-5-session package (Tiers 0-2) captures the remaining felt demand, and 3a gives the eventual biome a vertical LOOK for L, leaving P2-P4 permanently optional.**

## PROOF OBLIGATIONS (merge gates for Tier 2, the only shared/ change)

1. Byte-identity regression: full FORMAT_MODS round-robin replay (seeds × maps) hashes identical pre/post — the new `airborneT` field (create_fighter defaults, GameData.gd:699 region) and its guarded decrement must be provably inert when no fighter hops; the two gated call sites (Sim.gd:56-57 dir-projectiles, Sim.gd:151-152 hazard ticks) never execute in the harness because no player class emits dir-projectiles or damaging zones (strikezone is buff-only, GameData.gd:31; hazards are mob defs :187/:209-210/:304/:346-348/:379) — assert this with a harness-content lint, don't assume it.
2. No new/reordered RNG draws (crit 1/hit Combat.gd:148-153; leapAttack 2 draws Abilities.gd:124-125), no change inside deal_damage's early-return (Combat.gd:96-97) — gate at call sites only.
3. `submit_hop` becomes a combat input: it already carries the mandatory rate-limit convention (`_hop_next`, Server.gd:181) — keep it, re-run stab_hop 19/19 + stab_protocol + stab_authority.
4. Shared-engine change ⇒ server redeploy + client re-launch (CLAUDE.md), no Protocol bump needed (hop wire shipped in 0.5).

## PLAYTIME HONESTY (the active priority)

None of these tiers adds hours of content. Tier 1's cosmetic sinks add a small retention loop; Tier 2 adds combat depth to existing PvE (better moment-to-moment, same 6-8h of authored content); 3a makes future biome hours feel fresher. The direct playtime work remains the length roadmap — this package is deliberately priced so it never displaces more than a fraction of one length phase, versus P2-P4's 9-14 sessions ≈ the entire length-Phases 1-4 core that fixes the audited 93%-questless-grind flaw.
