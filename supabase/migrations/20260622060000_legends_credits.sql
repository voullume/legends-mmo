-- Credits: the single earned currency (no trading — earn from kills, spend/sell at the home shop).
-- Server-authoritative: only the zone server (service_role) and the owning player's RLS-scoped writes
-- touch it; the server persists it alongside xp/level on save_character.
alter table public.characters add column if not exists credits integer not null default 0;
