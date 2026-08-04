# Locale 1 greybox slice — build report + the owner playtest (Official Maps Phase 2)

**Status: BUILT, on branch `locale1-greybox` — NOT deployed.** Everything is primitive shapes by
design; the gate question is *"does it feel like one continuous place, and is the cache worth the
detour?"* — not how it looks. Per the handoff: **Phases 1 and 2 are the whole bet** — reshaping the
graph after this playtest is the designed outcome, not a failure.

## What was built (the approved §10 item-8 slice)

- **Four zones** off GY5's new south pad: `loc1_fields` (3600×2800 broad hub — ~2¼ max-zoom camera
  views wide), `loc1_pitch` (3200×2400 hub #2), `loc1_lane` (bent 2600×700 alternate route),
  `loc1_culvert` (1000×700 pocket = the cross-zone return shortcut). Provisional levels L5–10.
- **The seams:** fields→pitch main seam (stands in for the future lots leg), fields→lane→pitch
  alternate, pitch→culvert→fields return, the fields intra-map checkpoint. Matched horizons: GY
  smokestacks west, the Floodlight Tower east/north (`#617F70`), the Reclaimed Bowl far east, a
  treeline thickening west→east (the decay→nature gradient).
- **THE MAJOR CACHE (§9.1), pitch north islet:** a `championship_reward_chest` behind a 5-guard pack
  in two separable sub-clusters 340 su apart, three `glitchyard_wall` LOS covers forming a
  chokepoint gap, the prize visible from outside the pack's 320 aggro. **Opening = a 2.5 s channel
  (press R) that breaks on any hit or on moving** — kite-and-grab does not work; clear or control.
  Reward: a guaranteed **epic at ilvl 15** (= the guard elite's own drop math, above every route
  minion). Greybox lockout: the cache relocks **per-world for 2 min** after a loot (the real
  per-character expiring lockout is Phase 4.0).
- **Dev-lock:** `loc1_gate` is admin-only + hidden (HIDDEN_GATES) — non-admins can't see or enter the
  greybox, tampered `last_map` bounces to HOME, and merged batches stay inert on any interim release.
  One real fix rode along: the login admin-flag fetch now happens **before** gate re-validation, so an
  admin who logs out inside the greybox resumes there.
- **`--perf`** client harness + `docs/locale1-budgets.md` (the §10 ledger + proposed ceilings).
- **`tools/stab_locale1.gd` — 358 asserts, green**, registered in CI: boot pins, dev-lock, the full
  walk graph, tampered-restore, self-contained geometry sweeps (arrivals >320, r+16 collision
  clearance, elite-pad margins, engageability LOS rings), the mechanized §9.1 arena checklist
  (cluster separability, wall presence, see-the-prize-first), and the channel lifecycle
  (complete / hit-break / move-break / lockout / loot-once).
- `Protocol.VERSION` 3→4 (the new RPC pair). Mob-def golden untouched (all reused classes).

## How to playtest (local, ~15 min)

1. `SUPABASE_SERVICE_KEY=... godot --headless -- --server` (this branch), then launch the client
   from the editor with `--online 127.0.0.1 --perf` and log in as **admin@legends.dev**.
2. F1 → Teleport → **GY5**, walk to the south edge → the "▶ The Practice Fields" pad (visible to
   admins only).
3. **The walk:** fields entry → east across the hub (is it *big*?) → treeline break → pitch → find
   the tower ring → the cache islet (north) → try the cache at-level (F1 set level ~9): pull the
   pack as a blob once (should hurt), then try separating the clusters around the walls → open the
   chest (R) → leave via the culvert (west mouth) → pop out at the fields entry plaza.
4. Come back through the lane (fields SE gap) for the alternate-route feel; try the fields
   checkpoint pad; note the `[perf]` lines for `docs/locale1-budgets.md`.

## The gate questions (§11 row 2)

1. Does the slice read as **one continuous place** (seams = travel, not teleports)?
2. Is the hub's **scale** felt (you cannot see both walls; the tower pulls you east)?
3. Is the **cache worth the detour** — and is it beatable by *strategy* (separating the pack), not
   just by levels?
4. Traversal timings vs the graph doc §8 table (record what you actually walked).
5. `--perf` numbers into the budgets doc; ratify the proposed ceilings.

## Known greybox gaps (deliberate, land in Phase 4)

- Default theme/ground (no `loc1` palette yet) — the "one place" judgment should discount the turf.
- Bystanders don't see another player's channel bar (not in snapshots) — polish item.
- The chest renders even while relocked ("locked" toast on attempt) — the honest chest render lands
  with the real per-character lockout (4.0).
- Minor caches, the base hub, lots/ridge/press/boss: Phase 4 batches per the approved graph.
