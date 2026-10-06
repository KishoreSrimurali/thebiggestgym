-- The Biggest Gym Oman: core schema.
-- Money is stored in baisa (1 OMR = 1,000 baisa). Times are timestamptz (UTC); the gym's
-- local time zone lives in gym_settings and is used for slots and dates.

create extension if not exists btree_gist;

create type public.app_role as enum ('member', 'trainer', 'receptionist', 'admin', 'owner');
create type public.membership_status as enum ('pending', 'active', 'frozen', 'expired', 'cancelled');
create type public.session_status as enum ('held', 'booked', 'completed', 'cancelled', 'late_cancelled', 'no_show');
create type public.order_status as enum ('pending', 'processing', 'success', 'failed', 'cancelled', 'refunded');
create type public.support_status as enum ('open', 'waiting', 'resolved');

-- One row: gym-wide rules the functions read, so the owner can change policy without a release.
create table public.gym_settings (
  id                  int primary key default 1 check (id = 1),
  time_zone           text not null default 'Asia/Muscat',
  currency            text not null default 'OMR',
  vat_basis_points    int  not null default 500,       -- 5%
  free_cancel_hours   int  not null default 12,
  max_reschedules     int  not null default 2,
  hold_minutes        int  not null default 10,
  buffer_minutes      int  not null default 15,
  min_notice_minutes  int  not null default 120,
  max_daily_sessions  int  not null default 6,
  slot_step_minutes   int  not null default 30
);
insert into public.gym_settings default values;

create table public.profiles (
  id                     uuid primary key references auth.users (id) on delete cascade,
  first_name             text not null default '',
  last_name              text not null default '',
  email                  text,
  phone                  text,
  date_of_birth          date,
  goal                   text,
  experience             text,
  role                   public.app_role not null default 'member',
  trainer_sees_goals     boolean not null default true,
  share_progress_photos  boolean not null default false,
  deleted_at             timestamptz,
  created_at             timestamptz not null default now()
);

create table public.trainers (
  id                uuid primary key default gen_random_uuid(),
  profile_id        uuid references public.profiles (id) on delete set null,
  name              text not null,
  headline          text not null default '',
  bio               text not null default '',
  philosophy        text not null default '',
  specialties       text[] not null default '{}',
  certifications    text[] not null default '{}',
  years_experience  int not null default 0,
  languages         text[] not null default '{}',
  rating            numeric(2, 1) not null default 5.0,
  review_count      int not null default 0,
  session_minutes   int not null default 60 check (session_minutes between 15 and 180),
  is_active         boolean not null default true,
  sort_order        int not null default 0
);

-- Weekly working hours per trainer, in gym local time. weekday follows extract(dow): 0 = Sunday.
create table public.trainer_hours (
  trainer_id  uuid not null references public.trainers (id) on delete cascade,
  weekday     int  not null check (weekday between 0 and 6),
  start_time  time not null,
  end_time    time not null,
  check (end_time > start_time),
  primary key (trainer_id, weekday, start_time)
);

create table public.trainer_reviews (
  id          uuid primary key default gen_random_uuid(),
  trainer_id  uuid not null references public.trainers (id) on delete cascade,
  author      text not null,
  rating      int not null check (rating between 1 and 5),
  body        text not null,
  created_at  timestamptz not null default now()
);

create table public.membership_plans (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  summary        text not null default '',
  duration_days  int not null check (duration_days > 0),
  price_baisa    bigint not null check (price_baisa > 0),
  benefits       text[] not null default '{}',
  is_featured    boolean not null default false,
  is_active      boolean not null default true,
  sort_order     int not null default 0
);

create table public.pt_packages (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  session_count  int not null check (session_count > 0),
  price_baisa    bigint not null check (price_baisa > 0),
  validity_days  int not null check (validity_days > 0),
  is_active      boolean not null default true,
  sort_order     int not null default 0
);

create table public.orders (
  id                   uuid primary key default gen_random_uuid(),
  member_id            uuid references public.profiles (id) on delete set null,
  kind                 text not null check (kind in ('membership', 'pt_package')),
  plan_id              uuid references public.membership_plans (id),
  package_id           uuid references public.pt_packages (id),
  trainer_id           uuid references public.trainers (id),
  hold_session_id      uuid,
  title                text not null,
  amount_baisa         bigint not null check (amount_baisa > 0),
  vat_baisa            bigint not null,
  currency             text not null default 'OMR',
  status               public.order_status not null default 'pending',
  provider             text not null default 'test',
  provider_session_id  text,
  provider_payment_id  text,
  payment_method       text,
  idempotency_key      text not null,
  needs_new_time       boolean not null default false,
  created_at           timestamptz not null default now(),
  settled_at           timestamptz,
  unique (member_id, idempotency_key),
  check ((kind = 'membership' and plan_id is not null) or (kind = 'pt_package' and package_id is not null and trainer_id is not null))
);

create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.profiles (id) on delete cascade,
  plan_id     uuid not null references public.membership_plans (id),
  start_date  date not null,
  end_date    date not null check (end_date >= start_date),
  status      public.membership_status not null default 'active',
  order_id    uuid references public.orders (id),
  created_at  timestamptz not null default now()
);
create index on public.memberships (member_id, end_date desc);

create table public.owned_packages (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references public.profiles (id) on delete cascade,
  package_id      uuid not null references public.pt_packages (id),
  trainer_id      uuid not null references public.trainers (id),
  sessions_total  int not null check (sessions_total > 0),
  sessions_used   int not null default 0,
  expires_at      timestamptz not null,
  order_id        uuid references public.orders (id),
  created_at      timestamptz not null default now(),
  check (sessions_used between 0 and sessions_total)
);
create index on public.owned_packages (member_id, trainer_id);

-- A held time and a booked session are the same row in different states, so one
-- exclusion constraint protects both. buffer_ends_at = ends_at + the gym's buffer.
create table public.pt_sessions (
  id                uuid primary key default gen_random_uuid(),
  member_id         uuid not null references public.profiles (id) on delete cascade,
  trainer_id        uuid not null references public.trainers (id),
  owned_package_id  uuid references public.owned_packages (id),
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  buffer_ends_at    timestamptz not null,
  status            public.session_status not null,
  hold_expires_at   timestamptz,
  reschedule_count  int not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (ends_at > starts_at and buffer_ends_at >= ends_at),
  check (status <> 'held' or hold_expires_at is not null),
  check (status not in ('booked', 'completed', 'late_cancelled', 'no_show') or owned_package_id is not null),

  -- THE double-booking guarantee: no two live sessions or holds for a trainer may overlap,
  -- buffer included. Enforced by PostgreSQL even under concurrent requests.
  constraint no_trainer_overlap exclude using gist (
    trainer_id with =,
    tstzrange(starts_at, buffer_ends_at, '[)') with &&
  ) where (status in ('held', 'booked')),

  -- A member can't be in two sessions at once either.
  constraint no_member_overlap exclude using gist (
    member_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('held', 'booked'))
);
create index on public.pt_sessions (member_id, starts_at);
create index on public.pt_sessions (trainer_id, starts_at);

alter table public.orders
  add constraint orders_hold_fk foreign key (hold_session_id) references public.pt_sessions (id) on delete set null;

create sequence public.receipt_seq start 1001;

-- Invoices are kept when an account is deleted (tax law), so member_id is nullable.
create table public.receipts (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null unique references public.orders (id),
  member_id       uuid references public.profiles (id) on delete set null,
  number          text not null unique,
  member_name     text not null,
  product         text not null,
  amount_baisa    bigint not null,
  vat_baisa       bigint not null,
  currency        text not null default 'OMR',
  method          text not null,
  transaction_id  text not null,
  status          public.order_status not null default 'success',
  created_at      timestamptz not null default now()
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.profiles (id) on delete cascade,
  title       text not null,
  body        text not null,
  icon        text not null default 'bell',
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index on public.notifications (member_id, created_at desc);

create table public.notification_prefs (
  member_id  uuid not null references public.profiles (id) on delete cascade,
  type       text not null check (type in ('membership', 'ptReminders', 'classReminders', 'payments', 'workouts', 'announcements', 'support')),
  push       boolean not null default true,
  primary key (member_id, type)
);

create table public.announcements (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  body          text not null,
  published_at  timestamptz not null default now(),
  is_published  boolean not null default true
);

create table public.support_tickets (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.profiles (id) on delete cascade,
  category    text not null check (category in ('membership', 'pt', 'payments', 'classes', 'other')),
  status      public.support_status not null default 'open',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.support_messages (
  id           uuid primary key default gen_random_uuid(),
  ticket_id    uuid not null references public.support_tickets (id) on delete cascade,
  sender_id    uuid references public.profiles (id) on delete set null,
  from_member  boolean not null,
  body         text not null check (length(trim(body)) between 1 and 4000),
  created_at   timestamptz not null default now()
);

create table public.data_export_requests (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid references public.profiles (id) on delete set null,
  status      text not null default 'requested',
  created_at  timestamptz not null default now()
);

create table public.audit_log (
  id          bigserial primary key,
  actor_id    uuid,
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  detail      jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

-- New sign-ups get a profile automatically.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, phone)
  values (new.id, new.email, nullif(new.phone, ''));
  insert into public.notifications (member_id, title, body, icon)
  values (new.id, 'Welcome to The Biggest Gym', 'Choose a membership to start training.', 'hand.wave');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
