# Batch 001A review

Status: Complete. Candidates A and B approved and moved to their respective approved collections; C rejected.

Credits consumed: 80 (three 20-credit previews plus two 10-credit refinements).

## Candidates

- A — Clean broadcast arena
- B — Industrial Glitchyard
- C — Sportbound-pattern influence

No candidate is approved for refinement or game integration yet.

## Technical comparison

| Candidate | Triangles | Vertices | Bounds (raw preview) | Review |
|---|---:|---:|---|---|
| A — Clean broadcast | 7,637 | 10,627 | 1.90 × 0.66 × 0.62 | Strongest front-facing panel rhythm. Ends and lower rail are imperfect/lumpy, so it is a visual anchor rather than a production-ready tile. |
| B — Industrial Glitchyard | 7,517 | 10,980 | 1.90 × 0.54 × 0.52 | Flattest, longest, and most plausibly modular silhouette. Detail is industrial and subdued. Best geometry base if the textured refine carries the requested palette. |
| C — Sportbound pattern | 6,758 | 9,674 | 1.90 × 1.05 × 1.90 | Failed the wall proportion: generated a large floor/plinth and excessive depth. Reject or retry; do not refine this mesh. |

All previews contain one mesh primitive with UVs and normals, and no materials, textures, or animations (expected for preview mode). Raw dimensions are normalized by Meshy rather than authored at the requested six-meter scale; any accepted model would need deterministic rescaling and pivot cleanup before integration.

## Recommendation

Candidate B's refinement produced a coherent dark navy/graphite industrial wall with small orange wear/accent points. It is a usable Glitchyard base, but the requested cyan rails and lime diagnostic accents are nearly absent. Do not propagate it unchanged as the universal sports-tech kit.

Refined B contains one opaque, double-sided PBR material with 2048×2048 base-color, metallic-roughness, normal, and emissive textures. Geometry remains about 7.5k triangles. The 6.15 MB GLB is acceptable as a source candidate but its four 2K textures imply excessive runtime VRAM for a repeated ordinary wall; an accepted integration copy should be resized/compressed and likely use 1K maps.

Refined B was accepted as the **Glitchyard industrial wall anchor** and moved to `too_add_models/approved/environment/glitchyard_wall/` with approval metadata.

Refined A delivers the missing clean championship language much more successfully: navy/graphite panels, cyan horizontal energy rails, small lime/yellow and orange indicators, and a strong three-panel broadcast silhouette. It remains organically uneven at the top rail and ends, so it is not guaranteed seamless without cleanup, but it is a strong source candidate for the home-base/premium-arena family.

Refined A technical shape: about 7.6k triangles, one opaque double-sided PBR material, and four embedded 2048×2048 textures. Like B, it should be rescaled, pivot-corrected, texture-reduced/compressed, and visually seam-tested before integration.

Refined A was accepted as the **clean home-base/championship-arena wall anchor** and moved to `too_add_models/approved/environment/championship_arena_wall/` with approval metadata.
