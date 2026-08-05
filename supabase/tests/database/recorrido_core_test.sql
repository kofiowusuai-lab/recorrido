begin;

create or replace function pg_temp.assert_true(condition boolean, message text)
returns void
language plpgsql
as $$
begin
  if condition is not true then
    raise exception 'assertion failed: %', message;
  end if;
end;
$$;

select pg_temp.assert_true(to_regclass('public.recorrido_customer_accounts') is not null, 'accounts table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_account_members') is not null, 'members table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_whatsapp_identities') is not null, 'WhatsApp identities table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_stripe_customers') is not null, 'Stripe customers table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_subscription_entitlements') is not null, 'entitlements table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_credit_buckets') is not null, 'credit buckets table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_credit_ledger') is not null, 'credit ledger table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_generation_jobs') is not null, 'generation jobs table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_generation_reservations') is not null, 'reservations table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_payment_records') is not null, 'payment records table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_stripe_events') is not null, 'Stripe events table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_pending_outbound') is not null, 'pending outbound table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_approval_actions') is not null, 'approval actions table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_outbound_delivery_attempts') is not null, 'delivery attempts table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_consent_events') is not null, 'consent events table exists');
select pg_temp.assert_true(to_regclass('public.recorrido_price_catalog') is not null, 'price catalog exists');

select pg_temp.assert_true(
  (select count(*) = 6 from public.recorrido_price_catalog),
  'approved launch catalog has exactly six prices'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'single_listing_once_usd_22'
      and product_kind = 'extra_purchase'
      and amount_usd_minor = 2200 and credits = 1
  ),
  'Single Listing is USD 22 for one credit'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'pro_monthly_usd_32'
      and plan_code = 'pro' and billing_interval = 'month'
      and amount_usd_minor = 3200 and credits = 4 and team_member_limit = 1
  ),
  'Pro monthly is USD 32 with four credits'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'pro_annual_usd_320'
      and plan_code = 'pro' and billing_interval = 'year'
      and amount_usd_minor = 32000 and credits = 4 and team_member_limit = 1
  ),
  'Pro annual is USD 320 with four credits granted monthly'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'agency_monthly_usd_79'
      and plan_code = 'agency' and billing_interval = 'month'
      and amount_usd_minor = 7900 and credits = 12 and team_member_limit = 3
  ),
  'Agency monthly is USD 79 with 12 shared credits and three members'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'pro_extra_once_usd_18'
      and amount_usd_minor = 1800 and credits = 1
  ),
  'Pro extra generation is USD 18'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_price_catalog
    where product_code = 'agency_extra_once_usd_15'
      and amount_usd_minor = 1500 and credits = 1
  ),
  'Agency extra generation is USD 15'
);
select pg_temp.assert_true(
  not exists (
    select 1 from public.recorrido_price_catalog
    where product_code in ('starter_monthly', 'pro_monthly', 'pro_annual', 'extra_1', 'extra_5', 'extra_10')
  ),
  'invented and stale catalog entries are absent'
);

select pg_temp.assert_true(
  not exists (
    select 1
    from pg_class
    where relnamespace = 'public'::regnamespace
      and relname like 'recorrido_%'
      and relkind in ('r', 'p')
      and not relrowsecurity
  ),
  'RLS is enabled on every Recorrido table'
);

select pg_temp.assert_true(
  to_regclass('public.recorrido_stripe_events_stripe_event_id_key') is not null,
  'Stripe event replay uniqueness exists'
);
select pg_temp.assert_true(
  to_regclass('public.recorrido_generation_jobs_idempotency_key_key') is not null,
  'generation idempotency uniqueness exists'
);
select pg_temp.assert_true(
  to_regclass('public.recorrido_pending_outbound_idempotency_key_key') is not null,
  'outbound idempotency uniqueness exists'
);

select pg_temp.assert_true(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.recorrido_credit_ledger'::regclass
      and tgname = 'recorrido_credit_ledger_immutable'
      and not tgisinternal
  ),
  'credit ledger is immutable'
);
select pg_temp.assert_true(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.recorrido_stripe_events'::regclass
      and tgname = 'recorrido_stripe_events_immutable'
      and not tgisinternal
  ),
  'Stripe events are immutable'
);
select pg_temp.assert_true(
  exists (
    select 1 from pg_trigger
    where tgrelid = 'public.recorrido_approval_actions'::regclass
      and tgname = 'recorrido_approval_actions_immutable'
      and not tgisinternal
  ),
  'approval decisions are immutable'
);

select pg_temp.assert_true(to_regprocedure('public.recorrido_reserve_generation(uuid,uuid,text)') is not null, 'reserve RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_complete_generation(uuid,integer)') is not null, 'complete RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_release_generation(uuid,text)') is not null, 'release RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_grant_due_annual_quotas(timestamptz)') is not null, 'annual quota function exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_claim_approved_outbound(uuid)') is not null, 'approved outbound claim exists');

rollback;
