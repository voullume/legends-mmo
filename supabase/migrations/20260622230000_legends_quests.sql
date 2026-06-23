-- Legends MMO: per-character quest progress (kill-quest chain). Server-authoritative, mirroring the
-- inventory model: clients READ their own rows for the quest log; only the zone server (service_role,
-- from SUPABASE_SERVICE_KEY) WRITES — so progress/turn-ins can't be forged via direct REST.
create table if not exists public.character_quests (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  quest_id text not null,
  progress int not null default 0,
  completed boolean not null default false,
  rewarded boolean not null default false,    -- rewards granted? (turn-in sets it; gates reconnect re-grant)
  created_at timestamptz not null default now(),
  unique (character_id, quest_id)            -- one row per (character, quest); enables upsert
);
create index if not exists character_quests_character_idx on public.character_quests(character_id);

alter table public.character_quests enable row level security;

-- clients may READ their own quest progress (RLS-scoped to characters they own); no write policies →
-- authenticated/anon cannot insert/update/delete (service_role bypasses RLS for the zone server).
create policy "character_quests_select_own" on public.character_quests for select
  using (exists (select 1 from public.characters c where c.id = character_quests.character_id and c.user_id = auth.uid()));
revoke insert, update, delete on public.character_quests from authenticated, anon;
