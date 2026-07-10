-- gameplay-length P1(d): RESTED XP — a return hook. A pool that accrues while a character is logged OUT and is
-- spent as a bonus on top of earned kill/quest XP once back online, so time away is rewarded. Server-authoritative
-- (service_role writes bypass RLS); mirrors the progression table's atomic-fn pattern. Additive + safe (defaults,
-- no backfill; existing rows get rested_xp=0 / rested_seen=null = "no rest banked, currently online").
alter table public.progression add column if not exists rested_xp   int not null default 0 check (rested_xp >= 0);
alter table public.progression add column if not exists rested_seen  timestamptz;   -- set at logout; null while online

-- LOGIN (atomic, race-safe via FOR UPDATE): ensure the row, compute the FULL pool = banked + accrued-for-the-
-- offline-gap (now - rested_seen, at p_rate per HOUR), clamped into [current, p_cap]; then LEASE the whole pool to
-- this ONE session by zeroing the DB (rested_xp:=0, rested_seen:=null) and returning the leased amount. Zeroing is
-- what makes rested dupe/refund-safe: a concurrent or fast-relog second login reads 0 (can't double-load the pool),
-- and an unclean drop (crash/redeploy/failed logout) FORFEITS the unspent remainder — the safe direction — because
-- only the paired logout below adds it back. rate/cap are passed by the server (level-scaled); the fn stays generic.
create or replace function public.progression_rest_login(p_char uuid, p_rate numeric, p_cap int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_rested int; v_seen timestamptz; v_total int;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  select rested_xp, rested_seen into v_rested, v_seen
    from public.progression where character_id = p_char for update;
  v_total := greatest(v_rested, least(greatest(p_cap, 0),
             v_rested + greatest(floor(greatest(p_rate, 0) * (extract(epoch from (now() - coalesce(v_seen, now()))) / 3600.0))::int, 0)));
  update public.progression set rested_xp = 0, rested_seen = null, updated_at = now()
    where character_id = p_char;
  return coalesce(v_total, 0);
end $$;
revoke all on function public.progression_rest_login(uuid, numeric, int) from public, anon, authenticated;
grant execute on function public.progression_rest_login(uuid, numeric, int) to service_role;

-- LOGOUT: ADD BACK the session's unspent remainder (additive, NOT an absolute overwrite) so it can never clobber a
-- concurrent session's banked pool or resurrect an already-spent one, and stamp the offline time for the next
-- login's accrual. A missed logout (crash) simply forfeits the remainder (the DB stays at the leased-to-0 value).
create or replace function public.progression_rest_logout(p_char uuid, p_rested int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.progression
    set rested_xp = greatest(0, rested_xp + greatest(0, p_rested)), rested_seen = now(), updated_at = now()
    where character_id = p_char;
end $$;
revoke all on function public.progression_rest_logout(uuid, int) from public, anon, authenticated;
grant execute on function public.progression_rest_logout(uuid, int) to service_role;
