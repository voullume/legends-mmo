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

## Measured numbers (fill during the owner playtest)

| Zone | cold rebuild ms | warm rebuild ms | entry worst-frame ms | FPS (dense spot) | sig_avg_ms |
|---|---|---|---|---|---|
| loc1_fields | | | | | |
| loc1_pitch | | | | | |
| loc1_lane | | | | | |
| loc1_culvert | | | | | |

| Server | tick avg | p95 | worst | snap B avg/max |
|---|---|---|---|---|
| party clustered (pitch cache fight) | | | | |
| party spread (4 zones) | | | | |

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
