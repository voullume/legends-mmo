# Item System — Handoff for a New Session

**Mission:** turn Legends MMO's shallow item system into a **deep, real-MMORPG-grade itemization system**,
in reviewed phases. Start with the **selling overhaul** (the user's immediate pain), then build the deep
model (more slots, item levels, multi-affix gear, legendaries with effects), the progression sinks
(upgrade / reforge / sockets), and the chase/economy (sets, uniques, salvage → crafting).

> Read `CLAUDE.md` first (architecture, conventions, live-server + Supabase facts). Then this doc. All
> file:line refs verified 2026-06-27. **Build one phase at a time, reviewed (adversarial Workflow) before
> shipping** — this is live economy code where a dupe can hide.

**User decisions already locked in:**
- Bulk-sell uses **per-rarity selection toggles**; **default protects the top tier** (sells the bottom
  tiers, never the highest rarity unless explicitly opted in).
- **Item lock persists** (a DB `locked` column).
- Scope = **full MMORPG depth** (the whole roadmap below), built incrementally.

---

## 0. Orientation — where the item system lives

Items are **server-authoritative**, NOT in `GameData.gd` (that's only the combat engine — classes,
abilities, the `derive()` stat→effect formulas, `FORMAT_MODS`). The item/loot/shop/equip system lives in:

| Layer | File | Key spots |
|---|---|---|
| Item constants, catalog, loot/roll gen, sell, computed stats | `server/Server.gd` | 56–74, 472–498, 513–575, 877–995 |
| Stat → combat-effect formulas (`derive`) + balance mods (`FORMAT_MODS`) | `shared/GameData.gd` | 149–157, 179–189 |
| The deterministic damage pipeline (proc hook point) | `shared/Combat.gd` | `deal_damage` 59–136 |
| Per-tick fighter loop (DOT/ICD hook point) | `shared/Sim.gd` | ~47–52 |
| DB methods (REST/Supabase) | `client/Supabase.gd` | 126,145,153,159,172,181 |
| Inventory schema + RLS | `supabase/migrations/2026062116…/…17…/…18…`, `…22060000_credits` | — |
| Inventory + shop UI | `client/NetClient.gd` | 12, 154–230, 632–773, 677, 1366 |
| Item RPC stubs | `client/Net.gd` | 48–62, 102–120 |
| Computed-stat tooltip pattern (reuse for gear tooltips) | `client/Client.gd` | 1163–1201 |

---

## 1. Current system — precise map

**Item today (shallow):** `{name, rarity, slot, bonus_stat, bonus_amt}` + DB `id, character_id,
equipped, created_at`.
- **6 stats** `PWR PRE SPD END INS CLU` (`Server.gd:67`); effects in `GameData.derive` (`:179`): PWR→dmg,
  PRE→crit, SPD→move, END→HP, INS→cdr+crit, CLU→low-HP dmg/DR.
- **3 slots** `weapon|armor|trinket` (`Server.gd:56`). One equipped per slot.
- **4 rarities** common/uncommon/rare/epic (weights 60/28/10/2, mults 1/2/4/8) (`Server.gd:61`).
- **`RARITY_CAP` `{common:4, uncommon:10, rare:20, epic:40}` (`Server.gd:74`)** — the **anti-forge ceiling**:
  an equipped item's bonus only applies up to this, protecting the ~50% class balance. **This is the single
  most balance-critical line in the whole system — every new power source must funnel through it.**
- Prices `Server.gd:69–71`. Generation: `_roll_loot` (`:877`), `_catalog` (`:472`), `_do_shop_roll`
  (`:544`). Computed stats: `_apply_equipment` (`:945`, applies the cap at **`:966–967`**) →
  `_recompute_player_stats` (`:972`, derive + `FORMAT_MODS[5]` + level HP).
- **DB** (`client/Supabase.gd`): clients READ own inventory via RLS; **ALL WRITES via service_role**
  (`add_item_as` 145, `inv_set_equipped_as` 159 — the only field-update method today, `sell_item_as` 181
  atomic DELETE-returning-rarity, `clear_inventory_as` 172). No method to mutate `bonus_amt/stat/rarity`.
  Inventory table has **no CHECK constraints**. Credits live on `characters` (`…22060000_credits`).
- **Client UX:** Inventory (`I`) and Shop sell-list are **single BBCode `RichTextLabel`s** (no per-item
  Controls). Inventory = **direct client Supabase read**; server pushes `recv_inventory_changed` → client
  re-fetches. **Sell today = click item → click "Sell" in a modal popup. N items = N×(click+popup+click)**
  — the pain. Buy/roll fire immediately. Computed stats are shown only on the skill bar, never on gear.

---

## 2. ⚠️ THE DUPE-SAFETY CONTRACT — copy for every new mutating RPC

A review once caught a **sell-dupe money-printer** from omitting this (CLAUDE.md). Every client→server RPC
that mutates state **must**:

1. **Own a `_<name>_busy` / `_<name>_next` dict pair** keyed by `pid`. Give each *new* feature its **own
   pair** (don't share `_shop_busy` — a bulk job mustn't block single ops). **Erase both on disconnect**
   (`_on_peer_disconnected`, `Server.gd:199`).
2. **Set them BEFORE any `await`** (serialize + 300 ms rate-limit). Canonical gate (`_shop_lock`, `:505`):
   ```gdscript
   func _shop_lock(pid: int) -> bool:
       var now := Time.get_ticks_msec()
       if not _session.has(pid) or bool(_shop_busy.get(pid, false)) or now < int(_shop_next.get(pid, 0)):
           return false
       _shop_busy[pid] = true; _shop_next[pid] = now + 300; return true
   ```
   Wrapper: `if not _<name>_lock(pid): return` → `await _do_…(pid, …)` → `_<name>_busy.erase(pid)`.
3. **Re-check `_session.has(pid)` after every `await`** before touching session / sending RPCs.
4. **Deduct/mutate durable state BEFORE the write, roll back on failure** (mirror `_give_and_charge`
   `:489–495`: credits off before the DB write, refunded if it fails).
5. **DB is the second layer:** use **atomic conditional writes** — DELETE/PATCH whose filter includes the
   precondition, with `Prefer: return=representation`, so only the call that actually changed the row
   "wins" (the `sell_item_as` `id=eq.&select=rarity` pattern; for PATCH, gate on the expected old value,
   e.g. `upgrade_level=eq.<old>`). This closes the read-modify-write race.

**Batch ops (sell-many, salvage-many):** ONE locked server-side loop of atomic per-row deletes, batch
**≤ 50** ids, equipped+locked excluded server-side, then ONE credit/material add + ONE `_save_one` + ONE
`recv_inventory_changed`. Dupe-safe by construction.

---

## 3. The target item model (the blueprint all phases build toward)

Final DB shape of an `inventory` row (reached additively across phases — `add column if not exists`,
safe defaults, legacy rows keep working). **Keep items as a single row (affixes/gems as `jsonb`) — do NOT
normalize to child tables, or `sell_item_as`'s single-DELETE race-safety breaks.**

| Column | Type / default | Phase | Notes |
|---|---|---|---|
| `id, character_id, name, created_at, equipped` | existing | — | unchanged |
| `slot` | text, CHECK new 10-slot set | P2 | widen + `LEGACY_SLOT_MAP` |
| `rarity` | text, CHECK 6 tiers | P2 | add `legendary`, `mythic` |
| `primary_stat / primary_amt` | text / int | P2 | rename of `bonus_stat/bonus_amt`; migrate-copy, keep old as fallback one release |
| `ilvl` | int default 1, CHECK 1–80 | P2 | drives base power + affix budget |
| `affixes` | jsonb `'[]'`, CHECK len ≤ 4 | P2 | `[{stat,amt}]`, count by rarity |
| `item_power` | int default 0 | P2 | denormalized score; server recomputes on every write |
| `locked` | bool default false | P1 | persistent "do not sell/salvage" |
| `upgrade_level` | int default 0, CHECK 0–10 | P4 | raises this item's effective cap |
| `sockets / gems` | int 0–3 / jsonb `'[]'` | P4 | gems `[{stat,amt}]`, len ≤ sockets |
| `reforge_count` | int default 0 | P4 | escalating reforge cost |
| `set_id / unique_id / proc_id / proc_tier` | text / text / text / int 0–5 | P5/P6 | set membership, legendary identity, fixed-catalog effect |

**10 slots (P2):** `head, chest, legs, hands, feet, main_hand, off_hand, neck, ring, trinket`. Map legacy
`weapon→main_hand, armor→chest, trinket→trinket`. `LOOT_SLOTS`/`SHOP_SLOT_STAT` (`Server.gd:56,72`) extend.

**New rarities (P2):** `legendary` (mult 14, cap 60), `mythic` (mult 20, cap 80); weights e.g.
60/27/9/3/0.9/0.1. Keep mythic near-zero so its ceiling is aspirational.

**Budget model (P2)** — replaces the three divergent `mult*6` / `mult*(qty+lvl)` formulas with **one
builder `_make_item(slot, rarity, ilvl)`** that `_roll_loot`/`_catalog`/`_do_shop_roll` all call:
- `primary_amt = round(rarity_mult * (3 + ilvl*0.4))`
- `AFFIX_COUNT_BY_RARITY = {common:0, uncommon:1, rare:2, epic:3, legendary:4, mythic:4}`
- affix budget `= round(rarity_mult * (1 + ilvl*0.18))`, split across N affixes (min 1 each)
- `item_power = primary_amt + Σ affix amts + ilvl`
- drop ilvl `= clamp(mob_level + tier_bonus, 1, 80)` (elite +5, boss +12).

**`_apply_equipment` rewrite (P2, the load-bearing balance change):** iterate the 10 slots; for each
equipped item, sum **the primary AND each affix, each independently `min(amt, RARITY_CAP[rarity])`** (so a
stacked mythic still can't exceed the per-tier ceiling *per stat*). Add set bonuses here too (land set
logic in this SAME rewrite to avoid doing it twice), capped by a separate `SET_BONUS_CAP`. This single cap
site at **`Server.gd:966–967`** is where Foundation + Upgrade + Sets all converge — land P2 first.

---

## 4. The phased roadmap

Build top-to-bottom; each phase is independently shippable + reviewed. Effort S/M/L.

### Phase 1 — Selling & inventory QoL (M) — DO FIRST, mostly client + 2 small RPCs + 1 migration
The immediate pain; needs only the `locked` column, not the deep model.
- **Migration:** `inventory add column locked boolean not null default false`.
- **Server:** `inv_set_locked_as(token,item_id,val)` (Supabase, mirror `inv_set_equipped_as:159`).
  RPC `inv_set_locked(item_id,locked)` under its own `_lock_busy/_lock_next`. RPC
  `shop_sell_many(item_ids:Array)` under its own `_sellmany_busy/_sellmany_next` → `_do_shop_sell_many`:
  HOME-gate, ≤50/dedup/`_is_uuid`, serialized loop of atomic `sell_item_as`-style deletes (extend it to
  `select=rarity,equipped,locked` and **skip equipped/locked server-side**), sum `SELL_PRICE`, then ONE
  credit add + `_apply_equipment` + `_save_one` + `recv_inventory_changed`. Keep single `shop_sell` for
  back-compat (or route it through a 1-element call).
- **Client (`NetClient.gd:697–773`):** clicking a sell row **toggles a `_sell_selection` set** (✓/○ via
  `[url=seltoggle|<id>]`), not an immediate sell; locked rows show 🔒 + a `[url=lock|<id>]` toggle;
  equipped rows (★) are non-selectable. **Per-rarity checkboxes** (Common/Uncommon/Rare/Epic) select all
  *unlocked, unequipped* items of that rarity; the **highest owned tier is unchecked + flagged
  "protected — opt in"**. Footer **"Sell Selected (N) — ◈total"** → ONE confirm (generalize
  `_show_sell_confirm:739`) → ONE `shop_sell_many`. Add a cheap **sort/filter header** (rarity/slot/power;
  filter slot/rarity/equipped/locked) above the existing label.
- *No deps. Ship it, then move to the deep model.*

### Phase 2 — Item Foundation (M/L) — the deep model everything else needs (server/`shared/` change)
The full target model in §3: slots, ilvl, multi-affix, item_power, legendary/mythic, the `_make_item`
builder, the `_apply_equipment` rewrite (+ fold set bonuses in), widened DB select-lists
(`get_inventory_as` `:154` must add `ilvl,primary_stat,primary_amt,affixes,item_power,locked,set_id,…`).
Legacy-compatible. **Re-run the balance harness** (round-robin AI duels, CLAUDE.md) — more slots = more
stat surface; if any class passes ~53%, lower caps/affix budgets, never `FORMAT_MODS`.

### Phase 3 — Legibility (S/M) — make the new depth visible
- **Character sheet** (new panel, e.g. `K`): the snapshot self-fighter (`_snapshot_for`/`pinfo` ~`:1366`)
  pushes only `dmgMult/crit/critMult` today — **add `ms,cdr,clutchDmg,clutchDR,maxHP` + the raw 6-stat
  `equip_bonus` + `item_power`** so the sheet shows base+gear + Item Power. **Display the already-capped
  applied values + post-`FORMAT_MODS` finals (straight from the fighter dict), never raw `bonus_amt`** —
  the UI must never imply more power than combat grants.
- **Comparison tooltips:** per-row hover (RichTextLabel `meta_hover_started/ended`) → item stat block +
  **Δ vs the equipped item in that slot** (`+12 PWR ▲ +4`), green/red. Reuse `Client.gd:1163–1201`.

### Phase 4 — Progression sinks (L) — the chase + credit/material sinks
- **4a Salvage → materials (M):** new `materials` table (`character_id, dust/ember/sigil…, CHECK ≥0`, RLS
  select-own + service-write, mirror `…180000`). `mats_add_as` (atomic increment via a Postgres `rpc/`
  function) + `get_mats_as`; materials ride the snapshot like credits (`_my_credits():677`). RPC
  `salvage_many(ids)` (own `_salvage_busy/_salvage_next`) = the bulk-sell worker but pays materials, not
  credits — the **primary material faucet** + the keep-vs-sell choice.
- **4b Upgrade/Enhance (M):** `upgrade_level` column. **Cap model (recommended): upgrade RAISES the cap,
  not the raw amount** — `eff_cap = min(RARITY_CAP[rarity] + upgrade_level*UPGRADE_STEP[rarity], ABS_CAP=100)`,
  applied at the `_apply_equipment` cap site. `inv_upgrade_as` (atomic PATCH gated on
  `upgrade_level=eq.<old>`). RPC `forge_upgrade(item_id)` (own `_forge_busy/_forge_next`): cost
  credits + `ember`, deduct-before-write/refund-on-fail. v1 = pure sink (always succeeds); add a
  fail/risk option later.
- **4c Reforge (S/M):** reroll an affix for credits + `sigil`, escalating by `reforge_count`.
  `inv_reforge_as` (gated on `reforge_count=eq.<old>`). RPC `forge_reforge` (`_reforge_busy/_reforge_next`).
- **4d Sockets + Gems (L):** `sockets`/`gems` columns; gems share the **same capped pool** per stat (can't
  smuggle past the ceiling). RPCs `forge_socket`, `forge_gem_set/clear`.
- **UI:** a **Forge panel** at the home base, proximity-gated exactly like the shop pad (`NetClient.gd:632`),
  + a materials bar.

### Phase 5 — Sets & Crafting (M/L) — chase + economy
- **Set bonuses:** `set_id` column; `SET_DEFS` catalog in **`GameData.gd`** (one set per sport, themed to
  the existing base names), thresholds (2-pc/3-pc → escalating stat bonuses, capped by `SET_BONUS_CAP`).
  Application folds into the P2 `_apply_equipment` rewrite. Tooltip shows "(2/3) +PWR3 → next at 3".
- **Crafting:** recipes as a **static `GameData.RECIPES` catalog** (no recipes table — keep content out of
  migrations). RPC `craft(recipe_id)` (own `_craft_busy/_craft_next`, shared with salvage so they're
  mutually exclusive per player): validate recipe, check materials, deduct-before-`add_item_as`/refund.
  Craft panel + a Salvage tab reusing the P1 multi-select/lock UI.

### Phase 6 — Uniques & Procs (L) — the deepest; `shared/` engine change, highest review bar
- `unique_id/proc_id/proc_tier` columns; `UNIQUE_DEFS` + `PROC_CATALOG` in `GameData.gd`. Unique drops via
  a low post-rarity roll on boss tier (`_loot_rng`, deterministic).
- **See §5 — the deterministic-proc constraint is mandatory.** This touches `shared/Combat.gd` →
  server redeploy + client re-export, and the hardest adversarial review (combat determinism + balance).

### Phase 7 — Grid / paperdoll inventory (M/L) — do LAST (after the item shape is final)
Swap the single BBCode label for a `GridContainer` of per-item Buttons (icon + rarity border) so
hover/lock/compare/right-click-context are real Controls, and a paperdoll equip view. Deferred so the
per-item control is built once against the final affix/upgrade/set shape, not rebuilt.

---

## 5. Deterministic procs — the hard constraint (Phase 6)

The combat sim is **deterministic** (mulberry32 `state["rng"]`) and that is load-bearing for balance
testing + server authority. **Procs must be a FIXED ENUM of pure-data effect types — never arbitrary
scripts/callbacks/eval.**

- **Effect types (fixed ~6):** `DOT`, `FLAT_ON_HIT`, `SHIELD_ON_LOWHP`, `LIFESTEAL`, `MOVESPEED_ON_KILL`,
  `CDR_ON_HIT`. **Triggers:** `on_hit, on_crit, on_kill, on_lowhp`. Each has an **internal cooldown (`icd`)**
  on the fighter dict (`f["_procT"][proc_id]`, decremented in `sim_tick`).
- **Single hook point:** resolve procs inside `Combat.deal_damage` (`shared/Combat.gd:59`, the one damage
  choke point — crit already draws `state["rng"].next()` at line 104) after `tgt["hp"] -= dmg`; DOT ticks +
  ICD decay in the `sim_tick` per-fighter loop. Any proc RNG draw uses **the same `state["rng"]` stream** →
  stays deterministic.
- **Balance:** DOT/flat dmg routes back through `deal_damage` so it inherits `dmgMult` × `FORMAT_MODS`
  (never bypasses class balance). Clamp total proc contribution (`PROC_DPS_CAP`). `_recompute_player_stats`
  (`Server.gd:972`) stuffs `f["procs"]` from equipped items' + active set procs. Re-run the round-robin
  harness with proc loadouts; keep the win-rate spread ≤ ~10 pts.

---

## 6. Balance guardrails (don't break the ~50% class balance)

- **`RARITY_CAP` at `Server.gd:966–967` is the one chokepoint** — primary, every affix, gems, and upgrades
  all funnel through `min(amt, eff_cap)`. Hard `ABS_CAP = 100`.
- **Set bonuses** use a separate `SET_BONUS_CAP` (they're not per-item, so the per-item cap doesn't catch
  them).
- **Procs** clamp to `PROC_DPS_CAP` and inherit `FORMAT_MODS` via `deal_damage`.
- **Uniques** stay epic/`RARITY_CAP`-bound on their stat line — lean on the *proc* for identity, not a
  bigger number (recommended; safer).
- After any of P2/P4/P5/P6, **re-run the deterministic AI-duel round-robin** (CLAUDE.md balance harness:
  `GameData.create_fighter(cls,team,0,rng,5)`, loop `Sim.sim_tick` to a winner). Tune caps/budgets/weights,
  **never `FORMAT_MODS`**, to hold ≤ ~10-pt spread.

---

## 7. Conventions you MUST follow

- **Server-authoritative.** Clients send intents; server validates everything. Every new mutating RPC →
  the §2 contract, no exceptions. Equipped/locked checks happen **server-side**, not just in the client.
- **GDScript TABS.** Match indentation exactly (`sed -n … | cat -A` before an Edit). `:=` can't infer from
  a Variant — annotate `var x: T = …`.
- **Migrations additive + server-trusted.** `add column if not exists`, safe defaults, add CHECK
  constraints where cheap. Apply to the live DB via the Supabase MCP (`apply_migration`) AND commit the
  SQL. Inventory/materials writes stay **service_role**.
- **Content catalogs go in `GameData.gd`** (SET_DEFS/UNIQUE_DEFS/PROC_CATALOG/RECIPES), not migrations —
  edit content without a DB change, and `shared/` is readable by the deterministic sim.
- **Deploy:** server/`shared/` changes (P2, P4–P6) need **redeploy + client re-export**; pure-client phases
  (parts of P1/P3/P7) need only a **re-export**. Redeploy = the off-box pull pipeline
  (`[[legends-mmo-deploy-ops]]`): push → CI builds the image → run `deploy/setup.sh` on the droplet (fast
  pull). Re-export: `godot --headless --path . --export-release "Windows Desktop" dist/…exe` +
  `"Linux" dist/…x86_64` → `gh release upload v0.1.0-test … --clobber`.
- **Verify each phase:** compile-check (throwaway `SceneTree` that `load()`s every script; grep
  `SCRIPT ERROR`) → a headless test (extend `SceneTree`, run from a child `Node`'s `_ready` since
  `HTTPRequest` must be in-tree; test bot `legends_smoke1@testmail.dev` / `Testpass1234!`; the
  `AudioManager` autoload won't resolve in an isolated `--script` run — verify via a real headless client
  boot, not by preloading `Client.gd`) → an **adversarial review (Workflow)** focused on the dupe surface.
- **Off-limits:** never touch `voullume@proton.me`; service_role key stays in env. Admin =
  `admin@legends.dev`. Live droplet `159.89.132.86` (UDP 7777, DTLS). Meshy/character work is a known
  dead-end (`[[legends-mmo-character-anim-deadend]]`) — irrelevant to items.

---

## 8. Open decisions (compiled — confirm before the dependent phase)

**Phase 1 (selling):** per-rarity = four checkboxes (assumed) vs a "≤ rarity" slider? Exclude locked items
from the per-rarity total entirely (recommended)? Character-sheet/inventory: one unified screen or
separate panels?

**Phase 2 (foundation):** one ring slot or two (`ring`/`ring2` doubles ring stat surface → cap retune)?
`off_hand` for all classes or empty-able for ranged? ilvl cap 80 tied to a future level cap or decoupled?
Keep `bonus_*` as permanent aliases or commit to a `primary_*` cutover after one release?

**Phase 4 (progression):** confirm **cap model (A) raise-the-cap** (recommended) over (B) raw amount.
Upgrade = pure sink (always succeeds) vs risk/fail? Max upgrade level (10) + `ABS_CAP` (100). Gems as a
`materials` kind (simpler) or as inventory items (richer)? Salvage-only mats, or also a credit→mat
exchange?

**Phase 5/6 (sets/uniques/procs):** material kinds — 3 (dust/ember/sigil) or 1? Sets = one-per-sport (4)
or themed? Uniques boss-drop-only, craftable, or both? Ship 3 procs first or all 6? Mythic = ultra-rare
drop or crafted-only?

---

## 9. Start here (first-session steps)
1. Read `CLAUDE.md` + this doc. Skim `Server.gd:56–74, 472–575, 877–995`, `Supabase.gd:126–188`,
   `NetClient.gd:632–773`, `Combat.gd:59–136`.
2. Confirm the **Phase 1** open decisions with the user (they're small). Everything else can defer to its
   phase.
3. Build **Phase 1** (selling overhaul): `locked` migration → `inv_set_locked` + `shop_sell_many` RPCs
   (own lock pairs, §2) → client multi-select/lock/per-rarity/sort UI. Compile-check → headless test (sell
   a batch of 10: assert credits = Σ prices, no double-pay, equipped+locked skipped) → adversarial review
   of the bulk-sell dupe surface → ship (re-export; the RPCs are server-side → also redeploy).
4. Then **Phase 2 (foundation)** — the deep model — and proceed down the roadmap, one reviewed phase at a
   time, re-running the balance harness after each power-affecting phase.
