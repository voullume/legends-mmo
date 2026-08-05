# Locale 1 — client + server budgets (Official Maps §10)

**Purpose:** the per-zone budget ledger the greybox slice establishes and every later Locale batch is
held to (Phase 4 gate: "per-zone budgets held"; Phase 9 triggers only when a number here is breached).
Server half reads the live `[health]` line; client half comes from the **`--perf`** flag added in the
greybox (launch the client with `--perf` → `[perf]` lines on stdout).

## How to measure (the protocol)

- **Client** (owner's machine, the weakest target we care about): launch with `--perf`, log in, visit
  each zone twice — the FIRST visit is the cold number (GLB loads), the revisit is warm. Record:
  `[perf] decals … rebuild_ms cold=true/false`, `[perf] backdrops … rebuild_ms`,
  `[perf] zone-entry … worst_frame_ms`, and the 5 s `[perf] fps= draw_calls= sig_avg_ms=` line while
  standing in the zone's densest spot.
- **Server**: read `[health]` / `[health/zones]` (tick avg/p95/worst, snap bytes, per-zone `f=`/`c=`)
  with a party **clustered** at one camp vs **spread** across zones; residents toggled on.

## Static per-zone counts (greybox, authored)

| Zone | Decal records (const) | Backdrop records | Collision circles (obstacles + decals) |
|---|---|---|---|
| loc1_fields | 12 | 12 | 12 |
| loc1_pitch | 17 | 12 | 27 |
| loc1_lane | 6 | 4 | 14 |
| loc1_culvert | 7 | 2 | 6 |
| *(away_1 reference)* | *115* | *34* | *(shipped)* |

Circle counts: `World.circles_from(World.OBSTACLES[map]).size() + World.collision_from_decals(map).size()`.

## Measured numbers (owner playtest 2026-08-05, RX 5700 XT)

| Zone | cold decal rebuild ms | warm ms | backdrops cold/warm ms | entry worst-frame / FPS / sig |
|---|---|---|---|---|
| loc1_fields | 1.5 | 1.5–2.1 | 138.0 / 0.5 | *(pending — the reporter hook was dead online; fixed, re-measure next run)* |
| loc1_pitch | 221.5 | 1.8–4.7 | 3.2 / 0.5 |〃 |
| loc1_lane | 0.8 | 0.9–2.0 | 0.3 / 0.2 | 〃 |
| loc1_culvert | 0.8 | 0.7–1.8 | 0.2 / 0.1 | 〃 |
| *(references)* home 2343 cold (login GLB warm-up) · gy5 561 · finals_2 583 · away_1 300 — all warm ≤ 7 | | | |

Cold spikes are the process-lifetime GLB cache filling on FIRST visit (mostly at login on home);
warm revisits are 1–7 ms everywhere — well under every ceiling. One engine warning to carry:
`Sending 4840 bytes unreliably above MTU (1392)` fired once at login on home (full-roster snapshot)
— pre-existing class, watch it in Phase 4 when hub populations grow.

| Server (single player touring) | tick avg | p95 | worst | snap B avg/max |
|---|---|---|---|---|
| loc1 zones occupied | 0.7–2.3 ms | 2.8–8.4 | 6.1–16.9 | 928–2872 |

All inside the proposed ceilings. Clustered-vs-spread party runs still owed (needs 2+ players).

## Proposed ceilings (ratified at the Phase 2 gate, enforced per zone from Phase 4 on)

- **Zone-entry worst frame ≤ 120 ms cold, ≤ 50 ms warm** (the §10 hitch risk).
- **FPS ≥ 30 on the weakest target** in the densest authored spot.
- **sig_avg_ms ≤ 0.5** (the per-frame stringify tax — if a full-density hub breaches this, the Phase 9
  dirty-flag fix triggers).
- **Decal records per broad hub ≤ 300** (density falls as zones grow — away_1's 115 at 2.47M su² ⇒
  ~470 at hub area is the projected risk line; staying under 300 keeps a full hub below it).
- **Server tick p95 ≤ 15 ms** at ordinary population; **snapshot ≤ 2×** the P2-report baseline.

The greybox's own numbers will sit far under all of these (it is deliberately sparse); the point of
measuring it is the **baseline + the harness**, not the verdict.
