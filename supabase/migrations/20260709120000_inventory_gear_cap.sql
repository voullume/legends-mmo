-- Hard 50-item cap on a character's GEAR inventory (category <> 'build'; build items keep their own
-- BUILD_OWNED_CAP=50, enforced server-side). Belt-and-suspenders at the DB layer like characters_guard_*:
-- every server add path funnels through a service_role INSERT, so a BEFORE-INSERT trigger covers them all
-- (loot / shop / craft / quest / admin-give) with no per-path code and no redeploy.
--
-- When full we RAISE (not RETURN NULL): a silent skip returns HTTP 201, which the server reads as success —
-- fine for loot but it would make a shop/craft buy SILENTLY EAT the credits/scrap (those paths deduct up
-- front and only refund when add_item_as returns ok=false). Raising a check_violation → PostgREST 4xx →
-- add_item_as ok=false → loot cleanly skips its "you looted X" toast and every paid path refunds.
create or replace function public.inventory_gear_cap()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  gear_count int;
begin
  if coalesce(new.category, 'gear') <> 'build' then
    select count(*) into gear_count from public.inventory
      where character_id = new.character_id and coalesce(category, 'gear') <> 'build';
    if gear_count >= 50 then
      raise exception 'inventory full: 50-item gear cap reached for character %', new.character_id
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists inventory_gear_cap_trg on public.inventory;
create trigger inventory_gear_cap_trg
  before insert on public.inventory
  for each row execute function public.inventory_gear_cap();
