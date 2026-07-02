-- Endgame P1: per-character progression — the Camp Circuit Intensity ladder + (P2) Playbook Pages currency.
-- Server-authoritative (service_role writes bypass RLS), client reads own row. Mirrors the materials table.
create table if not exists public.progression (
  character_id uuid primary key references public.characters(id) on delete cascade,
  max_intensity int not null default 1 check (max_intensity between 1 and 30),
  playbook_pages int not null default 0 check (playbook_pages >= 0),   -- P2 uses this; default 0 is inert until then
  updated_at timestamptz not null default now()
);
alter table public.progression enable row level security;
drop policy if exists "progression_select_own" on public.progression;
create policy "progression_select_own" on public.progression for select
  using (exists (select 1 from public.characters c where c.id = progression.character_id and c.user_id = auth.uid()));
-- no client insert/update/delete policies → only the zone server (service_role) writes progression.

-- Atomic Intensity unlock: ensure the row exists, then bump max_intensity to p_tier+1 ONLY when the current
-- max equals p_tier (i.e. the player cleared at their ceiling). Race-safe: two concurrent clears at the same
-- tier compose (only the first bumps). Returns the resulting max (unchanged if the clear was below the ceiling
-- or already at INTENSITY_MAX). Mirrors mats_add.
create or replace function public.progression_unlock(p_char uuid, p_tier int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare new_max int;
begin
  insert into public.progression (character_id, max_intensity) values (p_char, 1)
    on conflict (character_id) do nothing;
  update public.progression
    set max_intensity = least(p_tier + 1, 30), updated_at = now()
    where character_id = p_char and max_intensity = p_tier and p_tier < 30
    returning max_intensity into new_max;
  if new_max is null then                         -- no bump (below ceiling / already maxed) → report current
    select max_intensity into new_max from public.progression where character_id = p_char;
  end if;
  return new_max;
end $$;
revoke all on function public.progression_unlock(uuid, int) from public, anon, authenticated;
grant execute on function public.progression_unlock(uuid, int) to service_role;
