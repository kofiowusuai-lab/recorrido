-- Recorrido billing, entitlement, usage, identity, and outbound approval core.
-- All objects are Recorrido-prefixed because this initially shares Kofi-Sketch.
-- This is a versioned atomic migration: apply it once to an empty target version.
-- Manual replay is intentionally unsupported because CREATE statements must expose
-- drift instead of silently accepting a partially different billing schema.
-- PostgreSQL 16 provides gen_random_uuid() in core. pgcrypto supplies digest()
-- for opaque approval-token lookup without storing bearer tokens.

create extension if not exists pgcrypto;

do $$
begin
  if current_setting('server_version_num')::integer < 160000 then
    raise exception 'Recorrido billing requires PostgreSQL 16 or newer';
  end if;
end;
$$;

do $$
declare v_role text;
begin
  foreach v_role in array array[
    'recorrido_billing_webhook_worker', 'recorrido_billing_checkout_worker',
    'recorrido_billing_generation_worker', 'recorrido_billing_quota_worker',
    'recorrido_billing_dispatcher_worker', 'recorrido_billing_approval_worker',
    'recorrido_billing_reconciliation_worker', 'recorrido_billing_health_worker'
  ] loop
    if not exists (select 1 from pg_roles where rolname = v_role) then
      execute format('create role %I nologin', v_role);
    end if;
  end loop;
end;
$$;

create or replace function public.recorrido_set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.recorrido_reject_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, public
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
  role text not null default 'member' check (role in ('owner', 'office_admin', 'operator', 'member')),
  status text not null default 'active' check (status in ('invited', 'active', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, phone_e164)
);
alter table public.recorrido_account_members add unique (account_id, id);
create unique index recorrido_one_active_owner_per_account
  on public.recorrido_account_members(account_id)
  where role = 'owner' and status = 'active';
create unique index recorrido_one_active_member_per_phone
  on public.recorrido_account_members(phone_e164)
  where status = 'active';

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
alter table public.recorrido_whatsapp_identities add constraint recorrido_whatsapp_member_account_fkey
  foreign key (account_id, member_id) references public.recorrido_account_members(account_id, id) on delete restrict;

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
  stripe_customer_id text references public.recorrido_stripe_customers(stripe_customer_id) on delete restrict,
  stripe_price_id text not null check (stripe_price_id like 'price_%'),
  catalog_product_code text not null,
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
  past_due_at timestamptz,
  latest_event_created timestamptz not null default 'epoch',
  latest_event_id text not null default 'evt_legacy' check (latest_event_id like 'evt_%'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recorrido_entitlements_account_status_idx
  on public.recorrido_subscription_entitlements(account_id, status);
alter table public.recorrido_subscription_entitlements add unique (account_id, id);
create unique index recorrido_one_authoritative_live_entitlement
  on public.recorrido_subscription_entitlements(account_id)
  where status in ('trialing', 'active', 'past_due', 'paused');

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
alter table public.recorrido_credit_buckets add unique (account_id, id);

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
alter table public.recorrido_credit_ledger add unique (account_id, bucket_id, id);
alter table public.recorrido_credit_ledger add constraint recorrido_ledger_bucket_account_fkey
  foreign key (account_id, bucket_id) references public.recorrido_credit_buckets(account_id, id) on delete restrict;

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
  unique (account_id, idempotency_key)
);
create index recorrido_generation_jobs_account_created_idx
  on public.recorrido_generation_jobs(account_id, created_at desc);
alter table public.recorrido_generation_jobs add unique (account_id, id);
alter table public.recorrido_generation_jobs add constraint recorrido_jobs_member_account_fkey
  foreign key (account_id, member_id) references public.recorrido_account_members(account_id, id) on delete restrict;

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
alter table public.recorrido_generation_reservations
  add constraint recorrido_reservation_job_account_fkey foreign key (account_id, job_id)
    references public.recorrido_generation_jobs(account_id, id) on delete restrict,
  add constraint recorrido_reservation_bucket_account_fkey foreign key (account_id, bucket_id)
    references public.recorrido_credit_buckets(account_id, id) on delete restrict,
  add constraint recorrido_reservation_reserve_ledger_fkey foreign key (account_id, bucket_id, reserve_ledger_id)
    references public.recorrido_credit_ledger(account_id, bucket_id, id) on delete restrict,
  add constraint recorrido_reservation_release_ledger_fkey foreign key (account_id, bucket_id, release_ledger_id)
    references public.recorrido_credit_ledger(account_id, bucket_id, id) on delete restrict;

create table public.recorrido_payment_records (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  stripe_customer_id text,
  stripe_payment_intent_id text,
  stripe_invoice_id text,
  stripe_subscription_id text,
  stripe_checkout_session_id text,
  product_code text not null,
  payment_kind text not null check (payment_kind in ('subscription', 'extra_purchase')),
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null check (currency ~ '^[a-z]{3}$'),
  status text not null check (status in ('pending', 'paid', 'failed', 'refunded', 'partially_refunded', 'disputed')),
  receipt_url text,
  paid_at timestamptz,
  service_period_start timestamptz,
  service_period_end timestamptz,
  refunded_amount_minor bigint not null default 0 check (refunded_amount_minor >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (payment_kind <> 'subscription' or status <> 'paid' or (
    stripe_customer_id is not null and stripe_payment_intent_id is not null
    and stripe_invoice_id is not null and stripe_subscription_id is not null
    and service_period_start is not null and service_period_end > service_period_start
  )),
  unique (stripe_payment_intent_id),
  unique (stripe_invoice_id),
  unique (stripe_checkout_session_id)
);
create index recorrido_payment_records_account_created_idx
  on public.recorrido_payment_records(account_id, created_at desc);
alter table public.recorrido_payment_records add unique (account_id, id);

create table public.recorrido_payment_credit_buckets (
  payment_id uuid not null references public.recorrido_payment_records(id) on delete restrict,
  bucket_id uuid not null unique references public.recorrido_credit_buckets(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (payment_id, bucket_id)
);
alter table public.recorrido_payment_credit_buckets add column account_id uuid not null;
alter table public.recorrido_payment_credit_buckets
  add constraint recorrido_payment_bucket_payment_account_fkey foreign key (account_id, payment_id)
    references public.recorrido_payment_records(account_id, id) on delete restrict,
  add constraint recorrido_payment_bucket_bucket_account_fkey foreign key (account_id, bucket_id)
    references public.recorrido_credit_buckets(account_id, id) on delete restrict;

create table public.recorrido_stripe_events (
  id uuid primary key default gen_random_uuid(),
  stripe_event_id text not null unique check (stripe_event_id like 'evt_%'),
  event_type text not null,
  stripe_object_id text,
  livemode boolean not null,
  stripe_api_version text not null check (length(btrim(stripe_api_version)) > 0),
  payload jsonb not null,
  payload_raw text not null check (octet_length(payload_raw) between 1 and 1048576),
  received_at timestamptz not null default now(),
  processing_status text not null default 'pending'
    check (processing_status in ('pending', 'processing', 'processed', 'failed')),
  processing_attempts integer not null default 0 check (processing_attempts >= 0),
  processing_error text,
  processing_started_at timestamptz,
  claim_token uuid,
  lease_expires_at timestamptz,
  processed_at timestamptz
);

create table public.recorrido_billing_runtime_config (
  singleton boolean primary key default true check (singleton),
  expected_stripe_livemode boolean not null,
  payment_grace_period interval not null default interval '3 days'
    check (payment_grace_period >= interval '0 seconds' and payment_grace_period <= interval '30 days'),
  created_at timestamptz not null default now()
);
insert into public.recorrido_billing_runtime_config(expected_stripe_livemode) values (false);

create table public.recorrido_stripe_reversals (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.recorrido_payment_records(id) on delete restrict,
  stripe_reversal_id text not null unique,
  reversal_kind text not null check (reversal_kind in ('refund','dispute')),
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null check (currency ~ '^[a-z]{3}$'),
  occurred_at timestamptz not null,
  verified_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table public.recorrido_stripe_reversal_resolutions (
  id uuid primary key default gen_random_uuid(),
  reversal_id uuid not null unique references public.recorrido_stripe_reversals(id) on delete restrict,
  stripe_event_id text not null unique check (stripe_event_id like 'evt_%'),
  outcome text not null check (outcome in ('won','lost','warning_closed')),
  resolved_at timestamptz not null,
  payload jsonb not null,
  created_at timestamptz not null default now()
);

create table public.recorrido_checkout_requests (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid not null references public.recorrido_account_members(id) on delete restrict,
  idempotency_key text not null check (length(btrim(idempotency_key)) > 0),
  product_code text not null,
  request_fingerprint text not null check (length(btrim(request_fingerprint)) > 0),
  request_payload jsonb not null,
  stripe_checkout_session_id text unique,
  stripe_payment_intent_id text unique check (stripe_payment_intent_id is null or stripe_payment_intent_id like 'pi_%'),
  status text not null default 'pending'
    check (status in ('pending', 'created', 'completed', 'failed', 'expired')),
  checkout_url text,
  expires_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, idempotency_key)
);
alter table public.recorrido_checkout_requests add constraint recorrido_checkout_member_account_fkey
  foreign key (account_id, member_id) references public.recorrido_account_members(account_id, id) on delete restrict;

create table public.recorrido_pending_outbound (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.recorrido_customer_accounts(id) on delete restrict,
  member_id uuid references public.recorrido_account_members(id) on delete restrict,
  recipient_phone_e164 text not null check (recipient_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  message_type text not null check (message_type in ('text', 'interactive', 'template', 'media')),
  payload jsonb not null,
  preview_text text not null,
  idempotency_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'editing', 'approved', 'rejected', 'sending', 'ambiguous', 'sent', 'failed')),
  approval_token_hash text not null,
  approval_expires_at timestamptz not null,
  edit_revision integer not null default 1 check (edit_revision > 0),
  approved_revision integer check (approved_revision > 0),
  approved_by_phone_e164 text,
  approved_at timestamptz,
  rejected_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.recorrido_pending_outbound add constraint recorrido_outbound_member_account_fkey
  foreign key (account_id, member_id) references public.recorrido_account_members(account_id, id)
  match full on delete restrict;
create index recorrido_pending_outbound_operator_queue_idx
  on public.recorrido_pending_outbound(status, created_at);
create unique index recorrido_pending_outbound_approval_token_hash_idx
  on public.recorrido_pending_outbound(approval_token_hash);

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
  status text not null check (status in ('claimed', 'sending', 'ambiguous', 'accepted', 'delivered', 'read', 'failed')),
  claim_token uuid not null default gen_random_uuid(),
  lease_expires_at timestamptz not null default (clock_timestamp()+interval '2 minutes'),
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
alter table public.recorrido_consent_events add constraint recorrido_consent_member_account_fkey
  foreign key (account_id, member_id) references public.recorrido_account_members(account_id, id)
  match full on delete restrict;

create table public.recorrido_price_catalog (
  id uuid primary key default gen_random_uuid(),
  product_code text not null unique,
  product_kind text not null check (product_kind in ('subscription', 'extra_purchase')),
  plan_code text check (plan_code in ('pro', 'agency')),
  eligible_plan_code text check (eligible_plan_code in ('pro', 'agency')),
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
    (product_kind = 'subscription' and plan_code is not null and eligible_plan_code is null and billing_interval is not null and team_member_limit is not null)
    or
    (product_kind = 'extra_purchase' and plan_code is null and billing_interval is null and team_member_limit is null)
  )
);

insert into public.recorrido_price_catalog
  (product_code, product_kind, plan_code, eligible_plan_code, billing_interval, stripe_price_id, amount_usd_minor, credits, team_member_limit)
values
  ('single_listing_once_usd_22', 'extra_purchase', null, null, null, 'price_1U1Ay4DKzfe4qZvAWMLfn3vO', 2200, 1, null),
  ('pro_monthly_usd_32', 'subscription', 'pro', null, 'month', 'price_1U1Ay4DKzfe4qZvAUMvzFsub', 3200, 4, 1),
  ('pro_annual_usd_320', 'subscription', 'pro', null, 'year', 'price_1U1Ay5DKzfe4qZvAga1h2Xix', 32000, 4, 1),
  ('agency_monthly_usd_79', 'subscription', 'agency', null, 'month', 'price_1U1Ay6DKzfe4qZvAy2tj89Ro', 7900, 12, 3),
  ('pro_extra_once_usd_18', 'extra_purchase', null, 'pro', null, 'price_1U1Ay6DKzfe4qZvAoS8ajnwf', 1800, 1, null),
  ('agency_extra_once_usd_15', 'extra_purchase', null, 'agency', null, 'price_1U1Ay7DKzfe4qZvAeXJTOEse', 1500, 1, null);

alter table public.recorrido_checkout_requests
  add constraint recorrido_checkout_requests_product_code_fkey
  foreign key (product_code) references public.recorrido_price_catalog(product_code) on delete restrict;
alter table public.recorrido_payment_records
  add constraint recorrido_payment_records_product_code_fkey
  foreign key (product_code) references public.recorrido_price_catalog(product_code) on delete restrict;
alter table public.recorrido_subscription_entitlements
  add constraint recorrido_entitlement_catalog_fkey foreign key (catalog_product_code)
  references public.recorrido_price_catalog(product_code) on delete restrict;
alter table public.recorrido_credit_buckets
  add constraint recorrido_bucket_entitlement_account_fkey
  foreign key (account_id, entitlement_id)
  references public.recorrido_subscription_entitlements(account_id, id) on delete restrict;
alter table public.recorrido_credit_ledger add constraint recorrido_ledger_sign_kind_check check (
  (entry_kind in ('grant','release') and delta > 0)
  or (entry_kind in ('reserve','refund_reversal') and delta < 0)
  or entry_kind = 'manual_adjustment'
);

create or replace function public.recorrido_validate_payment_snapshot()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare v_price public.recorrido_price_catalog;
begin
  select * into v_price from public.recorrido_price_catalog where product_code=new.product_code;
  if not found or new.payment_kind is distinct from v_price.product_kind
    or new.amount_minor <= 0 or new.currency !~ '^[a-z]{3}$' then
    raise exception 'payment financial snapshot does not match catalog' using errcode='23514';
  end if;
  if new.status='paid' and new.paid_at is null then new.paid_at := clock_timestamp(); end if;
  if new.refunded_amount_minor > new.amount_minor then
    raise exception 'refunded amount exceeds payment amount' using errcode='23514';
  end if;
  return new;
end;
$$;
create trigger recorrido_payment_snapshot_validate before insert on public.recorrido_payment_records
for each row execute function public.recorrido_validate_payment_snapshot();

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
alter table public.recorrido_payment_credit_buckets enable row level security;
alter table public.recorrido_stripe_events enable row level security;
alter table public.recorrido_billing_runtime_config enable row level security;
alter table public.recorrido_stripe_reversals enable row level security;
alter table public.recorrido_stripe_reversal_resolutions enable row level security;
alter table public.recorrido_checkout_requests enable row level security;
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
create trigger recorrido_checkout_requests_updated_at before update on public.recorrido_checkout_requests
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_pending_outbound_updated_at before update on public.recorrido_pending_outbound
for each row execute function public.recorrido_set_updated_at();
create trigger recorrido_price_catalog_updated_at before update on public.recorrido_price_catalog
for each row execute function public.recorrido_set_updated_at();

create trigger recorrido_credit_ledger_immutable
before update or delete on public.recorrido_credit_ledger
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_credit_buckets_immutable before update or delete on public.recorrido_credit_buckets
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_payment_credit_buckets_immutable before update or delete on public.recorrido_payment_credit_buckets
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_stripe_reversals_immutable before update or delete on public.recorrido_stripe_reversals
for each row execute function public.recorrido_reject_mutation();
create trigger recorrido_stripe_reversal_resolutions_immutable before update or delete on public.recorrido_stripe_reversal_resolutions
for each row execute function public.recorrido_reject_mutation();
create or replace function public.recorrido_protect_delivery_attempt()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op='DELETE' or new.id is distinct from old.id
    or new.pending_outbound_id is distinct from old.pending_outbound_id
    or new.attempt_number is distinct from old.attempt_number
    or new.created_at is distinct from old.created_at then
    raise exception 'delivery attempt identity is immutable' using errcode='55000';
  end if;
  if not ((old.status='claimed' and new.status in ('sending','failed'))
    or (old.status='sending' and new.status in ('accepted','failed','ambiguous'))
    or (old.status='ambiguous' and new.status in ('accepted','delivered','failed')))
    or new.claim_token is distinct from old.claim_token
    or (new.lease_expires_at is distinct from old.lease_expires_at
      and not (old.status='claimed' and new.status='sending' and new.lease_expires_at>old.lease_expires_at)) then
    raise exception 'unsafe delivery attempt transition' using errcode='55000';
  end if;
  return new;
end;
$$;
create trigger recorrido_outbound_delivery_attempts_immutable before update or delete on public.recorrido_outbound_delivery_attempts
for each row execute function public.recorrido_protect_delivery_attempt();
create or replace function public.recorrido_protect_payment_record()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op='UPDATE' and old.status='paid' and new.status='paid'
    and old.receipt_url is null and new.receipt_url ~ '^https://pay[.]stripe[.]com/'
    and (to_jsonb(new)-'receipt_url') is not distinct from (to_jsonb(old)-'receipt_url') then
    return new;
  end if;
  if tg_op='DELETE' or new.id is distinct from old.id or new.account_id is distinct from old.account_id
    or new.stripe_customer_id is distinct from old.stripe_customer_id
    or new.stripe_payment_intent_id is distinct from old.stripe_payment_intent_id
    or new.stripe_invoice_id is distinct from old.stripe_invoice_id
    or new.stripe_subscription_id is distinct from old.stripe_subscription_id
    or new.stripe_checkout_session_id is distinct from old.stripe_checkout_session_id
    or new.product_code is distinct from old.product_code or new.payment_kind is distinct from old.payment_kind
    or new.amount_minor is distinct from old.amount_minor or new.currency is distinct from old.currency
    or (new.receipt_url is distinct from old.receipt_url and not
      (old.receipt_url is null and new.receipt_url is not null and new.receipt_url ~ '^https://pay[.]stripe[.]com/'))
    or new.paid_at is distinct from old.paid_at
    or new.service_period_start is distinct from old.service_period_start
    or new.service_period_end is distinct from old.service_period_end
    or new.created_at is distinct from old.created_at
    or new.refunded_amount_minor < old.refunded_amount_minor
    or new.refunded_amount_minor > new.amount_minor
    or new.status not in ('partially_refunded','refunded','disputed') then
    raise exception 'payment evidence is immutable' using errcode='55000';
  end if;
  return new;
end; $$;
create trigger recorrido_payment_records_immutable before update or delete on public.recorrido_payment_records
for each row execute function public.recorrido_protect_payment_record();
create or replace function public.recorrido_protect_checkout_request()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
declare
  v_checkout_rpc_owner name;
begin
  if tg_op='DELETE' then raise exception 'recorrido_checkout_requests is append-only' using errcode='55000'; end if;
  if new.id is distinct from old.id or new.account_id is distinct from old.account_id
    or new.member_id is distinct from old.member_id or new.idempotency_key is distinct from old.idempotency_key
    or new.product_code is distinct from old.product_code or new.request_fingerprint is distinct from old.request_fingerprint
    or new.request_payload is distinct from old.request_payload or new.created_at is distinct from old.created_at
    or (new.stripe_payment_intent_id is distinct from old.stripe_payment_intent_id and not
      (old.stripe_payment_intent_id is null and new.stripe_payment_intent_id like 'pi_%')) then
    raise exception 'checkout request identity is immutable' using errcode='55000';
  end if;
  select pg_get_userbyid(proowner) into v_checkout_rpc_owner
  from pg_proc
  where oid='public.recorrido_create_checkout_request(uuid,uuid,text,text,text,jsonb)'::regprocedure;
  if not ((old.status='pending' and new.status='created' and old.stripe_checkout_session_id is null
      and new.stripe_checkout_session_id is not null and new.checkout_url is not null
      and new.expires_at > clock_timestamp() and new.last_error is null)
    or (current_user=v_checkout_rpc_owner
      and old.status='created' and new.status='expired'
      and old.stripe_checkout_session_id is not null
      and new.stripe_checkout_session_id is not distinct from old.stripe_checkout_session_id
      and new.checkout_url is not distinct from old.checkout_url
      and new.expires_at is not distinct from old.expires_at
      and old.expires_at<=clock_timestamp()
      and new.last_error='stripe_session_expired')
    or (current_user=v_checkout_rpc_owner
      and old.status='expired' and old.last_error='stripe_session_expired'
      and old.expires_at<=clock_timestamp() and new.status='pending'
      and new.stripe_checkout_session_id is null and new.checkout_url is null
      and new.expires_at is null and new.last_error is null)
    or (current_user=v_checkout_rpc_owner and new.status=old.status
      and old.status in ('created','completed') and old.stripe_payment_intent_id is null
      and new.stripe_payment_intent_id like 'pi_%'
      and new.stripe_checkout_session_id is not distinct from old.stripe_checkout_session_id
      and new.checkout_url is not distinct from old.checkout_url
      and new.expires_at is not distinct from old.expires_at
      and new.last_error is not distinct from old.last_error)
    or (new is not distinct from old)) then
    raise exception 'unsafe checkout lifecycle transition' using errcode='55000';
  end if;
  return new;
end;
$$;
create trigger recorrido_checkout_requests_immutable before update or delete on public.recorrido_checkout_requests
for each row execute function public.recorrido_protect_checkout_request();

create or replace function public.recorrido_protect_entitlement_identity()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op='DELETE' or new.id is distinct from old.id
    or new.account_id is distinct from old.account_id
    or new.stripe_subscription_id is distinct from old.stripe_subscription_id
    or new.stripe_customer_id is distinct from old.stripe_customer_id
    or new.stripe_price_id is distinct from old.stripe_price_id
    or new.catalog_product_code is distinct from old.catalog_product_code
    or new.plan_code is distinct from old.plan_code
    or new.billing_interval is distinct from old.billing_interval
    or new.credits_per_month is distinct from old.credits_per_month
    or new.team_member_limit is distinct from old.team_member_limit
    or new.created_at is distinct from old.created_at then
    raise exception 'entitlement identity and grant terms are immutable' using errcode='55000';
  end if;
  if new.current_period_start >= new.current_period_end then
    raise exception 'subscription period must have positive duration' using errcode='22000';
  end if;
  if new.current_period_start < old.current_period_start
    or new.current_period_end < old.current_period_end
    or (new.current_period_start = old.current_period_start and new.current_period_end <> old.current_period_end)
    or (new.current_period_start > old.current_period_start and new.current_period_end = old.current_period_end) then
    raise exception 'subscription period regression or conflict' using errcode='22000';
  end if;
  if old.status in ('canceled','unpaid','incomplete_expired') and new.status is distinct from old.status then
    raise exception 'terminal subscription cannot transition' using errcode='22000';
  end if;
  if new.status is distinct from old.status and not (
    (old.status='incomplete' and new.status in ('trialing','active','canceled','incomplete_expired'))
    or (old.status='trialing' and new.status in ('active','past_due','paused','canceled','unpaid'))
    or (old.status='active' and new.status in ('past_due','paused','canceled','unpaid'))
    or (old.status='past_due' and new.status in ('active','paused','canceled','unpaid'))
    or (old.status='paused' and new.status in ('active','past_due','canceled','unpaid'))
  ) then
    raise exception 'invalid subscription status transition' using errcode='22000';
  end if;
  if old.canceled_at is not null and (new.canceled_at is null or new.canceled_at < old.canceled_at) then
    raise exception 'subscription cancellation timestamp cannot regress' using errcode='22000';
  end if;
  return new;
end;
$$;
create trigger recorrido_entitlement_identity_immutable before update or delete
on public.recorrido_subscription_entitlements for each row execute function public.recorrido_protect_entitlement_identity();
create or replace function public.recorrido_protect_stripe_event_identity()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% is append-only', tg_table_name using errcode = '55000';
  end if;
  if new.id is distinct from old.id
    or new.stripe_event_id is distinct from old.stripe_event_id
    or new.event_type is distinct from old.event_type
    or new.stripe_object_id is distinct from old.stripe_object_id
    or new.livemode is distinct from old.livemode
    or new.stripe_api_version is distinct from old.stripe_api_version
    or new.payload is distinct from old.payload
    or new.payload_raw is distinct from old.payload_raw
    or new.received_at is distinct from old.received_at then
    raise exception 'Stripe event identity and payload are immutable' using errcode = '55000';
  end if;
  if not (
    ((old.processing_status in ('pending','failed')
       or (old.processing_status='processing' and old.lease_expires_at <= clock_timestamp()))
      and new.processing_status='processing' and new.processing_attempts=old.processing_attempts+1
      and new.claim_token is not null and new.lease_expires_at > clock_timestamp())
    or (old.processing_status='processing' and new.processing_status in ('processed','failed')
      and new.processing_attempts=old.processing_attempts and new.claim_token is null
      and new.lease_expires_at is null)
    or (old.processing_status='processing' and new.processing_status='processing'
      and new.processing_attempts=old.processing_attempts
      and new.processing_error is not distinct from old.processing_error
      and new.processing_started_at is not distinct from old.processing_started_at
      and new.claim_token is not distinct from old.claim_token
      and new.lease_expires_at > old.lease_expires_at
      and new.processed_at is not distinct from old.processed_at)
    or (new.processing_status is not distinct from old.processing_status
      and new.processing_attempts is not distinct from old.processing_attempts
      and new.processing_error is not distinct from old.processing_error
      and new.processing_started_at is not distinct from old.processing_started_at
      and new.claim_token is not distinct from old.claim_token
      and new.lease_expires_at is not distinct from old.lease_expires_at
      and new.processed_at is not distinct from old.processed_at)
  ) then
    raise exception 'unsafe Stripe processing transition' using errcode = '55000';
  end if;
  return new;
end;
$$;

create trigger recorrido_stripe_events_immutable
before update or delete on public.recorrido_stripe_events
for each row execute function public.recorrido_protect_stripe_event_identity();
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
set search_path = pg_catalog, public
as $$
  select coalesce(sum(l.delta), 0)::integer
  from public.recorrido_credit_ledger l
  join public.recorrido_credit_buckets b on b.id = l.bucket_id
  where l.account_id = p_account_id
    and b.account_id = p_account_id
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
set search_path = pg_catalog, public
as $$
declare
  v_bucket_id uuid;
  v_existing public.recorrido_credit_buckets;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_account_id::text, 0));
  if p_credits <= 0 then
    raise exception 'credits must be positive' using errcode = '22023';
  end if;
  if p_source_kind not in ('subscription', 'extra_purchase', 'refund', 'manual_adjustment') then
    raise exception 'invalid source kind' using errcode = '22023';
  end if;

  if p_source_kind = 'extra_purchase' then
    raise exception 'extra purchases require recorrido_grant_paid_purchase' using errcode = '42501';
  end if;

  insert into public.recorrido_credit_buckets
    (account_id, entitlement_id, source_kind, source_id, credits_granted, expires_at, metadata)
  values
    (p_account_id, p_entitlement_id, p_source_kind, p_source_id, p_credits, p_expires_at, p_metadata)
  on conflict (account_id, source_kind, source_id) do nothing
  returning id into v_bucket_id;

  if v_bucket_id is null then
    select * into v_existing
    from public.recorrido_credit_buckets
    where account_id = p_account_id and source_kind = p_source_kind and source_id = p_source_id
    for update;
    if v_existing.credits_granted is distinct from p_credits
      or v_existing.expires_at is distinct from p_expires_at
      or v_existing.entitlement_id is distinct from p_entitlement_id
      or v_existing.metadata is distinct from p_metadata then
      raise exception 'conflicting credit grant replay' using errcode = '22000';
    end if;
    v_bucket_id := v_existing.id;
  else
    insert into public.recorrido_credit_ledger
      (account_id, bucket_id, delta, entry_kind, source_type, source_id, metadata)
    values
      (p_account_id, v_bucket_id, p_credits, 'grant', p_source_kind, p_source_id, p_metadata);
  end if;

  return v_bucket_id;
end;
$$;

-- A paid purchase is the sole authority for product, amount, currency and credit
-- quantity. Fail closed: catalog changes after payment do not rewrite the immutable
-- payment snapshot, and a mismatch cannot mint credits.
create or replace function public.recorrido_grant_paid_purchase(p_payment_id uuid)
returns uuid language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare v_payment public.recorrido_payment_records;
declare v_price public.recorrido_price_catalog;
declare v_bucket_id uuid;
begin
  select * into v_payment from public.recorrido_payment_records where id=p_payment_id for update;
  if not found or v_payment.status <> 'paid' or v_payment.payment_kind <> 'extra_purchase' then
    raise exception 'locked paid extra-purchase payment required' using errcode='23503';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_payment.account_id::text,0));
  select * into v_price from public.recorrido_price_catalog
    where product_code=v_payment.product_code and product_kind='extra_purchase' and active for share;
  if not found or v_payment.amount_minor <= 0 or v_payment.currency !~ '^[a-z]{3}$' then
    raise exception 'payment snapshot does not match active catalog' using errcode='22000';
  end if;
  perform public.recorrido_assert_price_eligibility(v_payment.account_id,v_payment.product_code);
  insert into public.recorrido_credit_buckets
    (account_id,source_kind,source_id,credits_granted,metadata)
  values (v_payment.account_id,'extra_purchase',v_payment.id::text,v_price.credits,
    jsonb_build_object('payment_id',v_payment.id,'product_code',v_payment.product_code,
      'amount_minor',v_payment.amount_minor,'currency',v_payment.currency))
  on conflict (account_id,source_kind,source_id) do nothing returning id into v_bucket_id;
  if v_bucket_id is null then
    select id into v_bucket_id from public.recorrido_credit_buckets
      where account_id=v_payment.account_id and source_kind='extra_purchase' and source_id=v_payment.id::text;
  else
    insert into public.recorrido_credit_ledger(account_id,bucket_id,delta,entry_kind,source_type,source_id)
      values(v_payment.account_id,v_bucket_id,v_price.credits,'grant','stripe_payment',v_payment.id::text);
    insert into public.recorrido_payment_credit_buckets(payment_id,bucket_id,account_id)
      values(v_payment.id,v_bucket_id,v_payment.account_id);
  end if;
  return v_bucket_id;
end;
$$;

create or replace function public.recorrido_record_stripe_reversal(
  p_payment_id uuid, p_stripe_reversal_id text, p_kind text, p_amount_minor bigint,
  p_currency text, p_occurred_at timestamptz)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_payment public.recorrido_payment_records; v_existing public.recorrido_stripe_reversals; v_id uuid; v_total bigint;
begin
  select * into v_payment from public.recorrido_payment_records where id=p_payment_id for update;
  if not found then raise exception 'payment not found' using errcode='P0002'; end if;
  if p_kind not in ('refund','dispute') or p_amount_minor <= 0
    or lower(p_currency) is distinct from v_payment.currency then
    raise exception 'invalid reversal evidence' using errcode='22000';
  end if;
  select * into v_existing from public.recorrido_stripe_reversals where stripe_reversal_id=p_stripe_reversal_id for update;
  if found then
    if v_existing.payment_id is distinct from p_payment_id or v_existing.reversal_kind is distinct from p_kind
      or v_existing.amount_minor is distinct from p_amount_minor or v_existing.currency is distinct from p_currency
      or v_existing.occurred_at is distinct from p_occurred_at then
      raise exception 'conflicting Stripe reversal replay' using errcode='22000';
    end if;
    return v_existing.id;
  end if;
  select coalesce(sum(amount_minor),0) into v_total from public.recorrido_stripe_reversals
    where payment_id=p_payment_id and reversal_kind='refund';
  if (p_kind='refund' and v_total+p_amount_minor > v_payment.amount_minor)
    or (p_kind='dispute' and p_amount_minor > v_payment.amount_minor) then
    raise exception 'verified reversal exceeds payment bounds' using errcode='22003';
  end if;
  insert into public.recorrido_stripe_reversals(payment_id,stripe_reversal_id,reversal_kind,amount_minor,currency,occurred_at)
    values(p_payment_id,p_stripe_reversal_id,p_kind,p_amount_minor,lower(p_currency),p_occurred_at)
    returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.recorrido_revoke_stripe_reversal(p_reversal_id uuid)
returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_r public.recorrido_stripe_reversals; v_p public.recorrido_payment_records;
declare v_bucket public.recorrido_credit_buckets; v_quantity integer; v_id uuid;
begin
  select * into v_r from public.recorrido_stripe_reversals where id=p_reversal_id for update;
  if not found then raise exception 'verified reversal not found' using errcode='P0002'; end if;
  select * into v_p from public.recorrido_payment_records where id=v_r.payment_id for update;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_p.account_id::text,0));
  select b.* into v_bucket from public.recorrido_payment_credit_buckets pcb
    join public.recorrido_credit_buckets b on b.id=pcb.bucket_id
    where pcb.payment_id=v_p.id for update of b;
  if not found then raise exception 'payment grant not found' using errcode='23503'; end if;
  -- Fail-closed policy: any verified partial refund/dispute revokes the whole
  -- indivisible one-credit launch purchase exactly once. Each Stripe reversal
  -- remains durable evidence even after the payment's credit is already revoked.
  v_quantity := v_bucket.credits_granted;
  select id into v_id from public.recorrido_credit_ledger
    where bucket_id=v_bucket.id and entry_kind='refund_reversal' and source_type='stripe_reversal'
    order by created_at,id limit 1;
  if found then return v_id; end if;
  insert into public.recorrido_credit_ledger(account_id,bucket_id,delta,entry_kind,source_type,source_id,metadata)
    values(v_p.account_id,v_bucket.id,-v_quantity,'refund_reversal','stripe_reversal',v_r.id::text,
      jsonb_build_object('amount_minor',v_r.amount_minor,'kind',v_r.reversal_kind))
    on conflict(bucket_id,entry_kind,source_type,source_id) do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.recorrido_credit_ledger
    where bucket_id=v_bucket.id and entry_kind='refund_reversal' and source_type='stripe_reversal' and source_id=v_r.id::text; end if;
  return v_id;
end;
$$;

create or replace function public.recorrido_assert_price_eligibility(
  p_account_id uuid,
  p_product_code text
)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_price public.recorrido_price_catalog;
  v_plan_code text;
begin
  select * into v_price
  from public.recorrido_price_catalog
  where product_code = p_product_code and active;

  if not found then
    raise exception 'price is not active' using errcode = 'P0002';
  end if;
  if v_price.eligible_plan_code is null then
    return v_price.product_code;
  end if;

  select plan_code into v_plan_code
  from public.recorrido_subscription_entitlements
  where account_id = p_account_id and status in ('trialing', 'active')
    and current_period_end > now()
  order by current_period_end desc
  limit 1;

  if v_plan_code is distinct from v_price.eligible_plan_code then
    raise exception 'account is not eligible for price' using errcode = '42501';
  end if;
  return v_price.product_code;
end;
$$;

-- Owner-only lifecycle helpers keep expiry mutations out of runtime roles. The
-- checkout trigger independently constrains both updates to their exact shapes.
create or replace function public.recorrido_expire_checkout_requests(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.recorrido_checkout_requests
  set status='expired',last_error='stripe_session_expired'
  where account_id=p_account_id and status='created' and expires_at<=clock_timestamp();
end;
$$;

create or replace function public.recorrido_recover_checkout_request(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  update public.recorrido_checkout_requests
  set status='pending',stripe_checkout_session_id=null,checkout_url=null,expires_at=null,last_error=null
  where id=p_request_id and status='expired' and last_error='stripe_session_expired'
    and expires_at<=clock_timestamp();
  if not found then
    raise exception 'checkout request is not recoverable' using errcode='55000';
  end if;
end;
$$;

create or replace function public.recorrido_create_checkout_request(
  p_account_id uuid,
  p_member_id uuid,
  p_idempotency_key text,
  p_product_code text,
  p_request_fingerprint text,
  p_request_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_request public.recorrido_checkout_requests;
  v_price public.recorrido_price_catalog;
  v_stripe_customer_id text;
  v_member_phone text;
  v_country char(2);
begin
  if nullif(btrim(p_idempotency_key), '') is null
    or nullif(btrim(p_request_fingerprint), '') is null
    or p_request_payload is null then
    raise exception 'checkout idempotency key, fingerprint, and payload are required' using errcode = '22023';
  end if;
  select home_country into v_country from public.recorrido_customer_accounts
  where id = p_account_id and status = 'active' for update;
  if not found then
    raise exception 'account is not active' using errcode = '42501';
  end if;
  select phone_e164 into v_member_phone from public.recorrido_account_members
  where id = p_member_id and account_id = p_account_id and status = 'active'
    and role in ('owner','office_admin');
  if not found then
    raise exception 'billing owner or office admin is required' using errcode = '42501';
  end if;
  if v_country is null then
    raise exception 'verified account country is required for checkout' using errcode = '22023';
  end if;
  perform public.recorrido_assert_price_eligibility(p_account_id, p_product_code);

  perform public.recorrido_expire_checkout_requests(p_account_id);

  if exists (select 1 from public.recorrido_price_catalog where product_code=p_product_code and product_kind='subscription')
    and exists (select 1 from public.recorrido_checkout_requests cr
      join public.recorrido_price_catalog pc on pc.product_code=cr.product_code
      where cr.account_id=p_account_id and pc.product_kind='subscription'
        and cr.status in ('pending','created') and cr.idempotency_key<>p_idempotency_key) then
    raise exception 'conflicting open subscription checkout' using errcode='23505';
  end if;

  insert into public.recorrido_checkout_requests
    (account_id, member_id, idempotency_key, product_code, request_fingerprint, request_payload)
  values
    (p_account_id, p_member_id, p_idempotency_key, p_product_code, p_request_fingerprint, p_request_payload)
  on conflict (account_id, idempotency_key) do nothing
  returning * into v_request;

  if not found then
    select * into v_request from public.recorrido_checkout_requests
    where account_id = p_account_id and idempotency_key = p_idempotency_key
    for update;
    if v_request.member_id is distinct from p_member_id
      or v_request.product_code is distinct from p_product_code
      or v_request.request_fingerprint is distinct from p_request_fingerprint
      or v_request.request_payload is distinct from p_request_payload then
      raise exception 'conflicting checkout request replay' using errcode = '22000';
    end if;
    if v_request.status='expired' then
      perform public.recorrido_recover_checkout_request(v_request.id);
      select * into strict v_request from public.recorrido_checkout_requests where id=v_request.id;
    end if;
  end if;
  select * into v_price from public.recorrido_price_catalog
  where product_code=v_request.product_code and active and stripe_price_id is not null;
  if not found then raise exception 'active Stripe price is required' using errcode='P0002'; end if;
  select stripe_customer_id into v_stripe_customer_id from public.recorrido_stripe_customers
  where account_id=p_account_id;
  return to_jsonb(v_request) || jsonb_build_object(
    'stripe_price_id',v_price.stripe_price_id,
    'mode',case when v_price.product_kind='subscription' then 'subscription' else 'payment' end,
    'amount_minor',v_price.amount_usd_minor,
    'currency','usd',
    'stripe_customer_id',v_stripe_customer_id,
    'normalized_whatsapp_phone',v_member_phone,
    'country',v_country
  );
end;
$$;

create or replace function public.recorrido_claim_stripe_event(
  p_stripe_event_id text,
  p_event_type text,
  p_stripe_object_id text,
  p_livemode boolean,
  p_stripe_api_version text,
  p_payload jsonb,
  p_lease_duration interval default interval '2 minutes',
  p_payload_raw text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event public.recorrido_stripe_events;
  v_claimed boolean := false;
begin
  if p_payload_raw is null or octet_length(p_payload_raw) not between 1 and 1048576 then
    raise exception 'invalid raw Stripe evidence size' using errcode='22023';
  end if;
  if p_lease_duration <= interval '0 seconds' or p_lease_duration > interval '15 minutes' then
    raise exception 'invalid Stripe claim lease' using errcode='22023';
  end if;
  if p_livemode is distinct from (select expected_stripe_livemode from public.recorrido_billing_runtime_config where singleton) then
    raise exception 'unexpected Stripe livemode' using errcode='42501';
  end if;
  insert into public.recorrido_stripe_events
    (stripe_event_id, event_type, stripe_object_id, livemode, stripe_api_version, payload, payload_raw)
  values
    (p_stripe_event_id, p_event_type, p_stripe_object_id, p_livemode, p_stripe_api_version, p_payload,
      p_payload_raw)
  on conflict (stripe_event_id) do nothing
  returning * into v_event;

  if not found then
    select * into v_event from public.recorrido_stripe_events
    where stripe_event_id = p_stripe_event_id for update;
    if v_event.event_type is distinct from p_event_type
      or v_event.stripe_object_id is distinct from p_stripe_object_id
      or v_event.livemode is distinct from p_livemode
      or v_event.stripe_api_version is distinct from p_stripe_api_version
      or v_event.payload is distinct from p_payload
      or v_event.payload_raw is distinct from p_payload_raw then
      raise exception 'conflicting Stripe event replay' using errcode = '22000';
    end if;
  end if;

  if v_event.processing_status in ('pending', 'failed')
    or (v_event.processing_status='processing' and v_event.lease_expires_at <= clock_timestamp()) then
    update public.recorrido_stripe_events
    set processing_status = 'processing',
        processing_attempts = processing_attempts + 1,
        processing_error = null,
        processing_started_at = clock_timestamp(),
        claim_token = gen_random_uuid(),
        lease_expires_at = clock_timestamp() + p_lease_duration,
        processed_at = null
    where id = v_event.id
    returning * into v_event;
    v_claimed := true;
  end if;
  return to_jsonb(v_event) || jsonb_build_object('claimed', v_claimed);
end;
$$;

create or replace function public.recorrido_finalize_checkout_request(
  p_request_id uuid, p_account_id uuid, p_member_id uuid, p_product_code text,
  p_stripe_checkout_session_id text, p_checkout_url text, p_expires_at timestamptz
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_request public.recorrido_checkout_requests;
begin
  if nullif(pg_catalog.btrim(p_stripe_checkout_session_id),'') is null
    or p_stripe_checkout_session_id not like 'cs_%'
    or p_checkout_url !~ '^https://checkout[.]stripe[.]com(/|$)'
    or p_expires_at <= clock_timestamp() then
    raise exception 'valid Stripe session, hosted URL, and future expiry are required' using errcode='22023';
  end if;
  select * into v_request from public.recorrido_checkout_requests where id=p_request_id for update;
  if not found then raise exception 'checkout request not found' using errcode='P0002'; end if;
  if v_request.account_id is distinct from p_account_id or v_request.member_id is distinct from p_member_id
    or v_request.product_code is distinct from p_product_code then
    raise exception 'checkout request identity mismatch' using errcode='22000';
  end if;
  perform 1 from public.recorrido_account_members where id=p_member_id and account_id=p_account_id
    and status='active' and role in ('owner','office_admin');
  if not found then raise exception 'billing member is no longer eligible' using errcode='42501'; end if;
  perform public.recorrido_assert_price_eligibility(p_account_id,p_product_code);
  if v_request.status='created' then
    if v_request.stripe_checkout_session_id is distinct from p_stripe_checkout_session_id
      or v_request.checkout_url is distinct from p_checkout_url or v_request.expires_at is distinct from p_expires_at then
      raise exception 'conflicting checkout finalization replay' using errcode='22000';
    end if;
    return to_jsonb(v_request);
  end if;
  if v_request.status<>'pending' then raise exception 'checkout request cannot be finalized' using errcode='55000'; end if;
  update public.recorrido_checkout_requests set stripe_checkout_session_id=p_stripe_checkout_session_id,
    checkout_url=p_checkout_url, expires_at=p_expires_at, status='created', last_error=null
    where id=p_request_id returning * into v_request;
  return to_jsonb(v_request);
end;
$$;

create or replace function public.recorrido_finish_stripe_event(
  p_event_id uuid,
  p_claim_token uuid,
  p_attempt integer,
  p_succeeded boolean,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event public.recorrido_stripe_events;
begin
  select * into v_event from public.recorrido_stripe_events where id = p_event_id for update;
  if not found then raise exception 'Stripe event not found' using errcode = 'P0002'; end if;
  if v_event.processing_status <> 'processing'
    or v_event.claim_token is distinct from p_claim_token
    or v_event.processing_attempts is distinct from p_attempt
    or v_event.lease_expires_at <= clock_timestamp() then
    raise exception 'Stripe event claim is not owned by this attempt' using errcode = '55000';
  end if;
  update public.recorrido_stripe_events
  set processing_status = case when p_succeeded then 'processed' else 'failed' end,
      processing_error = case when p_succeeded then null else p_error end,
      claim_token = null,
      lease_expires_at = null,
      processed_at = case when p_succeeded then clock_timestamp() else null end
  where id = p_event_id returning * into v_event;
  return to_jsonb(v_event);
end;
$$;

create or replace function public.recorrido_assert_owned_stripe_event(
  p_event_id uuid, p_claim_token uuid, p_attempt integer
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event public.recorrido_stripe_events;
begin
  select * into v_event from public.recorrido_stripe_events where id=p_event_id for update;
  if not found then raise exception 'Stripe event not found' using errcode='P0002'; end if;
  if v_event.processing_status<>'processing' or v_event.claim_token is distinct from p_claim_token
    or v_event.processing_attempts is distinct from p_attempt or v_event.lease_expires_at <= clock_timestamp() then
    raise exception 'Stripe event claim is not live and owned by this attempt' using errcode='55000';
  end if;
  return to_jsonb(v_event);
end;
$$;

create or replace function public.recorrido_renew_stripe_event_lease(
  p_event_id uuid, p_claim_token uuid, p_attempt integer, p_lease_duration interval
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_row public.recorrido_stripe_events;
begin
  if p_lease_duration<=interval '0 seconds' or p_lease_duration>interval '15 minutes' then
    raise exception 'invalid Stripe claim lease' using errcode='22023';
  end if;
  v_event := public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  update public.recorrido_stripe_events set lease_expires_at=clock_timestamp()+p_lease_duration
    where id=p_event_id returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

create or replace function public.recorrido_apply_stripe_payment_event(
  p_event_id uuid, p_claim_token uuid, p_attempt integer
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_object jsonb; v_account uuid; v_product text; v_price public.recorrido_price_catalog;
declare v_payment public.recorrido_payment_records; v_existing public.recorrido_payment_records; v_customer public.recorrido_stripe_customers;
declare v_request public.recorrido_checkout_requests;
declare v_bucket uuid; v_paid_at timestamptz;
declare v_payment_intent_id text; v_checkout_session_id text; v_customer_id text; v_invoice_id text; v_receipt_url text;
begin
  v_event:=public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  if v_event->>'event_type' not in ('payment_intent.succeeded','checkout.session.completed') then
    raise exception 'event is not verified payment evidence' using errcode='22000';
  end if;
  v_object:=v_event#>'{payload,data,object}';
  v_account:=nullif(v_object#>>'{metadata,account_id}','')::uuid;
  v_product:=v_object#>>'{metadata,product_code}';
  if v_event->>'event_type'='checkout.session.completed' then
    select * into v_price from public.recorrido_price_catalog where product_code=v_product and active for share;
    if not found or v_object->>'id' not like 'cs_%' or v_object->>'currency' !~ '^[a-z]{3}$'
      or (v_object->>'amount_total')::bigint<=0
      or (v_object->>'amount_total')::bigint is distinct from v_price.amount_usd_minor
      or v_object->>'currency' is distinct from 'usd'
      or v_object->>'payment_status'<>'paid' or v_object->>'status'<>'complete'
      or v_object#>>'{metadata,checkout_request_id}' is distinct from v_object->>'client_reference_id' then
      raise exception 'checkout session does not match active catalog evidence' using errcode='22000';
    end if;
    select cr.* into v_request from public.recorrido_checkout_requests cr
      join public.recorrido_account_members m on m.id=cr.member_id and m.account_id=cr.account_id
      join public.recorrido_customer_accounts a on a.id=cr.account_id
      where cr.id=(v_object->>'client_reference_id')::uuid
      and cr.account_id=v_account and cr.product_code=v_product and cr.status in ('created','completed')
      and cr.stripe_checkout_session_id=v_object->>'id'
      and v_object#>>'{metadata,member_id}'=cr.member_id::text
      and v_object#>>'{metadata,internal_price_code}'=cr.product_code
      and v_object#>>'{metadata,normalized_whatsapp_phone}'=m.phone_e164
      and v_object#>>'{metadata,country}'=a.home_country
      and v_object#>>'{metadata,purchase_type}'=case
        when v_price.product_kind='subscription' then 'subscription'
        when v_price.product_code like 'single_listing_%' then 'single_listing'
        else 'extra_credits' end
      for update of cr;
    if not found then raise exception 'checkout session is not owned by authoritative account identity and product' using errcode='22000'; end if;
    if v_object->>'mode'='subscription' and v_price.product_kind='subscription' then
      v_customer_id:=nullif(v_object->>'customer','');
      if v_customer_id is null or v_customer_id !~ '^cus_[A-Za-z0-9_]+$' then
        raise exception 'subscription checkout requires a valid Stripe customer' using errcode='22000';
      end if;
      insert into public.recorrido_stripe_customers(account_id,stripe_customer_id,email,country)
        values(v_account,v_customer_id,nullif(v_object->>'customer_email',''),nullif(v_object->>'customer_country',''))
        on conflict do nothing;
      select * into v_customer from public.recorrido_stripe_customers where stripe_customer_id=v_customer_id;
      if not found or v_customer.account_id is distinct from v_account then
        raise exception 'Stripe customer account mismatch' using errcode='22000';
      end if;
      return jsonb_build_object('ignored',true,'reason','subscription_checkout');
    end if;
    if v_object->>'mode'<>'payment' or v_price.product_kind<>'extra_purchase'
      or v_object->>'payment_intent' not like 'pi_%' then
      raise exception 'checkout session payment mode is invalid' using errcode='22000';
    end if;
    v_payment_intent_id:=v_object->>'payment_intent'; v_checkout_session_id:=v_object->>'id';
    if v_request.stripe_payment_intent_id is null then
      update public.recorrido_checkout_requests set stripe_payment_intent_id=v_payment_intent_id
        where id=v_request.id returning * into v_request;
    elsif v_request.stripe_payment_intent_id is distinct from v_payment_intent_id then
      raise exception 'checkout request payment intent mismatch' using errcode='22000';
    end if;
    v_customer_id:=nullif(v_object->>'customer',''); v_invoice_id:=null;
    v_receipt_url:=null; v_paid_at:=v_request.created_at;
  else
    if v_object->>'id' !~ '^pi_[A-Za-z0-9_]+$'
      or (v_object->>'amount_received')::bigint<=0
      or v_object->>'currency' !~ '^[a-z]{3}$' or v_object->>'status'<>'succeeded'
      or v_object#>>'{metadata,internal_price_code}' is distinct from v_product
      or v_object#>>'{metadata,checkout_request_id}' !~ '^[0-9a-fA-F-]{36}$' then
      raise exception 'payment event does not match server-issued checkout evidence' using errcode='22000';
    end if;
    select cr.* into v_request
    from public.recorrido_checkout_requests cr
    join public.recorrido_account_members m on m.id=cr.member_id and m.account_id=cr.account_id
    join public.recorrido_customer_accounts a on a.id=cr.account_id
    where cr.id=(v_object#>>'{metadata,checkout_request_id}')::uuid
      and cr.account_id=v_account and cr.product_code=v_product and cr.status in ('created','completed')
      and v_object#>>'{metadata,member_id}'=cr.member_id::text
      and v_object#>>'{metadata,internal_price_code}'=cr.product_code
      and v_object#>>'{metadata,normalized_whatsapp_phone}'=m.phone_e164
      and v_object#>>'{metadata,country}'=a.home_country
      and v_object#>>'{metadata,purchase_type}'=case when cr.product_code like 'single_listing_%'
        then 'single_listing' else 'extra_credits' end
    for update of cr;
    if not found then
      raise exception 'payment intent is not bound to an owned active checkout request' using errcode='22000';
    end if;
    select * into v_price from public.recorrido_price_catalog
      where product_code=v_request.product_code and active and product_kind='extra_purchase' for share;
    if not found or (v_object->>'amount_received')::bigint is distinct from v_price.amount_usd_minor
      or v_object->>'currency' is distinct from 'usd' then
      raise exception 'payment intent catalog evidence mismatch' using errcode='22000';
    end if;
    v_payment_intent_id:=v_object->>'id';
    if v_request.stripe_payment_intent_id is null then
      update public.recorrido_checkout_requests set stripe_payment_intent_id=v_payment_intent_id
        where id=v_request.id returning * into v_request;
    elsif v_request.stripe_payment_intent_id is distinct from v_payment_intent_id then
      raise exception 'payment intent does not match checkout request' using errcode='22000';
    end if;
    v_checkout_session_id:=v_request.stripe_checkout_session_id;
    v_customer_id:=nullif(v_object->>'customer',''); v_invoice_id:=nullif(v_object->>'invoice','');
    v_receipt_url:=nullif(v_object#>>'{latest_charge,receipt_url}','');
    if v_receipt_url is not null and v_receipt_url !~ '^https://pay[.]stripe[.]com/' then
      raise exception 'invalid Stripe receipt evidence' using errcode='22000';
    end if;
    v_paid_at:=v_request.created_at;
  end if;
  perform 1 from public.recorrido_customer_accounts where id=v_account and status='active';
  if not found then raise exception 'payment account is not active' using errcode='42501'; end if;
  if v_checkout_session_id is not null then
    perform 1 from public.recorrido_checkout_requests cr where cr.account_id=v_account
      and cr.product_code=v_product and cr.status='created'
      and cr.stripe_checkout_session_id=v_checkout_session_id;
    if not found then raise exception 'payment checkout session is not owned by account and product' using errcode='22000'; end if;
  end if;
  if v_customer_id is not null then
    insert into public.recorrido_stripe_customers(account_id,stripe_customer_id,email,country)
      values(v_account,v_customer_id,nullif(v_object->>'customer_email',''),nullif(v_object->>'customer_country',''))
      on conflict(stripe_customer_id) do nothing;
    select * into v_customer from public.recorrido_stripe_customers where stripe_customer_id=v_customer_id;
    if v_customer.account_id is distinct from v_account then raise exception 'Stripe customer account mismatch' using errcode='22000'; end if;
  end if;
  insert into public.recorrido_payment_records(account_id,stripe_customer_id,stripe_payment_intent_id,stripe_invoice_id,
    stripe_checkout_session_id,product_code,payment_kind,amount_minor,currency,status,receipt_url,paid_at)
  values(v_account,v_customer_id,v_payment_intent_id,v_invoice_id,
    v_checkout_session_id,v_product,v_price.product_kind,
    case when v_event->>'event_type'='checkout.session.completed' then (v_object->>'amount_total')::bigint else (v_object->>'amount_received')::bigint end,
    v_object->>'currency','paid',
    v_receipt_url,v_paid_at)
  on conflict(stripe_payment_intent_id) do nothing returning * into v_payment;
  if not found then
    select * into v_existing from public.recorrido_payment_records where stripe_payment_intent_id=v_payment_intent_id;
    if v_existing.receipt_url is null and v_receipt_url is not null then
      update public.recorrido_payment_records set receipt_url=v_receipt_url
        where id=v_existing.id returning * into v_existing;
    end if;
    if v_existing.account_id is distinct from v_account or v_existing.product_code is distinct from v_product
      or v_existing.payment_kind is distinct from v_price.product_kind
      or v_existing.amount_minor is distinct from (case when v_event->>'event_type'='checkout.session.completed'
        then (v_object->>'amount_total')::bigint else (v_object->>'amount_received')::bigint end)
      or v_existing.currency is distinct from v_object->>'currency'
      or v_existing.status<>'paid' or v_existing.stripe_customer_id is distinct from v_customer_id
      or v_existing.stripe_checkout_session_id is distinct from v_checkout_session_id
      or v_existing.stripe_invoice_id is distinct from v_invoice_id
      or (v_receipt_url is not null and v_existing.receipt_url is distinct from v_receipt_url)
      or v_existing.paid_at is distinct from v_paid_at then
      raise exception 'conflicting payment evidence replay' using errcode='22000';
    end if;
    v_payment:=v_existing;
  end if;
  if v_price.product_kind='extra_purchase' then v_bucket:=public.recorrido_grant_paid_purchase(v_payment.id); end if;
  return jsonb_build_object('payment_id',v_payment.id,'bucket_id',v_bucket);
end;
$$;

create or replace function public.recorrido_apply_stripe_subscription_event(
  p_event_id uuid, p_claim_token uuid, p_attempt integer
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_object jsonb; v_item jsonb; v_account uuid; v_product text; v_price public.recorrido_price_catalog;
declare v_row public.recorrido_subscription_entitlements; v_existing public.recorrido_subscription_entitlements;
declare v_start timestamptz; v_end timestamptz; v_canceled_at timestamptz; v_event_type text;
declare v_event_created timestamptz; v_stripe_event_id text;
declare v_existing_rank integer; v_incoming_rank integer; v_equal_second boolean;
begin
  v_event:=public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  v_event_type:=v_event->>'event_type';
  v_event_created:=coalesce(to_timestamp(nullif(v_event#>>'{payload,created}','')::double precision),
    (v_event->>'received_at')::timestamptz);
  v_stripe_event_id:=v_event->>'stripe_event_id';
  if v_event_type not in ('customer.subscription.created','customer.subscription.updated','customer.subscription.deleted') then
    raise exception 'event is not supported subscription lifecycle evidence' using errcode='22000';
  end if;
  v_object:=v_event#>'{payload,data,object}';
  if jsonb_typeof(v_object#>'{items,data}')<>'array' or jsonb_array_length(v_object#>'{items,data}')<>1 then
    raise exception 'subscription must contain exactly one authoritative item' using errcode='22000';
  end if;
  v_item:=v_object#>'{items,data,0}';
  v_account:=nullif(v_object#>>'{metadata,account_id}','')::uuid;
  v_product:=v_object#>>'{metadata,product_code}';
  select * into v_price from public.recorrido_price_catalog where product_code=v_product and product_kind='subscription'
    and active and stripe_price_id=v_item#>>'{price,id}' for share;
  if not found then raise exception 'subscription does not match active catalog evidence' using errcode='22000'; end if;
  perform 1 from public.recorrido_stripe_customers where account_id=v_account and stripe_customer_id=v_object->>'customer';
  if not found then raise exception 'subscription customer is not owned by account' using errcode='22000'; end if;
  if v_object->>'id' !~ '^sub_[A-Za-z0-9_]+$' or v_item->>'id' !~ '^si_[A-Za-z0-9_]+$'
    or v_item->>'subscription' is distinct from v_object->>'id'
    or jsonb_typeof(v_item->'current_period_start')<>'number'
    or jsonb_typeof(v_item->'current_period_end')<>'number' then
    raise exception 'invalid Basil subscription item evidence' using errcode='22000';
  end if;
  v_start:=to_timestamp((v_item->>'current_period_start')::double precision);
  v_end:=to_timestamp((v_item->>'current_period_end')::double precision);
  v_canceled_at:=case when jsonb_typeof(v_object->'canceled_at')='number'
    then to_timestamp((v_object->>'canceled_at')::double precision) else null end;
  if v_start>=v_end or v_object->>'status' not in
      ('trialing','active','past_due','paused','canceled','unpaid','incomplete','incomplete_expired')
    or (v_event_type='customer.subscription.deleted' and v_object->>'status' not in ('canceled','unpaid','incomplete_expired')) then
    raise exception 'invalid subscription lifecycle evidence' using errcode='22000';
  end if;
  insert into public.recorrido_subscription_entitlements(account_id,stripe_subscription_id,stripe_customer_id,stripe_price_id,catalog_product_code,
    plan_code,billing_interval,status,credits_per_month,team_member_limit,current_period_start,current_period_end,
    next_credit_grant_at,cancel_at_period_end,canceled_at,past_due_at,latest_event_created,latest_event_id)
  values(v_account,v_object->>'id',v_object->>'customer',v_price.stripe_price_id,v_price.product_code,v_price.plan_code,v_price.billing_interval,
    v_object->>'status',v_price.credits,v_price.team_member_limit,v_start,v_end,
    null,(v_object->>'cancel_at_period_end')::boolean,v_canceled_at,
    case when v_object->>'status'='past_due' then v_event_created else null end,v_event_created,v_stripe_event_id)
  on conflict(stripe_subscription_id) do nothing returning * into v_row;
  if not found then
    select * into v_existing from public.recorrido_subscription_entitlements where stripe_subscription_id=v_object->>'id' for update;
    if v_existing.account_id is distinct from v_account or v_existing.stripe_customer_id is distinct from v_object->>'customer'
      or v_existing.stripe_price_id is distinct from v_price.stripe_price_id
      or v_existing.catalog_product_code is distinct from v_price.product_code or v_existing.plan_code is distinct from v_price.plan_code
      or v_existing.billing_interval is distinct from v_price.billing_interval or v_existing.credits_per_month is distinct from v_price.credits
      or v_existing.team_member_limit is distinct from v_price.team_member_limit then
      raise exception 'conflicting subscription identity or catalog evidence' using errcode='22000';
    end if;
    if v_event_created < v_existing.latest_event_created then
      return jsonb_build_object('entitlement_id',v_existing.id,'ignored',true,
        'reason','stale_event');
    end if;
    v_equal_second:=v_event_created=v_existing.latest_event_created;
    v_existing_rank:=case v_existing.status
      when 'incomplete' then 10 when 'trialing' then 20 when 'active' then 30
      when 'past_due' then 40 when 'paused' then 50
      when 'incomplete_expired' then 100 when 'unpaid' then 110 when 'canceled' then 120 else 0 end;
    v_incoming_rank:=case v_object->>'status'
      when 'incomplete' then 10 when 'trialing' then 20 when 'active' then 30
      when 'past_due' then 40 when 'paused' then 50
      when 'incomplete_expired' then 100 when 'unpaid' then 110 when 'canceled' then 120 else 0 end;
    if v_existing.current_period_start > v_start or v_existing.current_period_end > v_end
      or (v_existing.current_period_start=v_start and v_existing.current_period_end<>v_end)
      or (v_existing.current_period_start<v_start and v_existing.current_period_end=v_end)
      or (v_existing.status in ('canceled','unpaid','incomplete_expired') and v_existing.status is distinct from v_object->>'status')
      or (v_existing.canceled_at is not null and (v_canceled_at is null or v_canceled_at<v_existing.canceled_at))
      or (v_existing.cancel_at_period_end and not (v_object->>'cancel_at_period_end')::boolean)
      or (v_equal_second and v_incoming_rank<v_existing_rank) then
      return jsonb_build_object('entitlement_id',v_existing.id,'ignored',true,
        'reason',case when v_equal_second then 'equal_second_semantic_regression' else 'lifecycle_regression' end);
    end if;
    update public.recorrido_subscription_entitlements set
      status=v_object->>'status', cancel_at_period_end=(v_object->>'cancel_at_period_end')::boolean,
      canceled_at=v_canceled_at,
      past_due_at=case when v_object->>'status'='past_due' then coalesce(v_existing.past_due_at,v_event_created) else null end,
      current_period_start=v_start, current_period_end=v_end,
      latest_event_created=v_event_created,latest_event_id=v_stripe_event_id
    where id=v_existing.id returning * into v_row;
  end if;
  return jsonb_build_object('entitlement_id',v_row.id);
end;
$$;

-- A paid Stripe invoice is the sole authority for a subscription-period grant.
-- The durable source key is subscription + paid service-period start, so Stripe's
-- related paid event types and retries converge on one bucket.
create or replace function public.recorrido_apply_stripe_subscription_payment_event(
  p_event_id uuid, p_claim_token uuid, p_attempt integer
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_object jsonb; v_line jsonb; v_subscription_id text; v_currency text;
declare v_entitlement public.recorrido_subscription_entitlements; v_price public.recorrido_price_catalog;
declare v_period_start timestamptz; v_period_end timestamptz; v_grant_end timestamptz;
declare v_bucket uuid; v_source_id text; v_payment public.recorrido_payment_records; v_conflict_count integer;
begin
  v_event:=public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  if v_event->>'event_type' not in ('invoice.paid','invoice.payment_succeeded') then
    raise exception 'event is not paid subscription invoice evidence' using errcode='22000';
  end if;
  v_object:=v_event#>'{payload,data,object}';
  v_line:=v_object#>'{lines,data,0}';
  v_subscription_id:=v_object#>>'{parent,subscription_details,subscription}';
  v_currency:=lower(v_object->>'currency');
  if v_object->>'status'<>'paid' or coalesce((v_object->>'paid')::boolean,false) is not true
    or v_currency !~ '^[a-z]{3}$' or (v_object->>'amount_paid')::bigint<=0 or nullif(v_object->>'id','') is null
    or v_object->>'payment_intent' !~ '^pi_[A-Za-z0-9_]+$'
    or v_object#>>'{parent,type}' is distinct from 'subscription_details'
    or v_subscription_id !~ '^sub_[A-Za-z0-9_]+$' or jsonb_array_length(v_object#>'{lines,data}')<>1
    or v_object->>'billing_reason' not in ('subscription_create','subscription_cycle')
    or v_line#>>'{parent,type}' is distinct from 'subscription_item_details'
    or coalesce((v_line#>>'{parent,subscription_item_details,proration}')::boolean,true) is true
    or v_line#>>'{parent,subscription_item_details,subscription_item}' !~ '^si_[A-Za-z0-9_]+$'
    or v_line#>>'{pricing,type}' is distinct from 'price_details'
    or lower(v_line->>'currency') is distinct from v_currency
    or (v_line->>'amount')::bigint<=0
    or (v_line->>'amount')::bigint is distinct from (v_object->>'amount_paid')::bigint then
    raise exception 'invoice is not unambiguous paid subscription evidence' using errcode='22000';
  end if;
  select * into v_entitlement from public.recorrido_subscription_entitlements
    where stripe_subscription_id=v_subscription_id for update;
  if not found or v_entitlement.status not in ('trialing','active')
    or v_entitlement.stripe_customer_id is distinct from v_object->>'customer' then
    raise exception 'paid invoice subscription is not live or customer-owned' using errcode='22000';
  end if;
  select * into v_price from public.recorrido_price_catalog
    where product_code=v_entitlement.catalog_product_code and product_kind='subscription' and active for share;
  if not found or v_price.stripe_price_id is distinct from v_entitlement.stripe_price_id
    or v_price.stripe_price_id is distinct from v_line#>>'{pricing,price_details,price}'
    or v_price.plan_code is distinct from v_entitlement.plan_code
    or v_price.billing_interval is distinct from v_entitlement.billing_interval
    or v_price.credits is distinct from v_entitlement.credits_per_month
    or v_price.team_member_limit is distinct from v_entitlement.team_member_limit then
    raise exception 'paid invoice does not match immutable active catalog terms' using errcode='22000';
  end if;
  v_period_start:=to_timestamp((v_line#>>'{period,start}')::double precision);
  v_period_end:=to_timestamp((v_line#>>'{period,end}')::double precision);
  if v_period_start>=v_period_end or v_period_start is distinct from v_entitlement.current_period_start
    or v_period_end is distinct from v_entitlement.current_period_end then
    raise exception 'paid invoice period does not match subscription period' using errcode='22000';
  end if;
  v_grant_end:=case when v_entitlement.billing_interval='year'
    then least(v_period_start+interval '1 month',v_period_end) else v_period_end end;
  v_source_id:=v_entitlement.stripe_subscription_id||':'||extract(epoch from v_period_start)::bigint::text;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_entitlement.account_id::text,0));
  v_bucket:=public.recorrido_grant_credit_bucket(v_entitlement.account_id,'subscription',v_source_id,
    v_entitlement.credits_per_month,v_grant_end,v_entitlement.id,
    jsonb_build_object('period_start',v_period_start,'period_end',v_grant_end));
  insert into public.recorrido_payment_records(account_id,stripe_customer_id,stripe_payment_intent_id,
    stripe_invoice_id,stripe_subscription_id,product_code,payment_kind,amount_minor,currency,status,paid_at,
    service_period_start,service_period_end)
  values(v_entitlement.account_id,v_entitlement.stripe_customer_id,nullif(v_object->>'payment_intent',''),
    v_object->>'id',v_entitlement.stripe_subscription_id,v_entitlement.catalog_product_code,'subscription',(v_object->>'amount_paid')::bigint,
    v_currency,'paid',coalesce(to_timestamp(nullif(v_object->>'status_transitions_paid_at','')::double precision),clock_timestamp()),
    v_period_start,v_period_end)
  on conflict do nothing
  returning * into v_payment;
  if v_payment.id is null then
    select count(*) into v_conflict_count
      from public.recorrido_payment_records
      where stripe_invoice_id=v_object->>'id'
        or stripe_payment_intent_id=v_object->>'payment_intent';
    if v_conflict_count=0 then
      raise exception 'subscription invoice payment evidence disappeared' using errcode='40001';
    elsif v_conflict_count<>1 then
      raise exception 'Stripe invoice and payment intent identify different payment records' using errcode='22000';
    end if;
    select * into v_payment
      from public.recorrido_payment_records
      where stripe_invoice_id=v_object->>'id'
        or stripe_payment_intent_id=v_object->>'payment_intent'
      for update;
  end if;
  if v_payment.account_id is distinct from v_entitlement.account_id
    or v_payment.stripe_customer_id is distinct from v_entitlement.stripe_customer_id
    or v_payment.stripe_payment_intent_id is distinct from v_object->>'payment_intent'
    or v_payment.stripe_invoice_id is distinct from v_object->>'id'
    or v_payment.stripe_subscription_id is distinct from v_entitlement.stripe_subscription_id
    or v_payment.service_period_start is distinct from v_period_start
    or v_payment.service_period_end is distinct from v_period_end
    or v_payment.product_code is distinct from v_entitlement.catalog_product_code
    or v_payment.payment_kind<>'subscription' or v_payment.amount_minor is distinct from (v_object->>'amount_paid')::bigint
    or v_payment.currency is distinct from v_currency or v_payment.status<>'paid' then
    raise exception 'conflicting subscription invoice payment evidence' using errcode='22000';
  end if;
  insert into public.recorrido_payment_credit_buckets(payment_id,bucket_id,account_id)
  values(v_payment.id,v_bucket,v_entitlement.account_id) on conflict do nothing;
  if v_entitlement.billing_interval='year' and
      (v_entitlement.next_credit_grant_at is null or v_entitlement.next_credit_grant_at<v_grant_end) then
    update public.recorrido_subscription_entitlements set next_credit_grant_at=v_grant_end where id=v_entitlement.id;
  end if;
  return jsonb_build_object('entitlement_id',v_entitlement.id,'bucket_id',v_bucket,
    'credits_granted',v_entitlement.credits_per_month,'source_id',v_source_id);
end;
$$;

create or replace function public.recorrido_apply_stripe_reversal_event(
  p_event_id uuid, p_claim_token uuid, p_attempt integer
)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_object jsonb; v_item jsonb; v_payment public.recorrido_payment_records;
declare v_reversal uuid; v_ledger uuid; v_reversals jsonb := '[]'::jsonb; v_ledgers jsonb := '[]'::jsonb;
declare v_reversal_evidence public.recorrido_stripe_reversals;
declare v_resolution public.recorrido_stripe_reversal_resolutions; v_existing_resolution public.recorrido_stripe_reversal_resolutions;
begin
  v_event:=public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  if v_event->>'event_type' not in ('charge.refunded','charge.dispute.created','charge.dispute.closed') then
    raise exception 'event is not reversal evidence' using errcode='22000';
  end if;
  v_object:=v_event#>'{payload,data,object}';
  if v_event->>'event_type'='charge.dispute.closed' then
    if v_object->>'id' !~ '^dp_[A-Za-z0-9_]+$' or v_object->>'object' is distinct from 'dispute'
      or v_object->>'status' not in ('won','lost','warning_closed') then
      raise exception 'invalid Stripe dispute resolution evidence' using errcode='22000';
    end if;
    select r.* into v_reversal_evidence
      from public.recorrido_stripe_reversals r
      where r.stripe_reversal_id=v_object->>'id' and r.reversal_kind='dispute'
      for update;
    if not found then
      raise exception 'dispute resolution is not bound to verified payment evidence' using errcode='22000';
    end if;
    v_reversal:=v_reversal_evidence.id;
    select p.* into v_payment from public.recorrido_payment_records p
      join public.recorrido_stripe_reversals r on r.payment_id=p.id
      where r.id=v_reversal for update of p;
    if not found or lower(v_object->>'currency') is distinct from v_payment.currency
      or (v_object->>'amount')::bigint is distinct from v_reversal_evidence.amount_minor
      or nullif(v_object->>'payment_intent','') is distinct from v_payment.stripe_payment_intent_id then
      raise exception 'dispute resolution is not bound to verified payment evidence' using errcode='22000';
    end if;
    insert into public.recorrido_stripe_reversal_resolutions
      (reversal_id,stripe_event_id,outcome,resolved_at,payload)
    values(v_reversal,v_event->>'stripe_event_id',v_object->>'status',
      to_timestamp((v_object->>'created')::double precision),v_object)
    on conflict do nothing returning * into v_resolution;
    if v_resolution.id is null then
      select * into v_existing_resolution from public.recorrido_stripe_reversal_resolutions
        where reversal_id=v_reversal or stripe_event_id=v_event->>'stripe_event_id' for update;
      if not found or v_existing_resolution.reversal_id is distinct from v_reversal
        or v_existing_resolution.stripe_event_id is distinct from v_event->>'stripe_event_id'
        or v_existing_resolution.outcome is distinct from v_object->>'status'
        or v_existing_resolution.resolved_at is distinct from to_timestamp((v_object->>'created')::double precision)
        or v_existing_resolution.payload is distinct from v_object then
        raise exception 'conflicting Stripe dispute resolution replay' using errcode='22000';
      end if;
      v_resolution:=v_existing_resolution;
    end if;
    return jsonb_build_object('resolution_id',v_resolution.id,'reversal_id',v_reversal);
  end if;
  select * into v_payment from public.recorrido_payment_records where stripe_payment_intent_id=v_object->>'payment_intent' for update;
  if not found then raise exception 'reversal payment not found' using errcode='P0002'; end if;
  if v_event->>'event_type'='charge.refunded' then
    if v_object->>'id' !~ '^ch_[A-Za-z0-9_]+$' or jsonb_typeof(v_object#>'{refunds,data}')<>'array'
      or jsonb_array_length(v_object#>'{refunds,data}')=0 then
      raise exception 'charge refund does not contain Stripe refund evidence' using errcode='22000';
    end if;
    for v_item in select value from jsonb_array_elements(v_object#>'{refunds,data}') loop
      if v_item->>'id' !~ '^re_[A-Za-z0-9_]+$' or v_item->>'charge' is distinct from v_object->>'id'
        or nullif(v_item->>'payment_intent','') is distinct from v_object->>'payment_intent'
        or lower(v_item->>'currency') is distinct from v_payment.currency
        or v_item->>'status' is distinct from 'succeeded' then
        raise exception 'invalid Stripe refund evidence' using errcode='22000';
      end if;
      v_reversal:=public.recorrido_record_stripe_reversal(v_payment.id,v_item->>'id','refund',
        (v_item->>'amount')::bigint,v_item->>'currency',to_timestamp((v_item->>'created')::double precision));
      v_ledger:=public.recorrido_revoke_stripe_reversal(v_reversal);
      v_reversals:=v_reversals||jsonb_build_array(v_reversal);
      v_ledgers:=v_ledgers||jsonb_build_array(v_ledger);
    end loop;
  else
    if v_object->>'id' !~ '^dp_[A-Za-z0-9_]+$' or v_object->>'object' is distinct from 'dispute'
      or lower(v_object->>'currency') is distinct from v_payment.currency then
      raise exception 'invalid Stripe dispute evidence' using errcode='22000';
    end if;
    v_reversal:=public.recorrido_record_stripe_reversal(v_payment.id,v_object->>'id','dispute',
      (v_object->>'amount')::bigint,v_object->>'currency',to_timestamp((v_object->>'created')::double precision));
    v_ledger:=public.recorrido_revoke_stripe_reversal(v_reversal);
    v_reversals:=jsonb_build_array(v_reversal); v_ledgers:=jsonb_build_array(v_ledger);
  end if;
  update public.recorrido_payment_records
    set refunded_amount_minor=(select coalesce(sum(r.amount_minor),0) from public.recorrido_stripe_reversals r
          where r.payment_id=v_payment.id and r.reversal_kind='refund'),
        status=case
          when exists(select 1 from public.recorrido_stripe_reversals r where r.payment_id=v_payment.id and r.reversal_kind='dispute') then 'disputed'
          when (select coalesce(sum(r.amount_minor),0) from public.recorrido_stripe_reversals r
            where r.payment_id=v_payment.id and r.reversal_kind='refund')>=amount_minor then 'refunded'
          else 'partially_refunded' end
    where id=v_payment.id;
  if v_payment.payment_kind='subscription' then
    update public.recorrido_subscription_entitlements
      set status='unpaid', next_credit_grant_at=null
      where account_id=v_payment.account_id and catalog_product_code=v_payment.product_code
        and status in ('trialing','active','past_due','paused');
  end if;
  return jsonb_build_object('reversal_ids',v_reversals,'ledger_ids',v_ledgers);
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
set search_path = pg_catalog, public
as $$
declare
  v_job public.recorrido_generation_jobs;
  v_bucket_id uuid;
  v_ledger_id uuid;
  v_reservation_id uuid;
  v_remaining integer;
  v_entitlement_status text;
  v_past_due_at timestamptz;
  v_grace interval;
  v_billing_locked boolean := false;
begin
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_account_id::text, 0));

  if not exists (
    select 1 from public.recorrido_customer_accounts
    where id = p_account_id and status = 'active'
  ) then
    raise exception 'account is not active' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.recorrido_account_members
    where id = p_member_id and account_id = p_account_id and status = 'active'
  ) then
    raise exception 'member is not active on account' using errcode = '42501';
  end if;

  select * into v_job
  from public.recorrido_generation_jobs
  where account_id = p_account_id and idempotency_key = p_idempotency_key;

  if found then
    if v_job.member_id is distinct from p_member_id or v_job.generation_kind <> 'property_video' then
      raise exception 'conflicting generation replay' using errcode='22000';
    end if;
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

  select e.status,e.past_due_at into v_entitlement_status,v_past_due_at
  from public.recorrido_subscription_entitlements e
  where e.account_id=p_account_id
  order by e.latest_event_created desc,e.updated_at desc,e.id desc
  limit 1;
  if found then
    select payment_grace_period into v_grace from public.recorrido_billing_runtime_config where singleton;
    v_billing_locked:=v_entitlement_status not in ('trialing','active')
      and not (v_entitlement_status='past_due' and v_past_due_at is not null
        and clock_timestamp()<v_past_due_at+v_grace);
  end if;
  if exists(
    select 1 from public.recorrido_stripe_reversals r
    join public.recorrido_payment_records p on p.id=r.payment_id
    where p.account_id=p_account_id and (
      (r.reversal_kind='dispute' and not exists(
        select 1 from public.recorrido_stripe_reversal_resolutions rr where rr.reversal_id=r.id
      ))
      or exists(
        select 1 from public.recorrido_payment_credit_buckets pcb
        join public.recorrido_generation_reservations gr on gr.bucket_id=pcb.bucket_id
        where pcb.payment_id=p.id and gr.status='consumed'
      )
    )
  ) then
    v_billing_locked:=true;
  end if;
  if v_billing_locked then
    update public.recorrido_generation_jobs set status='denied' where id=v_job.id;
    return jsonb_build_object(
      'allowed',false,'job_id',v_job.id,'reservation_id',null,'status','denied',
      'remaining',public.recorrido_available_credits(p_account_id),'reason','billing_locked'
    );
  end if;

  if public.recorrido_available_credits(p_account_id) <= 0 then
    update public.recorrido_generation_jobs set status = 'denied' where id = v_job.id;
    return jsonb_build_object(
      'allowed', false,
      'job_id', v_job.id,
      'reservation_id', null,
      'status', 'denied',
      'remaining', public.recorrido_available_credits(p_account_id)
    );
  end if;

  select b.id into v_bucket_id
  from public.recorrido_credit_buckets b
  where b.account_id = p_account_id
    and (b.expires_at is null or b.expires_at > now())
    and (
      select coalesce(sum(l.delta), 0)
      from public.recorrido_credit_ledger l
      where l.bucket_id = b.id
    ) > 0
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
set search_path = pg_catalog, public
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
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.account_id::text, 0));
  if v_reservation.status = 'released' then
    raise exception 'released reservation cannot be consumed' using errcode = '55000';
  end if;
  if v_reservation.status='consumed' and
    (select duration_seconds from public.recorrido_generation_jobs where id=v_reservation.job_id)
      is distinct from p_duration_seconds then
    raise exception 'conflicting completion replay' using errcode='22000';
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
set search_path = pg_catalog, public
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
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_reservation.account_id::text, 0));
  if v_reservation.status = 'consumed' then
    raise exception 'consumed reservation cannot be released' using errcode = '55000';
  end if;
  if v_reservation.status='released' and
    (select failure_reason from public.recorrido_generation_jobs where id=v_reservation.job_id)
      is distinct from p_reason then
    raise exception 'conflicting release replay' using errcode='22000';
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

create or replace function public.recorrido_grant_due_annual_quotas_internal(p_as_of timestamptz)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_entitlement public.recorrido_subscription_entitlements;
  v_grants integer := 0;
  v_grant_number integer;
  v_period_start timestamptz;
  v_period_end timestamptz;
begin
  for v_entitlement in
    select e.*
    from public.recorrido_subscription_entitlements e
    join public.recorrido_price_catalog pc on pc.product_code=e.catalog_product_code
      and pc.product_kind='subscription' and pc.active and pc.stripe_price_id=e.stripe_price_id
      and pc.plan_code=e.plan_code and pc.billing_interval=e.billing_interval
      and pc.credits=e.credits_per_month and pc.team_member_limit=e.team_member_limit
    where e.billing_interval = 'year'
      and e.status in ('trialing', 'active')
      and e.next_credit_grant_at is not null
      and e.next_credit_grant_at <= p_as_of
      and e.next_credit_grant_at < e.current_period_end
    for update skip locked
  loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_entitlement.account_id::text, 0));
    if v_entitlement.next_credit_grant_at <= p_as_of
      and v_entitlement.next_credit_grant_at < v_entitlement.current_period_end
    then
      select count(*)::integer into v_grant_number
      from public.recorrido_credit_buckets
      where entitlement_id=v_entitlement.id and source_kind='subscription';
      -- Stripe period boundaries are UTC instants. Do the calendar-month
      -- calculation in UTC so the database session timezone/DST cannot move
      -- annual monthly quota boundaries by an hour.
      v_period_start := least(
        (v_entitlement.current_period_start at time zone 'UTC'
          + v_grant_number * interval '1 month') at time zone 'UTC',
        v_entitlement.current_period_end
      );
      v_period_end := least(
        (v_entitlement.current_period_start at time zone 'UTC'
          + (v_grant_number + 1) * interval '1 month') at time zone 'UTC',
        v_entitlement.current_period_end
      );
      if v_period_start >= v_period_end then
        update public.recorrido_subscription_entitlements
          set next_credit_grant_at=current_period_end where id=v_entitlement.id;
        continue;
      end if;
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
    end if;

    update public.recorrido_subscription_entitlements
      set next_credit_grant_at = v_entitlement.next_credit_grant_at
      where id = v_entitlement.id;
  end loop;
  return v_grants;
end;
$$;

create or replace function public.recorrido_grant_due_annual_quotas()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  return public.recorrido_grant_due_annual_quotas_internal(v_now);
end;
$$;

create or replace function public.recorrido_create_outbound_draft(
  p_account_id uuid,p_member_id uuid,p_recipient_phone_e164 text,p_body text,
  p_idempotency_key text,p_review_ttl interval default interval '1 hour')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_token text; v_row public.recorrido_pending_outbound;
begin
  if p_recipient_phone_e164 !~ '^\+[1-9][0-9]{7,14}$' or p_body is null
    or length(p_body) not between 1 and 4096 or btrim(p_body)=''
    or p_idempotency_key is null or length(p_idempotency_key) not between 1 and 256
    or p_review_ttl<=interval '0 seconds' or p_review_ttl>interval '24 hours'
    or not exists(select 1 from public.recorrido_account_members where id=p_member_id and account_id=p_account_id and status='active') then
    raise exception 'invalid outbound draft' using errcode='22023';
  end if;
  select * into v_row from public.recorrido_pending_outbound where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('id',v_row.id,'created',false); end if;
  v_token:=encode(public.gen_random_bytes(32),'base64');
  v_token:=replace(replace(rtrim(v_token,'='),'+','-'),'/','_');
  insert into public.recorrido_pending_outbound(account_id,member_id,recipient_phone_e164,message_type,
    payload,preview_text,idempotency_key,status,approval_token_hash,approval_expires_at)
  values(p_account_id,p_member_id,p_recipient_phone_e164,'text',jsonb_build_object('body',p_body),p_body,
    p_idempotency_key,'pending',encode(public.digest(v_token,'sha256'),'hex'),clock_timestamp()+p_review_ttl)
  returning * into v_row;
  return jsonb_build_object('id',v_row.id,'created',true,'approvalToken',v_token,
    'approvalExpiresAt',v_row.approval_expires_at,'currentDraftVersion',v_row.edit_revision);
end; $$;

create or replace function public.recorrido_apply_stripe_failed_payment_event(
  p_event_id uuid,p_claim_token uuid,p_attempt integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_event jsonb; v_object jsonb; v_account uuid; v_member public.recorrido_account_members;
declare v_ent public.recorrido_subscription_entitlements; v_product text; v_draft jsonb; v_failed_at timestamptz;
declare v_out public.recorrido_pending_outbound; v_token text;
begin
  v_event:=public.recorrido_assert_owned_stripe_event(p_event_id,p_claim_token,p_attempt);
  if v_event->>'event_type' not in ('payment_intent.payment_failed','invoice.payment_failed') then
    raise exception 'event is not failed payment evidence' using errcode='22000'; end if;
  v_object:=v_event#>'{payload,data,object}';
  if v_event->>'event_type'='invoice.payment_failed' then
    if v_object#>>'{parent,type}' is distinct from 'subscription_details'
      or v_object#>>'{parent,subscription_details,subscription}' !~ '^sub_[A-Za-z0-9_]+$' then
      raise exception 'failed invoice does not contain Basil subscription evidence' using errcode='22000';
    end if;
    select * into v_ent from public.recorrido_subscription_entitlements
      where stripe_subscription_id=v_object#>>'{parent,subscription_details,subscription}' for update;
    if not found or v_ent.stripe_customer_id is distinct from v_object->>'customer'
      or v_ent.status not in ('trialing','active','past_due') then
      raise exception 'failed invoice subscription mismatch' using errcode='22000'; end if;
    v_failed_at:=coalesce(to_timestamp(nullif(v_event#>>'{payload,created}','')::double precision),
      (v_event->>'received_at')::timestamptz);
    v_account:=v_ent.account_id; v_product:=v_ent.catalog_product_code;
    update public.recorrido_subscription_entitlements
      set status='past_due',past_due_at=coalesce(past_due_at,v_failed_at),next_credit_grant_at=null
      where id=v_ent.id;
  else
    v_account:=nullif(v_object#>>'{metadata,account_id}','')::uuid;
    v_product:=v_object#>>'{metadata,product_code}';
    perform 1 from public.recorrido_price_catalog where product_code=v_product and active;
    if not found or v_object->>'id' !~ '^pi_[A-Za-z0-9_]+$' or v_object->>'status'<>'requires_payment_method' then
      raise exception 'failed payment catalog evidence mismatch' using errcode='22000'; end if;
    insert into public.recorrido_payment_records(account_id,stripe_customer_id,stripe_payment_intent_id,
      product_code,payment_kind,amount_minor,currency,status)
    select v_account,nullif(v_object->>'customer',''),v_object->>'id',c.product_code,c.product_kind,
      greatest((v_object->>'amount')::bigint,1),v_object->>'currency','failed'
    from public.recorrido_price_catalog c where c.product_code=v_product
    on conflict(stripe_payment_intent_id) do nothing;
  end if;
  select * into v_member from public.recorrido_account_members
    where account_id=v_account and status='active' order by (role='owner') desc,created_at,id limit 1;
  if not found then raise exception 'failed payment account has no active recipient' using errcode='P0002'; end if;
  v_draft:=public.recorrido_create_outbound_draft(v_account,v_member.id,v_member.phone_e164,
    'We could not process your Recorrido payment. Please update your payment method.',
    'stripe-failed-payment:'||(v_event->>'stripe_event_id'),interval '24 hours');
  if not (v_draft->>'created')::boolean then
    select * into v_out from public.recorrido_pending_outbound where id=(v_draft->>'id')::uuid for update;
    if v_out.status<>'pending' then
      return jsonb_build_object('review',jsonb_build_object('required',false,'draftId',v_out.id));
    end if;
    v_token:=replace(replace(rtrim(encode(public.gen_random_bytes(32),'base64'),'='),'+','-'),'/','_');
    update public.recorrido_pending_outbound set
      approval_token_hash=encode(public.digest(v_token,'sha256'),'hex'),
      approval_expires_at=clock_timestamp()+interval '24 hours'
      where id=v_out.id returning * into v_out;
    v_draft:=jsonb_build_object('id',v_out.id,'created',false,'approvalToken',v_token,
      'currentDraftVersion',v_out.edit_revision,'approvalExpiresAt',v_out.approval_expires_at);
  end if;
  return jsonb_build_object('review',jsonb_build_object('required',true,
    'draftId',v_draft->>'id','approvalToken',v_draft->>'approvalToken',
    'currentDraftVersion',(v_draft->>'currentDraftVersion')::integer));
end; $$;

create or replace function public.recorrido_billing_health()
returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object(
    'status',case when count(*) filter(where processing_status='processing' and lease_expires_at<clock_timestamp())=0
      and not exists(select 1 from public.recorrido_payment_records p where p.status='paid' and p.payment_kind='subscription'
        and not exists(select 1 from public.recorrido_subscription_entitlements e where e.account_id=p.account_id)) then 'ok' else 'degraded' end,
    'stale_webhooks',count(*) filter(where processing_status='processing' and lease_expires_at<clock_timestamp()),
    'payment_without_entitlement',(select count(*) from public.recorrido_payment_records p where p.status='paid' and p.payment_kind='subscription'
      and not exists(select 1 from public.recorrido_subscription_entitlements e where e.account_id=p.account_id)),
    'newest_webhook_at',max(received_at)) from public.recorrido_stripe_events;
$$;

create or replace function public.recorrido_apply_owner_action(
  p_owner_phone_e164 text, p_sender_phone_e164 text, p_action text, p_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_hash text;
  v_row public.recorrido_pending_outbound;
begin
  if p_owner_phone_e164 is null or p_owner_phone_e164 !~ '^\+[1-9][0-9]{7,14}$'
    or p_sender_phone_e164 is distinct from p_owner_phone_e164
    or p_action is null or p_action not in ('approve','reject')
    or p_token is null or length(p_token) not between 1 and 256
    or p_token !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'approval action rejected' using errcode='42501';
  end if;
  v_hash := pg_catalog.encode(public.digest(p_token,'sha256'),'hex');
  select o.* into v_row
  from public.recorrido_pending_outbound o
  where o.approval_token_hash=v_hash
  for update;
  if not found or v_row.status <> 'pending'
    or v_row.approval_expires_at <= pg_catalog.clock_timestamp()
    or exists(select 1 from public.recorrido_approval_actions where token_hash=v_hash) then
    raise exception 'approval action rejected' using errcode='42501';
  end if;
  insert into public.recorrido_approval_actions
    (pending_outbound_id,token_hash,action,operator_phone_e164,prior_revision,details)
  values(v_row.id,v_hash,p_action,p_owner_phone_e164,v_row.edit_revision,
    pg_catalog.jsonb_build_object('revision',v_row.edit_revision));
  if p_action='approve' then
    update public.recorrido_pending_outbound set status='approved',
      approved_by_phone_e164=p_owner_phone_e164, approved_at=pg_catalog.clock_timestamp(),
      approved_revision=edit_revision, rejected_at=null, last_error=null
    where id=v_row.id;
    return pg_catalog.jsonb_build_object('decision','approve','id',v_row.id);
  end if;
  update public.recorrido_pending_outbound set status='rejected', rejected_at=pg_catalog.clock_timestamp(),
    approved_by_phone_e164=null, approved_at=null, approved_revision=null
  where id=v_row.id;
  return pg_catalog.jsonb_build_object('decision','reject','id',v_row.id);
end;
$$;

create or replace function public.recorrido_apply_owner_edit(
  p_owner_phone_e164 text, p_sender_phone_e164 text, p_token text, p_replacement text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_hash text;
  v_new_token text;
  v_row public.recorrido_pending_outbound;
begin
  if p_owner_phone_e164 is null or p_owner_phone_e164 !~ '^\+[1-9][0-9]{7,14}$'
    or p_sender_phone_e164 is distinct from p_owner_phone_e164
    or p_token is null or length(p_token) not between 1 and 256
    or p_token !~ '^[A-Za-z0-9_-]+$'
    or p_replacement is null or length(p_replacement) not between 1 and 4096
    or btrim(p_replacement)='' then
    raise exception 'approval edit rejected' using errcode='42501';
  end if;
  v_hash := pg_catalog.encode(public.digest(p_token,'sha256'),'hex');
  select o.* into v_row
  from public.recorrido_pending_outbound o
  where o.approval_token_hash=v_hash
  for update;
  if not found or v_row.status not in ('pending','editing') or v_row.message_type <> 'text'
    or v_row.approval_expires_at <= pg_catalog.clock_timestamp()
    or exists(select 1 from public.recorrido_approval_actions where token_hash=v_hash) then
    raise exception 'approval edit rejected' using errcode='42501';
  end if;
  insert into public.recorrido_approval_actions
    (pending_outbound_id,token_hash,action,operator_phone_e164,prior_revision,details)
  values(v_row.id,v_hash,'edit',p_owner_phone_e164,v_row.edit_revision,
    pg_catalog.jsonb_build_object('replacementLength',length(p_replacement)));
  v_new_token:=pg_catalog.encode(public.gen_random_bytes(32),'base64');
  v_new_token:=replace(replace(rtrim(v_new_token,'='),'+','-'),'/','_');
  update public.recorrido_pending_outbound set payload=pg_catalog.jsonb_build_object('body',p_replacement),
    preview_text=p_replacement, edit_revision=edit_revision+1, status='pending',
    approval_token_hash=pg_catalog.encode(public.digest(v_new_token,'sha256'),'hex'),
    approval_expires_at=pg_catalog.clock_timestamp()+interval '1 hour', approved_by_phone_e164=null,
    approved_at=null, approved_revision=null, rejected_at=null
  where id=v_row.id;
  return pg_catalog.jsonb_build_object('decision','need_new_review','id',v_row.id,
    'currentDraftVersion',v_row.edit_revision+1,'approvalToken',v_new_token,
    'approvalExpiresAt',pg_catalog.clock_timestamp()+interval '1 hour');
end;
$$;

create or replace function public.recorrido_claim_approved_outbound(
  p_limit integer, p_owner_phone_e164 text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  v_result jsonb;
begin
  if p_limit is null or p_limit not between 1 and 100
    or p_owner_phone_e164 is null or p_owner_phone_e164 !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'invalid dispatch claim' using errcode='22023';
  end if;
  with stale as (
    update public.recorrido_outbound_delivery_attempts
    set status=case when status='claimed' then 'failed' else 'ambiguous' end,
        error_code=case when status='claimed' then 'lease_expired_unbegun' else 'lease_expired_after_begin' end
    where status in ('claimed','sending') and lease_expires_at<=pg_catalog.clock_timestamp()
    returning pending_outbound_id,status
  )
  update public.recorrido_pending_outbound o
  set status=case when s.status='failed' then 'approved' else 'ambiguous' end,
      last_error=case when s.status='failed' then 'lease_expired_unbegun' else 'lease_expired_after_begin' end
  from stale s where o.id=s.pending_outbound_id and o.status='sending';
  with eligible as (
    select o.id
    from public.recorrido_pending_outbound o
    where o.status='approved' and o.approved_by_phone_e164=p_owner_phone_e164
      and o.approved_at is not null and o.approved_revision=o.edit_revision
      and o.approval_expires_at > pg_catalog.clock_timestamp()
      and o.message_type='text' and pg_catalog.jsonb_typeof(o.payload)='object'
      and (o.payload-'body')='{}'::jsonb and pg_catalog.jsonb_typeof(o.payload->'body')='string'
      and length(o.payload->>'body') between 1 and 4096 and btrim(o.payload->>'body')<>''
      and not exists (
        select 1 from public.recorrido_consent_events ce
        where ce.phone_e164=o.recipient_phone_e164 and ce.event_kind='opt_out'
          and not exists (select 1 from public.recorrido_consent_events later
            where later.phone_e164=ce.phone_e164 and later.occurred_at>ce.occurred_at
              and later.event_kind in ('opt_in','transactional_consent','marketing_consent')))
    order by o.created_at,o.id
    for update skip locked
    limit p_limit
  ), attempts as (
    insert into public.recorrido_outbound_delivery_attempts
      (pending_outbound_id,attempt_number,status,claim_token,lease_expires_at)
    select e.id,coalesce((select max(a.attempt_number)+1
      from public.recorrido_outbound_delivery_attempts a where a.pending_outbound_id=e.id),1),'claimed',
      gen_random_uuid(),pg_catalog.clock_timestamp()+interval '2 minutes'
    from eligible e returning id,pending_outbound_id,attempt_number,claim_token,lease_expires_at
  ), claimed as (
    update public.recorrido_pending_outbound o set status='sending'
    from attempts a where o.id=a.pending_outbound_id
    returning o.*,a.id as attempt_id,a.claim_token,a.lease_expires_at
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',id,'attemptId',attempt_id,'claimToken',claim_token,'leaseExpiresAt',lease_expires_at,'draftId',id,
    'ownerWhatsAppE164',approved_by_phone_e164,'recipientE164',recipient_phone_e164,
    'messageType',message_type,'payload',payload,'body',payload->>'body','previewText',preview_text,
    'status','approved','approvedAt',approved_at,'approvedBy',approved_by_phone_e164,
    'approvedVersion',approved_revision,'currentDraftVersion',edit_revision,
    'tokenValid',true,'approvalExpiresAt',approval_expires_at,
    'optedOut',false,'recipientConsented',true,'sentAt',sent_at,'providerMessageId',null
  ) order by created_at,id),'[]'::jsonb) into v_result from claimed;
  return v_result;
end;
$$;

create or replace function public.recorrido_begin_outbound_send(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_attempt public.recorrido_outbound_delivery_attempts;
begin
  select * into v_attempt from public.recorrido_outbound_delivery_attempts where id=p_attempt_id
    and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_attempt.id is null or v_attempt.status<>'claimed' or v_attempt.lease_expires_at<=pg_catalog.clock_timestamp()
    or not exists(select 1 from public.recorrido_pending_outbound where id=p_pending_outbound_id and status='sending') then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  update public.recorrido_outbound_delivery_attempts
    set status='sending',lease_expires_at=pg_catalog.clock_timestamp()+interval '2 minutes'
    where id=p_attempt_id returning * into v_attempt;
  return pg_catalog.jsonb_build_object('begun',true,'leaseExpiresAt',v_attempt.lease_expires_at);
end; $$;

create or replace function public.recorrido_mark_outbound_delivered(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid,p_provider_message_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_out public.recorrido_pending_outbound; v_attempt public.recorrido_outbound_delivery_attempts;
begin
  if p_provider_message_id is null or length(p_provider_message_id) not between 1 and 512 or btrim(p_provider_message_id)=''
    or p_provider_message_id ~ '[[:cntrl:]]' then raise exception 'invalid provider id' using errcode='22023'; end if;
  select * into v_out from public.recorrido_pending_outbound where id=p_pending_outbound_id for update;
  select * into v_attempt from public.recorrido_outbound_delivery_attempts
    where id=p_attempt_id and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_out.id is null or v_attempt.id is null then
    raise exception 'delivery ownership conflict' using errcode='40001';
  end if;
  if found and v_out.status='sent' and v_attempt.status='accepted'
    and v_attempt.provider_message_id=p_provider_message_id then
    return '{"marked":true}'::jsonb;
  end if;
  if v_out.status<>'sending' or v_attempt.status<>'sending'
    or v_attempt.lease_expires_at<=pg_catalog.clock_timestamp() then
    raise exception 'delivery ownership conflict' using errcode='40001';
  end if;
  update public.recorrido_outbound_delivery_attempts set status='accepted',provider_message_id=p_provider_message_id
    where id=p_attempt_id;
  update public.recorrido_pending_outbound set status='sent',sent_at=pg_catalog.clock_timestamp(),last_error=null
    where id=p_pending_outbound_id;
  return '{"marked":true}'::jsonb;
end;
$$;

create or replace function public.recorrido_mark_outbound_failed(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid,p_error_code text,p_retryable boolean)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_out public.recorrido_pending_outbound; v_attempt public.recorrido_outbound_delivery_attempts; v_target text;
begin
  if p_error_code is null or length(p_error_code) not between 1 and 128
    or p_error_code !~ '^[A-Za-z0-9_.:-]+$' or p_retryable is null then
    raise exception 'invalid delivery error' using errcode='22023'; end if;
  v_target:=case when p_retryable then 'approved' else 'failed' end;
  select * into v_out from public.recorrido_pending_outbound where id=p_pending_outbound_id for update;
  select * into v_attempt from public.recorrido_outbound_delivery_attempts
    where id=p_attempt_id and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_out.id is null or v_attempt.id is null then
    raise exception 'delivery ownership conflict' using errcode='40001';
  end if;
  if found and v_attempt.status='failed' and v_attempt.error_code=p_error_code
    and v_out.status=v_target and v_out.last_error=p_error_code then
    return '{"marked":true}'::jsonb;
  end if;
  if v_out.status<>'sending' or v_attempt.status not in ('claimed','sending')
    or v_attempt.lease_expires_at<=pg_catalog.clock_timestamp() then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  update public.recorrido_outbound_delivery_attempts set status='failed',error_code=p_error_code where id=p_attempt_id;
  update public.recorrido_pending_outbound set status=v_target,last_error=p_error_code where id=p_pending_outbound_id;
  return '{"marked":true}'::jsonb;
end;
$$;

create or replace function public.recorrido_mark_outbound_ambiguous(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid,p_error_code text,p_provider_message_id text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_out public.recorrido_pending_outbound; v_attempt public.recorrido_outbound_delivery_attempts;
begin
  if p_error_code is null or p_error_code !~ '^[A-Za-z0-9_.:-]{1,128}$' or
    (p_provider_message_id is not null and (length(p_provider_message_id) not between 1 and 512
      or btrim(p_provider_message_id)='' or p_provider_message_id ~ '[[:cntrl:]]')) then
    raise exception 'invalid ambiguous outcome' using errcode='22023'; end if;
  select * into v_out from public.recorrido_pending_outbound where id=p_pending_outbound_id for update;
  select * into v_attempt from public.recorrido_outbound_delivery_attempts where id=p_attempt_id and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_out.id is null or v_attempt.id is null then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  if v_attempt.status='ambiguous' and v_out.status='ambiguous' and v_attempt.error_code=p_error_code
    and v_attempt.provider_message_id is not distinct from p_provider_message_id then return '{"marked":true}'::jsonb; end if;
  if v_out.status<>'sending' or v_attempt.status<>'sending'
    or v_attempt.lease_expires_at<=pg_catalog.clock_timestamp() then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  update public.recorrido_outbound_delivery_attempts set status='ambiguous',error_code=p_error_code,provider_message_id=p_provider_message_id where id=p_attempt_id;
  update public.recorrido_pending_outbound set status='ambiguous',last_error=p_error_code where id=p_pending_outbound_id;
  return '{"marked":true}'::jsonb;
end; $$;

create or replace function public.recorrido_reconcile_outbound_accepted(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid,p_provider_message_id text,p_delivered boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_out public.recorrido_pending_outbound; v_attempt public.recorrido_outbound_delivery_attempts; v_status text;
begin
  if p_provider_message_id is null or length(p_provider_message_id) not between 1 and 512
    or btrim(p_provider_message_id)='' or p_provider_message_id ~ '[[:cntrl:]]' or p_delivered is null then
    raise exception 'invalid reconciliation' using errcode='22023'; end if;
  v_status:=case when p_delivered then 'delivered' else 'accepted' end;
  select * into v_out from public.recorrido_pending_outbound where id=p_pending_outbound_id for update;
  select * into v_attempt from public.recorrido_outbound_delivery_attempts where id=p_attempt_id and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_out.id is null or v_attempt.id is null then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  if v_out.status='sent' and v_attempt.status=v_status and v_attempt.provider_message_id=p_provider_message_id then return '{"resolved":true}'::jsonb; end if;
  if v_out.status<>'ambiguous' or v_attempt.status<>'ambiguous' then raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  update public.recorrido_outbound_delivery_attempts set status=v_status,provider_message_id=p_provider_message_id where id=p_attempt_id;
  update public.recorrido_pending_outbound set status='sent',sent_at=pg_catalog.clock_timestamp(),last_error=null where id=p_pending_outbound_id;
  return '{"resolved":true}'::jsonb;
end; $$;

create or replace function public.recorrido_reconcile_outbound_not_accepted(
  p_pending_outbound_id uuid,p_attempt_id uuid,p_claim_token uuid,p_error_code text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_out public.recorrido_pending_outbound; v_attempt public.recorrido_outbound_delivery_attempts;
begin
  if p_error_code is null or p_error_code !~ '^[A-Za-z0-9_.:-]{1,128}$' then raise exception 'invalid reconciliation' using errcode='22023'; end if;
  select * into v_out from public.recorrido_pending_outbound where id=p_pending_outbound_id for update;
  select * into v_attempt from public.recorrido_outbound_delivery_attempts where id=p_attempt_id and pending_outbound_id=p_pending_outbound_id and claim_token=p_claim_token for update;
  if v_out.id is null or v_attempt.id is null then
    raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  if v_out.status='approved' and v_attempt.status='failed' and v_attempt.error_code=p_error_code then return '{"resolved":true}'::jsonb; end if;
  if v_out.status<>'ambiguous' or v_attempt.status<>'ambiguous' then raise exception 'delivery ownership conflict' using errcode='40001'; end if;
  update public.recorrido_outbound_delivery_attempts set status='failed',error_code=p_error_code where id=p_attempt_id;
  update public.recorrido_pending_outbound set status='approved',last_error=p_error_code where id=p_pending_outbound_id;
  return '{"resolved":true}'::jsonb;
end; $$;

create or replace function public.recorrido_enforce_team_member_limit()
returns trigger
language plpgsql
set search_path = pg_catalog, public
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
  where account_id = new.account_id and status in ('trialing', 'active')
    and current_period_start <= now() and current_period_end > now();

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

-- Explicit inventory: never pattern-match shared-schema objects or alter shared
-- schema privileges during revocation.
revoke all on table
  public.recorrido_customer_accounts, public.recorrido_account_members,
  public.recorrido_whatsapp_identities, public.recorrido_stripe_customers,
  public.recorrido_subscription_entitlements, public.recorrido_credit_buckets,
  public.recorrido_credit_ledger, public.recorrido_generation_jobs,
  public.recorrido_generation_reservations, public.recorrido_payment_records,
  public.recorrido_payment_credit_buckets, public.recorrido_stripe_events,
  public.recorrido_billing_runtime_config, public.recorrido_stripe_reversals,
  public.recorrido_stripe_reversal_resolutions,
  public.recorrido_checkout_requests, public.recorrido_pending_outbound,
  public.recorrido_approval_actions, public.recorrido_outbound_delivery_attempts,
  public.recorrido_consent_events, public.recorrido_price_catalog
from anon, authenticated, service_role;
revoke all on function public.recorrido_available_credits(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.recorrido_grant_credit_bucket(uuid, text, text, integer, timestamptz, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.recorrido_assert_price_eligibility(uuid, text) from public, anon, authenticated;
revoke all on function public.recorrido_expire_checkout_requests(uuid) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_recover_checkout_request(uuid) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_create_checkout_request(uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.recorrido_finalize_checkout_request(uuid,uuid,uuid,text,text,text,timestamptz) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_grant_paid_purchase(uuid) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_record_stripe_reversal(uuid,text,text,bigint,text,timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_revoke_stripe_reversal(uuid) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_claim_stripe_event(text, text, text, boolean, text, jsonb, interval, text) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_finish_stripe_event(uuid, uuid, integer, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.recorrido_assert_owned_stripe_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_renew_stripe_event_lease(uuid,uuid,integer,interval) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_stripe_payment_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_stripe_subscription_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_stripe_subscription_payment_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_stripe_reversal_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_stripe_failed_payment_event(uuid,uuid,integer) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_create_outbound_draft(uuid,uuid,text,text,text,interval) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_billing_health() from public,anon,authenticated,service_role;
revoke all on function public.recorrido_reserve_generation(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.recorrido_complete_generation(uuid, integer) from public, anon, authenticated;
revoke all on function public.recorrido_release_generation(uuid, text) from public, anon, authenticated;
revoke all on function public.recorrido_grant_due_annual_quotas_internal(timestamptz)
  from public, anon, authenticated, service_role, recorrido_billing_quota_worker;
revoke all on function public.recorrido_grant_due_annual_quotas() from public, anon, authenticated;
revoke all on function public.recorrido_apply_owner_action(text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_apply_owner_edit(text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_claim_approved_outbound(integer,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_begin_outbound_send(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text) from public,anon,authenticated,service_role;

grant execute on function public.recorrido_available_credits(uuid, timestamptz) to service_role;
grant execute on function public.recorrido_assert_price_eligibility(uuid, text) to service_role;
grant execute on function public.recorrido_create_checkout_request(uuid, uuid, text, text, text, jsonb) to recorrido_billing_checkout_worker;
grant execute on function public.recorrido_finalize_checkout_request(uuid,uuid,uuid,text,text,text,timestamptz) to recorrido_billing_checkout_worker;
grant execute on function public.recorrido_claim_stripe_event(text,text,text,boolean,text,jsonb,interval,text),
  public.recorrido_finish_stripe_event(uuid,uuid,integer,boolean,text),
  public.recorrido_renew_stripe_event_lease(uuid,uuid,integer,interval),
  public.recorrido_apply_stripe_payment_event(uuid,uuid,integer),
  public.recorrido_apply_stripe_subscription_event(uuid,uuid,integer),
  public.recorrido_apply_stripe_subscription_payment_event(uuid,uuid,integer),
  public.recorrido_apply_stripe_reversal_event(uuid,uuid,integer),
  public.recorrido_apply_stripe_failed_payment_event(uuid,uuid,integer),
  public.recorrido_create_outbound_draft(uuid,uuid,text,text,text,interval) to recorrido_billing_webhook_worker;
grant execute on function public.recorrido_reserve_generation(uuid,uuid,text),
  public.recorrido_complete_generation(uuid,integer), public.recorrido_release_generation(uuid,text)
  to recorrido_billing_generation_worker;
grant execute on function public.recorrido_grant_due_annual_quotas() to recorrido_billing_quota_worker;
grant execute on function public.recorrido_billing_health() to recorrido_billing_health_worker;
grant execute on function public.recorrido_apply_owner_action(text,text,text,text),
  public.recorrido_apply_owner_edit(text,text,text,text),
  public.recorrido_create_outbound_draft(uuid,uuid,text,text,text,interval) to recorrido_billing_approval_worker;
grant execute on function public.recorrido_claim_approved_outbound(integer,text),
  public.recorrido_begin_outbound_send(uuid,uuid,uuid),
  public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text),
  public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean),
  public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text) to recorrido_billing_dispatcher_worker;
grant execute on function public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean),
  public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text) to recorrido_billing_reconciliation_worker;

-- Supabase service_role may SET ROLE into narrowly scoped workers, preserving the
-- runtime JWT role while preventing broad direct table or RPC access.
grant recorrido_billing_webhook_worker, recorrido_billing_checkout_worker,
  recorrido_billing_generation_worker, recorrido_billing_quota_worker,
  recorrido_billing_dispatcher_worker, recorrido_billing_approval_worker,
  recorrido_billing_reconciliation_worker, recorrido_billing_health_worker
  to service_role with inherit false, set true;

-- PostgREST connects as authenticator and must be allowed to assume the exact
-- role carried by each separately signed worker JWT. The membership is SET-only
-- so authenticator never inherits worker privileges outside a verified request.
grant recorrido_billing_webhook_worker, recorrido_billing_checkout_worker,
  recorrido_billing_generation_worker, recorrido_billing_quota_worker,
  recorrido_billing_dispatcher_worker, recorrido_billing_approval_worker,
  recorrido_billing_reconciliation_worker, recorrido_billing_health_worker
  to authenticator with inherit false, set true;
