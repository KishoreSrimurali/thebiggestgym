-- Adds username + password sign-in on top of email. Members and staff can log in with
-- either their email or a chosen username; a staff account is still created by hand in
-- the Supabase dashboard (Authentication -> Users -> Add user) and gets its profiles row
-- from the same handle_new_user() trigger as a member who signs up through the site.

alter table public.profiles add column if not exists username text;

create unique index if not exists profiles_username_unique
  on public.profiles (lower(username))
  where username is not null;

-- Same body as the staff migration's version (20261001000300_staff.sql), plus setting
-- username from raw_user_meta_data->>'username' when the sign-up supplied one.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  full_name text := trim(coalesce(meta->>'full_name', meta->>'name', ''));
  first text := coalesce(nullif(meta->>'given_name', ''), split_part(full_name, ' ', 1));
  last text := coalesce(nullif(meta->>'family_name', ''),
                        case when position(' ' in full_name) > 0 then substr(full_name, position(' ' in full_name) + 1) else '' end);
  uname text := nullif(trim(meta->>'username'), '');
begin
  insert into public.profiles (id, email, phone, first_name, last_name, username)
  values (new.id, new.email, nullif(new.phone, ''), coalesce(first, ''), coalesce(last, ''), uname);
  insert into public.notifications (member_id, title, body, icon)
  values (new.id, 'Welcome to The Biggest Gym', 'Choose a membership to start training.', 'hand.wave');
  return new;
end $$;

-- Lets a signed-out visitor resolve a username to the email Supabase Auth needs for
-- signInWithPassword, without granting any broader access to the profiles table.
create or replace function public.email_for_username(p_username text) returns text
language sql stable security definer set search_path = public as $$
  select email from public.profiles where lower(username) = lower(p_username) limit 1;
$$;

grant execute on function public.email_for_username(text) to anon, authenticated;
