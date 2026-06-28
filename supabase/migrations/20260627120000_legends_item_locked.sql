-- Phase 1 (item system): a persistent per-item "locked" flag. A locked item is protected from
-- selling/salvage — the server REFUSES to sell or bulk-sell it on every path (see Server.gd
-- _do_shop_sell_many / Supabase.gd sell_item_safe_as, which gate the atomic DELETE on locked=false).
-- Inventory writes are already server-only (20260621180000…); the surviving "inventory_select_own"
-- policy lets clients READ this column via select=* for the sell UI. Boolean default → legacy rows
-- are unlocked, so nothing changes for existing items.
alter table public.inventory add column if not exists locked boolean not null default false;
