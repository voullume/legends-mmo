-- Phase 4b (item system): reforge — reroll an item's affixes for credits + scrap. reforge_count tracks
-- how many times an item has been reforged so the cost escalates; it also gates the atomic PATCH so a
-- duplicate/concurrent reforge can't double-charge or double-apply.
alter table public.inventory add column if not exists reforge_count int not null default 0
  check (reforge_count >= 0);
