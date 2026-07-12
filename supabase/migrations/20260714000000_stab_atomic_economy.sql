-- Stabilization P3: ATOMIC + IDEMPOTENT ECONOMY.
-- Every multi-step currency↔item exchange the zone server performs becomes ONE Postgres transaction,
-- guarded IN the mutation (balance checks in the UPDATE itself, ownership/state in the row filter),
-- with a server-generated operation id recorded in a bounded ledger so a RETRIED request returns the
-- original result instead of applying twice. This retires the application-level
-- deduct-in-memory → write → refund-on-fail sequences (which could not survive a crash, timeout, or
-- concurrent session between their steps).
--
-- ADDITIVE + SAFE: new table + new functions only; nothing existing is altered or dropped. INERT
-- until the stabilization server code deploys (the old server never calls these).
--
-- DEPLOY ORDER (no downtime):
--   1. apply THIS migration (backward-compatible — the running server ignores it);
--   2. deploy the stabilization server (it probes econ_version() at boot and switches to these fns);
--   3. verify: boot log shows "✓ atomic economy functions live", then exercise a shop buy/sell;
--   4. (later change) delete the legacy fallback paths from Server.gd once burn-in is done.
-- Do NOT deploy the new server against a database missing this migration in production: it FAILS
-- CLOSED (economy ops refused) rather than silently using the legacy non-atomic path.
--
-- Access model: service_role ONLY (the zone server). Every function is SECURITY DEFINER with
-- search_path pinned, EXECUTE revoked from public/anon/authenticated. Clients can neither call the
-- fns nor read/write the ledger.
--
-- Result contract: every op fn returns jsonb
--   { ok:bool, reason?: 'insufficient_credits'|'insufficient_tokens'|'insufficient_scrap'|
--     'inventory_full'|'stale_item'|'owned'|'nothing'|'no_character'|'bad_price',
--     credits?:int, tokens?:int, scrap?:int, payout?:int, sold?:[uuid…], item_id?:uuid,
--     duplicate?:true }   -- duplicate = this op id was already applied; fields are the ORIGINAL result
--
-- Locking discipline: every fn locks the characters row FIRST (FOR UPDATE), then materials /
-- inventory / progression rows — one global order, so concurrent econ fns for one character
-- serialize instead of deadlocking.

-- ---------------------------------------------------------------------------------------------
-- 1) the idempotency ledger (bounded: pruned opportunistically per character on every recorded op)
create table if not exists public.economy_ops (
  op_id uuid primary key,
  character_id uuid not null references public.characters(id) on delete cascade,
  kind text not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists economy_ops_char_created_idx on public.economy_ops(character_id, created_at);
alter table public.economy_ops enable row level security;
revoke select, insert, update, delete on public.economy_ops from authenticated, anon;

-- ---------------------------------------------------------------------------------------------
-- 2) internal helpers (NOT granted to any role — callable only from the definer-owned fns below)

-- the already-recorded result for an op id, or NULL if unseen
create or replace function public.econ_seen(p_op uuid)
returns jsonb language sql security definer set search_path = public as $$
  select result from public.economy_ops where op_id = p_op
$$;
revoke all on function public.econ_seen(uuid) from public, anon, authenticated;

-- record an op's result (first writer wins) + prune this character's ledger tail. Returns p_result.
create or replace function public.econ_record(p_op uuid, p_char uuid, p_kind text, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  insert into public.economy_ops (op_id, character_id, kind, result)
    values (p_op, p_char, p_kind, p_result)
  on conflict (op_id) do nothing;
  delete from public.economy_ops
    where character_id = p_char and created_at < now() - interval '7 days';
  return p_result;
end $$;
revoke all on function public.econ_record(uuid, uuid, text, jsonb) from public, anon, authenticated;

-- one inventory insert from the server-built item jsonb (the gear-cap trigger still applies)
create or replace function public.econ_insert_item(p_char uuid, p_item jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.inventory (character_id, name, rarity, slot, bonus_stat, bonus_amt,
      primary_stat, primary_amt, ilvl, affixes, item_power, set_id, unique_id, proc_id, proc_tier,
      category, model)
    values (p_char,
      coalesce(p_item->>'name', 'Item'),
      coalesce(p_item->>'rarity', 'common'),
      coalesce(p_item->>'slot', 'trinket'),
      p_item->>'bonus_stat',
      coalesce((p_item->>'bonus_amt')::int, 0),
      p_item->>'primary_stat',
      coalesce((p_item->>'primary_amt')::int, 0),
      coalesce((p_item->>'ilvl')::int, 1),
      coalesce(p_item->'affixes', '[]'::jsonb),
      coalesce((p_item->>'item_power')::int, 0),
      p_item->>'set_id',
      p_item->>'unique_id',
      p_item->>'proc_id',
      coalesce((p_item->>'proc_tier')::int, 0),
      coalesce(p_item->>'category', 'gear'),
      p_item->>'model')
    returning id into v_id;
  return v_id;
end $$;
revoke all on function public.econ_insert_item(uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3) version probe — the server detects at boot whether the atomic economy is available
create or replace function public.econ_version()
returns int language sql security definer set search_path = public as $$ select 1 $$;
revoke all on function public.econ_version() from public, anon, authenticated;
grant execute on function public.econ_version() to service_role;

-- ---------------------------------------------------------------------------------------------
-- 4) AWARD (kill credits / practice tokens / quest currency / admin adjustments): a delta flush;
-- credits deltas may be negative (the balance floors at 0), token deltas are award-only.
-- Idempotent via the ledger — the server retries a transport-failed flush with the SAME op id.
create or replace function public.econ_award(p_op uuid, p_char uuid, p_credits int, p_tokens int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_tokens int;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform 1 from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  update public.characters
    set credits = greatest(0, credits + p_credits),           -- p_credits may be NEGATIVE (admin
        practice_tokens = greatest(0, practice_tokens + greatest(p_tokens, 0))   -- corrections); floor at 0
    where id = p_char
    returning credits, practice_tokens into v_credits, v_tokens;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  return public.econ_record(p_op, p_char, 'award',
    jsonb_build_object('ok', true, 'credits', v_credits, 'tokens', v_tokens));
end $$;
revoke all on function public.econ_award(uuid, uuid, int, int) from public, anon, authenticated;
grant execute on function public.econ_award(uuid, uuid, int, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 5) BUY ITEM (shop catalog / random roll / practice vendor / build shop): debit credits and/or
-- tokens + mint the item in ONE transaction. The gear-cap trigger raising inside rolls the whole
-- op back (reason inventory_full, nothing charged).
create or replace function public.econ_buy_item(p_op uuid, p_char uuid, p_credits int, p_tokens int, p_item jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_tokens int; v_id uuid;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits, practice_tokens into v_credits, v_tokens
    from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 or p_tokens < 0 then
    return public.econ_record(p_op, p_char, 'buy_item', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'buy_item',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits, 'tokens', v_tokens));
  end if;
  if v_tokens < p_tokens then
    return public.econ_record(p_op, p_char, 'buy_item',
      jsonb_build_object('ok', false, 'reason', 'insufficient_tokens', 'credits', v_credits, 'tokens', v_tokens));
  end if;
  begin
    v_id := public.econ_insert_item(p_char, p_item);
  exception when check_violation then       -- gear cap / shape check → the block rolls back, nothing charged
    return public.econ_record(p_op, p_char, 'buy_item',
      jsonb_build_object('ok', false, 'reason', 'inventory_full', 'credits', v_credits, 'tokens', v_tokens));
  end;
  update public.characters
    set credits = credits - p_credits, practice_tokens = practice_tokens - p_tokens
    where id = p_char
    returning credits, practice_tokens into v_credits, v_tokens;
  return public.econ_record(p_op, p_char, 'buy_item',
    jsonb_build_object('ok', true, 'credits', v_credits, 'tokens', v_tokens, 'item_id', v_id));
end $$;
revoke all on function public.econ_buy_item(uuid, uuid, int, int, jsonb) from public, anon, authenticated;
grant execute on function public.econ_buy_item(uuid, uuid, int, int, jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 6) SELL ITEMS (single + bulk): delete each owned, unequipped, unlocked GEAR row and credit the
-- rarity-priced payout, all in one transaction. p_prices = {rarity: price} from the server's
-- SELL_PRICE table (server-only fn, so the price map is trusted; a missing rarity pays 10 — the
-- server's own fallback). Build items are NEVER sellable here (they live in the build flow).
create or replace function public.econ_sell_items(p_op uuid, p_char uuid, p_ids uuid[], p_prices jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_payout int := 0; v_sold jsonb := '[]'::jsonb;
        v_id uuid; v_rarity text;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits into v_credits from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  foreach v_id in array p_ids loop
    delete from public.inventory
      where id = v_id and character_id = p_char
        and equipped = false and locked = false and coalesce(category, 'gear') <> 'build'
      returning rarity into v_rarity;
    if found then
      v_payout := v_payout + coalesce((p_prices->>v_rarity)::int, 10);
      v_sold := v_sold || to_jsonb(v_id::text);
    end if;
  end loop;
  if v_payout > 0 then
    update public.characters set credits = credits + v_payout
      where id = p_char returning credits into v_credits;
  end if;
  return public.econ_record(p_op, p_char, 'sell',
    jsonb_build_object('ok', true, 'payout', v_payout, 'credits', v_credits, 'sold', v_sold));
end $$;
revoke all on function public.econ_sell_items(uuid, uuid, uuid[], jsonb) from public, anon, authenticated;
grant execute on function public.econ_sell_items(uuid, uuid, uuid[], jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 7) SALVAGE ITEMS: like selling, but yields scrap into materials. p_yields = {rarity: scrap}
-- (the server pre-applies its per-player perk multiplier).
create or replace function public.econ_salvage_items(p_op uuid, p_char uuid, p_ids uuid[], p_yields jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_scrap int; v_total int := 0; v_salvaged jsonb := '[]'::jsonb;
        v_id uuid; v_rarity text;
begin
  perform 1 from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  insert into public.materials (character_id, scrap) values (p_char, 0)
    on conflict (character_id) do nothing;
  select scrap into v_scrap from public.materials where character_id = p_char for update;
  foreach v_id in array p_ids loop
    delete from public.inventory
      where id = v_id and character_id = p_char
        and equipped = false and locked = false and coalesce(category, 'gear') <> 'build'
      returning rarity into v_rarity;
    if found then
      v_total := v_total + greatest(1, coalesce((p_yields->>v_rarity)::int, 1));
      v_salvaged := v_salvaged || to_jsonb(v_id::text);
    end if;
  end loop;
  if v_total > 0 then
    update public.materials set scrap = scrap + v_total, updated_at = now()
      where character_id = p_char returning scrap into v_scrap;
  end if;
  return public.econ_record(p_op, p_char, 'salvage',
    jsonb_build_object('ok', true, 'scrap', v_scrap, 'salvaged', v_salvaged));
end $$;
revoke all on function public.econ_salvage_items(uuid, uuid, uuid[], jsonb) from public, anon, authenticated;
grant execute on function public.econ_salvage_items(uuid, uuid, uuid[], jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 8) FORGE UPGRADE: validate both currencies UNDER LOCK, patch the item gated on its current
-- upgrade_level (a stale/duplicate request matches no row → stale_item, nothing spent), then debit
-- credits + scrap — one transaction, no application-level refund path needed.
create or replace function public.econ_forge_upgrade(p_op uuid, p_char uuid, p_item uuid,
    p_old_level int, p_new_ip int, p_credits int, p_scrap int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_scrap int;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits into v_credits from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 or p_scrap < 0 then
    return public.econ_record(p_op, p_char, 'forge_upgrade', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  insert into public.materials (character_id, scrap) values (p_char, 0)
    on conflict (character_id) do nothing;
  select scrap into v_scrap from public.materials where character_id = p_char for update;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'forge_upgrade',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  if v_scrap < p_scrap then
    return public.econ_record(p_op, p_char, 'forge_upgrade',
      jsonb_build_object('ok', false, 'reason', 'insufficient_scrap', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  update public.inventory set upgrade_level = p_old_level + 1, item_power = p_new_ip
    where id = p_item and character_id = p_char and upgrade_level = p_old_level
      and coalesce(category, 'gear') <> 'build';
  if not found then
    return public.econ_record(p_op, p_char, 'forge_upgrade',
      jsonb_build_object('ok', false, 'reason', 'stale_item', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  update public.characters set credits = credits - p_credits
    where id = p_char returning credits into v_credits;
  update public.materials set scrap = scrap - p_scrap, updated_at = now()
    where character_id = p_char returning scrap into v_scrap;
  return public.econ_record(p_op, p_char, 'forge_upgrade',
    jsonb_build_object('ok', true, 'credits', v_credits, 'scrap', v_scrap));
end $$;
revoke all on function public.econ_forge_upgrade(uuid, uuid, uuid, int, int, int, int) from public, anon, authenticated;
grant execute on function public.econ_forge_upgrade(uuid, uuid, uuid, int, int, int, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 9) FORGE REFORGE: same shape, gated on reforge_count, writes the server-rolled affixes.
create or replace function public.econ_forge_reforge(p_op uuid, p_char uuid, p_item uuid,
    p_old_count int, p_affixes jsonb, p_new_ip int, p_credits int, p_scrap int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_scrap int;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits into v_credits from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 or p_scrap < 0 then
    return public.econ_record(p_op, p_char, 'forge_reforge', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  insert into public.materials (character_id, scrap) values (p_char, 0)
    on conflict (character_id) do nothing;
  select scrap into v_scrap from public.materials where character_id = p_char for update;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'forge_reforge',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  if v_scrap < p_scrap then
    return public.econ_record(p_op, p_char, 'forge_reforge',
      jsonb_build_object('ok', false, 'reason', 'insufficient_scrap', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  update public.inventory set affixes = coalesce(p_affixes, '[]'::jsonb),
      reforge_count = p_old_count + 1, item_power = p_new_ip
    where id = p_item and character_id = p_char and reforge_count = p_old_count
      and coalesce(category, 'gear') <> 'build';
  if not found then
    return public.econ_record(p_op, p_char, 'forge_reforge',
      jsonb_build_object('ok', false, 'reason', 'stale_item', 'credits', v_credits, 'scrap', v_scrap));
  end if;
  update public.characters set credits = credits - p_credits
    where id = p_char returning credits into v_credits;
  update public.materials set scrap = scrap - p_scrap, updated_at = now()
    where character_id = p_char returning scrap into v_scrap;
  return public.econ_record(p_op, p_char, 'forge_reforge',
    jsonb_build_object('ok', true, 'credits', v_credits, 'scrap', v_scrap));
end $$;
revoke all on function public.econ_forge_reforge(uuid, uuid, uuid, int, jsonb, int, int, int) from public, anon, authenticated;
grant execute on function public.econ_forge_reforge(uuid, uuid, uuid, int, jsonb, int, int, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 10) CRAFT: spend scrap + mint the server-rolled item in one transaction (cap-raise refunds by rollback).
create or replace function public.econ_craft(p_op uuid, p_char uuid, p_scrap int, p_item jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_scrap int; v_id uuid;
begin
  perform 1 from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_scrap < 0 then
    return public.econ_record(p_op, p_char, 'craft', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  insert into public.materials (character_id, scrap) values (p_char, 0)
    on conflict (character_id) do nothing;
  select scrap into v_scrap from public.materials where character_id = p_char for update;
  if v_scrap < p_scrap then
    return public.econ_record(p_op, p_char, 'craft',
      jsonb_build_object('ok', false, 'reason', 'insufficient_scrap', 'scrap', v_scrap));
  end if;
  begin
    v_id := public.econ_insert_item(p_char, p_item);
  exception when check_violation then
    return public.econ_record(p_op, p_char, 'craft',
      jsonb_build_object('ok', false, 'reason', 'inventory_full', 'scrap', v_scrap));
  end;
  update public.materials set scrap = scrap - p_scrap, updated_at = now()
    where character_id = p_char returning scrap into v_scrap;
  return public.econ_record(p_op, p_char, 'craft',
    jsonb_build_object('ok', true, 'scrap', v_scrap, 'item_id', v_id));
end $$;
revoke all on function public.econ_craft(uuid, uuid, int, jsonb) from public, anon, authenticated;
grant execute on function public.econ_craft(uuid, uuid, int, jsonb) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 11) BUY COSMETIC: debit + grant-if-not-owned in one transaction (already-owned charges nothing).
create or replace function public.econ_buy_cosmetic(p_op uuid, p_char uuid, p_dye text, p_credits int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits into v_credits from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 then
    return public.econ_record(p_op, p_char, 'buy_cosmetic', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'buy_cosmetic',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits));
  end if;
  insert into public.character_cosmetics (character_id) values (p_char)
    on conflict (character_id) do nothing;
  update public.character_cosmetics set owned = owned || to_jsonb(p_dye), updated_at = now()
    where character_id = p_char and not (owned ? p_dye);
  if not found then
    return public.econ_record(p_op, p_char, 'buy_cosmetic',
      jsonb_build_object('ok', false, 'reason', 'owned', 'credits', v_credits));
  end if;
  update public.characters set credits = credits - p_credits
    where id = p_char returning credits into v_credits;
  return public.econ_record(p_op, p_char, 'buy_cosmetic',
    jsonb_build_object('ok', true, 'credits', v_credits));
end $$;
revoke all on function public.econ_buy_cosmetic(uuid, uuid, text, int) from public, anon, authenticated;
grant execute on function public.econ_buy_cosmetic(uuid, uuid, text, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 12) UNLOCK LOCKER ROOM: debit + flip locker_unlocked false→true in one gated transaction.
create or replace function public.econ_unlock_locker(p_op uuid, p_char uuid, p_credits int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int; v_unlocked boolean;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits, locker_unlocked into v_credits, v_unlocked
    from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 then
    return public.econ_record(p_op, p_char, 'unlock_locker', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  if v_unlocked then
    return public.econ_record(p_op, p_char, 'unlock_locker',
      jsonb_build_object('ok', false, 'reason', 'owned', 'credits', v_credits));
  end if;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'unlock_locker',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits));
  end if;
  update public.characters set credits = credits - p_credits, locker_unlocked = true
    where id = p_char returning credits into v_credits;
  return public.econ_record(p_op, p_char, 'unlock_locker',
    jsonb_build_object('ok', true, 'credits', v_credits));
end $$;
revoke all on function public.econ_unlock_locker(uuid, uuid, int) from public, anon, authenticated;
grant execute on function public.econ_unlock_locker(uuid, uuid, int) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 13) RESPEC TALENTS: debit credits + reset the allocation in one transaction (nothing allocated
-- charges nothing).
create or replace function public.econ_respec_talents(p_op uuid, p_char uuid, p_credits int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prev jsonb; v_credits int;
begin
  -- run AS the service role for the characters guard triggers regardless of the invocation path
  -- (PostgREST rpc, SQL editor, psql): EXECUTE is already service_role-only, so this only makes the
  -- request-scoped GUC the triggers read match the privilege the caller must already hold.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select credits into v_credits from public.characters where id = p_char for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_character');   -- never recorded (FK: no character row)
  end if;
  -- lock held → NOW dedup: a same-op retry that raced its still-executing first attempt
  -- serialized on the row lock above and now SEES the recorded result (no double-apply).
  v_prev := public.econ_seen(p_op);
  if v_prev is not null then return v_prev || jsonb_build_object('duplicate', true); end if;
  if p_credits < 0 then
    return public.econ_record(p_op, p_char, 'respec', jsonb_build_object('ok', false, 'reason', 'bad_price'));
  end if;
  if v_credits < p_credits then
    return public.econ_record(p_op, p_char, 'respec',
      jsonb_build_object('ok', false, 'reason', 'insufficient_credits', 'credits', v_credits));
  end if;
  insert into public.progression (character_id) values (p_char) on conflict (character_id) do nothing;
  update public.progression set talents = '{}'::jsonb, talent_spent = 0, updated_at = now()
    where character_id = p_char and talent_spent > 0;
  if not found then
    return public.econ_record(p_op, p_char, 'respec',
      jsonb_build_object('ok', false, 'reason', 'nothing', 'credits', v_credits));
  end if;
  update public.characters set credits = credits - p_credits
    where id = p_char returning credits into v_credits;
  return public.econ_record(p_op, p_char, 'respec',
    jsonb_build_object('ok', true, 'credits', v_credits));
end $$;
revoke all on function public.econ_respec_talents(uuid, uuid, int) from public, anon, authenticated;
grant execute on function public.econ_respec_talents(uuid, uuid, int) to service_role;
