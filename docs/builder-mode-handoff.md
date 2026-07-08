# Builder Mode + the Locker Room — Handoff

**Status:** planned, not started — but **fully specced and ready to hand off.** All design decisions are
**locked (2026-07-07)** and the F4 decorator this reuses tested OK. Paste the kickoff prompt at the bottom to begin.
**Goal:** a purchasable, per-player customizable personal space ("the **Locker Room**") that players decorate by
buying and placing furniture/props with credits. Private per player for v1.

> Naming note: this personal zone is called the **Locker Room**. It is *distinct* from the existing **Locker
> Loadout** gear screen (key `U`). If that overlap becomes confusing in-game, rename the zone later — the
> internal map id `locker_room` is easy to change.

---

## 1. What we're building

- A new **private, per-player instanced zone** — the **Locker Room** — reached by a portal from the shared
  **Home Base**. Not visitable by others in v1 (private is the *default* with instancing; visits are an easy
  later add).
- A one-time **10,000-credit unlock** to buy access to your Locker Room.
- **Build items** = a new inventory category (furniture/props). Bought **one at a time with credits** from a
  new **Build Shop pad in the Home Base** (a vendor pad like the shop/forge), they land in a **separate
  "Build" tab** in the inventory (so gear stays uncluttered).
- **Builder mode** inside your Locker Room = the existing F4 decorator UX (place / grab-move / rotate / lift /
  undo), placing from your **owned build items**, server-authoritative and saved to your account. **Removing a
  placed item returns it to your Build inventory** as that item (no refund, no dupe).
- Hard **caps + server authority** (50-item cap/char) so it can't be abused, dupe'd, or overstocked.

## 2. Why it's feasible — every primitive already exists

This is a **recombination**, not new tech. Zero `shared/` combat-engine changes.

| Builder needs… | …already exists as |
|---|---|
| Per-player persistent data | Supabase `characters` / `inventory` tables (server writes via `service_role`, RLS-scoped) |
| A private per-player space | The **instancing** system — Camp/Drill spin up a private `"<template>#<owner>"` world, torn down when empty (`World.INSTANCE_MAPS`, `is_instance_template`, `_template()`) |
| Buying with credits, server-validated | The **shop** flow (`shop_buy` deducts credits server-side; rate-limited + serialized) |
| Items in a tabbed inventory | The **inventory** system + its UI (sort/filter tabs, the work already done) |
| Place / move / rotate / lift / undo | The **F4 decorator** (`Client._deco_*`, `DECO_PROPS`) |
| Render a per-space layout | `_render_decals` already honors a server-sent `_state["decals"]` (currently unused by the server) |

## 3. Architecture

### 3a. The Locker Room = a personal instanced zone
- New instance template `locker_room` in `shared/World.gd` (add to `INSTANCE_MAPS`), a **safe** map (no combat,
  no mobs), sized like a room.
- Reached via a portal in the shared Home Base: `{"x":…, "y":…, "instance": LOCKER_ROOM, "label": "▶ Your Locker Room"}`.
- **Owner keying:** existing instances (Camp) key by *party*; the Locker Room keys by **character** →
  `"locker_room#<char_id>"`. Small server tweak to the instance-creation path to use the entering
  character as owner for personal instances.
- **Ephemeral instance, persistent layout:** the world is spun up on entry and torn down when you leave; your
  placed items live in the DB. Server cost = only active builders.

### 3b. Build items = a new inventory category + a "Build" tab
- Add an item **category** flag (e.g. `kind:"build"` / `slot:"build"`) distinguishing furniture from gear.
- The inventory UI gets a **"Build" tab/filter** that shows *only* build items — gear tabs stay unchanged, so
  no clutter. (Extends the existing inventory sort/filter work.)
- Build items are **not** equippable and carry no combat stats — they carry a **model id** + an optional
  **placement transform** (see data model).

### 3c. Data model (inventory-centric — single source of truth)
Keep all build items in the **`inventory`** table as rows of the new category. Each build item stores its
placement inline, so "your Build tab" and "your Locker Room layout" are the *same data*, just filtered:

```
inventory row (category = "build"):
  id, owner_char_id, model            -- e.g. "tree_oak", "chair", …
  placed        bool                  -- is it currently in the room?
  x, y, oy, yaw, h                     -- transform (null/0 when unplaced)   [or a jsonb `xform`]
```
- **Buy** → insert an unplaced build row (credits deducted).
- **Place** → `placed = true` + write transform. **Remove** → `placed = false`. **Move/rotate/lift** → update transform.
- **Locker Room render** = server queries `inventory where category='build' and placed=true and owner=<char>`,
  sends it as the snapshot's `decals` → the existing `_render_decals` path draws it. Minimal client change.
- A tiny `unlocked` flag for Locker-Room access lives on the **character** (a column) — no separate table needed.

> Invariant this gives you: total build items = unplaced (Build tab) + placed (in room). **No dupes, no
> credit-refund exploit surface** — placing/removing just flips a flag, it never mints or destroys items.

### 3d. Credits + caps (anti-abuse — server-authoritative, no exceptions) — LOCKED
- **Unlock**: `buy_locker_room` RPC → deduct **10,000 credits** (one-time) → set `unlocked = true`. The
  Home-Base Locker-Room portal shows "Purchase (10,000)" until then.
- **Buy item**: `build_buy(model)` RPC from the **Home-Base Build Shop pad** → validate the model is in the
  server catalog, enough credits, **under the 50-item cap** → deduct the item's price → insert an unplaced
  build row.
- **Place / move / remove**: `build_place / move / remove` RPCs. Placing/moving is **free** (you own it); the
  only credit event is the purchase. **Remove returns the item to the Build tab** (`placed = false`) — as that
  item, no refund, no dupe.
- **Caps & guards (all server-side):**
  - **Max owned build items per character: 50** — hard cap; bounds stockpile *and* render (placed ⊆ owned),
    keeping each Locker Room cheap to store + send.
  - **Optional per-model cap: ~20** of one prop — easy to switch on if someone hoards 50 identical trees.
  - **Coordinate validation:** server clamps / rejects placements outside the Locker Room bounds.
  - Every credit-spending / mutating RPC is **rate-limited + serialized** (the `_shop_busy` / `_equipping`
    pattern) — CLAUDE.md flags this class; a prior review caught a sell-dupe money-printer from skipping it.
  - Credits + item grants are **100% server-owned**; the client only sends intents.
- **Starter price catalog** — one central server constant, trivial to retune later (that's the whole point).
  Suggested tiers so the 10k unlock ≈ a handful of nice pieces:

  | Tier | Example props | Price |
  |---|---|---|
  | Small | cone, flower_redA / yellowB, plant_bush, grass_large, log_stack | 250 |
  | Medium | rock_large*, stone_largeB, plant_bushLarge, fence_* | 600 |
  | Trees | tree_oak / default / thin / pineRoundC / palmDetailedTall | 1,000 |
  | Props | bag, barrier, rack, chimney-*, detail-tank | 1,500 |
  | Large | building-*, stadium | 4,000 |

  Credits are the natural economic limiter; unlock + purchases are a healthy **credit sink**.

### 3e. Client — reuse the decorator, swap the data layer
- Reuse the F4 decorator UX (grab/place/rotate/lift/undo) **only** in your own Locker Room when `unlocked`.
  The free dev decorator (local `data/decals` JSON) stays source-only/admin for authoring shipped zones.
- "Place" now pulls from your **Build inventory** and sends a server RPC (wait for confirm) instead of
  appending to local JSON. Move/rotate/lift/remove send lightweight update RPCs.
- **Buying happens at a new Build Shop pad in the Home Base** — a home-only vendor pad following the existing
  shop / forge / Practice-Vendor pattern (`SHOP_POS`-style const + a `build_shop` panel + `map == HOME` server
  guards). Purchased items land in your **Build tab**; you carry them into your Locker Room to place.

## 4. Phased plan

- **P0 — Foundation:** `build` item category + inventory support; `unlocked` flag on the character;
  `buy_locker_room` **10,000-credit** unlock RPC; server catalog + tiered prices; the **50-item cap** (+ optional
  per-model cap).
- **P1 — The space:** `locker_room` instance template + Home Base portal; **per-character** instance keying;
  on entry, query placed build items → send as `decals`.
- **P2 — Server authority:** `build_buy` (from the Home-Base Build Shop pad) + `build_place / move / remove`
  RPCs (rate-limited + serialized), credit + cap + bounds validation, persistence + `recv_inventory_changed`
  echoes. Remove → `placed = false` (returns to the Build tab).
- **P3 — Client:** the **Build Shop pad + panel** in Home Base; the **Build inventory tab** (filter to build
  items); port the decorator UX behind the Locker-Room + unlocked gate, wired to the RPCs.
- **P4 — Polish:** price tuning, empty-room onboarding, "placed" badges in the Build tab, per-model-cap UX,
  save-on-disconnect hardening.
- **Later:** friend visits (join another player's instance), functional/animated furniture, floor/wall themes.

## 5. Scope, risks, conventions

- **Scope:** medium. ~1 schema change (build category + placement fields + unlock flag), ~5 RPCs, the personal
  instance keying, and porting the client UX. **No combat/determinism changes → low blast radius.**
- **Deploy:** touches server + client (and `shared/World.gd` for the new zone/portal) → **server redeploy +
  client re-export** from the same commit (see `docs/`… and the deploy-ops notes: wait for CI before the
  droplet redeploy).
- **Risks to watch:**
  1. **Credit/item dupe** — every mutating RPC MUST be rate-limited + serialized; grants server-only.
  2. **Concurrent-session save-clobber** — a known deferred issue in the security audit; the Locker Room's
     per-character writes must guard against a stale session overwriting a newer one.
  3. **Instance lifecycle** — persist on disconnect, not just clean exit; tear down empty instances.
  4. **Render/storage bound** — the owned-item cap is what keeps a Locker Room cheap to send + draw.

## 6. Decisions — LOCKED (2026-07-07)
1. **Keying:** per-**character** (matches how credits/inventory are keyed). ✓
2. **Owned-item cap:** **50** per character (chosen over 150 — discourages hoarding, less data to store).
   Optional per-model cap ~20 if one prop gets spammed.
3. **Prices:** unlock = **10,000 credits**; per-item prices per the tiered starter catalog in §3d — a single
   central server constant, easy to retune. ✓
4. **Remove behavior:** the placed item **returns to the Build inventory** as that item (`placed = false`) —
   no refund, no dupe. ✓
5. **Buy point:** a new **Build Shop pad in the Home Base** (a home-only vendor pad like shop/forge). ✓
6. **Visitors:** **private-only for v1.** ✓

---

## Kickoff prompt (paste to start, after playtesting is done)

> Implement **Builder Mode + the Locker Room** per `docs/builder-mode-handoff.md` (all decisions are LOCKED in
> §6). Start with **P0**: add a `build` item category to the inventory (non-gear, carries a `model` id +
> placement transform + `placed` flag), keyed **per-character**; an `unlocked` flag on the character; a
> rate-limited + serialized `buy_locker_room` unlock RPC costing **10,000 credits**; and a server-side
> build-item catalog with the tiered prices from §3d and a hard **50-item owned cap per character** (+ optional
> ~20 per-model cap). Follow the server-authoritative + rate-limit conventions in CLAUDE.md (clients send
> intents only; the server owns credits and item grants). Do NOT change anything in `shared/` combat logic.
> After P0 compiles + passes a headless check, stop and show me the schema + RPCs before P1 (the `locker_room`
> per-character instanced zone + a Home Base portal to it, and the Home-Base **Build Shop pad** for buying).
> Adversarially review each phase (dupe/credit exploits, cap bypass, concurrent-save clobber) before done.
