# Approval Queue

**What this is:** the single file to read after time away. Every item below is work that is *built or
proposed* but waiting on an owner decision. Nothing in this repo ships to the droplet without that
decision — see `CLAUDE.md` §Releases.

**How it works**
- Work happens on a **branch + PR**, never straight on `main`. CI verifies every push and PR.
- Each item names: what it is, where the evidence lives (report section, captures, PR), and the
  **exact decision** needed — so a batch of answers can be given in one sitting.
- When an item is decided, it moves to *Decided* with the date and the call, then out of the file at
  the next ship. Nothing is deleted silently.
- **Blocked-on-owner is a stopping point, not a reason to guess.** Items sit here indefinitely; that
  is the design.

**Standing vetoes** (do not build, do not re-litigate): P7a sockets+gems; walkable sim-z / the
jump-verticality gate (`docs/jump-verticality-phase1-decision.md`). See `CLAUDE.md`.

---

## Waiting on you

### Official Maps — Phase 1: the Locale 1 graph (2026-08-04, NEW)
**`docs/locale1-graph.md` is the paper locale graph** (zone set, topology, seams, POI/traversal
budgets, cache + tape reservations) per the handoff's Phase 1. Nothing is built. **Decision needed:
the 8-item block in that doc's §10** — one sitting unlocks Phase 2 (the greybox slice). Evidence:
the doc itself + PR `locale1-graph`.

### Open right now (2026-08-02, after the v1.17.0 batch)
1. **PR #3 `p5-taste-tweaks` is PARKED, not merged** — gy2 tower 400 su closer, away_boss silhouette
   spire, two backdrop masses pulled off the wall. Built, green, costs nothing sitting there. Merge
   it whenever visuals come back around, or close it if the mapping pass supersedes it.
2. **Death pass-3 for the remaining five wildlife mobs.** warfrog + howler shipped in v1.17.0. The
   other five almost certainly carry the SAME bug (a spin about the body axis instead of a topple,
   plus a vertical offset on an axis that does nothing) — skink, grazer, forager, magpie and the
   splinterback are unaudited. The authoring + measured-grounding scripts port directly:
   `too_add_models/anim_pass3_warfrog/`.
3. **`too_add_models/` history purge.** It is untracked as of v1.17.0, but 318 MB remains in git
   HISTORY. Reclaiming it needs a filter-repo rewrite + force-push that rewrites every commit and
   tag. Only worth it if clone size actually bothers you.
   ⚠ **Related hazard, learned the hard way:** untracking does NOT protect the files from git.
   Checking out any commit from BEFORE the untracking (307dabc) restores the tracked copies, and
   switching back deletes them again — all 253 files, including `.gdignore`, vanished from disk
   during the merge and had to be restored. Without `.gdignore` Godot would try to import 4.6 GB.
   **The durable fix is to move the staging directory OUTSIDE the repo** (e.g. `~/legends-staging/`)
   so no git operation can reach it. Say the word.
4. **Phase 6 (world-expansion perf) is ready to close or continue** — it is the last unbuilt phase.
   v1.17.0 shipped the telemetry it demanded. If the numbers show headroom at real player counts,
   the correct outcome is "measured, no ceiling, closed", which finishes the program.

### From P5 / v1.16.0 (shipped 2026-07-29 — these are tuning, not blockers)
Evidence: `docs/world-expansion-p2-report.md` §11, captures `docs/world-expansion-p2-shots/AFTER_p5_*.png`.

| # | Item | Decision needed | Cost if yes |
|---|---|---|---|
| 1 | **gy2 first-sighting is faint** — the Command Tower reads as a subtle fogged spike at ~3400 su | leave / move ~400 su closer / add height | one record edit, client-only |
| 2 | **away_boss reads as mood, not silhouette** — low ember ridge + sparse dead trees | accept / add one silhouette element | a few records, client-only |
| 3 | **6 new tint hexes** (`#4A3B28` tower, `#452718` ember den, `#3B3366`/`#2A2450`/`#1C1838` finals city, `#617F70` arena floodlight) | keep / swap any | one dict value each |
| 4 | **gy3 cover barrier** adds real LOS cover 125 su from two ranged camps (consistent with gy1 grammar) | keep / move | one record, **server+client** |
| 5 | **Two backdrop masses sit tight to the wall** — `away_boss[0]` 61 su, `finals_1[15]` 76 su (shipped floor is 197) | leave / push out | two records, client-only |
| 6 | **Live client login smoke for v1.16.0 never happened** — no headless connect harness exists; needs a GUI login to see the gy5 tower in production | you spend a minute, or we accept the image-level verification already done | — |

### From P4 / v1.15.0
Evidence: `docs/world-expansion-p2-report.md` §10 items 1–7.
- **Concourse/Roof quests** — layer kills currently credit nothing map-matched (`away3_*` quests key
  `away_3` exactly). A layer quest is a separate design call.
- **The Rafter's 338 su aggro margin** — inside grammar, but the tightest in P4.
- **Moss-patch texture reads banded** — polish candidate.
- **Resident-freeze tradeoff** — with all zones asleep the 11 AI residents stop and their RP4
  playtest-report stream pauses. If the 24/7 fiction matters more than the CPU, the alternative is a
  low-rate tick (every Nth step) instead of a full stop. Say the word and it switches.

### From P2 / P3 (v1.14.0)
- Broodmother respawn cadence (default 6 s elite; a per-row rarity would rebase the mob golden).
- Broodmother tint `#3A5230` — owner-swappable, same flow as the A4 palette.
- `stadium.glb` weight (578k verts) — sits 1450 su past the clamp.
- Wallow-ring vocabulary, nest respawn, discovery affordances, monument/flora scale.

### Program-level
- **Class skill VFX/SFX: 7 of 8 classes remain** (Goalkeeper / Batter / Pitcher / Quarterback /
  Linebacker / Setter / Spiker). Striker shipped v1.12.0 and left a reusable keyed-VFX system, the F3
  tuner, and a capture harness. Decision: which class next, and in what order.
- **World-expansion Phase 6 (perf)** — the only unbuilt phase. Explicitly measurement-driven, and the
  capacity problem it targeted is already closed (idle `peak_tick` 1.9 ms at `asleep=18/18`). Nothing
  to do until a measurement says otherwise.

---

## Decided (kept for the record)

| Date | Item | Call |
|---|---|---|
| 2026-07-29 | P5 gy2 tower / away_boss / 6 tints / gy3 barrier, at ship time | keep all as-is (still swappable — see above) |
| 2026-07-29 | `Protocol.VERSION` → 3 for the P5 decal-data ship | yes — converts silent invisible walls into a clean update prompt |
| 2026-07-26 | P4 capacity gate | option 1 — build the empty-zone sleep |
| 2026-07-25 | Combine world-expansion P3 into the P2 deploy | yes |
