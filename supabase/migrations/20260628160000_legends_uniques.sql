-- Phase 6 (item system): uniques + procs. A unique item carries a fixed identity (unique_id) and a
-- signature combat effect (proc_id, scaled by proc_tier). Effect/proc content lives in GameData
-- (PROC_CATALOG / UNIQUE_DEFS), NOT in migrations — so unique_id/proc_id are validated by the server,
-- not a DB CHECK (content can change without a schema change). proc_tier is bounded.
alter table public.inventory add column if not exists unique_id  text;
alter table public.inventory add column if not exists proc_id    text;
alter table public.inventory add column if not exists proc_tier  int not null default 0 check (proc_tier between 0 and 5);
