-- RP4: bot_reports — an append-only log where the AI residents (automated playtesters) record anomalies they
-- hit while playing (no combat progress in a zone despite live mobs; repeated deaths in one zone). Written by
-- the zone server via the service_role key (bypasses RLS); dev-only — clients have no access (query via the
-- dashboard / service_role). Mirrors the leaderboards access model + character_quests' id/created_at shape.
create table if not exists public.bot_reports (
	id uuid primary key default gen_random_uuid(),
	created_at timestamptz not null default now(),
	resident_id text not null,
	resident_name text not null,
	zone text not null,
	kind text not null,             -- 'no_progress' | 'repeated_death'
	detail text,
	metrics jsonb not null default '{}'::jsonb
);
create index if not exists bot_reports_created_idx on public.bot_reports(created_at desc);
create index if not exists bot_reports_kind_idx on public.bot_reports(kind, created_at desc);

alter table public.bot_reports enable row level security;
-- no client policy → RLS default-denies every client; only service_role (the zone server) can write/read.
revoke select, insert, update, delete on public.bot_reports from authenticated, anon;
