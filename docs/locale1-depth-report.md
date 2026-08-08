# Locale 1 — the Depth Pass (report)

**Date:** 2026-08-06, round 2 2026-08-08 · **Branch/PR:** `locale1-p4` / PR #10 ·
**Commits:** `95566cd`, `492a29a`, `d6f6131` + round 2 `a0613c5`
**Status:** built, verified, dev-locked — waiting on the owner's look checkpoint (see APPROVAL_QUEUE).

## Round 2 — the scale-hierarchy pass (2026-08-08)

Owner's round-1 verdict: *"alot of the objects on the map are all the same small sizing and it
still feels and looks like a flat map."* Measured and confirmed: loc1 trees sat at median h 3.3 in
a 0.9-wide band (away_1: 4.0–8.0, median 5.5); buildings 2–3.6 vs home's 11. The fix, applied by
five per-zone composers (positions preserved; capture-and-look rounds each) + one geometry critic:

- **Tiers with jitter:** landmarks h 6.5–8.5 (fields 13 / pitch 11 / base 3 / lane 2; the culvert's
  landmarks are its six ≥5.8 spires), canopy 4.2–6.0, deliberate scrub below; deterministic
  position-hash jitter ±8–12% so no two neighbors match.
- **Verticals:** rock_tallC spires 2.6–3.4 → 4.3–6.5; buildings to parity (sheds 6.3–7.4,
  bunkhouse 5.6, stall/forge ~4.5); fences to away_1's 2.2–2.6.
- **Berms:** 176 rocks half-sunk via negative `oy` (render-only; server collision ignores `oy`) so
  ridgelines read as continuous earthen banks.
- **Re-proof:** collision replica proven byte-exact vs the engine dump (worst delta 3.6e-12);
  const prefixes frozen; keep-clears hold; all 41 camps ≥50% firing-ring LOS; per-zone flood-fill —
  five newly-sealed pockets reopened by minimum nudges; the base gate re-proven the only opening
  (plug test), 52.7 su walkable. `stab_locale1` 466/466; no `shared/` changes, so the round-1
  `bal_identity` proof stands. The prop-scale look-call from round 1 is hereby resolved by owner
  feedback; rings-as-paint and the pitch 300/300 cap remain open below.

## Why this exists

The Phase 4.1 look/feel checkpoint failed: *"it doesnt look like a place to revisit, its just
another blank rectangle map."* The response — promised then, delivered here — was to stop
checkpointing skeletons and dress the **whole locale** before coming back: every zone at the density
of `away_1` (the composed zone that already reads as a place), verified visually with an offline
capture harness before the owner ever sees it.

*(Recovery note: the session that built most of this crashed with everything uncommitted; the work
was recovered from the working tree, committed, and finished in the next session.)*

## What shipped

| Zone | Records | The read |
|---|---|---|
| `loc1_fields` | 299 | overgrown park — tree walls, rock ridgelines, shed-ruin/store-yard/equipment POIs, hidden pads |
| `loc1_pitch` | 300 (AT cap) | flooded pitches — islet approach, tower yard, container walls, ridge rims |
| `loc1_lane` | 142 | bent service lane — barrier corridors, fence lines, shelf POIs |
| `loc1_culvert` | 76 | drainage pocket — rock-lined walls, tube-mouth telegraph |
| `loc1_base` | 179 | **fenced groundskeeper compound**: continuous chest-high perimeter, ONE east gate (arrive on the open apron, walk in through light-column-flanked gate), zoned interior — forge yard / market front / notice corner / SW bunkhouse / fire-pit circle at the spawn plaza / SE work yard |

Plus: backdrop horizon rework for all five (`data/backdrops/loc1_*.json`), **`Protocol.VERSION`
4→5** (the decal files add collision — a stale client would hit invisible walls), the dev-only
`--capture` boot mode (`Main.gd` + `client/CaptureClient.gd`) that renders any map offline for the
art-pass screenshot loop, and `tools/stab_locale1.gd` 456→466 asserts (decal files must reproduce
the `World.DECALS` const as an exact ordered prefix, stay ≤300 records, and **existing files may
not silently vanish** — a missing decal file is now a red suite, negative-tested).

Screenshots: `docs/locale1-shots/` — 13 current shots + `before/` (the pre-pass look) +
`ref_away1_over.png` (the density reference).

## Verification stack

1. **Per-zone composer + adversarial critic** (5×2 agents): palette/bounds/cap conformance,
   keep-clears recomputed with engine `PROP_FOOTPRINT` circles, camp LOS ≥50% from the 250-su ring,
   chord-sweep sightline audits (fields: >1600-su clear chords cut 71%).
2. **The Base compound pass** (composer with 7 capture-and-look rounds + critic): 9 violations
   found/fixed; the east gate topology-proven the ONLY perimeter opening (all 82 fence circles form
   a single connected chain under gap<30 adjacency).
3. **Final 3-lens adversarial review** (after the global rock-scale/spire mutations that postdated
   the per-zone critics): a walkable-connectivity proof — collision replicated then proven
   **byte-exact against a headless-Godot dump** of `World.obstacle_circles` +
   `World.collision_from_decals`, flood-fill at player radius, **every POI reachable in every
   zone**; a code review of the capture harness / Protocol bump / suite pins; a 10-file data sweep.
   Two should-fixes applied (5 sealed free-ground pockets reopened by minimum-distance moves; the
   missing-file suite guard), the rest below.
4. **The battery:** all 36 CI suites green; `bal_identity` **byte-identical**
   (`sig_w=158545831 sig_d=343688940` — the CI pins). `stab_locale1` 466/466 on the final tree.

## Owner look-calls (accepted for now — confirm or overturn at the checkpoint)

- **15 decorative rings** sit far from camps (fields/pitch mostly). Kept as *painted field
  markings* — the approved greybox const already uses landmark rings (the pitch floodlight ring,
  the culvert junction ring). Overturn = recenter them onto camp/cache coords.
- **Prop scale continuity:** the whole locale is dressed at ~40–50% of the home/basecamp prop scale
  (trees median h 3.3–3.5 vs 4.6–9.0; base service props under half hub size). It reads fine in
  isolation — the question is whether it should be the loc1 family language, or the Base services
  should be lifted toward hub parity so they stay recognizable.
- **`loc1_pitch` is at exactly 300/300** — the density cap has zero headroom; the next pitch decal
  must displace one or move the cap (a deliberate decision, not a drive-by).
- **`--capture` exposure:** any player build can render dev-locked zones with a flag — but the zone
  data always shipped inside the client pck, so this only lowers the spoiler bar from "unpack the
  pck" to "pass a flag"; server-side dev-locks are untouched. Accepted. (Optional hardening:
  editor-gate the branch like `--token`.)
- Cosmetic nits logged, not acted on: three `glitchyard_wall` panels dress loc1 (biome-foreign,
  thematic swap someday); 53 spires carry a dead `oy: 0.0` field (tidy later); one lane pylon is
  visually embedded in a rock.

## What Phase 4.x still owes (untouched by this pass)

- The fields **checkpoint pad still teleports** — the "jarring teleport" disguise/replace is a
  mechanic change, not dressing (4.2/4.3 material). The pad is at least *hidden* behind the NW rock
  spur now.
- **Cache-arena breathing room** (pitch) and the owner's "maybe a little too small still" — both
  deliberately AFTER this density pass lands, per the owner's own sequencing.
- The **global `MOB_RESPAWN_DELAY` decision** is still open in the queue (unrelated to this pass).
