-- gameplay-length P4: TALENT TREES — vertical build-depth. A class-symmetric 3-branch×3-node PURE-STAT tree
-- (numbers in shared/GameData.TALENT_SHAPE, names in TALENT_FLAVOR); 1 point/level (L1=0 … L30=29). Points are
-- DERIVED from level (available = (level-1) - talent_spent) — there is no stored point counter, so nothing to
-- grant/dupe. Only the ALLOCATION persists here (talents jsonb {node_id:ranks}) + a talent_spent tally that is the
-- atomic budget backstop. Talents fold into the SAME server stat-seam as gear set-bonuses (a bounded delta on the
-- 6 derive() stats, capped by TALENT_STAT_CAP) → the deterministic Sim is byte-identical (the AI-duel harness never
-- sees talents). Additive + safe: existing rows default to {} / 0, so every current character simply gains its
-- unspent points (no grandfathering needed). Service-role writes bypass RLS; mirrors the progression atomic-fn pattern.
alter table public.progression add column if not exists talents      jsonb not null default '{}'::jsonb;
alter table public.progression add column if not exists talent_spent int   not null default 0 check (talent_spent >= 0);

-- SPEND (atomic, race-safe via FOR UPDATE): put p_ranks more points into node p_node. The server has already
-- validated node existence, the branch prerequisite (req), the per-node stat cap and the slot ordering; this fn is
-- the DUPE-SAFE backstop for the two things a concurrent second session could race — the level budget and the node
-- ceiling. p_budget = the point budget at this level (= level-1, passed by the server); p_node_max = the node's rank
-- cap. Rejects (returns NULL, which the wrapper reads as "spend refused") if ranks<=0, if it would overspend the
-- level budget (talent_spent + ranks > budget), or if it would overfill the node (current + ranks > node_max).
-- On success: bump the node's ranks + the spent tally in ONE update and return the resulting talents map.
create or replace function public.progression_talent_spend(p_char uuid, p_node text, p_ranks int, p_budget int, p_node_max int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_talents jsonb; v_spent int; v_cur int;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  select talents, talent_spent into v_talents, v_spent
    from public.progression where character_id = p_char for update;
  v_talents := coalesce(v_talents, '{}'::jsonb);
  v_cur := coalesce((v_talents->>p_node)::int, 0);
  if p_ranks <= 0 or v_spent + p_ranks > p_budget or v_cur + p_ranks > p_node_max then
    return null;
  end if;
  v_talents := jsonb_set(v_talents, array[p_node], to_jsonb(v_cur + p_ranks), true);
  update public.progression
    set talents = v_talents, talent_spent = v_spent + p_ranks, updated_at = now()
    where character_id = p_char;
  return v_talents;
end $$;
revoke all on function public.progression_talent_spend(uuid, text, int, int, int) from public, anon, authenticated;
grant execute on function public.progression_talent_spend(uuid, text, int, int, int) to service_role;

-- RESPEC: wipe the whole allocation back to zero so the points can be re-spent. The credit cost (TALENT_RESPEC_CREDITS)
-- is charged server-side against the characters table BEFORE this runs (dupe-safe there); this fn just resets the
-- progression allocation atomically and returns the (empty) map.
create or replace function public.progression_talent_respec(p_char uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.progression
    set talents = '{}'::jsonb, talent_spent = 0, updated_at = now()
    where character_id = p_char;
  return '{}'::jsonb;
end $$;
revoke all on function public.progression_talent_respec(uuid) from public, anon, authenticated;
grant execute on function public.progression_talent_respec(uuid) to service_role;
