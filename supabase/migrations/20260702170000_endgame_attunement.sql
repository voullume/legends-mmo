-- Endgame P2: attunement. Playbook Pages (already a progression column) are earned from Camp Circuit clears +
-- the Head Coach boss; spend them to forge the Master Key, which (together with completing every quest) opens
-- the secret boss. Server-authoritative: service_role writes only; the client reads its own row via RLS.

alter table public.progression add column if not exists has_master_key boolean not null default false;

-- Atomic page add/spend (mirrors mats_add): ensure the row, then add p_delta only if the result stays >= 0,
-- returning the new total (NULL when a spend would underflow → caller treats NULL as "insufficient").
create or replace function public.progression_add_pages(p_char uuid, p_delta int)
returns int
language plpgsql security definer set search_path = public
as $$
declare new_total int;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression
    set playbook_pages = playbook_pages + p_delta, updated_at = now()
    where character_id = p_char and playbook_pages + p_delta >= 0
    returning playbook_pages into new_total;
  return new_total;
end $$;
revoke all on function public.progression_add_pages(uuid, int) from public, anon, authenticated;
grant execute on function public.progression_add_pages(uuid, int) to service_role;

-- Atomic Master Key craft: in ONE update, spend p_cost pages AND set has_master_key — only if the player has
-- enough pages AND doesn't already hold the key. Returns true iff it crafted (so no double-spend / double-craft
-- even under concurrent calls). The dupe-safety contract for the key.
create or replace function public.progression_craft_key(p_char uuid, p_cost int)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare crafted boolean;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression
    set playbook_pages = playbook_pages - p_cost, has_master_key = true, updated_at = now()
    where character_id = p_char and playbook_pages >= p_cost and has_master_key = false
    returning true into crafted;
  return coalesce(crafted, false);
end $$;
revoke all on function public.progression_craft_key(uuid, int) from public, anon, authenticated;
grant execute on function public.progression_craft_key(uuid, int) to service_role;
