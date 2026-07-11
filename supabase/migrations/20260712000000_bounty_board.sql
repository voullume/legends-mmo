-- gameplay-length P6b: daily/weekly BOUNTY BOARD. Rotating, auto-tracked objectives (kill / Circuit-clear /
-- Drill-wave) that reset on a UTC boundary and pay shipped currencies (credits/tokens/Playbook-Pages). The
-- bounty CONTENT + rotation + progress all live server-side (progress is session-only, never persisted → not a
-- dupe surface); this migration adds ONLY the durable per-period CLAIM ledger — the single novel dupe surface.
-- Additive + safe: one jsonb column defaulting to '{}' (no backfill, nothing granted retroactively) + one
-- security-definer claim fn. Nothing reads the column until the P6b server deploys, so applying this ahead of
-- the code is inert.
alter table public.progression add column if not exists bounty_claims jsonb not null default '{}'::jsonb;

-- PER-PERIOD IDEMPOTENT CLAIM (the marquee dupe fix): bounty_claims maps bounty_id -> the last UTC period integer
-- claimed (day int = floor(unix/86400) for dailies, week int = floor(unix/604800) for the weekly). A single gated
-- UPDATE advances the stored period to p_period ONLY when the stored value is strictly less — so exactly ONE caller
-- per (character, bounty, period) succeeds and every replay / concurrent same-character session / stale-period
-- request matches zero rows and grants nothing. Structurally the same compare-and-set as quest_mark_rewarded_as,
-- re-keyed from a one-shot boolean to a rolling integer so the SAME bounty re-opens exactly once each new period.
-- The server computes p_period from its own wall clock (never sent by the client), so a future period can't be
-- forged. The row lock inside the UPDATE serializes concurrent claims. Returns true iff THIS call won the claim.
create or replace function public.bounty_claim(p_char uuid, p_bounty text, p_period int)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_ok boolean := false;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression
    set bounty_claims = jsonb_set(coalesce(bounty_claims, '{}'::jsonb), array[p_bounty], to_jsonb(p_period)),
        updated_at    = now()
    where character_id = p_char
      and coalesce((bounty_claims ->> p_bounty)::int, -1) < p_period
    returning true into v_ok;
  return coalesce(v_ok, false);
end $$;
revoke all on function public.bounty_claim(uuid, text, int) from public, anon, authenticated;
grant execute on function public.bounty_claim(uuid, text, int) to service_role;
