# Batch 004 review

Status: six previews complete; five recommended for refinement and one recommended for rejection.

Credits consumed: 120 (six 20-credit Meshy 6 previews). No refinement credits have been spent.

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
