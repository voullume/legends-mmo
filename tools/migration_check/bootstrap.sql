-- Migration-check bootstrap (stabilization follow-up): the MINIMAL Supabase-runtime stubs a clean
-- vanilla Postgres needs before `supabase/migrations/*.sql` can apply in order — the three API
-- roles, the `auth` schema with a `users` table, and `auth.uid()`. Used by the clean-database
-- migration verification (see assertions.sql header for the exact commands). NEVER run this
-- against a real Supabase project — there these objects already exist and are managed by Supabase.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  email_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Supabase resolves the caller's JWT subject; the stub reads the same GUC PostgREST would set.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema public to anon, authenticated, service_role;
