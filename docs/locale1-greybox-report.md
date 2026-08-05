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
- **Full verification:** all 37 CI suites green (incl. stab_away's world-wide sweeps over the new
  zones, 233/233) and **`bal_identity` byte-identical** (sig_w=158545831 / sig_d=343688940 — the CI
  pins; the cache channel provably never touched the sim).

## How to playtest (local, ~15 min — ONE command)

1. On this branch: **`./play.sh dev --perf`** — it boots the headless server (reads your `.env`
   key), opens the client already pointed at it, and shuts the server down when you close the
   window. Log in as **admin@legends.dev**. *(Launching the client alone, or from the editor
   without run args, lands in the offline sandbox — the paused practice field.)*
2. F1 → Teleport → **L1F** drops you straight into the fields (or GY5 and walk the south-edge
   "▶ The Practice Fields" pad — visible to admins only — for the full arrival).
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

## Adversarial review (3 lenses, 24 findings — the material ones fixed)

**Fixed:** the concurrent-channel loot dupe (N simultaneous channelers each minted an epic — the
completion path now re-checks the relock, first finisher wins, the rest hear "locked"); the login
escape-hatch hole (a transient gear/quest fetch failure no longer suppresses the dev-lock bounce —
strict for `loc1_gate` only, since it consumes neither); the culvert's fields mouth moved to the
entry plaza's south rim (600,1900) as the approved item-2 telegraph actually specified; the tower
got a real visitable in-zone mass (r32 collision column) so visible-before/visitable-after is
testable; `_cache_next`/`_cache_channel` joined the PID_DICTS cleanup contract; and the suite gained
~40 asserts closing its own blind spots (S1 every-pad gate loop, CACHES↔chest↔test-origin pins,
channel-duration + loot-quality + rate-limit + lockout-remainder asserts, guard-level floor,
order-proof clustering, GY5-side pad grammar, backdrop JSON integrity, a wait_until cap, and a
flake-proof production-delta clean-run driver).

**Accepted for the greybox (owner-visible, revisit at Phase 4):**
- Party roster shows a greybox zone NAME to a non-admin partied with an admin inside it (string
  leak only; gone when the gate opens at 4.5).
- "done" + the relock fire before the loot DB write resolves — on a failed save the player sees the
  banner but gets nothing and the world stays locked ~2 min. Phase 4.0's per-character claim will be
  transactional (claim only after the write lands).
- A transient admins-table read failure at login bounces a resuming ADMIN home (F1 goto recovers;
  non-admins unaffected).
- The GY5 pad sits 328 su from the nearest camp — 8 su of margin over the 320 rule, now pinned by an
  assert so it cannot silently shrink.

## Known greybox gaps (deliberate, land in Phase 4)

- Default theme/ground (no `loc1` palette yet) — the "one place" judgment should discount the turf.
- Bystanders don't see another player's channel bar (not in snapshots) — polish item.
- The chest renders even while relocked ("locked" toast on attempt) — the honest chest render lands
  with the real per-character lockout (4.0).
- Minor caches, the base hub, lots/ridge/press/boss: Phase 4 batches per the approved graph.
