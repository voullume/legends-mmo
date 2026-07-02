-- SECURITY FIX (critical): the characters table was client-writable for ALL columns. The
-- `characters_update_own` RLS policy (auth.uid() = user_id) plus the standing UPDATE grant to the
-- `authenticated` role let any logged-in client PATCH their OWN row's economy/progression columns
-- (credits / level / xp / practice_tokens) straight through PostgREST with the public anon key + their
-- own access token — a money-printer + free-progression + effectively-infinite-HP (huge level) exploit,
-- bypassing the entire server-authoritative economy. (inventory / character_quests / materials were all
-- locked to server-only writes; characters was missed because the zone server persisted via the PLAYER
-- token, which required client UPDATE.)
--
-- Fix: the zone server now saves via service_role (Supabase.gd save_character_as), so clients no longer
-- need write access to those columns. Rather than revoke UPDATE outright (which would break the local
-- single-player dev autosave of position — Client.gd _save_progress writes last_x/last_y/last_map with the
-- player token), a BEFORE UPDATE trigger PINS the economy/progression columns to their old values for any
-- non-service_role writer. Position columns stay client-writable; credits/level/xp/practice_tokens can only
-- change via the service_role zone server. service_role writes bypass RLS AND this trigger, so the server is
-- unaffected.
--
-- DEPLOY ORDERING (no downtime): deploy the server code that saves via service_role FIRST (it works under
-- the current permissive policy), THEN apply this migration (it is a no-op for the service_role server and
-- closes the client hole). Applying this BEFORE the server switch would silently pin the server's own
-- progression saves (the server currently writes with the player token). Do NOT apply to live until the
-- service_role save is deployed.

create or replace function public.characters_guard_progression()
returns trigger language plpgsql as $$
begin
  -- service_role (the zone server) may change everything; any other writer (authenticated client) may only
  -- touch position columns — pin the economy/progression columns to their prior values.
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    new.credits         := old.credits;
    new.level           := old.level;
    new.xp              := old.xp;
    new.practice_tokens := old.practice_tokens;
  end if;
  return new;
end;
$$;

drop trigger if exists characters_guard_progression on public.characters;
create trigger characters_guard_progression
  before update on public.characters
  for each row execute function public.characters_guard_progression();

-- Defense-in-depth bounds (safe on existing data: all live rows are >= 0 / level >= 1). No upper bound on
-- credits (legitimately large from long play); level's upper bound is enforced in code (authenticate clamps
-- 1..99) rather than a CHECK, so an already-tampered row can't block this migration from applying.
alter table public.characters drop constraint if exists characters_nonneg_check;
alter table public.characters add constraint characters_nonneg_check
  check (credits >= 0 and xp >= 0 and practice_tokens >= 0 and level >= 1);
