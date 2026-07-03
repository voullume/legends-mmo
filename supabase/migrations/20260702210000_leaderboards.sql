-- Endgame P5: leaderboards. Scores are SERVER-authoritative (the zone runs the sim + spawns the waves, so a
-- client can't forge a score) — service_role writes, and the client reads the board only through a server RPC
-- (no client SELECT policy), so we never expose character_ids and the board can't be poisoned by direct REST.
create table if not exists public.leaderboards (
  category text not null,                          -- e.g. 'drill' (Two-Minute Drill wave), 'gear', 'intensity'
  character_id uuid not null references public.characters(id) on delete cascade,
  name text not null,
  score int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (category, character_id)             -- one best row per (category, character)
);
create index if not exists leaderboards_cat_score_idx on public.leaderboards(category, score desc);
alter table public.leaderboards enable row level security;
-- no client policies at all (RLS default-denies) AND revoke the base grants → only the zone server
-- (service_role) reads/writes; clients get the board via the fetch_leaderboard RPC.
revoke select, insert, update, delete on public.leaderboards from authenticated, anon;

-- Submit a score keeping the personal BEST (a run only ever improves your board entry). Returns the best.
create or replace function public.leaderboard_submit(p_cat text, p_char uuid, p_name text, p_score int)
returns int
language plpgsql security definer set search_path = public
as $$
declare best int;
begin
  insert into public.leaderboards (category, character_id, name, score)
    values (p_cat, p_char, p_name, p_score)
  on conflict (category, character_id) do update
    set score = greatest(public.leaderboards.score, excluded.score),
        name = excluded.name, updated_at = now()
  returning score into best;
  return best;
end $$;
revoke all on function public.leaderboard_submit(text, uuid, text, int) from public, anon, authenticated;
grant execute on function public.leaderboard_submit(text, uuid, text, int) to service_role;
