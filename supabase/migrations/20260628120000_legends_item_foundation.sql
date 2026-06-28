-- Phase 2 (item system): the deep item-model foundation. Additive + legacy-safe — existing rows are
-- remapped/backfilled, the legacy bonus_* columns are KEPT one release as a fallback (server reads
-- primary_* first, then bonus_*). New columns: primary_stat/primary_amt (rename of bonus_*), ilvl,
-- affixes (jsonb [{stat,amt}]), item_power (denormalized score the server sets on write).
--
-- Slots: 10 item-TYPE values. There are 11 EQUIP slots because `ring` has equip capacity 2 — that
-- capacity is enforced server-side (Server.gd SLOT_CAP), so the column only needs the 10 type strings.

-- 1) Remap legacy slot values BEFORE the strict CHECK (live data is only weapon/armor/trinket today).
update public.inventory set slot = 'main_hand' where slot = 'weapon';
update public.inventory set slot = 'chest'     where slot = 'armor';

-- 2) New columns (safe defaults; legacy rows keep working).
alter table public.inventory add column if not exists primary_stat text;
alter table public.inventory add column if not exists primary_amt  int   not null default 0;
alter table public.inventory add column if not exists ilvl         int   not null default 1;
alter table public.inventory add column if not exists affixes      jsonb not null default '[]'::jsonb;
alter table public.inventory add column if not exists item_power   int   not null default 0;

-- 3) Backfill from legacy bonus_* (guards keep a re-run idempotent).
update public.inventory
  set primary_stat = coalesce(primary_stat, bonus_stat),
      primary_amt  = case when primary_amt = 0 then bonus_amt else primary_amt end
  where primary_stat is null or primary_amt = 0;
update public.inventory set item_power = primary_amt + ilvl where item_power = 0;

-- 4) Constraints (data already conforms after steps 1-3).
alter table public.inventory drop constraint if exists inventory_slot_check;
alter table public.inventory add constraint inventory_slot_check check (
  slot in ('head','chest','legs','hands','feet','main_hand','off_hand','neck','ring','trinket'));

alter table public.inventory drop constraint if exists inventory_rarity_check;
alter table public.inventory add constraint inventory_rarity_check check (
  rarity in ('common','uncommon','rare','epic','legendary','mythic'));

alter table public.inventory drop constraint if exists inventory_ilvl_check;
alter table public.inventory add constraint inventory_ilvl_check check (ilvl between 1 and 80);

alter table public.inventory drop constraint if exists inventory_affixes_check;
alter table public.inventory add constraint inventory_affixes_check check (
  jsonb_typeof(affixes) = 'array' and jsonb_array_length(affixes) <= 4);
