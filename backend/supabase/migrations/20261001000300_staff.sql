-- Coach panel: staff (trainer, receptionist, admin, owner) can see and manage everything.
-- Safeguards: every change is written to audit_log with who made it; only owners/admins can change
-- roles; receipts are never edited (refunds are recorded, not rewritten).

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------

create function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and deleted_at is null
$$;

create function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role() in ('trainer', 'receptionist', 'admin', 'owner'), false)
$$;

create function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role() in ('admin', 'owner'), false)
$$;

create function public.require_staff() returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  return auth.uid();
end $$;

-- Names from Google (full_name / given_name) or Apple fill the profile on first sign-in.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  full_name text := trim(coalesce(meta->>'full_name', meta->>'name', ''));
  first text := coalesce(nullif(meta->>'given_name', ''), split_part(full_name, ' ', 1));
  last text := coalesce(nullif(meta->>'family_name', ''),
                        case when position(' ' in full_name) > 0 then substr(full_name, position(' ' in full_name) + 1) else '' end);
begin
  insert into public.profiles (id, email, phone, first_name, last_name)
  values (new.id, new.email, nullif(new.phone, ''), coalesce(first, ''), coalesce(last, ''));
  insert into public.notifications (member_id, title, body, icon)
  values (new.id, 'Welcome to The Biggest Gym', 'Choose a membership to start training.', 'hand.wave');
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Audit trail for everything staff edit directly in tables
-- ---------------------------------------------------------------------------

alter table public.audit_log add column if not exists entity_key text;
create index if not exists audit_log_created on public.audit_log (created_at desc);

create function public.audit_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  row_new jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
  row_old jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
  key text := coalesce(row_new->>'id', row_old->>'id', row_new->>'trainer_id', row_old->>'trainer_id');
begin
  insert into audit_log (actor_id, action, entity, entity_key, entity_id, detail)
  values (auth.uid(), lower(tg_op), tg_table_name, key,
          case when key ~ '^[0-9a-f-]{36}$' then key::uuid end,
          jsonb_strip_nulls(jsonb_build_object('before', row_old, 'after', row_new)));
  return coalesce(new, old);
end $$;

create trigger audit_trainers after insert or update or delete on public.trainers for each row execute function public.audit_change();
create trigger audit_trainer_hours after insert or update or delete on public.trainer_hours for each row execute function public.audit_change();
create trigger audit_plans after insert or update or delete on public.membership_plans for each row execute function public.audit_change();
create trigger audit_packages after insert or update or delete on public.pt_packages for each row execute function public.audit_change();
create trigger audit_announcements after insert or update or delete on public.announcements for each row execute function public.audit_change();
create trigger audit_settings after update on public.gym_settings for each row execute function public.audit_change();
create trigger audit_reviews after insert or update or delete on public.trainer_reviews for each row execute function public.audit_change();

create function public.log_staff(p_action text, p_entity text, p_id uuid, p_detail jsonb default '{}') returns void
language sql security definer set search_path = public as $$
  insert into audit_log (actor_id, action, entity, entity_id, entity_key, detail)
  values (auth.uid(), p_action, p_entity, p_id, p_id::text, p_detail)
$$;

-- ---------------------------------------------------------------------------
-- Staff access rules (added to the member rules; any matching policy allows)
-- ---------------------------------------------------------------------------

create policy "staff read profiles" on public.profiles for select to authenticated using (is_staff());
create policy "staff read memberships" on public.memberships for select to authenticated using (is_staff());
create policy "staff read packages owned" on public.owned_packages for select to authenticated using (is_staff());
create policy "staff read sessions" on public.pt_sessions for select to authenticated using (is_staff());
create policy "staff read orders" on public.orders for select to authenticated using (is_staff());
create policy "staff read receipts" on public.receipts for select to authenticated using (is_staff());
create policy "staff read tickets" on public.support_tickets for select to authenticated using (is_staff());
create policy "staff read messages" on public.support_messages for select to authenticated using (is_staff());
create policy "staff read audit" on public.audit_log for select to authenticated using (is_staff());
create policy "staff read exports" on public.data_export_requests for select to authenticated using (is_staff());

-- Catalogue: staff can add, edit and remove.
create policy "staff manage trainers" on public.trainers for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff manage hours" on public.trainer_hours for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff manage reviews" on public.trainer_reviews for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff manage plans" on public.membership_plans for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff manage packages" on public.pt_packages for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff manage announcements" on public.announcements for all to authenticated using (is_staff()) with check (is_staff());
create policy "staff update settings" on public.gym_settings for update to authenticated using (is_staff()) with check (is_staff());

-- ---------------------------------------------------------------------------
-- Staff actions on members (functions, so every change is checked and logged)
-- ---------------------------------------------------------------------------

create function public.member_json(p_member uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(p) || jsonb_build_object(
    'membership', (
      select to_jsonb(m) || jsonb_build_object('plan_name', pl.name)
      from memberships m join membership_plans pl on pl.id = m.plan_id
      where m.member_id = p.id
      order by (m.status = 'active' and gym_today() between m.start_date and m.end_date) desc, m.end_date desc
      limit 1),
    'sessions_left', (
      select coalesce(sum(o.sessions_total - o.sessions_used), 0) from owned_packages o
      where o.member_id = p.id and o.expires_at > now()))
  from profiles p where p.id = p_member
$$;

create function public.staff_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s gym_settings;
  v_today date;
  v_month_start timestamptz;
begin
  perform require_staff();
  select * into s from gym_settings where id = 1;
  v_today := gym_today();
  v_month_start := (date_trunc('month', v_today)::timestamp) at time zone s.time_zone;
  return jsonb_build_object(
    'today', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ps.id, 'starts_at', ps.starts_at, 'ends_at', ps.ends_at, 'status', ps.status,
        'member_id', ps.member_id, 'member_name', trim(pr.first_name || ' ' || pr.last_name),
        'trainer_name', t.name) order by ps.starts_at)
      from pt_sessions ps join profiles pr on pr.id = ps.member_id join trainers t on t.id = ps.trainer_id
      where ps.status in ('booked', 'completed', 'no_show')
        and (ps.starts_at at time zone s.time_zone)::date = v_today), '[]'::jsonb),
    'active_members', (
      select count(distinct member_id) from memberships
      where status = 'active' and v_today between start_date and end_date),
    'expiring', coalesce((
      select jsonb_agg(jsonb_build_object('member_id', m.member_id,
        'member_name', trim(pr.first_name || ' ' || pr.last_name), 'end_date', m.end_date, 'plan', pl.name)
        order by m.end_date)
      from memberships m join profiles pr on pr.id = m.member_id join membership_plans pl on pl.id = m.plan_id
      where m.status = 'active' and m.end_date between v_today and v_today + 7
        and not exists (select 1 from memberships later where later.member_id = m.member_id
                        and later.status = 'active' and later.start_date > m.end_date)), '[]'::jsonb),
    'revenue_month_baisa', (
      select coalesce(sum(amount_baisa), 0) from receipts where status = 'success' and created_at >= v_month_start),
    'new_members_month', (select count(*) from profiles where created_at >= v_month_start and deleted_at is null),
    'open_tickets', (select count(*) from support_tickets where status = 'open'),
    'my_role', my_role()
  );
end $$;

create function public.staff_members(p_search text default '') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(member_json(p.id) order by p.first_name, p.last_name)
    from (select * from profiles
          where deleted_at is null
            and (lower(first_name || ' ' || last_name) like q or lower(coalesce(email, '')) like q or coalesce(phone, '') like q)
          order by first_name, last_name limit 200) p), '[]'::jsonb);
end $$;

create function public.staff_member_detail(p_member uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_staff();
  return member_json(p_member) || jsonb_build_object(
    'memberships', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('plan_name', pl.name) order by m.start_date desc)
                    from memberships m join membership_plans pl on pl.id = m.plan_id where m.member_id = p_member), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(to_jsonb(o) || jsonb_build_object('package_name', k.name, 'trainer_name', t.name) order by o.created_at desc)
                 from owned_packages o join pt_packages k on k.id = o.package_id join trainers t on t.id = o.trainer_id
                 where o.member_id = p_member), '[]'::jsonb),
    'sessions', coalesce((select jsonb_agg(to_jsonb(x) order by x.starts_at desc) from (
                   select ps.id, ps.starts_at, ps.ends_at, ps.status, ps.reschedule_count, t.name as trainer_name
                   from pt_sessions ps join trainers t on t.id = ps.trainer_id
                   where ps.member_id = p_member and ps.status <> 'held'
                   order by ps.starts_at desc limit 40) x), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
                 from receipts r where r.member_id = p_member), '[]'::jsonb)
  );
end $$;

create function public.staff_update_member(p_member uuid, p_first text, p_last text, p_phone text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform require_staff();
  update profiles set first_name = trim(p_first), last_name = trim(p_last),
         phone = nullif(trim(p_phone), ''), email = nullif(trim(p_email), '')
   where id = p_member and deleted_at is null;
  perform log_staff('member.updated', 'profiles', p_member, jsonb_build_object('first_name', p_first, 'last_name', p_last));
  return member_json(p_member);
end $$;

create function public.staff_set_role(p_member uuid, p_role public.app_role) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform require_staff();
  if not is_owner() then raise exception 'OWNER_ONLY' using errcode = '42501'; end if;
  if p_member = auth.uid() then raise exception 'CANNOT_CHANGE_OWN_ROLE'; end if;
  update profiles set role = p_role where id = p_member;
  perform log_staff('member.role_changed', 'profiles', p_member, jsonb_build_object('role', p_role));
  return member_json(p_member);
end $$;

-- Cash or card-machine payment taken at the gym. Goes through the same settlement as app payments,
-- so the member gets their membership or sessions and a numbered receipt.
create function public.staff_record_payment(p_member uuid, p_kind text, p_item uuid, p_trainer uuid default null,
                                            p_method text default 'Cash at reception') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s gym_settings;
  v_amount bigint;
  v_title text;
  v_order orders;
begin
  perform require_staff();
  select * into s from gym_settings where id = 1;
  if p_kind = 'membership' then
    select price_baisa, name || ' membership' into v_amount, v_title from membership_plans where id = p_item;
  elsif p_kind = 'pt_package' then
    select k.price_baisa, k.name || ' with ' || split_part(t.name, ' ', 1) into v_amount, v_title
    from pt_packages k, trainers t where k.id = p_item and t.id = p_trainer;
  end if;
  if v_amount is null then raise exception 'ITEM_UNAVAILABLE'; end if;

  insert into orders (member_id, kind, plan_id, package_id, trainer_id, title, amount_baisa, vat_baisa,
                      currency, provider, idempotency_key)
  values (p_member, p_kind,
          case when p_kind = 'membership' then p_item end,
          case when p_kind = 'pt_package' then p_item end,
          case when p_kind = 'pt_package' then p_trainer end,
          v_title, v_amount,
          (v_amount * s.vat_basis_points + (10000 + s.vat_basis_points) / 2) / (10000 + s.vat_basis_points),
          s.currency, 'in_person', 'staff-' || gen_random_uuid())
  returning * into v_order;

  perform settle_order(v_order.id, 'in-person-' || left(v_order.id::text, 8), coalesce(nullif(trim(p_method), ''), 'Cash at reception'));
  perform log_staff('payment.recorded', 'orders', v_order.id,
    jsonb_build_object('member', p_member, 'amount_baisa', v_amount, 'method', p_method));
  return staff_member_detail(p_member);
end $$;

-- Free or courtesy membership (no payment, no receipt). Logged.
create function public.staff_grant_membership(p_member uuid, p_plan uuid, p_start date, p_end date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform require_staff();
  insert into memberships (member_id, plan_id, start_date, end_date, status)
  values (p_member, p_plan, p_start, p_end, 'active') returning id into v_id;
  perform log_staff('membership.granted', 'memberships', v_id, jsonb_build_object('member', p_member, 'start', p_start, 'end', p_end));
  perform notify_member(p_member, 'Membership updated', 'Active until ' || to_char(p_end, 'FMDD Mon YYYY') || '.', 'checkmark.seal');
  return staff_member_detail(p_member);
end $$;

-- Extend, freeze or cancel a membership.
create function public.staff_update_membership(p_membership uuid, p_end date, p_status public.membership_status) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v memberships;
begin
  perform require_staff();
  update memberships set end_date = p_end, status = p_status where id = p_membership returning * into v;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform log_staff('membership.updated', 'memberships', p_membership, jsonb_build_object('end', p_end, 'status', p_status));
  perform notify_member(v.member_id, 'Membership updated',
    case p_status when 'frozen' then 'Your membership is paused.'
                  when 'cancelled' then 'Your membership was cancelled. Contact reception with any questions.'
                  else 'Now ends ' || to_char(p_end, 'FMDD Mon YYYY') || '.' end, 'person.text.rectangle');
  return staff_member_detail(v.member_id);
end $$;

create function public.staff_update_package(p_package uuid, p_total int, p_used int, p_expires date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v owned_packages; s gym_settings;
begin
  perform require_staff();
  select * into s from gym_settings where id = 1;
  update owned_packages
     set sessions_total = p_total, sessions_used = p_used,
         expires_at = ((p_expires + 1)::timestamp) at time zone s.time_zone
   where id = p_package returning * into v;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform log_staff('package.updated', 'owned_packages', p_package, jsonb_build_object('total', p_total, 'used', p_used, 'expires', p_expires));
  return staff_member_detail(v.member_id);
end $$;

-- Book on a member's behalf (e.g. at reception). Gym hours aren't enforced for staff,
-- but the database still refuses any overlap for the trainer or the member.
create function public.staff_book_session(p_member uuid, p_trainer uuid, p_starts_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s gym_settings;
  t trainers;
  v_pkg owned_packages;
  v_id uuid;
begin
  perform require_staff();
  select * into s from gym_settings where id = 1;
  select * into t from trainers where id = p_trainer;
  select * into v_pkg from owned_packages
   where member_id = p_member and trainer_id = p_trainer and sessions_used < sessions_total and expires_at > now()
   order by expires_at limit 1 for update;
  if not found then raise exception 'NO_CREDITS'; end if;
  perform expire_holds();
  begin
    insert into pt_sessions (member_id, trainer_id, owned_package_id, starts_at, ends_at, buffer_ends_at, status)
    values (p_member, p_trainer, v_pkg.id, p_starts_at,
            p_starts_at + make_interval(mins => t.session_minutes),
            p_starts_at + make_interval(mins => t.session_minutes + s.buffer_minutes), 'booked')
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE';
  end;
  update owned_packages set sessions_used = sessions_used + 1 where id = v_pkg.id;
  perform notify_member(p_member, 'PT session booked', t.name || ', ' || gym_when(p_starts_at) || '.', 'calendar.badge.checkmark');
  perform log_staff('session.booked', 'pt_sessions', v_id, jsonb_build_object('member', p_member, 'trainer', p_trainer, 'starts_at', p_starts_at));
  return jsonb_build_object('id', v_id);
end $$;

create function public.staff_move_session(p_session uuid, p_starts_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v pt_sessions; s gym_settings; t trainers;
begin
  perform require_staff();
  select * into s from gym_settings where id = 1;
  select * into v from pt_sessions where id = p_session and status = 'booked' for update;
  if not found then raise exception 'SESSION_NOT_ACTIVE'; end if;
  select * into t from trainers where id = v.trainer_id;
  begin
    update pt_sessions set starts_at = p_starts_at,
           ends_at = p_starts_at + make_interval(mins => t.session_minutes),
           buffer_ends_at = p_starts_at + make_interval(mins => t.session_minutes + s.buffer_minutes),
           updated_at = now()
     where id = p_session;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE';
  end;
  perform notify_member(v.member_id, 'Session moved', 'Now ' || gym_when(p_starts_at) || '.', 'calendar');
  perform log_staff('session.moved', 'pt_sessions', p_session, jsonb_build_object('from', v.starts_at, 'to', p_starts_at));
  return jsonb_build_object('id', p_session);
end $$;

-- Mark attended, missed or cancelled. Cancelling can return the credit.
create function public.staff_set_session_status(p_session uuid, p_status public.session_status, p_return_credit boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v pt_sessions;
begin
  perform require_staff();
  if p_status not in ('completed', 'no_show', 'cancelled', 'late_cancelled', 'booked') then raise exception 'BAD_STATUS'; end if;
  select * into v from pt_sessions where id = p_session for update;
  if not found or v.status = 'held' then raise exception 'NOT_FOUND'; end if;
  update pt_sessions set status = p_status, updated_at = now() where id = p_session;
  if p_status = 'cancelled' and p_return_credit and v.status in ('booked', 'completed', 'no_show', 'late_cancelled') then
    update owned_packages set sessions_used = greatest(sessions_used - 1, 0) where id = v.owned_package_id;
  end if;
  if p_status in ('cancelled', 'late_cancelled') then
    perform notify_member(v.member_id, 'Session cancelled by the gym',
      gym_when(v.starts_at) || case when p_return_credit then '. The session is back in your package.' else '.' end, 'calendar.badge.minus');
  end if;
  perform log_staff('session.status', 'pt_sessions', p_session, jsonb_build_object('from', v.status, 'to', p_status, 'credit_returned', p_return_credit));
  return jsonb_build_object('id', p_session, 'status', p_status);
end $$;

create function public.staff_reply_ticket(p_ticket uuid, p_body text, p_resolve boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v support_tickets;
begin
  perform require_staff();
  update support_tickets set status = case when p_resolve then 'resolved'::support_status else 'waiting'::support_status end,
         updated_at = now()
   where id = p_ticket returning * into v;
  if not found then raise exception 'NOT_FOUND'; end if;
  if length(trim(coalesce(p_body, ''))) > 0 then
    insert into support_messages (ticket_id, sender_id, from_member, body) values (p_ticket, auth.uid(), false, trim(p_body));
    perform notify_member(v.member_id, 'Reply from the gym', left(trim(p_body), 120), 'bubble.left.and.bubble.right');
  end if;
  return to_jsonb(v);
end $$;

-- Records a refund. The money itself is returned in the Thawani dashboard or at the till.
-- The original receipt is kept and marked refunded; what the payment granted is withdrawn.
create function public.staff_refund_order(p_order uuid, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  perform require_staff();
  select * into o from orders where id = p_order for update;
  if not found or o.status <> 'success' then raise exception 'ORDER_NOT_REFUNDABLE'; end if;
  update orders set status = 'refunded' where id = p_order;
  update receipts set status = 'refunded' where order_id = p_order;
  update memberships set status = 'cancelled' where order_id = p_order;
  update owned_packages set expires_at = now() where order_id = p_order;
  update pt_sessions set status = 'cancelled', updated_at = now()
   where owned_package_id in (select id from owned_packages where order_id = p_order)
     and status = 'booked' and starts_at > now();
  perform notify_member(o.member_id, 'Refund recorded', o.title || ' was refunded.', 'arrow.uturn.backward');
  perform log_staff('order.refunded', 'orders', p_order, jsonb_build_object('note', p_note, 'amount_baisa', o.amount_baisa));
  return jsonb_build_object('id', p_order, 'status', 'refunded');
end $$;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

grant execute on function
  public.my_role(), public.is_staff(),
  public.staff_dashboard(), public.staff_members(text), public.staff_member_detail(uuid),
  public.staff_update_member(uuid, text, text, text, text), public.staff_set_role(uuid, public.app_role),
  public.staff_record_payment(uuid, text, uuid, uuid, text), public.staff_grant_membership(uuid, uuid, date, date),
  public.staff_update_membership(uuid, date, public.membership_status), public.staff_update_package(uuid, int, int, date),
  public.staff_book_session(uuid, uuid, timestamptz), public.staff_move_session(uuid, timestamptz),
  public.staff_set_session_status(uuid, public.session_status, boolean),
  public.staff_reply_ticket(uuid, text, boolean), public.staff_refund_order(uuid, text)
to authenticated;

revoke execute on function public.audit_change(), public.log_staff(text, text, uuid, jsonb),
  public.member_json(uuid), public.is_owner(), public.require_staff() from authenticated;

-- Staff need to see inactive plans and trainers too (members still only see active ones).
create policy "staff read all trainers" on public.trainers for select to authenticated using (is_staff());
create policy "staff read all plans" on public.membership_plans for select to authenticated using (is_staff());
create policy "staff read all packages" on public.pt_packages for select to authenticated using (is_staff());
create policy "staff read all announcements" on public.announcements for select to authenticated using (is_staff());
