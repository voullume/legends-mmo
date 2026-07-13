# Batch 002 review

Status: complete. Five refined models approved and moved to the approved staging collection; malformed locker bank rejected.

Credits consumed: 170 (six 20-credit previews and five 10-credit refinements).

## Preview comparison

| Candidate | Triangles | Visual assessment | Recommendation |
|---|---:|---|---|
| Single locker | 5,686 | Clear isolated locker silhouette, closed door, usable proportions. Some organic dents but strong enough to texture-test. | Refine |
| Four-locker bank | 5,745 | Generated four irregular separated/overlapping lockers instead of one clean joined bank. Poor repetition and footprint. | Reject and later retry using the approved single locker as a reference |
| Player bench | 6,065 | Recognizable three-person bench with a stable broad silhouette. Surface is somewhat lumpy but appropriate for a padded sports bench. | Refine |
| Equipment shelf | 5,775 | Strongest geometry in the batch: clean freestanding rack, three shelves, lower cubbies, flat usable profile. | Refine |
| Multi-sport ball rack | 6,468 | Strong rolling-rack silhouette and visible storage tiers. Ball shapes are numerous and imperfect but should read correctly at gameplay distance. | Refine |
| Trophy pedestal | 5,378 | Ignored the empty-pedestal instruction and generated a complete trophy/cup. The result is visually useful as a championship trophy, but not as the requested empty pedestal. | Refine as a trophy candidate and rename if texture succeeds |

All six previews contain one UV-mapped mesh primitive with normals and no materials/textures/animations, as expected for Meshy preview mode. Meshy normalized their raw dimensions; every accepted source will require deterministic game scale and floor-contact pivot cleanup.

## Recommended refinement set

Refine the single locker, player bench, equipment shelf, ball rack, and trophy reinterpretation: five tasks at an expected 10 credits each, hard ceiling 50 credits. Do not refine the locker bank. A future bank should be derived from repeated copies of one approved single-locker model or generated from a controlled reference rather than accepted as this malformed combined mesh.

## Refined results

- **Single locker:** successful. Strong navy/graphite body, bright cyan identity rail, orange latches, and readable vents. Approve.
- **Player bench:** successful. Clean navy padded bench with cyan under-rail and dark supports. Approve.
- **Equipment shelf:** successful. Coherent dark rack with subtle lime/cyan fittings and empty usable shelves/cubbies. Approve.
- **Ball rack:** successful as a sports-equipment rack, but not genuinely multi-sport: most balls read as soccer balls with several orange/brown generic balls. Approve under the more accurate name `sports_ball_rack` rather than promising four distinct sports.
- **Trophy:** highly successful as a complete championship trophy rather than an empty pedestal. Approve and rename `championship_trophy`.

Every refined source uses large embedded PBR textures and remains a staging/source candidate. Before runtime integration, normalize scale/pivot, reduce textures (normally toward 1K for repeated furniture), compress through the Godot import pipeline, and inspect actual in-engine lighting.

## Final decision

Approved on 2026-07-12: `single_locker`, `player_bench`, `equipment_shelf`, `sports_ball_rack` (generated as `multi_sport_ball_rack`), and `championship_trophy` (generated as `trophy_pedestal`). The approved source GLBs and thumbnails are staged under `too_add_models/approved/locker/`. No model has been integrated into gameplay.
