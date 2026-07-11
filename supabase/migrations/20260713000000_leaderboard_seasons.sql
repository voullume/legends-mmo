-- gameplay-length P7d: LEADERBOARD SEASONS. The SKILL boards {drill, circuit_time, boss_time} reset each week
-- (season = int(unix/WEEK_SECS)); the PROGRESSION boards {gear, intensity} stay ALL-TIME (pinned to season 0 —
-- they're cumulative ceilings, resetting them is nonsensical). A `season` int joins the PK so a new week = fresh
-- rows appear automatically and past seasons are archived-by-number (no cron, no archive job). The weekly
-- Champion cosmetic is granted LAZILY on login (rank-1 in the just-ended season → an idempotent dye grant).
-- Additive-safe: every legacy row defaults season=0 so uniqueness holds; INERT until the P7d server code deploys.
alter table public.leaderboards add column if not exists season int not null default 0;
alter table public.leaderboards drop constraint if exists leaderboards_pkey;
alter table public.leaderboards add primary key (category, season, character_id);   -- brief table lock; safe (legacy rows season=0)
create index if not exists leaderboards_cat_season_score_idx on public.leaderboards(category, season, score desc);

-- season-aware submit (5-arg; different arity → coexists with the legacy 4-arg fn). Keeps the personal best per
-- (category, season, character). Identical greatest() body, just keyed on season too.
create or replace function public.leaderboard_submit(p_cat text, p_season int, p_char uuid, p_name text, p_score int)
returns int language plpgsql security definer set search_path = public as $$
declare best int;
begin
  insert into public.leaderboards (category, season, character_id, name, score)
    values (p_cat, p_season, p_char, p_name, p_score)
  on conflict (category, season, character_id) do update
    set score = greatest(public.leaderboards.score, excluded.score), name = excluded.name, updated_at = now()
  returning score into best;
  return best;
end $$;
revoke all on function public.leaderboard_submit(text, int, uuid, text, int) from public, anon, authenticated;
grant execute on function public.leaderboard_submit(text, int, uuid, text, int) to service_role;

-- a character's rank (1 = best) in a (season, category), or 0 if unranked. Powers the lazy season-end Champion check.
create or replace function public.leaderboard_rank(p_cat text, p_season int, p_char uuid)
returns int language sql security definer set search_path = public as $$
  select case when not exists (select 1 from public.leaderboards where category = p_cat and season = p_season and character_id = p_char)
    then 0
    else 1 + (select count(*) from public.leaderboards l
              where l.category = p_cat and l.season = p_season
                and l.score > (select score from public.leaderboards where category = p_cat and season = p_season and character_id = p_char))
  end $$;
revoke all on function public.leaderboard_rank(text, int, uuid) from public, anon, authenticated;
grant execute on function public.leaderboard_rank(text, int, uuid) to service_role;

-- per-character last-settled season marker + a guarded compare-and-set (clone of bounty_claim): exactly one
-- caller per (char, season) advances it, so the lazy on-login reward scan runs once per new week.
alter table public.progression add column if not exists last_season int not null default 0;
create or replace function public.season_claim(p_char uuid, p_season int)
returns boolean language plpgsql security definer set search_path = public as $$
declare hit boolean;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression set last_season = p_season, updated_at = now()
    where character_id = p_char and last_season < p_season
    returning true into hit;
  return coalesce(hit, false);
end $$;
revoke all on function public.season_claim(uuid, int) from public, anon, authenticated;
grant execute on function public.season_claim(uuid, int) to service_role;
