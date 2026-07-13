# Batch 004 review

Status: complete. Five refined models approved and moved to the approved staging collection; one preview candidate rejected.

Credits consumed: 170 (six 20-credit Meshy 6 previews and five 10-credit refinements).

## Preview comparison

| Candidate | Triangles | Visual assessment | Recommendation |
|---|---:|---|---|
| Player tunnel gate | 6,154 | Clear connected walk-through opening and strong entrance silhouette. The surface is more irregular and heavy than the prompt intended, but the structure is coherent enough for a texture test and could serve as a rougher arena entrance family. | Refine |
| Straight cover barrier | 6,008 | Strong low horizontal cover silhouette with repeatable-looking end supports and visible side rails. Slightly uneven, but practical as field cover at gameplay distance. | Refine |
| Spectator safety rail | 5,704 | Readable handrail, lower guard panel, supports and floor rail. It generated two main supports rather than three and includes a very thin stray line that may need mesh cleanup, but the main structure is usable. | Refine |
| Arena service door | 5,436 | Cleanest preview in the batch: unmistakable closed double door, contained armored frame, central latch and flat wall-insert profile. | Refine |
| Equipment transport crate | 6,465 | Strong connected road-case silhouette with armored corners, recessed center panel and visible wheel forms. Suitable as movable dressing or substantial cover after scale review. | Refine |
| Team dugout canopy | 6,286 | Broad shelter volume is recognizable, but a bar floats above the roof and the front corners became malformed seat/rail-like structures despite the empty-interior requirement. Texture cannot correct those structural failures. | Reject; retry later with a simpler three-sided shelter prompt or assemble a canopy manually |

All previews contain one untextured mesh primitive, no materials or animations, and remain staging-only. Meshy-normalized scale and generated pivots are not game-ready.

## Recommended refinement set

Refine `player_tunnel_gate`, `straight_cover_barrier`, `spectator_safety_rail`, `arena_service_door`, and `equipment_transport_crate`: five tasks at an expected 10 credits each, hard ceiling 50 credits. Do not refine `team_dugout_canopy`.

Any approved refined result will still require deterministic scale and pivot cleanup, texture reduction/compression, collision decisions, modular seam testing where relevant, and an in-engine lighting review before integration.

## Refined results

- **Player tunnel gate:** successful. The irregular armored geometry became a distinctive heavy arena entrance with coherent navy metal, cyan rails and orange controls. It is less clean/championship-like than requested but works well as a rugged Glitchyard or away-arena gate. Recommend approval under that usage caveat.
- **Straight cover barrier:** successful. Compact navy field cover with bright orange protection rails, cyan end details and readable supports. Recommend approval; seam-test before modular repetition.
- **Spectator safety rail:** successful with cleanup caveat. The navy/orange material family reads clearly and the main structure is coherent. One thin stray strand remains behind the guard panel and should be removed during mesh cleanup. Recommend approval.
- **Arena service door:** successful. Clean navy double door and frame with a strong orange center latch and small status light. A tiny generated marking near the header should be removed or obscured during texture cleanup. Recommend approval.
- **Equipment transport crate:** highly successful. Strong road-case silhouette, cyan identity rail, orange latches, lime indicators and visible wheels. Recommend approval.

All five refined GLBs contain large embedded PBR textures and remain staging sources. Approval would not authorize gameplay integration.

## Final decision

Approved on 2026-07-13: `player_tunnel_gate`, `straight_cover_barrier`, `spectator_safety_rail`, `arena_service_door`, and `equipment_transport_crate`. Their source GLBs and thumbnails are staged under `too_add_models/approved/arena_structure/`. `team_dugout_canopy` remains rejected in this batch. No model has been integrated into gameplay.
