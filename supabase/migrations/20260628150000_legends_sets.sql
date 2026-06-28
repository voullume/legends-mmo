-- Phase 5 (item system): item sets. Every item belongs to one of the 4 sport sets; wearing N matching
-- pieces grants a set bonus (server _apply_equipment). Only EPIC+ pieces count toward the bonus right now,
-- so the (above-cap) set power stays gated to high-tier gear.
alter table public.inventory add column if not exists set_id text;
-- backfill existing rows deterministically (by id hash) so sets work on current gear too
update public.inventory
  set set_id = (array['baseball','football','volleyball','soccer'])[1 + (abs(hashtext(id::text)::bigint) % 4)]
  where set_id is null;
alter table public.inventory drop constraint if exists inventory_set_check;
alter table public.inventory add constraint inventory_set_check
  check (set_id is null or set_id in ('baseball','football','volleyball','soccer'));
