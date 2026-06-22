-- Admin allow-list for the in-game god-mode tools. RLS is enabled with NO policies, so the
-- authenticated/anon roles can't read or write it — only the zone server (service_role) checks it.
-- An account is admin iff its user_id is present here; populate it manually (or via service role).
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
