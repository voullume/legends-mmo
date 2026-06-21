-- Inventory is now server-authoritative: only the zone server (service_role, from the
-- SUPABASE_SERVICE_KEY env var) may write the table. Clients keep READ of their own items for
-- the inventory UI but can no longer forge or raise rows via direct REST — closing the self-forge
-- gap that rarity caps previously only bounded.
drop policy if exists "inventory_insert_own" on public.inventory;
drop policy if exists "inventory_update_own" on public.inventory;
drop policy if exists "inventory_delete_own" on public.inventory;
revoke insert, update, delete on public.inventory from authenticated, anon;
-- "inventory_select_own" stays so clients can read their own inventory.
