# Item System — Handoff for a New Session

**Mission:** Improve **itemization depth** and the **functionality of the item/inventory/shop system** in
Legends MMO. The user's #1 immediate pain: **selling is one item at a time with a confirm popup each
time — extremely slow.** The per-item confirm exists to prevent *accidental* sales, so the fix must be
**fast AND still protect good gear.** Start with the selling overhaul, then add depth.

> Read `CLAUDE.md` first (architecture, conventions, the live-server + Supabase facts). Then this doc.
> Everything below is verified against the codebase as of 2026-06-27.

---

## 0. Orientation — where the item system actually lives

**Structural correction (important):** items are **not** in `shared/GameData.gd`. `GameData.gd` is only the
combat engine (classes, abilities, `derive()` stat→effect formulas). The whole item/loot/shop/equip
system is **server-authoritative and lives in `server/Server.gd`**, with the DB layer in
`client/Supabase.gd` and the UI in `client/NetClient.gd`.

| Layer | File | Key spots |
|---|---|---|
| Item constants, catalog, loot/roll gen, sell value, computed stats | `server/Server.gd` | 56–74, 472–498, 513–575, 877–995 |
| Stat → combat-effect formulas (`derive`) | `shared/GameData.gd` | 179–189 |
| DB methods (REST/Supabase) | `client/Supabase.gd` | 126,145,153,159,172,181 |
| Inventory schema + RLS | `supabase/migrations/2026062116…/…17…/…18…`, `…22060000_credits` | — |
| Inventory + shop UI, sell-confirm | `client/NetClient.gd` | 12, 154–230, 632–773 |
| Item RPC stubs | `client/Net.gd` | 48–62, 102–120 |
| Loot FX (chat-log popup) | `client/NetClient.gd` (`recv_loot`) | 881–893 |

---

## 1. Current system — precise map

### Item shape (5 content fields + DB metadata)
```
{ "name": String, "rarity": String, "slot": String, "bonus_stat": String, "bonus_amt": int }
```
DB row adds `id` (uuid), `character_id` (uuid FK), `equipped` (bool), `created_at`.

- **Stats (6):** `PWR PRE SPD END INS CLU` — `Server.gd:67` `LOOT_STATS`. Effects in `GameData.derive`
  (`GameData.gd:179`): PWR→dmgMult, PRE→crit, SPD→move speed, END→maxHP, INS→cooldown reduction + crit,
  CLU→low-HP dmg/DR. No long names anywhere; only the 3-letter codes.
- **Slots (3):** `weapon | armor | trinket` — `Server.gd:56` `LOOT_SLOTS` (each maps to base-name lists).
  One equipped item per slot is enforced server-side.
- **Rarities (4):** `common/uncommon/rare/epic` — `Server.gd:61` `RARITIES` (weights 60/28/10/2, mults
  1/2/4/8). Colors are client-side: `NetClient.gd:12` `RARITY_COLORS`.
- **Equip cap (anti-forge):** `Server.gd:74` `RARITY_CAP = {common:4, uncommon:10, rare:20, epic:40}` —
  a bonus only applies up to this when equipped, regardless of stored `bonus_amt`.
- **Prices:** `Server.gd:69–71` `BUY {40,110,280,650}`, `ROLL {50,130,320,720}`, `SELL {14,38,95,230}`.

### How items are created
- **Mob loot:** `_roll_loot(mob)` `Server.gd:877` — drop chance 1.0 elite/boss, 0.65 minion;
  `_roll_rarity(tier)` (`:892`) elite +2 tiers, boss → epic; `bonus_amt = mult*(qty+lvl)` (scales w/ mob).
  Granted by `_grant_loot(pid,mob)` (`:862`) on kill from `_award_kills()` (`:792`).
- **Shop buy:** `_catalog()` (`:472`) = 12 fixed items (3 slots × 4 rarities), fixed stat per slot
  (`SHOP_SLOT_STAT` `:72`), `bonus_amt = mult*6`. Bought via `_do_shop_buy` (`:531`).
- **Shop roll (gamble):** `_do_shop_roll` (`:544`) — random slot/base/stat within the paid rarity,
  `bonus_amt = mult*6`.
- All generation uses the deterministic server RNG `_loot_rng` (`:78`).

### Computed stats (base + gear → final)
`_apply_equipment(pid)` (`Server.gd:945`): reads inventory, sums **equipped** bonuses (one per slot),
**caps each by `RARITY_CAP`** (`:966`), caches `_session[pid]["equip_bonus"]`, then
`_recompute_player_stats` (`:972`): base class stats + bonuses → `GameData.derive` → `FORMAT_MODS[5]` →
+level HP, preserving HP fraction. Re-run on join, equip, sell, respawn.

### DB layer (`client/Supabase.gd`) — RLS: clients READ own; **all WRITES via service_role**
| Method | Line | Key | Does |
|---|---|---|---|
| `get_inventory()` | 126 | player token | client reads its own bag (`select=*`, RLS-scoped) |
| `get_inventory_as(token)` | 153 | player token | server reads a player's bag (ownership check) |
| `add_item_as(token, char_id, item)` | 145 | **service** | INSERT (loot/buy/roll). `ok` only on HTTP 201 |
| `inv_set_equipped_as(token, filter, val)` | 159 | **service** | PATCH `equipped` (the only field update method) |
| `sell_item_as(char_id, item_id)` | 181 | **service** | **atomic** DELETE …`select=rarity`, `return=representation` — only the call that removed the row gets the rarity (race-safe) |
| `clear_inventory_as(char_id)` | 172 | **service** | admin "clear items" |

There is **no** generic `update_item` (can't change `bonus_amt`/`bonus_stat`/`rarity` after creation) and
**no `remove_item`** other than sell/clear. The inventory table has **no CHECK constraints** on
rarity/slot/bonus_stat — the server is fully trusted on those.

### Client UX (`client/NetClient.gd`)
- **Inventory (`I`):** `_build_inventory` (154), `_load_inventory` (187) → `supa.get_inventory()` direct
  REST. Rendered as **one BBCode `RichTextLabel`** (no per-item Controls). Click an item url
  (`_on_item_clicked`, 220) → `net.equip.rpc_id(1, id, slot)` toggle. **No tooltips / no computed
  stats shown on gear.** (Computed-stat tooltips exist only on the skill bar: `Client.gd:1177`.)
- **Shop (`B`, proximity-gated):** `_build_shop` (632), two BBCode labels (buy / sell). Buy & roll fire
  **immediately, no confirm** (`_on_shop_meta`, 724). **Sell** → `_show_sell_confirm(item_id)` (739) =
  a modal Panel with Sell/Cancel. **So selling one item = click item → click "Sell" in popup. N items =
  N×(click + popup + click).** No multi-select, no "sell all", no item lock.
- Inventory source of truth = **direct client Supabase read**; server pushes
  `recv_inventory_changed()` (a "go re-fetch" ping) after any mutation; client re-fetches
  (`recv_inventory_changed`, 225). Credits ride in the snapshot (`_my_credits()`, 677).

### RPCs (`client/Net.gd`)
`recv_loot` (48, S→C), `equip` (54, C→S), `recv_inventory_changed` (59, S→C), `shop_buy` (102),
`shop_roll` (107), `shop_sell` (112, all C→S), `recv_shop_info` (117, S→C).

---

## 2. ⚠️ THE DUPE-SAFETY CONTRACT — copy this for every new mutating RPC

A review once caught a **sell-dupe money-printer** from omitting this (CLAUDE.md). Every client→server
RPC that mutates state **must**:

1. **Own a busy-flag + next-timestamp pair**, keyed by `pid` (e.g. `_shop_busy`/`_shop_next`,
   `_equipping`/`_equip_next`). Erase **both** on disconnect (`_on_peer_disconnected`, `Server.gd:199`).
2. **Set those flags BEFORE any `await`** (serialize + rate-limit at the gate). The canonical gate
   (`_shop_lock`, `Server.gd:505`):
   ```gdscript
   func _shop_lock(pid: int) -> bool:
       var now := Time.get_ticks_msec()
       if not _session.has(pid) or bool(_shop_busy.get(pid, false)) or now < int(_shop_next.get(pid, 0)):
           return false
       _shop_busy[pid] = true
       _shop_next[pid] = now + 300
       return true
   ```
   Wrapper: `if not _shop_lock(pid): return` → `await _do_…(pid, …)` → `_shop_busy.erase(pid)`.
3. **Re-check `_session.has(pid)` after every `await`** before touching session/sending RPCs.
4. **Set the durable/guard state before the await, roll back on write failure** (e.g. `_give_and_charge`
   deducts credits *before* the DB write and refunds if it fails; quest turn-in sets `completed=true`
   before persisting and rolls back on failure).
5. **Lean on the DB as the second layer:** the atomic DELETE-returning-representation in `sell_item_as`
   means only the call that actually removed a row gets paid — a concurrent dup gets `{ok:false}`.

**The sell "confirmation" is purely a client dialog (`NetClient.gd:739`) — there is NO server pending-sell
state.** So a bulk-sell is safe as long as it runs through ONE locked server-side loop of atomic deletes.

---

## 3. The plan

### Phase 1 — Selling overhaul (DO FIRST; client-heavy + 1 small server RPC)
Goal: clear a bag of junk in seconds, with no accidental loss of good/equipped gear.

**Design (recommended):**
1. **Multi-select + ONE confirm.** In the shop SELL list, clicking an item **toggles selection** (a ✓
   prefix via BBCode `[url=seltoggle|<id>]`), not an immediate sell. A footer button **"Sell Selected
   (N) — ◈<total>"** opens **one** confirm ("Sell N items for ◈<total>?") → fires **one** bulk RPC.
   N items become: select-several + 1 confirm + 1 click.
2. **Quick "sell all junk" buttons.** "Sell all Common", "Sell all ≤ Uncommon" — select all unlocked,
   unequipped items at/below that rarity, then the same single confirm. Fastest path for trash.
3. **Lock / protect.** Equipped items are **never** bulk-sellable (exclude them). Add a per-item **lock
   toggle** (`[url=lock|<id>] 🔒`) so a player can protect keepers; locked items can't be selected/sold.
   Lock state can live in memory client-side for v1 (no schema change), or persist later.
4. **Server RPC (the only server change):** add `shop_sell_many(item_ids: Array)` →
   `server.shop_sell_many(pid, ids)`. Implement under the **existing `_shop_lock`** as ONE loop:
   for each id → `_is_uuid` check → `await supa.sell_item_as(char_id, id)` → on `ok`, sum
   `SELL_PRICE[rarity]`. After the loop: one `_apply_equipment` (in case an equipped item slipped
   through — but you should also block equipped server-side), one `s["credits"] += total`, one
   `_save_one`, one `net.recv_inventory_changed`. **Cap the batch size** (e.g. ≤ 50 ids) to bound the
   loop. This is dupe-safe by construction (serialized lock + atomic deletes). Keep the single
   `shop_sell` too (back-compat / single-item path) or route it through the same worker.

**Why this satisfies the brief:** still a confirm (no accidental mass-sell), but **one** confirm for many
items, plus locks + equipped-exclusion so good gear is safe.

**Files to touch:** `NetClient.gd` (`_load_shop_sell` 697, `_on_shop_meta` 724, `_show_sell_confirm` 739
→ generalize to a "sell these N" confirm; add selection set + lock set + footer buttons); `Net.gd`
(add `shop_sell_many` stub mirroring `shop_sell` 112); `Server.gd` (add `_<name>_…` already covered by
`_shop_lock`; add `shop_sell_many` + `_do_shop_sell_many`, and **reject equipped items server-side**).

### Phase 2 — Make gear legible (small, high-value; do before deeper itemization)
- **Hover tooltips on inventory/shop items** showing the item's stat in context + **compare vs the
  currently-equipped item in that slot** (Δ). Reuse the skill-bar tooltip pattern (`Client.gd:1177`).
  Note inventory is currently one BBCode label with no per-row hover — you'll likely move to a small
  per-item control or use a tooltip surface keyed by hovered url.
- **Character sheet:** show the 6 computed stats (the server already computes them; surface them — push
  the derived stats to the client or compute client-side from gear). Without this, depth is invisible.

### Phase 3 — Gear upgrade / enhancement (credit sink + progression; the big depth win)
Spend credits to raise an item's `bonus_amt` (e.g. +1 per upgrade, escalating cost), up to a new cap
(or raise `RARITY_CAP` per item via an `upgrade_level` column). This is the first real **credit sink**
(today credits only buy/roll/are hoarded) and a progression goal.
- **Needs a DB write path that doesn't exist yet:** add `inv_set_amt_as(token, item_id, amt)` (PATCH
  `bonus_amt`) in `Supabase.gd`, or an `upgrade_level int default 0` column (migration, additive) +
  fold it into `_apply_equipment`'s cap.
- New RPC `shop_upgrade(item_id)` under a lock; validate cost, deduct (with refund-on-fail), PATCH,
  `_apply_equipment`, `_save_one`, `recv_inventory_changed`.

### Phase 4 — Build depth (pick one; bigger)
- **Multi-affix items** (2–3 stats): migration adds `bonus_stat2/bonus_amt2` (or a `jsonb affixes`);
  update generation (`_roll_loot`/`_catalog`/`_do_shop_roll`), `_apply_equipment`, and the UI.
- **Set bonuses** (e.g. "3 same-sport items → +X"): add a `set`/`sport` field + bonus logic in
  `_apply_equipment`.

### Phase 5 — Economy depth (optional)
- **Reroll** an item's stat for credits (another sink, pairs with the gamble).
- **Salvage → crafting currency** (an alternative to selling; feeds upgrades/rerolls).

**Recommended order:** 1 (selling) → 2 (legibility) → 3 (upgrade) → 4 (affixes/sets) → 5 (economy).
Confirm priorities with the user before Phase 4+ (those are larger).

---

## 4. Conventions you MUST follow

- **Server-authoritative.** Clients send intents; the server validates everything. New mutating RPCs →
  the dupe-safety contract in §2, no exceptions.
- **GDScript uses TABS.** Match indentation exactly (`sed -n … | cat -A` to verify before an Edit).
- **`:=` can't infer from a Variant** (dict access / `await` result) — annotate `var x: T = …`.
- **DB migrations are additive + server-trusted.** New columns: `add column if not exists`, default a
  safe value. Apply to the live DB via the Supabase MCP (`apply_migration`) AND commit the SQL file.
  Inventory writes are service-role only — keep new write methods on `service_key`.
- **Deploy:** item/server/`shared/` changes need **server redeploy + client re-export**; pure client UI
  changes need only a **client re-export**. Redeploy = the off-box pull pipeline (see
  `[[legends-mmo-deploy-ops]]`): push → CI builds the image → run the `deploy/setup.sh` one-liner on the
  droplet (fast pull, ~17s, no on-box build). Re-export: `godot --headless --path . --export-release
  "Windows Desktop" dist/…exe` + `"Linux" dist/…x86_64`, then `gh release upload v0.1.0-test … --clobber`.
- **Verify each phase:** compile-check (a throwaway `SceneTree` script that `load()`s every script; grep
  `SCRIPT ERROR`), a headless connect/boot test, then an **adversarial review** (Workflow: dimension
  reviewers → per-finding refutation) before calling it done — economy code is exactly where a dupe can
  hide. Headless test harness pattern: extend `SceneTree`, run work from a child `Node`'s `_ready`
  (an `HTTPRequest` needs to be in the tree), use a test bot token (`legends_smoke1@testmail.dev` /
  `Testpass1234!`). The `AudioManager` autoload won't resolve in an isolated `--script` run — verify
  client logic via a real headless client boot, not by preloading `Client.gd`.
- **Off-limits:** never touch `voullume@proton.me`; service_role key stays in env (`SUPABASE_SERVICE_KEY`,
  never committed). Admin = `admin@legends.dev`. Live server: droplet `159.89.132.86` (UDP 7777, DTLS).
- **Balance note:** equipped bonuses feed combat power. The `RARITY_CAP` (`Server.gd:74`) is the
  anti-forge ceiling — upgrades (Phase 3) and multi-affix (Phase 4) must respect/extend it
  deliberately, or they'll break the ~50% class balance (`FORMAT_MODS[5]`).

---

## 5. Start here (first session steps)
1. Read `CLAUDE.md` + this doc. Skim `Server.gd:56–74, 472–575, 877–995`, `NetClient.gd:632–773`,
   `Supabase.gd:126–188`.
2. Confirm the **Phase 1 selling design** with the user (multi-select + 1 confirm + lock + "sell junk").
   Ask: should lock persist (a `locked` column) or be session-only for v1? Cap on batch size?
3. Build Phase 1: client selection/lock UI + the `shop_sell_many` RPC under `_shop_lock` (block equipped
   server-side). Compile-check → headless sell test (sell 10 items in one batch; assert credits = sum,
   no double-pay, equipped excluded) → adversarial review focused on the bulk-sell dupe surface.
4. Ship (client-only if no schema change → re-export; the RPC is server-side → also redeploy).
5. Then propose Phase 2 (legibility) and proceed down the roadmap, one reviewed phase at a time.

## 6. Open decisions for the user
- Lock persistence (DB column vs session-only) for v1.
- Whether "sell all ≤ rarity" should default to excluding rare/epic always.
- How far to take depth (Phase 4/5 are real scope — confirm appetite before building).
- Whether to add a salvage currency now or keep it pure-credits.
