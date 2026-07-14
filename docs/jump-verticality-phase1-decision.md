# Jump / Verticality — Phase 1 Decision Memo

**Date:** 2026-07-13 · **This is the Phase-1 deliverable of `docs/jump-verticality-handoff.md`** ("write
down the specific gameplay height enables; if you can't, stop at Phase 0.5"). Produced by an 11-agent
mine → design → judge workflow over the live repo (4 read-only miners: class kits / world+arenas / combat
model / priorities; 3 path designers; 3 adversarial value-for-cost judges; 1 completeness critic), with the
load-bearing claims re-verified by hand against git. Full path blueprints:
`docs/verticality-designs-archive.md`.

**Status: DECIDED 2026-07-13 — the owner CLOSED the gate.** Verdict = **"feel": the cosmetic hop
suffices; true verticality is not a pillar.** The standalone jump work-stream ends at Phase 0.5. The §4
re-open condition (the Phase-8 *named-moment test*) stands and is the only path back. Immediate actions
executed with this decision: Phases 0+0.5 committed + deployed (server-first, Protocol 1→2) and the
`hops/min` demand counter added to the server health log.

---

## 0. Corrected ground truth (changes the whole cost picture)

The judges caught that the opportunity-cost frame everyone (including `CLAUDE.md`) was using is **stale**:

- **Gameplay-length Phases 1–7 have SHIPPED** (verified in git): P1 XP-economy `0d88148` (07-09),
  P2 level-gated kits `fa93617`, P3/3a/3b Camp-Circuit+roster `42ca796`/`e8d4900`/`2b4f714`, P4 talent
  trees `2a8ed40`, P5 Paragon+Audibles `578f292`, P6 Bounty Board `02bb436`, P7b/7c/7d procs/boss-scaling/
  seasons `abf3a54`/`f63f45b`/`f2fea90` (07-10..07-11), plus Difficulty Pass v1 `ec4250f`.
- **What actually remains:** gameplay-length **Phase 8 (second biome, XL)**, **P7a sockets+gems** (no
  matching commit exists), difficulty-pass residuals, PRIME tuning.
- So verticality does **not** compete with "the whole length roadmap" — it competes with **Phase 8**, which
  is *exactly* where any verticality would most cheaply ride along (shared deploy window, shared content
  budget, shared bot-policy decision).
- Also flagged as **urgent hygiene independent of the gate**: verticality Phases 0+0.5 sit **uncommitted
  across 6 hot files** (`Client.gd`, `NetClient.gd`, `Net.gd`, `Player.gd`, `Server.gd`, `Protocol.gd` +
  `tools/stab_hop.gd`) with a `p5-review-stash` on main — a live conflict/loss risk. Commit + deploy
  (server-first; Protocol 1→2) regardless of the gate answer.

*(The stale status lines in `CLAUDE.md` and `docs/gameplay-length-handoff.md` were corrected alongside
this memo.)*

## 1. The verdicts

| Path | MVP | Honest cost | Judge | Playtime added | Identity fit |
|---|---|---|---|---|---|
| **A. Combat verticality** — server-authoritative discrete `airT`, hop-dodge vs `groundwave`-tagged attacks, per-map `vertical` flag, "Upper Deck" teaching instance + "Away Game" boss | "Jump the Shockwave" (2-3 sessions) | 7–10 sessions (+2–3 conditional re-tune) | **3/10 · weak** | barely | workable |
| **B. Traversal verticality** — client heightmap risers (T0), "Season Ticket" vantage pads (T1), discrete portal-layers (T2, new-content-only) | HOME "Grandstand" (2.5–3 sessions re-priced) | ~5–8 sessions worst-case | **4/10 · weak** | barely | workable |
| **C. Minimal slices** — knock-up-as-skin, hop cosmetics, PvE hop-dodge on tagged mob attacks only | PvE hop-dodge (1.5–2.5 claimed, 4–6 honest) | 3.5–5 claimed / 4–6 honest | **4/10 · weak** | barely | workable |

**Unanimous across all three judges + the completeness critic: reject Phases 2–4 (continuous sim-z) outright,
and reject every path as a build-now standalone work-stream.** The best-scored artifacts are kept as
blueprints for a possible Phase-8 ride-along (archive doc).

## 2. Why every path failed the gate (cross-cutting findings)

1. **The netcode cannot render a jump-timing mechanic honestly.** The local hop is client-predicted and
   plays instantly; any authoritative dodge window is stamped server-side on a 30 Hz tick at RPC arrival.
   At 60–120 ms RTT the on-screen arc misaligns with the server's window by up to half the window — a
   player can be *visibly airborne and still eat the ground attack*, with no ack/rollback channel designed.
   This is the vertical-predictor problem the handoff priced as "the hard part," reappearing even in the
   discrete designs.
2. **The AI dilemma is structural.** A deterministic, no-rng jump policy for mobs tunes to either
   **psychic** (dodges every player groundwave → guts Batter `grandslam` / GK `sweeper` in vertical maps)
   or **helpless** (players trivialize content). Randomness would fix the middle band — and is forbidden
   by the determinism invariant.
3. **The cosmetic-lie surface is structural, not incidental.** Melee and homing projectiles (every ranged
   class's basic) still hit visibly-airborne fighters by design; a hop that dodges *some tagged things in
   some maps* teaches a rule the rest of the game silently breaks. Worse, the minimal path's server gate
   (`HOP_RATE_MS` 250 ms) means a modified client gets ~80% dodge uptime the moment airtime "has teeth" —
   fixing that means decoupling a dodge-cooldown from the hop cadence, more new surface.
4. **Playtime-per-session loses to Phase 8 everywhere.** The active goal is *making the game longer to
   play*. Every path's own numbers deliver ~0–2 h of one-time content for 3–10 sessions; the same sessions
   spent on the second biome buy directed playtime at several times that rate.
5. **Deploy churn is real.** Each sim-true tier is another Protocol bump + server-first redeploy + client
   re-export on a live public server, stacked on the still-undeployed v2 bump. If any tier is ever built,
   it should land **inside Phase 8's unavoidable deploy window**, not standalone.
6. **The expectation ratchet makes "stop at 0.5" time-dependent.** Shipping the networked hop trains
   players to attempt hop-dodges; every future telegraphed ground AoE raises the rate at which the
   cosmetic-lie surfaces as bug reports. The gate answer should be **re-checked at each content phase**,
   not treated as permanent.

## 3. What DOES survive the review (cheap, real, nobody had them on a list)

- **Portal-stacked "vertical" stadium (zero `shared/`).** The shipped `PORTALS` system can present the
  Phase-8 biome as field level → concourse → upper deck → rooftop, where each "level" is an ordinary flat
  `MAPS` entry and "climbing" is a ramp-dressed portal. Delivers the climb-the-stadium *fantasy* the T2
  design charges 3–5 sessions for, at content-authoring cost only.
- **Vertical set-dressing via the live props pipeline.** The camera is an orbit+zoom (not locked
  top-down); tall non-walkable silhouettes (bleachers, scaffolds, light towers) read as depth. The
  admin-decor pipeline that shipped 21 props in `09d1551` does this today.
- **Per-class cosmetic apex flourishes.** The sports identity's vertical moments (spike, hurdle, robbed
  home-run) as leap-on-cast flourishes riding the existing cosmetic `airborne` tag — jump as *identity*,
  not mechanic. Zero sim risk.
- **The free demand instrument.** `submit_hop` is already a server RPC: **one log line** counts
  hops/session forever. Two weeks of decay data answers "do players even keep jumping after the novelty?" —
  the exact Phase-1 input every path substituted with designer intuition.

## 4. Recommendation

**Gate answer: "feel" — the cosmetic hop suffices. True verticality is NOT a gameplay pillar for this
game. Close the standalone jump work-stream at Phase 0.5.**

> **Re-open condition EXERCISED at Phase-8 planning (2026-07-14):** the owner ran the named-moment test
> below and answered **NO** — Phase 8 (the Away Circuit) ships flat-2D everywhere. The gate remains
> closed. The `hops/min` counter keeps accruing; the test may be re-run at any future content phase.

With one owner-facing re-open condition, recorded here (the critic's "sharpest question"):

> **At Phase-8 planning, name one specific moment in the second biome where a player's jump must CHANGE an
> outcome — dodge a *named* attack or reach a *named* place.** If you can name it, build **exactly that**
> (one flagged boss carrying hop-dodge as its signature mechanic — combat Slice A scoped to one instanced
> arena — *or* one portal-stacked traversal level) **inside Phase 8's existing budget and deploy window.**
> If you cannot name it, the gate stays closed.

**Immediate actions regardless of the gate answer:**
1. **Commit + deploy Phases 0+0.5** (server-first — Protocol 1→2 — then client): the only
   positive-ROI verticality work outstanding, and an outstanding conflict risk while uncommitted.
2. **Add the one-line hop counter** to `submit_hop` (free demand data for the re-open condition).
3. ~~Fix the stale status lines~~ (done with this memo).

## 5. The owner's decision — **taken 2026-07-13: CLOSE THE GATE**

- ✅ **Close the gate (recommended) — CHOSEN:** hop suffices; §4 recorded; next work-stream = length
  Phase 8 / P7a.
- ~~Fold into Phase 8~~ — not pre-committed; note the §4 named-moment test can still surface one sim-true
  jump moment at Phase-8 planning.
- ~~Open a standalone verticality stream~~ — rejected with the judges (3–4/10).
- ~~Defer with data~~ — superseded; the `hops/min` counter ships anyway, so the demand data accrues for
  any future re-open.
