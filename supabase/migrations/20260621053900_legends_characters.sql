-- Legends MMO — one character per account; class chosen at creation and immutable.
create table if not exists public.characters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  class text not null check (class in
    ('pitcher','batter','quarterback','linebacker','setter','spiker','striker','goalkeeper')),
  level int not null default 1,
  xp int not null default 0,
  last_map text not null default 'stadium',
  last_x double precision not null default 480,
  last_y double precision not null default 270,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)               -- exactly one character (one class) per account
);

alter table public.characters enable row level security;

create policy "characters_select_own" on public.characters
  for select using (auth.uid() = user_id);
create policy "characters_insert_own" on public.characters
  for insert with check (auth.uid() = user_id);
create policy "characters_update_own" on public.characters
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "characters_delete_own" on public.characters
  for delete using (auth.uid() = user_id);

-- the class lock: it can never be changed after the character is created
create or replace function public.lock_character_class()
returns trigger language plpgsql as $$
begin
  if new.class is distinct from old.class then
    raise exception 'character class is immutable (one class per account)';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger characters_lock_class
  before update on public.characters
  for each row execute function public.lock_character_class();
