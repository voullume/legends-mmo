-- Equipping: an `equipped` flag on items. The zone server enforces one equipped item per slot
-- and applies the (capped) stat bonuses to your fighter (see Server.gd _apply_equipment).
alter table public.inventory add column if not exists equipped boolean not null default false;
create index if not exists inventory_equipped_idx on public.inventory(character_id, equipped) where equipped;

-- equipping toggles inventory.equipped, which needs an UPDATE policy (the table originally had none)
create policy "inventory_update_own" on public.inventory for update
  using (exists (select 1 from public.characters c where c.id = inventory.character_id and c.user_id = auth.uid()))
  with check (exists (select 1 from public.characters c where c.id = inventory.character_id and c.user_id = auth.uid()));
