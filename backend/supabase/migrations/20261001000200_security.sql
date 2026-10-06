-- Row level security: members see only their own rows. Financial and booking tables have
-- no insert/update policies at all, so the only way to change them is through the functions.

alter table public.gym_settings          enable row level security;
alter table public.profiles              enable row level security;
alter table public.trainers              enable row level security;
alter table public.trainer_hours         enable row level security;
alter table public.trainer_reviews       enable row level security;
alter table public.membership_plans      enable row level security;
alter table public.pt_packages           enable row level security;
alter table public.orders                enable row level security;
alter table public.memberships           enable row level security;
alter table public.owned_packages        enable row level security;
alter table public.pt_sessions           enable row level security;
alter table public.receipts              enable row level security;
alter table public.notifications         enable row level security;
alter table public.notification_prefs    enable row level security;
alter table public.announcements         enable row level security;
alter table public.support_tickets       enable row level security;
alter table public.support_messages      enable row level security;
alter table public.data_export_requests  enable row level security;
alter table public.audit_log             enable row level security;

-- Catalogue: readable by any signed-in member.
create policy "settings readable" on public.gym_settings for select to authenticated using (true);
create policy "trainers readable" on public.trainers for select to authenticated using (is_active);
create policy "hours readable" on public.trainer_hours for select to authenticated using (true);
create policy "reviews readable" on public.trainer_reviews for select to authenticated using (true);
create policy "plans readable" on public.membership_plans for select to authenticated using (is_active);
create policy "packages readable" on public.pt_packages for select to authenticated using (is_active);
create policy "announcements readable" on public.announcements for select to authenticated using (is_published);

-- Own rows only.
create policy "own profile" on public.profiles for select to authenticated using (id = auth.uid());
create policy "edit own profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "own orders" on public.orders for select to authenticated using (member_id = auth.uid());
create policy "own memberships" on public.memberships for select to authenticated using (member_id = auth.uid());
create policy "own packages" on public.owned_packages for select to authenticated using (member_id = auth.uid());
create policy "own sessions" on public.pt_sessions for select to authenticated using (member_id = auth.uid());
create policy "own receipts" on public.receipts for select to authenticated using (member_id = auth.uid());
create policy "own notifications" on public.notifications for select to authenticated using (member_id = auth.uid());
create policy "own prefs read" on public.notification_prefs for select to authenticated using (member_id = auth.uid());
create policy "own prefs insert" on public.notification_prefs for insert to authenticated with check (member_id = auth.uid());
create policy "own prefs update" on public.notification_prefs for update to authenticated
  using (member_id = auth.uid()) with check (member_id = auth.uid());
create policy "own tickets" on public.support_tickets for select to authenticated using (member_id = auth.uid());
create policy "own ticket messages" on public.support_messages for select to authenticated
  using (exists (select 1 from public.support_tickets t where t.id = ticket_id and t.member_id = auth.uid()));

-- Payment and booking receipts can't be switched off.
alter table public.notification_prefs add constraint payments_always_on check (type <> 'payments' or push);

-- Members may edit only these profile columns. In particular, never their own role.
revoke update on public.profiles from authenticated, anon;
grant update (first_name, last_name, email, date_of_birth, goal, experience,
              trainer_sees_goals, share_progress_photos) on public.profiles to authenticated;

-- Nothing for signed-out visitors.
revoke all on all tables in schema public from anon;

-- Functions: PostgreSQL lets everyone execute new functions by default. Lock that down.
revoke execute on all functions in schema public from public, anon;

grant execute on function
  public.available_slots(uuid, date, uuid),
  public.hold_slot(uuid, timestamptz),
  public.confirm_booking(uuid, uuid),
  public.reschedule_session(uuid, timestamptz),
  public.cancel_session(uuid),
  public.create_order(text, uuid, uuid, uuid, text),
  public.home_summary(),
  public.usable_package(uuid),
  public.mark_notifications_read(),
  public.open_support_ticket(text, text),
  public.send_support_message(uuid, text),
  public.request_data_export()
to authenticated;

-- Server only. The app can never mark an order paid or activate a membership.
revoke execute on function
  public.settle_order(uuid, text, text),
  public.mark_order_failed(uuid),
  public.anonymise_member(uuid),
  public._book_from_hold(uuid, uuid),
  public.expire_holds(),
  public.notify_member(uuid, text, text, text),
  public.session_json(public.pt_sessions),
  public.owned_package_json(public.owned_packages)
from authenticated;

grant execute on function
  public.settle_order(uuid, text, text),
  public.mark_order_failed(uuid),
  public.anonymise_member(uuid)
to service_role;

-- Functions created later are not executable by members unless granted explicitly.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
