-- gameplay-length P5: PARAGON ("Overtime") + repeatable Playbook-Pages sink ("Audibles"). Post-cap (level 30) XP
-- overflow feeds a monotonic overtime_xp odometer; paragon level is DERIVED closed-form (overtime_xp / OT_PER_LEVEL)
-- identically on server + client, so there is no stored level to desync/dupe. Points spend into a respec-free QoL-only
-- "Bench Board" (paragon_perks jsonb; a whole-board idempotent SET guarded by a derived budget) that touches NO combat
-- stat — every perk is a multiplier on the SERVER reward path, never the deterministic sim. Every 5th paragon level
-- also grants +gear-inventory slots (gear_bag_bonus), read by the inventory_gear_cap trigger below. The Pages sink
-- (Audibles) reuses the existing atomic progression_add_pages(-cost) burn — no new fn for it. Additive + safe: existing
-- rows default to 0/{}, so nothing is granted retroactively and no backfill runs. Service-role writes bypass RLS.
alter table public.progression add column if not exists overtime_xp     bigint not null default 0 check (overtime_xp >= 0);
alter table public.progression add column if not exists paragon_perks   jsonb  not null default '{}'::jsonb;
alter table public.progression add column if not exists paragon_spent   int    not null default 0 check (paragon_spent >= 0);
alter table public.progression add column if not exists gear_bag_bonus  int    not null default 0 check (gear_bag_bonus >= 0);

-- OVERTIME FLUSH (MONOTONIC, race-safe): the server accrues post-cap XP in-session and flushes the running total here
-- at each paragon-level crossing. greatest() makes it monotonic — a stale reconnect / late logout can never LOWER the
-- odometer (so it can never claw back an already-granted paragon point), and a crash between flushes only forfeits
-- sub-one-level progress (never a spendable point, never an over-grant). gear_bag_bonus is likewise raised monotonically
-- (the server computes it from the paragon formula and passes the target, keeping this fn decoupled from OT_PER_LEVEL /
-- the milestone cadence). Returns the resulting overtime_xp.
create or replace function public.progression_set_overtime(p_char uuid, p_overtime bigint, p_bag_bonus int)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_out bigint;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression
    set overtime_xp    = greatest(overtime_xp, greatest(p_overtime, 0)),
        gear_bag_bonus = greatest(gear_bag_bonus, greatest(p_bag_bonus, 0)),
        updated_at     = now()
    where character_id = p_char
    returning overtime_xp into v_out;
  return coalesce(v_out, 0);
end $$;
revoke all on function public.progression_set_overtime(uuid, bigint, int) from public, anon, authenticated;
grant execute on function public.progression_set_overtime(uuid, bigint, int) to service_role;

-- BENCH BOARD SET (atomic, idempotent, budget-guarded): the client sends the WHOLE proposed board; the server has
-- already validated every perk id + per-node cap and computed p_spent = sum(ranks) and p_budget = paragon_level. This
-- is the dupe-safe backstop: reject (return NULL) if spent is out of [0, budget]; else SET the allocation in ONE gated
-- update (not an increment — respec-free reallocation, so concurrent duplicates converge to the same board and can
-- never accumulate). Returns the stored map. Mirrors progression_talent_spend but as a SET rather than a +=.
create or replace function public.progression_paragon_set(p_char uuid, p_perks jsonb, p_spent int, p_budget int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_perks jsonb;
begin
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  perform 1 from public.progression where character_id = p_char for update;
  if p_spent < 0 or p_spent > p_budget then
    return null;
  end if;
  update public.progression
    set paragon_perks = coalesce(p_perks, '{}'::jsonb), paragon_spent = p_spent, updated_at = now()
    where character_id = p_char
    returning paragon_perks into v_perks;
  return v_perks;
end $$;
revoke all on function public.progression_paragon_set(uuid, jsonb, int, int) from public, anon, authenticated;
grant execute on function public.progression_paragon_set(uuid, jsonb, int, int) to service_role;

-- GEAR CAP trigger rewrite (P5 gear-bag milestone): the base 50-item gear cap now stacks the character's paragon
-- gear_bag_bonus. Read straight from progression (security-definer bypasses RLS; PK lookup on character_id) so the DB
-- stays the single source of truth and NO server code path can be forgotten — every add path (loot/shop/craft/quest/
-- admin) still funnels through this one BEFORE-INSERT trigger. Everything else is unchanged from the original: build
-- items are exempt, and we RAISE check_violation (not RETURN NULL) so PostgREST 4xx → add_item_as ok=false → loot
-- skips cleanly AND every paid path (shop/craft, which deduct up front) still refunds correctly.
create or replace function public.inventory_gear_cap()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  gear_count int;
  cap int;
begin
  if coalesce(new.category, 'gear') <> 'build' then
    select count(*) into gear_count from public.inventory
      where character_id = new.character_id and coalesce(category, 'gear') <> 'build';
    cap := 50 + coalesce((select gear_bag_bonus from public.progression where character_id = new.character_id), 0);
    if gear_count >= cap then
      raise exception 'inventory full: %-item gear cap reached for character %', cap, new.character_id
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;
-- trigger binding unchanged (create-or-replace of the fn above rebinds automatically); re-assert for idempotency.
drop trigger if exists inventory_gear_cap_trg on public.inventory;
create trigger inventory_gear_cap_trg
  before insert on public.inventory
  for each row execute function public.inventory_gear_cap();
