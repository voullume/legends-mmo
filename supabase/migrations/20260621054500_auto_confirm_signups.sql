-- No SMTP is configured on this project, so email confirmation can't complete and unconfirmed
-- accounts can't log in. Auto-confirm new signups (project-wide) so accounts are usable
-- immediately. To re-enable real email confirmation, drop this trigger and configure SMTP.
create or replace function public.auto_confirm_user()
returns trigger language plpgsql as $$
begin
  if new.email_confirmed_at is null then
    new.email_confirmed_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists auto_confirm_on_signup on auth.users;
create trigger auto_confirm_on_signup
  before insert on auth.users
  for each row execute function public.auto_confirm_user();

-- one-time backfill: confirm accounts that were created before this trigger existed
update auth.users set email_confirmed_at = now() where email_confirmed_at is null;
