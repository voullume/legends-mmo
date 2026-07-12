-- Clean-database migration verification — ASSERTIONS (stabilization follow-up).
-- Run on a scratch Postgres AFTER bootstrap.sql + every supabase/migrations/*.sql in filename
-- order. Every block RAISEs on failure (psql -v ON_ERROR_STOP=1 exits non-zero), so this is
-- CI-gradeable with nothing but psql:
--
--   createdb legends_migcheck
--   psql -d legends_migcheck -v ON_ERROR_STOP=1 -f tools/migration_check/bootstrap.sql
--   for f in supabase/migrations/*.sql; do psql -d legends_migcheck -v ON_ERROR_STOP=1 -f "$f"; done
--   psql -d legends_migcheck -v ON_ERROR_STOP=1 -f tools/migration_check/assertions.sql
--
-- Covers: grants/RLS posture of the atomic-economy layer, the characters guard triggers, and the
-- REAL plpgsql behavior of the stabilization economy functions (idempotent replay, guarded debits,
-- equipped-item protection, stale-version refusal, gear-cap rollback). Superuser context stands in
-- for service_role (RLS-bypassing), with the request.jwt.claims GUC driving the guard triggers.

-- ---- 1. privilege / posture checks -------------------------------------------------------------
do $priv$
begin
  if has_function_privilege('anon', 'public.econ_buy_item(uuid,uuid,integer,integer,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.econ_buy_item(uuid,uuid,integer,integer,jsonb)', 'execute') then
    raise exception 'POSTURE: econ_buy_item is executable by client roles';
  end if;
  if not has_function_privilege('service_role', 'public.econ_buy_item(uuid,uuid,integer,integer,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.econ_version()', 'execute') then
    raise exception 'POSTURE: service_role cannot execute the econ functions';
  end if;
  if has_function_privilege('anon', 'public.econ_seen(uuid)', 'execute') then
    raise exception 'POSTURE: internal helper econ_seen is executable by anon';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.economy_ops'::regclass) then
    raise exception 'POSTURE: economy_ops has RLS disabled';
  end if;
  if public.econ_version() < 1 then
    raise exception 'POSTURE: econ_version() < 1';
  end if;
  raise notice 'posture checks OK';
end $priv$;

-- ---- 2. behavior checks (one transaction; rolled back afterwards is fine — scratch DB) ---------
do $test$
declare
  v_uid uuid; v_char uuid; v_a uuid; v_b uuid; op uuid; r jsonb; i int;
begin
  -- service-role context for setup (the guard triggers pin economy columns for anyone else)
  perform set_config('request.jwt.claims', '{"role":"service_role"}', false);
  insert into auth.users (id, email) values (gen_random_uuid(), 'mig-check@test.dev') returning id into v_uid;
  insert into public.characters (user_id, name, class) values (v_uid, 'MigCheck', 'striker') returning id into v_char;
  update public.characters set credits = 100, practice_tokens = 10 where id = v_char;
  if (select credits from public.characters where id = v_char) <> 100 then
    raise exception 'GUARD: service_role credit update did not apply';
  end if;

  -- the pre-existing guard trigger still pins client writes after the new migration
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', false);
  update public.characters set credits = 999999, level = 99 where id = v_char;
  if (select credits from public.characters where id = v_char) <> 100
     or (select level from public.characters where id = v_char) <> 1 then
    raise exception 'GUARD: non-service_role economy write was NOT pinned';
  end if;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', false);

  -- econ_buy_item: debit+mint once; the SAME op id replays the original result
  op := gen_random_uuid();
  r := public.econ_buy_item(op, v_char, 40, 0, '{"name":"T","rarity":"common","slot":"head"}'::jsonb);
  if not (r->>'ok')::bool or (r->>'credits')::int <> 60 then raise exception 'BUY: %', r; end if;
  r := public.econ_buy_item(op, v_char, 40, 0, '{"name":"T","rarity":"common","slot":"head"}'::jsonb);
  if not coalesce((r->>'duplicate')::bool, false) or (r->>'credits')::int <> 60 then
    raise exception 'BUY REPLAY: %', r;
  end if;
  if (select count(*) from public.inventory where character_id = v_char) <> 1 then
    raise exception 'BUY REPLAY minted a second item';
  end if;
  r := public.econ_buy_item(gen_random_uuid(), v_char, 9999, 0, '{"name":"X","slot":"head"}'::jsonb);
  if (r->>'reason') is distinct from 'insufficient_credits' then raise exception 'BUY INSUFFICIENT: %', r; end if;

  -- econ_award: idempotent delta
  op := gen_random_uuid();
  r := public.econ_award(op, v_char, 100, 5);
  if (r->>'credits')::int <> 160 or (r->>'tokens')::int <> 15 then raise exception 'AWARD: %', r; end if;
  r := public.econ_award(op, v_char, 100, 5);
  if not coalesce((r->>'duplicate')::bool, false) or (r->>'credits')::int <> 160 then
    raise exception 'AWARD REPLAY double-applied: %', r;
  end if;

  -- econ_sell_items: pays per removed row, never an equipped row; replay is inert
  v_a := public.econ_insert_item(v_char, '{"name":"A","rarity":"common","slot":"feet"}'::jsonb);
  v_b := public.econ_insert_item(v_char, '{"name":"B","rarity":"rare","slot":"neck"}'::jsonb);
  update public.inventory set equipped = true where id = v_b;
  op := gen_random_uuid();
  r := public.econ_sell_items(op, v_char, array[v_a, v_b], '{"common":14,"rare":95}'::jsonb);
  if (r->>'payout')::int <> 14 then raise exception 'SELL payout: %', r; end if;
  if not exists (select 1 from public.inventory where id = v_b) then
    raise exception 'SELL consumed an EQUIPPED item';
  end if;
  r := public.econ_sell_items(op, v_char, array[v_a], '{"common":14}'::jsonb);
  if not coalesce((r->>'duplicate')::bool, false) then raise exception 'SELL REPLAY: %', r; end if;

  -- econ_forge_upgrade: a stale item version spends nothing
  r := public.econ_forge_upgrade(gen_random_uuid(), v_char, gen_random_uuid(), 0, 10, 1, 0);
  if (r->>'reason') is distinct from 'stale_item' then raise exception 'FORGE STALE: %', r; end if;

  -- econ_unlock_locker: once, then 'owned' (free)
  update public.characters set credits = 20000 where id = v_char;
  r := public.econ_unlock_locker(gen_random_uuid(), v_char, 10000);
  if not (r->>'ok')::bool or (r->>'credits')::int <> 10000 then raise exception 'LOCKER: %', r; end if;
  r := public.econ_unlock_locker(gen_random_uuid(), v_char, 10000);
  if (r->>'reason') is distinct from 'owned' or (r->>'credits')::int <> 10000 then
    raise exception 'LOCKER OWNED re-charged: %', r;
  end if;

  -- econ_respec_talents: nothing allocated is free; a real respec charges once
  r := public.econ_respec_talents(gen_random_uuid(), v_char, 500);
  if (r->>'reason') is distinct from 'nothing' then raise exception 'RESPEC NOTHING: %', r; end if;
  insert into public.progression (character_id, talents, talent_spent) values (v_char, '{"x":1}'::jsonb, 1)
    on conflict (character_id) do update set talents = '{"x":1}'::jsonb, talent_spent = 1;
  r := public.econ_respec_talents(gen_random_uuid(), v_char, 500);
  if not (r->>'ok')::bool or (select talent_spent from public.progression where character_id = v_char) <> 0 then
    raise exception 'RESPEC: %', r;
  end if;

  -- econ_craft: guarded scrap spend + mint
  r := public.econ_craft(gen_random_uuid(), v_char, 999, '{"name":"C","rarity":"rare","slot":"ring"}'::jsonb);
  if (r->>'reason') is distinct from 'insufficient_scrap' then raise exception 'CRAFT SCARCE: %', r; end if;
  perform public.mats_add(v_char, 12);
  r := public.econ_craft(gen_random_uuid(), v_char, 12, '{"name":"C","rarity":"rare","slot":"ring"}'::jsonb);
  if not (r->>'ok')::bool or (r->>'scrap')::int <> 0 then raise exception 'CRAFT: %', r; end if;

  -- gear cap: the trigger's RAISE rolls the whole buy back (inventory_full, nothing charged)
  select count(*) into i from public.inventory
    where character_id = v_char and coalesce(category, 'gear') <> 'build';
  while i < 50 loop
    perform public.econ_insert_item(v_char, '{"name":"F","rarity":"common","slot":"trinket"}'::jsonb);
    i := i + 1;
  end loop;
  r := public.econ_buy_item(gen_random_uuid(), v_char, 0, 0, '{"name":"Over","rarity":"common","slot":"head"}'::jsonb);
  if (r->>'reason') is distinct from 'inventory_full' then raise exception 'GEAR CAP: %', r; end if;

  raise notice 'behavior checks OK';
end $test$;
