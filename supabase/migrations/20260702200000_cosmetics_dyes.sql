-- Endgame P4: cosmetic dyes — a pure-prestige character tint + a credit sink (no balance/sim impact).
-- Server-authoritative like every other economy surface: service_role writes, client reads its own row.
create table if not exists public.character_cosmetics (
  character_id uuid primary key references public.characters(id) on delete cascade,
  owned jsonb not null default '[]'::jsonb,      -- array of owned dye ids
  equipped text,                                  -- the equipped dye id (null = default look)
  updated_at timestamptz not null default now()
);
alter table public.character_cosmetics enable row level security;
drop policy if exists "cosmetics_select_own" on public.character_cosmetics;
create policy "cosmetics_select_own" on public.character_cosmetics for select
  using (exists (select 1 from public.characters c where c.id = character_cosmetics.character_id and c.user_id = auth.uid()));
revoke insert, update, delete on public.character_cosmetics from authenticated, anon;

-- Atomic grant: ensure the row, then append p_dye to owned ONLY if not already present. Returns true iff it
-- was newly granted (so a duplicate/concurrent buy can't add it twice — the dupe-safety contract for the buy).
create or replace function public.cosmetics_grant(p_char uuid, p_dye text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare granted boolean;
begin
  insert into public.character_cosmetics (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.character_cosmetics
    set owned = owned || to_jsonb(p_dye), updated_at = now()
    where character_id = p_char and not (owned ? p_dye)
    returning true into granted;
  return coalesce(granted, false);
end $$;
revoke all on function public.cosmetics_grant(uuid, text) from public, anon, authenticated;
grant execute on function public.cosmetics_grant(uuid, text) to service_role;

-- Equip: set equipped to p_dye only if it is owned (or '' to clear to default). Returns true on success.
-- Not a currency op, but keeping ownership enforced IN the write means a client can't equip an unowned dye.
create or replace function public.cosmetics_equip(p_char uuid, p_dye text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare done boolean;
begin
  insert into public.character_cosmetics (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.character_cosmetics
    set equipped = nullif(p_dye, ''), updated_at = now()
    where character_id = p_char and (p_dye = '' or owned ? p_dye)
    returning true into done;
  return coalesce(done, false);
end $$;
revoke all on function public.cosmetics_equip(uuid, text) from public, anon, authenticated;
grant execute on function public.cosmetics_equip(uuid, text) to service_role;
