-- Legends MMO: per-character item inventory (loot). RLS scopes rows to characters the user owns.
create table if not exists public.inventory (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  name text not null,
  rarity text not null,
  slot text not null,
  bonus_stat text,
  bonus_amt int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists inventory_character_idx on public.inventory(character_id);

alter table public.inventory enable row level security;

create policy "inventory_select_own" on public.inventory for select
  using (exists (select 1 from public.characters c where c.id = inventory.character_id and c.user_id = auth.uid()));
create policy "inventory_insert_own" on public.inventory for insert
  with check (exists (select 1 from public.characters c where c.id = inventory.character_id and c.user_id = auth.uid()));
create policy "inventory_delete_own" on public.inventory for delete
  using (exists (select 1 from public.characters c where c.id = inventory.character_id and c.user_id = auth.uid()));
