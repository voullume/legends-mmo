-- SECURITY (gameplay-length P2): the level-gated ability kits grandfather EXISTING characters (created before
-- the gate epoch) to the full kit by reading characters.created_at server-side. But created_at was NOT pinned
-- against client writes — unlike credits / level / xp / practice_tokens / locker_unlocked — so a logged-in client
-- could PATCH its OWN created_at to a pre-epoch value (or set it in the create_character INSERT) straight through
-- PostgREST with the public anon key + its own token, and self-grandfather the full kit (incl. the ultimate) at
-- level 1 — fully defeating the gate. This is the same client-writable-column class the characters_guard_progression
-- / characters_guard_insert fixes closed for the economy/progression columns; extend BOTH guards to created_at so
-- it becomes a trustworthy server-authoritative signal for the grandfather decision.
--
-- NO-OP for legitimate use: the zone server writes via service_role (bypasses RLS + these triggers); existing
-- created_at values are preserved on UPDATE; a non-service_role INSERT gets now() (also the column default). No
-- ordering hazard — safe to apply before or after the server redeploy / client re-export.

-- UPDATE guard: pin created_at to its prior value for any non-service_role writer (adds to the existing pinned set).
create or replace function public.characters_guard_progression()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    new.credits         := old.credits;
    new.level           := old.level;
    new.xp              := old.xp;
    new.practice_tokens := old.practice_tokens;
    new.locker_unlocked := old.locker_unlocked;
    new.created_at      := old.created_at;   -- gameplay-length P2: pin so the ability-gate grandfather signal can't be backdated
  end if;
  return new;
end;
$$;

-- INSERT guard: force created_at = now() for any non-service_role insert (ignore a client-supplied value).
create or replace function public.characters_guard_insert()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    new.credits         := 0;
    new.level           := 1;
    new.xp              := 0;
    new.practice_tokens := 0;
    new.locker_unlocked := false;
    new.created_at      := now();   -- gameplay-length P2: a new character is created NOW; ignore any client-supplied created_at (anti self-grandfather)
  end if;
  return new;
end;
$$;
