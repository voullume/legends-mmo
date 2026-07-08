-- Builder Mode + the Locker Room — P0 foundation (schema only; NO rows inserted, NO data migrated).
-- Adds two things, both server-authoritative:
--   (1) a per-character `locker_unlocked` flag guarding Locker-Room access — PINNED against client writes just
--       like credits/level/xp/practice_tokens (see the guard trigger below), so it can only be flipped by the
--       zone server (service_role) via the atomic gated unlock (Supabase.locker_unlock_as / buy_locker_room).
--   (2) a `build` inventory CATEGORY (furniture/props) carrying a model id + placement transform + a `placed`
--       flag, so a build item's Build-tab row IS its Locker-Room-layout row — placing just flips `placed` +
--       writes `xform`; it never mints or destroys a row. That invariant (owned = unplaced + placed) is what
--       makes the whole system dupe-proof and refund-exploit-free.
-- Inventory is ALREADY service_role-only writes (clients are denied insert/update/delete — see
-- 20260621180000_legends_inventory_server_only_writes.sql), so clients cannot self-grant build items either.
--
-- Additive + safe: every new column has a default; existing gear rows simply become category='gear' with a null
-- model/xform and placed=false, satisfying the new CHECKs without a backfill.
--
-- DEPLOY ORDERING: this is a NO-OP for the service_role zone server (it bypasses RLS + the guard trigger) and
-- immediately closes the client self-unlock hole. Safe to apply before OR after the server redeploy — no server
-- code ever writes locker_unlocked with a player token (only the service_role gated PATCH does).

-- 1) Per-character Locker-Room access flag (default: not owned).
alter table public.characters add column if not exists locker_unlocked boolean not null default false;

-- 2) PIN locker_unlocked against non-service_role writers (SECURITY). Without this a logged-in client could
--    PATCH locker_unlocked=true straight through PostgREST (RLS allows update-own; position columns stay
--    client-writable), unlocking the Locker Room for FREE — the exact money-printer class the
--    characters_guard_progression fix closed for credits/level/xp/practice_tokens. Re-create the guard with
--    locker_unlocked added to the pinned set (the BEFORE UPDATE trigger is already bound to this function).
create or replace function public.characters_guard_progression()
returns trigger language plpgsql as $$
begin
  -- service_role (the zone server) may change everything; any other writer (authenticated client) may only
  -- touch position columns — pin the economy/progression + Locker-Room columns to their prior values.
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    new.credits         := old.credits;
    new.level           := old.level;
    new.xp              := old.xp;
    new.practice_tokens := old.practice_tokens;
    new.locker_unlocked := old.locker_unlocked;
  end if;
  return new;
end;
$$;

-- 2b) PIN the same columns on INSERT (SECURITY — closes the OTHER half of the hole). The UPDATE guard above only
--     fires on UPDATE, but `authenticated`/`anon` hold INSERT + DELETE on characters (verified live), and there was
--     NO before-insert trigger. So a client could set credits/level/xp/practice_tokens/locker_unlocked to anything
--     at character CREATION (the client-side create_character POST — RLS insert-own has no column restriction), or
--     reset to a cheated character via DELETE-then-INSERT (delete-own is allowed; the cascade wipes their inventory
--     but not the economy grab). This pre-dates Builder Mode (it already exposed credits/level/xp/practice_tokens);
--     P0 would extend it to locker_unlocked, defeating the server-owns-the-unlock guarantee — so close it fully here.
--     New characters ALWAYS start at 0 credits / level 1 / 0 xp / 0 tokens / not-unlocked, so pinning these to their
--     safe starting values for any NON-service_role insert is a NO-OP for legitimate creation (name/class/position
--     are untouched). The zone server never inserts characters via a player token, and service_role bypasses this.
create or replace function public.characters_guard_insert()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    new.credits         := 0;
    new.level           := 1;
    new.xp              := 0;
    new.practice_tokens := 0;
    new.locker_unlocked := false;
  end if;
  return new;
end;
$$;
drop trigger if exists characters_guard_insert on public.characters;
create trigger characters_guard_insert
  before insert on public.characters
  for each row execute function public.characters_guard_insert();

-- 3) Build-item category + placement fields on the shared inventory table (single source of truth).
alter table public.inventory add column if not exists category text    not null default 'gear';
alter table public.inventory add column if not exists model    text;                          -- prop id (e.g. 'tree_oak'); null for gear
alter table public.inventory add column if not exists placed   boolean not null default false; -- currently placed in the Locker Room?
alter table public.inventory add column if not exists xform    jsonb;                          -- placement {x,y,h,yaw,oy}; null when unplaced

alter table public.inventory drop constraint if exists inventory_category_check;
alter table public.inventory add constraint inventory_category_check check (category in ('gear','build'));

-- allow the sentinel 'build' slot value (build items are non-gear + non-equippable; the slot column just carries
-- the marker so a build row still satisfies the NOT NULL slot column).
alter table public.inventory drop constraint if exists inventory_slot_check;
alter table public.inventory add constraint inventory_slot_check check (
  slot in ('head','chest','legs','hands','feet','main_hand','off_hand','neck','ring','trinket','build'));

-- shape invariants (defense-in-depth; the server validates too, this is the DB backstop):
--   build row → has a model, uses the 'build' slot, and if placed carries an xform.
--   gear  row → never carries a model and is never 'placed' (so gear can NEVER leak into a Locker-Room render).
alter table public.inventory drop constraint if exists inventory_build_shape_check;
alter table public.inventory add constraint inventory_build_shape_check check (
  case
    when category = 'build' then model is not null and slot = 'build' and (placed = false or xform is not null)
    else model is null and placed = false
  end);

-- fast per-character build lookups (Build-tab list, owned-cap count, Locker-Room placed render). Partial → tiny.
create index if not exists inventory_build_idx on public.inventory(character_id) where category = 'build';
