# Builder Mode — P3b (placement) + P4 (polish) handoff

**Status (2026-07-07):** P0–P2 (the whole server foundation) built, adversarially reviewed (3 rounds / 14 lenses),
and tested (builder smoke 84/84 + regressions green). The **P0 DB migration is APPLIED to production**
(`supabase/migrations/20260707120000_builder_mode_p0.sql`) and is backward-compatible with the currently-running
server. **P3a (buy/browse client UI)** is in progress. Nothing is redeployed yet — the server/client code
(P0+P1+P2+P3) lives in the working branch. This doc captures the two remaining pieces.

## What already works end-to-end (server, in-branch)
- **Unlock:** `buy_locker_room()` (10,000 cr, atomic gated flip, rate-limited). Client purchase prompt = P3a.
- **Zone:** `locker_room` per-character instance (`locker_room#<char_id>#1`), Home walk-on portal (gated on
  `locker_unlocked`), exit portal. Reconnect can't inject you into it (the `last_map` fix).
- **Buy items:** `build_buy(model)` — home-gated, catalog-priced, 50/20 caps (fetched under the lock), deduct-once
  + refund. Catalog `BUILD_CATALOG` (33 real props), tiered 250/600/1000/1500/4000.
- **Place/move/remove:** `build_place/move/remove` — own-locker-gated, char-scoped, gated PATCHes, coords clamped,
  refreshes the instance decal cache. Remove → `placed=false` (same item back to Build tab).
- **Render:** placed items → snapshot `decals` → `Client._render_decals` (already prefers server decals).
- **Client enablers shipped:** `self.locker_unlocked` in the snapshot; `recv_build_info` (catalog+caps+cost) on
  auth; `snap["build_shop"]` + `snap["locker_portal"]` pad positions; `World.BUILD_SHOP_POS/RADIUS`.

---

## P3b — Placement / decorator port (the interactive core; do against a LIVE client)

**Goal:** in your own unlocked Locker Room, place/move/remove your owned build items with the F4-decorator feel,
driven by the server RPCs (not local JSON). This is the piece that most needs a running client to build + tune,
which is why it's staged here rather than built blind.

### One required server tweak first
The placement UI must map a placed prop back to its inventory row to move/remove it, but the server decals don't
carry the item id yet. **Add `id` to the placed-items read + decals:**
- `Supabase.get_placed_build_items_as`: `select=id,model,xform` (add `id`).
- `Server._locker_decals`: include `"id": str((r as Dictionary).get("id",""))` in each decal dict.
  (`Client._render_decals` ignores the extra `id` key — safe. The locker is private, so leaking the id to the
  owner only is fine.)

### Client (reuse `Client.gd` decorator infra — see the map in the P3a context)
- Gate a **locker build mode** to `_in_own_locker` state (client knows it's in a `locker_room#…` map + unlocked).
  Reuse `_toggle_deco` / `_deco_input` / `_cursor_sim` / the HUD label, but:
  - **Selection** cycles your OWNED UNPLACED build items (from the Build tab inventory), not `DECO_PROPS`.
  - **Place** (LMB) → `net.build_place.rpc_id(1, item_id, {x,y,h,yaw,oy})` (server clamps; wait for the
    `recv_inventory_changed` echo + the room re-renders from the next snapshot's `decals`). Do NOT append to
    local JSON.
  - **Grab-nearest** finds the nearest placed decal by `id` (now that decals carry it) → **move** on drop →
    `net.build_move.rpc_id(1, id, xform)`.
  - **Delete-nearest** → `net.build_remove.rpc_id(1, id)` (returns it to the Build tab; no local delete).
  - yaw/scale(h)/lift(oy) tweaks reuse the existing keys; send them in the place/move xform.
- The free dev decorator (local `data/decals` JSON) stays source-only/admin for authoring shipped zones — keep it
  behind its existing gate; the locker build mode is the server-driven variant.

### Verify (needs a live client)
`./play.sh dev` (headless server + one client against the prod DB — the migration is live). Log in
(`legends_smoke1@testmail.dev` / `Testpass1234!`), buy the unlock, enter your locker, buy a few props, place /
move / rotate / remove them, confirm they persist across a re-enter and a relog. Watch the server log for
`SCRIPT ERROR`.

---

## P4 — Polish

- **Price tuning:** the tiered catalog (`BUILD_TIER_PRICE` 250/600/1000/1500/4000) + the 10k unlock are one central
  const — playtest and retune so the unlock ≈ a handful of nice pieces and the sink feels right.
- **Empty-room onboarding:** a first-entry hint in an empty locker ("Buy furniture at the Build Shop, press F4 to
  place"). Maybe a starter prop or a subtle floor grid/ring decal.
- **"Placed" badges** in the Build tab (if P3a didn't finish them) — and a count "N/50 owned, M placed".
- **Per-model-cap UX:** when a model hits 20, gray it out in the Build Shop with a reason (server silently no-ops a
  capped buy today — the client should reflect it so it's not confusing).
- **Cap feedback:** at 50 owned, the Build Shop should say so (the server no-ops; add client-side awareness).
- **Save-on-disconnect hardening / instance lifecycle:** confirm a disconnect mid-place leaves a consistent state
  (the review found this benign — periodic `_save_all` + per-kill save cover it — but re-verify with the live
  place flow).

## Known residuals (from the P0–P2 adversarial reviews — accepted/deferred, documented)
- **Concurrent same-character sessions** can (a) free-unlock via the systemic credit-clobber and (b) overshoot the
  50/20 caps by (sessions−1) via a fetch→insert TOCTOU. This is the **documented systemic** deduct-before-write /
  session-clobber issue shared by ALL spends (shop/forge/cosmetics), not Builder-specific. The clean fix is making
  economy DB-authoritative (atomic delta writes / conditional-insert RPCs). Optional Builder-local hardening: a
  security-definer `build_add_capped(p_char,p_model,p_owned_cap,p_model_cap)` RPC that counts-and-inserts atomically
  under a per-character row lock (mirrors `mats_add`), and a credit-atomic unlock RPC. Needs a small migration.
- **Lost-PATCH-response free unlock:** a network partition where the DB flip commits but the response is dropped →
  the refund path runs → one-time free unlock. Rare, non-repeatable (monotonic flag), same class as every
  deduct-before-write spend. Accepted.

## Deploy checklist (when ready — a production action, get explicit sign-off)
Touches server + client + `shared/World.gd` → **redeploy the server AND re-export the client from the SAME commit**
(see the deploy-ops notes). The P0 migration is already applied, so no DB step remains. Order: wait for CI green,
then the droplet redeploy (`curl … setup.sh | sudo -E bash`), then re-export/distribute the client. Verify with a
`./play.sh join 159.89.132.86` connect: unlock → buy → enter locker → place → relog persists.

## Full-feature playtest checklist
1. Fresh character → Build Shop pad shows; can't afford → tiles red; earn 10k → buy unlock at the locker portal.
2. Walk into locker (unlocked) → private room, empty.
3. Buy props (each tier) → they land in the Build tab; credits deducted; caps enforced at 50 / 20/model.
4. Place / move / rotate / lift / remove → persists across re-enter + relog; remove returns the item to the tab.
5. Two players can't see/enter each other's locker; a non-owner can't place in another's room.
6. No `SCRIPT ERROR` in the server log throughout.
