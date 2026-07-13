# Batch 003 review

Status: complete. Four refined models approved and moved to the approved staging collection; two preview candidates rejected.

Credits consumed: 160 (six 20-credit Meshy 6 previews and four 10-credit refinements).

## Preview comparison

| Candidate | Triangles | Visual assessment | Recommendation |
|---|---:|---|---|
| Zone terminal | 6,120 | Strong freestanding console silhouette, large clean display area, useful control lip and stable pedestal. It reads immediately as an interactive arena terminal. | Refine |
| Leaderboard kiosk | 5,478 | Clean tall information-totem silhouette with a large vertical display, secondary lower panel and stable base. Distinct enough from the shorter interaction terminals. | Refine |
| Bounty terminal | 5,938 | Strong chunky console silhouette with broad screen, front controls and armored lower body. It successfully reads as the more industrial terminal variant. | Refine |
| Boundary pylon | 6,395 | Simple repeatable post with readable inset channels, side nodes and stable foot. Appropriate as a modular boundary or objective-state marker. | Refine |
| Floodlight bank | 6,120 | Missed the requested six-lamp array, producing four uneven box reflectors with tangled/intersecting center geometry and a distorted bracket. Texture would not solve its structural problems. | Reject; retry later with a simpler four-lamp prompt or build from repeated lamp modules |
| Compact scoreboard | 5,944 | The wide proportion is correct, but the surface is lumpy, the intended three-screen hierarchy is unclear, and an unwanted heavy base/support assembly makes it read like equipment cabinetry. | Reject; retry as a simpler single blank display module |

All previews contain one untextured mesh primitive, no materials or animations, and are staging-only. Meshy-normalized scale and generated pivots must not be treated as game-ready.

## Recommended refinement set

Refine `zone_terminal`, `leaderboard_kiosk`, `bounty_terminal`, and `boundary_pylon`: four tasks at an expected 10 credits each, hard ceiling 40 credits. Do not refine `floodlight_bank` or `compact_scoreboard` from this batch.

Refinement is only a texture/material-candidate pass. Any approved result will still need deterministic scale and pivot cleanup, screen/material separation or overlays for live Godot content, texture reduction/compression, collision decisions, and an in-engine lighting review before integration.

## Refined results

- **Zone terminal:** successful. Strong silver/graphite housing, dark navy blank display, cyan rails and restrained lime details. The display remains suitable for a live UI overlay. Recommend approval.
- **Leaderboard kiosk:** successful. Tall, distinct information-totem proportions with a clean black display, navy lower service panel and restrained cyan/lime/orange signals. Recommend approval.
- **Bounty terminal:** successful with a caveat. Excellent heavy industrial console body, cyan panel seams, lime side indicators and orange interaction control. Its display textured light gray rather than dark, so integration should replace or cover that surface with a dedicated live screen. Recommend approval.
- **Boundary pylon:** successful. Very readable graphite post with a cyan vertical state channel, lime cap and orange side nodes. Strong repeated-placement candidate. Recommend approval.

All four refined GLBs contain large embedded PBR textures and remain staging sources. Approval does not authorize gameplay integration.

## Final decision

Approved on 2026-07-13: `zone_terminal`, `leaderboard_kiosk`, `bounty_terminal`, and `boundary_pylon`. Their source GLBs and thumbnails are staged under `too_add_models/approved/arena_technology/`. `floodlight_bank` and `compact_scoreboard` remain rejected in this batch. No model has been integrated into gameplay.
