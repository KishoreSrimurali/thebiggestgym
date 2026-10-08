-- Business rules. Every write a member can make goes through one of these functions;
-- members have no direct insert/update rights on bookings, orders or memberships.
-- Errors are raised with a stable code as the message (e.g. 'SLOT_UNAVAILABLE'), which the app maps
-- to a friendly explanation.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create function public.current_member() returns uuid
language plpgsql stable as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  return uid;
end $$;

create function public.gym_today() returns date
language sql stable as $$
  select (now() at time zone time_zone)::date from public.gym_settings where id = 1
$$;

create function public.has_active_membership(p_member uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from memberships m
    where m.member_id = p_member and m.status = 'active'
      and gym_today() between m.start_date and m.end_date
  )
$$;

-- Holds past their expiry stop blocking the slot.
create function public.expire_holds() returns void
language sql security definer set search_path = public as $$
  update pt_sessions set status = 'cancelled', updated_at = now()
  where status = 'held' and hold_expires_at <= now()
$$;

create function public.notify_member(p_member uuid, p_title text, p_body text, p_icon text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (member_id, title, body, icon) values (p_member, p_title, p_body, p_icon)
$$;

create function public.gym_when(p_at timestamptz) returns text
language sql stable set search_path = public as $$
  select to_char(p_at at time zone time_zone, 'Dy DD Mon, FMHH12:MI AM') from gym_settings where id = 1
$$;

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------

-- Free start times for a trainer on a gym-local day. A hint for the picker only:
-- the hold is what guarantees the time.
create function public.available_slots(p_trainer uuid, p_day date, p_exclude uuid default null)
returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  s gym_settings;
  t trainers;
  v_count int;
begin
  select * into s from gym_settings where id = 1;
  select * into t from trainers where id = p_trainer and is_active;
  if not found then return; end if;

  select count(*) into v_count
  from pt_sessions ps
  where ps.trainer_id = p_trainer
    and ps.status in ('held', 'booked')
    and ps.id is distinct from p_exclude
    and (ps.status <> 'held' or ps.hold_expires_at > now())
    and (ps.starts_at at time zone s.time_zone)::date = p_day;
  if v_count >= s.max_daily_sessions then return; end if;

  return query
  with windows as (
    select (p_day + h.start_time) at time zone s.time_zone as w_start,
           (p_day + h.end_time)   at time zone s.time_zone as w_end
    from trainer_hours h
    where h.trainer_id = p_trainer and h.weekday = extract(dow from p_day)::int
  ),
  candidates as (
    select g as c_start, g + make_interval(mins => t.session_minutes) as c_end
    from windows w,
         generate_series(w.w_start,
                         w.w_end - make_interval(mins => t.session_minutes),
                         make_interval(mins => s.slot_step_minutes)) as g
  )
  select c.c_start, c.c_end
  from candidates c
  where c.c_start >= now() + make_interval(mins => s.min_notice_minutes)
    and not exists (
      select 1 from pt_sessions ps
      where ps.trainer_id = p_trainer
        and ps.status in ('held', 'booked')
        and ps.id is distinct from p_exclude
        and (ps.status <> 'held' or ps.hold_expires_at > now())
        and tstzrange(ps.starts_at, ps.buffer_ends_at, '[)')
            && tstzrange(c.c_start, c.c_end + make_interval(mins => s.buffer_minutes), '[)')
    )
  order by c.c_start;
end $$;

-- ---------------------------------------------------------------------------
-- Booking
-- ---------------------------------------------------------------------------

create function public.hold_slot(p_trainer uuid, p_starts_at timestamptz) returns public.pt_sessions
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  s gym_settings;
  v_slot record;
  v_row pt_sessions;
begin
  select * into s from gym_settings where id = 1;
  if not has_active_membership(me) then
    raise exception 'MEMBERSHIP_INACTIVE';
  end if;

  perform expire_holds();
  -- One hold per member at a time: picking a new time releases the old one.
  update pt_sessions set status = 'cancelled', updated_at = now() where member_id = me and status = 'held';

  select * into v_slot
  from available_slots(p_trainer, (p_starts_at at time zone s.time_zone)::date) a
  where a.starts_at = p_starts_at;
  if not found then
    raise exception 'SLOT_UNAVAILABLE';
  end if;

  begin
    insert into pt_sessions (member_id, trainer_id, starts_at, ends_at, buffer_ends_at, status, hold_expires_at)
    values (me, p_trainer, v_slot.starts_at, v_slot.ends_at,
            v_slot.ends_at + make_interval(mins => s.buffer_minutes),
            'held', now() + make_interval(mins => s.hold_minutes))
    returning * into v_row;
  exception when exclusion_violation then
    -- Someone else's hold or booking committed first.
    raise exception 'SLOT_UNAVAILABLE';
  end;
  return v_row;
end $$;

-- Internal: turns a hold into a booking using one credit. Callers check ownership first.
create function public._book_from_hold(p_hold uuid, p_package uuid) returns public.pt_sessions
language plpgsql security definer set search_path = public as $$
declare
  v_row pt_sessions;
  v_trainer text;
begin
  update owned_packages set sessions_used = sessions_used + 1 where id = p_package;
  update pt_sessions
     set status = 'booked', owned_package_id = p_package, hold_expires_at = null, updated_at = now()
   where id = p_hold
  returning * into v_row;
  select name into v_trainer from trainers where id = v_row.trainer_id;
  perform notify_member(v_row.member_id, 'PT session booked', v_trainer || ', ' || gym_when(v_row.starts_at) || '.', 'calendar.badge.checkmark');
  return v_row;
end $$;

create function public.confirm_booking(p_hold uuid, p_owned_package uuid) returns public.pt_sessions
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  v_hold pt_sessions;
  v_pkg owned_packages;
begin
  select * into v_hold from pt_sessions where id = p_hold and member_id = me for update;
  if not found or v_hold.status <> 'held' or v_hold.hold_expires_at <= now() then
    raise exception 'HOLD_EXPIRED';
  end if;
  select * into v_pkg from owned_packages where id = p_owned_package and member_id = me for update;
  if not found or v_pkg.trainer_id <> v_hold.trainer_id or v_pkg.expires_at <= now()
     or v_pkg.sessions_used >= v_pkg.sessions_total then
    raise exception 'NO_CREDITS';
  end if;
  return _book_from_hold(v_hold.id, v_pkg.id);
end $$;

create function public.reschedule_session(p_session uuid, p_starts_at timestamptz) returns public.pt_sessions
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  s gym_settings;
  v pt_sessions;
  v_slot record;
begin
  select * into s from gym_settings where id = 1;
  select * into v from pt_sessions where id = p_session and member_id = me for update;
  if not found or v.status <> 'booked' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;
  if v.starts_at - now() < make_interval(hours => s.free_cancel_hours) then
    raise exception 'TOO_LATE_TO_CHANGE';
  end if;
  if v.reschedule_count >= s.max_reschedules then
    raise exception 'RESCHEDULE_LIMIT';
  end if;

  perform expire_holds();
  select * into v_slot
  from available_slots(v.trainer_id, (p_starts_at at time zone s.time_zone)::date, p_session) a
  where a.starts_at = p_starts_at;
  if not found then
    raise exception 'SLOT_UNAVAILABLE';
  end if;

  begin
    update pt_sessions
       set starts_at = v_slot.starts_at, ends_at = v_slot.ends_at,
           buffer_ends_at = v_slot.ends_at + make_interval(mins => s.buffer_minutes),
           reschedule_count = reschedule_count + 1, updated_at = now()
     where id = p_session
    returning * into v;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE';
  end;
  perform notify_member(me, 'Session moved', 'Now ' || gym_when(v.starts_at) || '.', 'calendar');
  return v;
end $$;

-- Returns true when the credit went back into the package.
create function public.cancel_session(p_session uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  s gym_settings;
  v pt_sessions;
  v_free boolean;
begin
  select * into s from gym_settings where id = 1;
  select * into v from pt_sessions where id = p_session and member_id = me for update;
  if not found or v.status <> 'booked' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;
  v_free := v.starts_at - now() >= make_interval(hours => s.free_cancel_hours);
  update pt_sessions
     set status = case when v_free then 'cancelled'::session_status else 'late_cancelled'::session_status end,
         updated_at = now()
   where id = p_session;
  if v_free then
    update owned_packages set sessions_used = sessions_used - 1 where id = v.owned_package_id;
  end if;
  perform notify_member(me, 'Session cancelled',
    case when v_free then 'Your session credit is back in your package.' else 'Late cancellation: the session was used.' end,
    'calendar.badge.minus');
  return v_free;
end $$;

-- ---------------------------------------------------------------------------
-- Orders and payments
-- ---------------------------------------------------------------------------

-- Creates (or returns, for a repeated idempotency key) a pending order. Prices are read here,
-- never taken from the app.
create function public.create_order(p_kind text, p_item uuid, p_trainer uuid default null,
                                    p_hold uuid default null, p_idempotency_key text default null)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  s gym_settings;
  v_existing orders;
  v_order orders;
  v_amount bigint;
  v_title text;
  v_plan membership_plans;
  v_pkg pt_packages;
  v_trainer trainers;
  v_hold pt_sessions;
begin
  if p_idempotency_key is null or length(p_idempotency_key) < 8 then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED';
  end if;
  select * into v_existing from orders where member_id = me and idempotency_key = p_idempotency_key;
  if found then return v_existing; end if;

  select * into s from gym_settings where id = 1;

  if p_kind = 'membership' then
    select * into v_plan from membership_plans where id = p_item and is_active;
    if not found then raise exception 'ITEM_UNAVAILABLE'; end if;
    v_amount := v_plan.price_baisa;
    v_title := v_plan.name || ' membership';
  elsif p_kind = 'pt_package' then
    select * into v_pkg from pt_packages where id = p_item and is_active;
    if not found then raise exception 'ITEM_UNAVAILABLE'; end if;
    select * into v_trainer from trainers where id = p_trainer and is_active;
    if not found then raise exception 'ITEM_UNAVAILABLE'; end if;
    if p_hold is not null then
      select * into v_hold from pt_sessions where id = p_hold and member_id = me;
      if not found or v_hold.status <> 'held' or v_hold.hold_expires_at <= now() or v_hold.trainer_id <> p_trainer then
        raise exception 'HOLD_EXPIRED';
      end if;
    end if;
    v_amount := v_pkg.price_baisa;
    v_title := v_pkg.name || ' with ' || split_part(v_trainer.name, ' ', 1);
  else
    raise exception 'ITEM_UNAVAILABLE';
  end if;

  begin
    insert into orders (member_id, kind, plan_id, package_id, trainer_id, hold_session_id, title,
                        amount_baisa, vat_baisa, currency, idempotency_key)
    values (me, p_kind, v_plan.id, v_pkg.id, v_trainer.id, p_hold, v_title, v_amount,
            -- VAT portion of a VAT-inclusive price, rounded to the nearest baisa.
            (v_amount * s.vat_basis_points + (10000 + s.vat_basis_points) / 2) / (10000 + s.vat_basis_points),
            s.currency, p_idempotency_key)
    returning * into v_order;
  exception when unique_violation then
    select * into v_order from orders where member_id = me and idempotency_key = p_idempotency_key;
  end;
  return v_order;
end $$;

-- Called ONLY by the server (edge function, service role) after the payment provider confirms.
-- Idempotent: a second call for a settled order changes nothing.
create function public.settle_order(p_order uuid, p_payment_id text, p_method text) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  s gym_settings;
  o orders;
  v_plan membership_plans;
  v_pkg pt_packages;
  v_start date;
  v_end date;
  v_current_end date;
  v_new_pkg uuid;
  v_hold pt_sessions;
  v_name text;
  v_today date := gym_today();
begin
  select * into s from gym_settings where id = 1;
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'ORDER_NOT_FOUND'; end if;
  if o.status = 'success' then return o; end if;
  if o.status not in ('pending', 'processing') then raise exception 'ORDER_NOT_PAYABLE'; end if;

  if o.kind = 'membership' then
    select * into v_plan from membership_plans where id = o.plan_id;
    -- Renewing early stacks the new period after the current one.
    select max(end_date) into v_current_end
    from memberships where member_id = o.member_id and status = 'active' and end_date >= v_today;
    v_start := coalesce(v_current_end + 1, v_today);
    v_end := v_start + v_plan.duration_days - 1;
    insert into memberships (member_id, plan_id, start_date, end_date, status, order_id)
    values (o.member_id, o.plan_id, v_start, v_end, 'active', o.id);
    perform notify_member(o.member_id, 'Payment successful',
      v_plan.name || ' membership active until ' || to_char(v_end, 'FMDD Mon YYYY') || '.', 'checkmark.seal');
  else
    select * into v_pkg from pt_packages where id = o.package_id;
    insert into owned_packages (member_id, package_id, trainer_id, sessions_total, expires_at, order_id)
    values (o.member_id, o.package_id, o.trainer_id, v_pkg.session_count,
            now() + make_interval(days => v_pkg.validity_days), o.id)
    returning id into v_new_pkg;
    perform notify_member(o.member_id, 'Payment successful', o.title || ' is ready to use.', 'checkmark.seal');

    if o.hold_session_id is not null then
      select * into v_hold from pt_sessions where id = o.hold_session_id for update;
      if found and v_hold.status = 'held' then
        -- Still ours (even if the 10 minutes ran out, nobody could take an uncleaned hold).
        perform _book_from_hold(v_hold.id, v_new_pkg);
      elsif found and v_hold.status = 'cancelled' then
        -- The hold lapsed and was released. Try to book the same time again.
        begin
          insert into pt_sessions (member_id, trainer_id, owned_package_id, starts_at, ends_at, buffer_ends_at, status)
          values (o.member_id, v_hold.trainer_id, v_new_pkg, v_hold.starts_at, v_hold.ends_at, v_hold.buffer_ends_at, 'booked');
          update owned_packages set sessions_used = sessions_used + 1 where id = v_new_pkg;
          perform notify_member(o.member_id, 'PT session booked', gym_when(v_hold.starts_at) || '.', 'calendar.badge.checkmark');
        exception when exclusion_violation then
          update orders set needs_new_time = true where id = o.id;
          perform notify_member(o.member_id, 'Pick a new time',
            'Your time was taken while you paid. Your session is saved in your package.', 'calendar.badge.exclamationmark');
        end;
      end if;
    end if;
  end if;

  select coalesce(nullif(trim(first_name || ' ' || last_name), ''), 'Member') into v_name
  from profiles where id = o.member_id;

  insert into receipts (order_id, member_id, number, member_name, product, amount_baisa, vat_baisa, currency, method, transaction_id)
  values (o.id, o.member_id,
          'TBG-' || extract(year from now() at time zone s.time_zone)::int || '-' || lpad(nextval('receipt_seq')::text, 6, '0'),
          coalesce(v_name, 'Member'), o.title, o.amount_baisa, o.vat_baisa, o.currency, p_method, p_payment_id);

  update orders
     set status = 'success', settled_at = now(), provider_payment_id = p_payment_id, payment_method = p_method
   where id = o.id
  returning * into o;

  insert into audit_log (actor_id, action, entity, entity_id, detail)
  values (null, 'order.settled', 'orders', o.id, jsonb_build_object('payment_id', p_payment_id, 'amount_baisa', o.amount_baisa));
  return o;
end $$;

create function public.mark_order_failed(p_order uuid) returns public.orders
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  update orders set status = 'failed' where id = p_order and status in ('pending', 'processing') returning * into o;
  return o;
end $$;

-- Server-side: account deletion. Cancels future sessions, clears personal data, keeps invoices.
create function public.anonymise_member(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update pt_sessions set status = 'cancelled', updated_at = now()
   where member_id = p_member and status in ('held', 'booked') and starts_at > now();
  update receipts set member_name = 'Deleted member', member_id = null where member_id = p_member;
  update orders set member_id = null where member_id = p_member;
  update profiles
     set first_name = '', last_name = '', email = null, phone = null, date_of_birth = null,
         goal = null, experience = null, deleted_at = now()
   where id = p_member;
  insert into audit_log (actor_id, action, entity, entity_id) values (p_member, 'account.deleted', 'profiles', p_member);
end $$;

-- ---------------------------------------------------------------------------
-- Reads the app makes in one round trip
-- ---------------------------------------------------------------------------

create function public.session_json(p pt_sessions) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(p) || jsonb_build_object('trainer', (select to_jsonb(t) from trainers t where t.id = p.trainer_id))
$$;

create function public.owned_package_json(p owned_packages) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(p) || jsonb_build_object('package', (select to_jsonb(k) from pt_packages k where k.id = p.package_id))
$$;

create function public.home_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := current_member();
  v_today date := gym_today();
begin
  return jsonb_build_object(
    'member', (select to_jsonb(p) from profiles p where p.id = me),
    'membership', (
      select to_jsonb(m) || jsonb_build_object('plan', to_jsonb(pl))
      from memberships m join membership_plans pl on pl.id = m.plan_id
      where m.member_id = me
      order by (m.status = 'active' and v_today between m.start_date and m.end_date) desc, m.end_date desc
      limit 1),
    'upcoming', coalesce((
      select jsonb_agg(session_json(s) order by s.starts_at)
      from (select * from pt_sessions where member_id = me and status = 'booked' and ends_at > now()
            order by starts_at limit 5) s), '[]'::jsonb),
    'owned_package', (
      select owned_package_json(o) from owned_packages o
      where o.member_id = me
      order by (o.sessions_used < o.sessions_total and o.expires_at > now()) desc, o.created_at desc
      limit 1),
    'announcements', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.published_at desc)
      from (select * from announcements where is_published order by published_at desc limit 2) a), '[]'::jsonb),
    'unread_notifications', (select count(*) from notifications where member_id = me and not is_read)
  );
end $$;

create function public.usable_package(p_trainer uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select owned_package_json(o) from owned_packages o
  where o.member_id = current_member() and o.trainer_id = p_trainer
    and o.sessions_used < o.sessions_total and o.expires_at > now()
  order by o.expires_at
  limit 1
$$;

create function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update notifications set is_read = true where member_id = current_member() and not is_read
$$;

create function public.open_support_ticket(p_category text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  v_ticket support_tickets;
begin
  insert into support_tickets (member_id, category) values (me, p_category) returning * into v_ticket;
  insert into support_messages (ticket_id, sender_id, from_member, body) values (v_ticket.id, me, true, trim(p_body));
  return to_jsonb(v_ticket) || jsonb_build_object('messages',
    (select jsonb_agg(to_jsonb(m) order by m.created_at) from support_messages m where m.ticket_id = v_ticket.id));
end $$;

create function public.send_support_message(p_ticket uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := current_member();
  v_ticket support_tickets;
begin
  update support_tickets set status = 'open', updated_at = now()
   where id = p_ticket and member_id = me returning * into v_ticket;
  if not found then raise exception 'TICKET_NOT_FOUND'; end if;
  insert into support_messages (ticket_id, sender_id, from_member, body) values (p_ticket, me, true, trim(p_body));
  return to_jsonb(v_ticket) || jsonb_build_object('messages',
    (select jsonb_agg(to_jsonb(m) order by m.created_at) from support_messages m where m.ticket_id = p_ticket));
end $$;

create function public.request_data_export() returns void
language sql security definer set search_path = public as $$
  insert into data_export_requests (member_id) values (current_member())
$$;
