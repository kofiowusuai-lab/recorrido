-- Recorrido billing, entitlement, usage, identity, and outbound approval core.
-- All objects are Recorrido-prefixed because this initially shares Kofi-Sketch.

create extension if not exists pgcrypto;

create or replace function public.recorrido_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.recorrido_reject_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '55000';
end;
$$;

create table public.recorrido_customer_accounts (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (length(btrim(display_name)) between 1 and 160),
  billing_email text,
  home_country char(2) check (home_country ~ '^[A-Z]{2}$'),
  status text not null default 'active' check (status in ('active', 'suspended', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.recorrido_account_members (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  full_name text not null check (length(btrim(full_name)) between 1 and 160),
  phone_e164 text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  role text not null default 'member' check (role in ('owner', 'operator', 'member')),
  status text not null default 'active' check (status in ('invited', 'active', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, phone_e164)
);
create unique index recorrido_one_active_owner_per_account
  on public.recorrido_account_members(account_id)
  where role = 'owner' and status = 'active';

create table public.recorrido_whatsapp_identities (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid not null references public.recorrido_account_members(id) on delete restrict,
  phone_e164 text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  wa_id text,
  verified_at timestamptz,
  last_inbound_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (phone_e164),
  unique (wa_id)
);

create table public.recorrido_stripe_customers (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null unique references public.recorrido_customer_accounts(id) on delete restrict,
  stripe_customer_id text not null unique check (stripe_customer_id like 'cus_%'),
  email text,
  country char(2) check (country ~ '^[A-Z]{2}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.recorrido_subscription_entitlements (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  stripe_subscription_id text not null unique check (stripe_subscription_id like 'sub_%'),
  stripe_price_id text not null check (stripe_price_id like 'price_%'),
  plan_code text not null check (plan_code in ('pro', 'agency')),
  billing_interval text not null check (billing_interval in ('month', 'year')),
  status text not null check (status in ('trialing', 'active', 'past_due', 'paused', 'canceled', 'unpaid', 'incomplete', 'incomplete_expired')),
  credits_per_month integer not null check (credits_per_month > 0),
  team_member_limit integer not null check (team_member_limit between 1 and 50),
  current_period_start timestamptz not null,
  current_period_end timestamptz not null check (current_period_end > current_period_start),
  next_credit_grant_at timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recorrido_entitlements_account_status_idx
  on public.recorrido_subscription_entitlements(account_id, status);

create table public.recorrido_credit_buckets (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  entitlement_id uuid references public.recorrido_subscription_entitlements(id) on delete restrict,
  source_kind text not null check (source_kind in ('subscription', 'extra_purchase', 'refund', 'manual_adjustment')),
  source_id text not null,
  credits_granted integer not null check (credits_granted > 0),
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (account_id, source_kind, source_id)
);
create index recorrido_credit_buckets_spend_order_idx
  on public.recorrido_credit_buckets(account_id, expires_at nulls last, created_at);

create table public.recorrido_credit_ledger (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  bucket_id uuid not null references public.recorrido_credit_buckets(id) on delete restrict,
  delta integer not null check (delta <> 0),
  entry_kind text not null check (entry_kind in ('grant', 'reserve', 'release', 'refund_reversal', 'manual_adjustment')),
  source_type text not null,
  source_id text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (bucket_id, entry_kind, source_type, source_id)
);
create index recorrido_credit_ledger_account_created_idx
  on public.recorrido_credit_ledger(account_id, created_at);
create index recorrido_credit_ledger_bucket_idx
  on public.recorrido_credit_ledger(bucket_id);

create table public.recorrido_generation_jobs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid not null references public.recorrido_account_members(id) on delete restrict,
  idempotency_key text not null,
  generation_kind text not null default 'property_video',
  status text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed', 'denied')),
  duration_seconds integer check (duration_seconds >= 0),
  failure_reason text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (idempotency_key)
);
create index recorrido_generation_jobs_account_created_idx
  on public.recorrido_generation_jobs(account_id, created_at desc);

create table public.recorrido_generation_reservations (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null unique references public.recorrido_generation_jobs(id) on delete restrict,
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  bucket_id uuid not null references public.recorrido_credit_buckets(id) on delete restrict,
  reserve_ledger_id uuid not null unique references public.recorrido_credit_ledger(id) on delete restrict,
  release_ledger_id uuid unique references public.recorrido_credit_ledger(id) on delete restrict,
  status text not null default 'reserved' check (status in ('reserved', 'consumed', 'released')),
  reserved_at timestamptz not null default now(),
  settled_at timestamptz
);

create table public.recorrido_payment_records (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  stripe_customer_id text,
  stripe_payment_intent_id text,
  stripe_invoice_id text,
  stripe_checkout_session_id text,
  product_code text not null,
  payment_kind text not null check (payment_kind in ('subscription', 'extra_purchase')),
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null check (currency ~ '^[a-z]{3}$'),
  status text not null check (status in ('pending', 'paid', 'failed', 'refunded', 'partially_refunded', 'disputed')),
  receipt_url text,
  paid_at timestamptz,
  refunded_amount_minor bigint not null default 0 check (refunded_amount_minor >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (stripe_payment_intent_id),
  unique (stripe_invoice_id),
  unique (stripe_checkout_session_id)
);
create index recorrido_payment_records_account_created_idx
  on public.recorrido_payment_records(account_id, created_at desc);

create table public.recorrido_stripe_events (
  id uuid primary key default gen_random_uuid(),
  stripe_event_id text not null unique check (stripe_event_id like 'evt_%'),
  event_type text not null,
  stripe_object_id text,
  livemode boolean not null,
  payload jsonb not null,
  received_at timestamptz not null default now()
);

create table public.recorrido_pending_outbound (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid references public.recorrido_account_members(id) on delete restrict,
  recipient_phone_e164 text not null check (recipient_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  message_type text not null check (message_type in ('text', 'interactive', 'template', 'media')),
  payload jsonb not null,
  preview_text text not null,
  idempotency_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'editing', 'approved', 'rejected', 'sending', 'sent', 'failed')),
  approval_token_hash text not null,
  approval_expires_at timestamptz not null,
  edit_revision integer not null default 0 check (edit_revision >= 0),
  approved_by_phone_e164 text,
  approved_at timestamptz,
  rejected_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recorrido_pending_outbound_operator_queue_idx
  on public.recorrido_pending_outbound(status, created_at);

create table public.recorrido_approval_actions (
  id uuid primary key default gen_random_uuid(),
  pending_outbound_id uuid not null references public.recorrido_pending_outbound(id) on delete restrict,
  token_hash text not null unique,
  action text not null check (action in ('approve', 'reject', 'edit', 'approve_edited')),
  operator_phone_e164 text not null check (operator_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  prior_revision integer not null check (prior_revision >= 0),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index recorrido_approval_actions_pending_idx
  on public.recorrido_approval_actions(pending_outbound_id, created_at);

create table public.recorrido_outbound_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  pending_outbound_id uuid not null references public.recorrido_pending_outbound(id) on delete restrict,
  attempt_number integer not null check (attempt_number > 0),
  provider_message_id text,
  status text not null check (status in ('sending', 'accepted', 'delivered', 'read', 'failed')),
  http_status integer,
  error_code text,
  error_message text,
  response jsonb,
  created_at timestamptz not null default now(),
  unique (pending_outbound_id, attempt_number)
);

create table public.recorrido_consent_events (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid references public.recorrido_account_members(id) on delete restrict,
  phone_e164 text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  event_kind text not null check (event_kind in ('opt_in', 'opt_out', 'transactional_consent', 'marketing_consent', 'marketing_withdrawal')),
  source text not null,
  evidence jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create table public.recorrido_price_catalog (
  id uuid primary key default gen_random_uuid(),
  product_code text not null unique,
  product_kind text not null check (product_kind in ('subscription', 'extra_purchase')),
  plan_code text check (plan_code in ('pro', 'agency')),
  billing_interval text check (billing_interval in ('month', 'year')),
  stripe_price_id text unique check (stripe_price_id is null or stripe_price_id like 'price_%'),
  amount_usd_minor integer not null check (amount_usd_minor > 0),
  credits integer not null check (credits > 0),
  team_member_limit integer check (team_member_limit between 1 and 50),
  adaptive_pricing_enabled boolean not null default true,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (product_kind = 'subscription' and plan_code is not null and billing_interval is not null and team_member_limit is not null)
    or
    (product_kind = 'extra_purchase' and plan_code is null and billing_interval is null and team_member_limit is null)
  )
);

insert into public.recorrido_price_catalog
  (product_code, product_kind, plan_code, billing_interval, amount_usd_minor, credits, team_member_limit)
values
  ('single_listing_once_usd_22', 'extra_purchase', null, null, 2200, 1, null),
  ('pro_monthly_usd_32', 'subscription', 'pro', 'month', 3200, 4, 1),
  ('pro_annual_usd_320', 'subscription', 'pro', 'year', 32000, 4, 1),
  ('agency_monthly_usd_79', 'subscription', 'agency', 'month', 7900, 12, 3),
  ('pro_extra_once_usd_18', 'extra_purchase', null, null, 1800, 1, null),
  ('agency_extra_once_usd_15', 'extra_purchase', null, null, 1500, 1, null);

-- Fail closed for client JWT roles. Service-role database access bypasses RLS.
alter table public.recorrido_customer_accounts enable row level security;
alter table public.recorrido_account_members enable row level security;
alter table public.recorrido_whatsapp_identities enable row level security;
alter table public.recorrido_stripe_customers enable row level security;
alter table public.recorrido_subscription_entitlements enable row level security;
alter table public.recorrido_credit_buckets enable row level security;
alter table public.recorrido_credit_ledger enable row level security;
alter table public.recorrido_generation_jobs enable row level security;
alter table public.recorrido_generation_reservations enable row level security;
alter table public.recorrido_payment_records enable row level security;
alter table public.recorrido_stripe_events enable row level security;
alter table public.recorrido_pending_outbound enable row level security;
alter table public.recorrido_approval_actions enable row level security;
alter table public.recorrido_outbound_delivery_attempts enable row level security;
alter table public.recorrido_consent_events enable row level security;
alter table public.recorrido_price_catalog enable row level security;

create trigger recorrido_accounts_updated_at before update on public.recorrido_customer_accounts
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_members_updated_at before update on public.recorrido_account_members
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_whatsapp_identities_updated_at before update on public.recorrido_whatsapp_identities
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_stripe_customers_updated_at before update on public.recorrido_stripe_customers
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_entitlements_updated_at before update on public.recorrido_subscription_entitlements
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_generation_jobs_updated_at before update on public.recorrido_generation_jobs
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_payment_records_updated_at before update on public.recorrido_payment_records
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_pending_outbound_updated_at before update on public.recorrido_pending_outbound
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_price_catalog_updated_at before update on public.recorrido_price_catalog
for each row execute function public.recorrido_set_updated_at();

create trigger recorrido_credit_ledger_immutable
before update or delete on public.recorrido_credit_ledger
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_stripe_events_immutable
before update or delete on public.recorrido_stripe_events
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_approval_actions_immutable
before update or delete on public.recorrido_approval_actions
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_consent_events_immutable
before update or delete on public.recorrido_consent_events
for each row execute function public.recorrido_reject_mutation();

create or replace function public.recorrido_available_credits(p_account_id uuid, p_as_of timestamptz default now())
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(l.delta), 0)::integer
  from public.recorrido_credit_ledger l
  join public.recorrido_credit_buckets b on b.id = l.bucket_id
  where l.account_id = p_account_id
    and (b.expires_at is null or b.expires_at > p_as_of);
$$;

create or replace function public.recorrido_grant_credit_bucket(
  p_account_id uuid,
  p_source_kind text,
  p_source_id text,
  p_credits integer,
  p_expires_at timestamptz default null,
  p_entitlement_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bucket_id uuid;
begin
  if p_credits <= 0 then
    raise exception 'credits must be positive' using errcode = '22023';
  end if;
  if p_source_kind not in ('subscription', 'extra_purchase', 'refund', 'manual_adjustment') then
    raise exception 'invalid source kind' using errcode = '22023';
  end if;

  insert into public.recorrido_credit_buckets
    (account_id, entitlement_id, source_kind, source_id, credits_granted, expires_at, metadata)
  values
    (p_account_id, p_entitlement_id, p_source_kind, p_source_id, p_credits, p_expires_at, p_metadata)
  on conflict (account_id, source_kind, source_id) do nothing
  returning id into v_bucket_id;

  if v_bucket_id is null then
    select id into v_bucket_id
    from public.recorrido_credit_buckets
    where account_id = p_account_id and source_kind = p_source_kind and source_id = p_source_id;
    return v_bucket_id;
  end if;

  insert into public.recorrido_credit_ledger
    (account_id, bucket_id, delta, entry_kind, source_type, source_id, metadata)
  values
    (p_account_id, v_bucket_id, p_credits, 'grant', p_source_kind, p_source_id, p_metadata);

  return v_bucket_id;
end;
$$;

create or replace function public.recorrido_reserve_generation(
  p_account_id uuid,
  p_member_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.recorrido_generation_jobs;
  v_bucket_id uuid;
  v_ledger_id uuid;
  v_reservation_id uuid;
  v_remaining integer;
begin
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));

  if not exists (
    select 1 from public.recorrido_account_members
    where id = p_member_id and account_id = p_account_id and status = 'active'
  ) then
    raise exception 'member is not active on account' using errcode = '42501';
  end if;

  select * into v_job
  from public.recorrido_generation_jobs
  where idempotency_key = p_idempotency_key;

  if found then
    select id into v_reservation_id
    from public.recorrido_generation_reservations
    where job_id = v_job.id;
    return jsonb_build_object(
      'allowed', v_job.status <> 'denied',
      'job_id', v_job.id,
      'reservation_id', v_reservation_id,
      'status', v_job.status,
      'remaining', public.recorrido_available_credits(p_account_id)
    );
  end if;

  insert into public.recorrido_generation_jobs
    (account_id, member_id, idempotency_key, status)
  values
    (p_account_id, p_member_id, p_idempotency_key, 'queued')
  returning * into v_job;

  select b.id into v_bucket_id
  from public.recorrido_credit_buckets b
  join public.recorrido_credit_ledger l on l.bucket_id = b.id
  where b.account_id = p_account_id
    and (b.expires_at is null or b.expires_at > now())
  group by b.id, b.source_kind, b.expires_at, b.created_at
  having sum(l.delta) > 0
  order by
    case when b.source_kind = 'subscription' then 0 else 1 end,
    b.expires_at asc nulls last,
    b.created_at asc
  limit 1
  for update of b;

  if v_bucket_id is null then
    update public.recorrido_generation_jobs set status = 'denied' where id = v_job.id;
    return jsonb_build_object(
      'allowed', false,
      'job_id', v_job.id,
      'reservation_id', null,
      'status', 'denied',
      'remaining', 0
    );
  end if;

  insert into public.recorrido_credit_ledger
    (account_id, bucket_id, delta, entry_kind, source_type, source_id)
  values
    (p_account_id, v_bucket_id, -1, 'reserve', 'generation_job', v_job.id::text)
  returning id into v_ledger_id;

  insert into public.recorrido_generation_reservations
    (job_id, account_id, bucket_id, reserve_ledger_id)
  values
    (v_job.id, p_account_id, v_bucket_id, v_ledger_id)
  returning id into v_reservation_id;

  v_remaining := public.recorrido_available_credits(p_account_id);
  return jsonb_build_object(
    'allowed', true,
    'job_id', v_job.id,
    'reservation_id', v_reservation_id,
    'status', 'queued',
    'remaining', v_remaining
  );
end;
$$;

create or replace function public.recorrido_complete_generation(
  p_reservation_id uuid,
  p_duration_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation public.recorrido_generation_reservations;
begin
  select * into v_reservation
  from public.recorrido_generation_reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'reservation not found' using errcode = 'P0002';
  end if;
  if v_reservation.status = 'released' then
    raise exception 'released reservation cannot be consumed' using errcode = '55000';
  end if;

  if v_reservation.status = 'reserved' then
    update public.recorrido_generation_reservations
      set status = 'consumed', settled_at = now()
      where id = p_reservation_id;
    update public.recorrido_generation_jobs
      set status = 'completed', duration_seconds = p_duration_seconds, completed_at = now()
      where id = v_reservation.job_id;
  end if;

  return jsonb_build_object(
    'reservation_id', p_reservation_id,
    'status', 'consumed',
    'remaining', public.recorrido_available_credits(v_reservation.account_id)
  );
end;
$$;

create or replace function public.recorrido_release_generation(
  p_reservation_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation public.recorrido_generation_reservations;
  v_release_ledger_id uuid;
begin
  select * into v_reservation
  from public.recorrido_generation_reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'reservation not found' using errcode = 'P0002';
  end if;
  if v_reservation.status = 'consumed' then
    raise exception 'consumed reservation cannot be released' using errcode = '55000';
  end if;

  if v_reservation.status = 'reserved' then
    insert into public.recorrido_credit_ledger
      (account_id, bucket_id, delta, entry_kind, source_type, source_id, metadata)
    values
      (v_reservation.account_id, v_reservation.bucket_id, 1, 'release', 'generation_reservation', p_reservation_id::text,
       jsonb_build_object('reason', p_reason))
    returning id into v_release_ledger_id;

    update public.recorrido_generation_reservations
      set status = 'released', settled_at = now(), release_ledger_id = v_release_ledger_id
      where id = p_reservation_id;
    update public.recorrido_generation_jobs
      set status = 'failed', failure_reason = p_reason, completed_at = now()
      where id = v_reservation.job_id;
  end if;

  return jsonb_build_object(
    'reservation_id', p_reservation_id,
    'status', 'released',
    'remaining', public.recorrido_available_credits(v_reservation.account_id)
  );
end;
$$;

create or replace function public.recorrido_grant_due_annual_quotas(p_as_of timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entitlement public.recorrido_subscription_entitlements;
  v_grants integer := 0;
  v_period_start timestamptz;
  v_period_end timestamptz;
begin
  for v_entitlement in
    select *
    from public.recorrido_subscription_entitlements
    where billing_interval = 'year'
      and status in ('trialing', 'active')
      and next_credit_grant_at is not null
      and next_credit_grant_at <= p_as_of
      and next_credit_grant_at < current_period_end
    for update skip locked
  loop
    while v_entitlement.next_credit_grant_at <= p_as_of
      and v_entitlement.next_credit_grant_at < v_entitlement.current_period_end
    loop
      v_period_start := v_entitlement.next_credit_grant_at;
      v_period_end := least(v_period_start + interval '1 month', v_entitlement.current_period_end);
      perform public.recorrido_grant_credit_bucket(
        v_entitlement.account_id,
        'subscription',
        v_entitlement.stripe_subscription_id || ':' || extract(epoch from v_period_start)::bigint::text,
        v_entitlement.credits_per_month,
        v_period_end,
        v_entitlement.id,
        jsonb_build_object('period_start', v_period_start, 'period_end', v_period_end)
      );
      v_entitlement.next_credit_grant_at := v_period_end;
      v_grants := v_grants + 1;
    end loop;

    update public.recorrido_subscription_entitlements
      set next_credit_grant_at = v_entitlement.next_credit_grant_at
      where id = v_entitlement.id;
  end loop;
  return v_grants;
end;
$$;

create or replace function public.recorrido_claim_approved_outbound(p_pending_outbound_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.recorrido_pending_outbound;
begin
  select * into v_row
  from public.recorrido_pending_outbound
  where id = p_pending_outbound_id
  for update;

  if not found then
    raise exception 'outbound message not found' using errcode = 'P0002';
  end if;
  if v_row.status <> 'approved' or v_row.approved_at is null or v_row.approved_by_phone_e164 is null then
    raise exception 'outbound message lacks valid approval' using errcode = '42501';
  end if;

  update public.recorrido_pending_outbound
    set status = 'sending'
    where id = p_pending_outbound_id
    returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create or replace function public.recorrido_enforce_team_member_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_limit integer;
  v_active_count integer;
begin
  if new.status <> 'active' then
    return new;
  end if;

  perform 1 from public.recorrido_customer_accounts where id = new.account_id for update;
  select coalesce(max(team_member_limit), 1) into v_limit
  from public.recorrido_subscription_entitlements
  where account_id = new.account_id and status in ('trialing', 'active');

  select count(*)::integer into v_active_count
  from public.recorrido_account_members
  where account_id = new.account_id
    and status = 'active'
    and id <> new.id;

  if v_active_count >= v_limit then
    raise exception 'active team-member limit of % reached', v_limit using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger recorrido_team_member_limit
before insert or update of status, account_id on public.recorrido_account_members
for each row execute function public.recorrido_enforce_team_member_limit();

revoke all on all tables in schema public from anon, authenticated;
revoke all on function public.recorrido_available_credits(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.recorrido_grant_credit_bucket(uuid, text, text, integer, timestamptz, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.recorrido_reserve_generation(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.recorrido_complete_generation(uuid, integer) from public, anon, authenticated;
revoke all on function public.recorrido_release_generation(uuid, text) from public, anon, authenticated;
revoke all on function public.recorrido_grant_due_annual_quotas(timestamptz) from public, anon, authenticated;
revoke all on function public.recorrido_claim_approved_outbound(uuid) from public, anon, authenticated;

grant execute on function public.recorrido_available_credits(uuid, timestamptz) to service_role;
grant execute on function public.recorrido_grant_credit_bucket(uuid, text, text, integer, timestamptz, uuid, jsonb) to service_role;
grant execute on function public.recorrido_reserve_generation(uuid, uuid, text) to service_role;
grant execute on function public.recorrido_complete_generation(uuid, integer) to service_role;
grant execute on function public.recorrido_release_generation(uuid, text) to service_role;
grant execute on function public.recorrido_grant_due_annual_quotas(timestamptz) to service_role;
grant execute on function public.recorrido_claim_approved_outbound(uuid) to service_role;
