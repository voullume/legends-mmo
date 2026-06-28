-- Phase 4 (item system): progression sinks — salvage→materials + item upgrades.
-- A single generic material ("scrap"); server-authoritative like inventory/credits.

-- materials: one row per character, server-only writes (service_role bypasses RLS), client reads own.
create table if not exists public.materials (
  character_id uuid primary key references public.characters(id) on delete cascade,
  scrap int not null default 0 check (scrap >= 0),
  updated_at timestamptz not null default now()
);
alter table public.materials enable row level security;
drop policy if exists "materials_select_own" on public.materials;
create policy "materials_select_own" on public.materials for select
  using (exists (select 1 from public.characters c where c.id = materials.character_id and c.user_id = auth.uid()));
-- no client insert/update/delete policies → only the zone server (service_role) writes materials.

-- atomic conditional increment: ensures a row exists, then adds p_scrap ONLY if the result stays >= 0,
-- returning the new total (NULL when a deduct would underflow → the caller treats NULL as "insufficient").
-- Race-safe: concurrent salvage(+) and upgrade(-) on the same character compose instead of clobbering.
create or replace function public.mats_add(p_char uuid, p_scrap int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare new_total int;
begin
  insert into public.materials (character_id, scrap) values (p_char, 0)
    on conflict (character_id) do nothing;
  update public.materials
    set scrap = scrap + p_scrap, updated_at = now()
    where character_id = p_char and scrap + p_scrap >= 0
    returning scrap into new_total;
  return new_total;
end $$;
-- only the server (service_role) may call it; clients can't mint scrap via direct RPC.
revoke all on function public.mats_add(uuid, int) from public, anon, authenticated;
grant execute on function public.mats_add(uuid, int) to service_role;

-- item upgrade level: raises that item's per-item stat cap on equip (server _apply_equipment); the global
-- per-stat EQUIP_STAT_CAP still bounds the total, so upgrades never break class balance.
alter table public.inventory add column if not exists upgrade_level int not null default 0
  check (upgrade_level between 0 and 10);
