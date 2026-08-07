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

-- Synthetic fixtures have no signed HTTP body. Keep this adapter test-local.
create or replace function pg_temp.recorrido_claim_stripe_event(
  p_stripe_event_id text,p_event_type text,p_stripe_object_id text,p_livemode boolean,
  p_stripe_api_version text,p_payload jsonb,p_lease_duration interval default interval '2 minutes')
returns jsonb language sql as $$
  select public.recorrido_claim_stripe_event($1,$2,$3,$4,$5,$6,$7,$6::text)
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
select pg_temp.assert_true(to_regclass('public.recorrido_checkout_requests') is not null, 'checkout request idempotency table exists');

do $$
declare
  v_first_account uuid;
  v_second_account uuid;
begin
  insert into public.recorrido_customer_accounts(display_name)
    values ('Phone uniqueness account one') returning id into v_first_account;
  insert into public.recorrido_customer_accounts(display_name)
    values ('Phone uniqueness account two') returning id into v_second_account;

  insert into public.recorrido_account_members(account_id, full_name, phone_e164, role, status)
    values (v_first_account, 'First active member', '+573000000901', 'member', 'active');

  begin
    insert into public.recorrido_account_members(account_id, full_name, phone_e164, role, status)
      values (v_second_account, 'Second active member', '+573000000901', 'member', 'active');
    raise exception 'assertion failed: active member phone accepted across accounts';
  exception when unique_violation then
    null;
  end;
end;
$$;

select pg_temp.assert_true(
  has_table_privilege('anon', 'public.non_recorrido_privilege_sentinel', 'select')
    and has_table_privilege('authenticated', 'public.non_recorrido_privilege_sentinel', 'select'),
  'migration preserves privileges on non-Recorrido public objects'
);

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
  exists (select 1 from pg_indexes where schemaname = 'public'
    and tablename = 'recorrido_generation_jobs'
    and replace(indexdef, ' ', '') like '%UNIQUE%(account_id,idempotency_key)%'),
  'generation idempotency is unique per account'
);
select pg_temp.assert_true(
  to_regclass('public.recorrido_pending_outbound_idempotency_key_key') is not null,
  'outbound idempotency uniqueness exists'
);
select pg_temp.assert_true(
  to_regclass('public.recorrido_checkout_requests_account_id_idempotency_key_key') is not null,
  'checkout requests are idempotent per account'
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
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'recorrido_stripe_events'
      and column_name = 'processing_status'
  ),
  'Stripe events expose mutable processing state'
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
select pg_temp.assert_true(to_regprocedure('public.recorrido_grant_due_annual_quotas()') is not null, 'server-clock annual quota function exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_owner_action(text,text,text,text)') is not null, 'owner approval action RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_owner_edit(text,text,text,text)') is not null, 'owner edit RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_claim_approved_outbound(integer,text)') is not null, 'batch approved outbound claim exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_claim_approved_outbound(uuid)') is null, 'unsafe legacy single-row claim is absent');
select pg_temp.assert_true(to_regprocedure('public.recorrido_begin_outbound_send(uuid,uuid,uuid)') is not null, 'transmission checkpoint RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text)') is not null, 'fenced delivery acknowledgement RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean)') is not null, 'fenced delivery failure RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text)') is not null, 'ambiguous outcome RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean)') is not null, 'accepted reconciliation RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text)') is not null, 'not-accepted reconciliation RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_revoke_payment_credits(uuid,uuid,integer,text)') is null, 'unsupported payment revocation RPC is absent');
select pg_temp.assert_true(to_regprocedure('public.recorrido_assert_price_eligibility(uuid,text)') is not null, 'price eligibility RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_create_checkout_request(uuid,uuid,text,text,text,jsonb)') is not null, 'atomic checkout RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_claim_stripe_event(text,text,text,boolean,text,jsonb,interval,text)') is not null, 'leased atomic Stripe claim RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_finish_stripe_event(uuid,uuid,integer,boolean,text)') is not null, 'owned Stripe finish RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_finalize_checkout_request(uuid,uuid,uuid,text,text,text,timestamptz)') is not null, 'checkout finalizer exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_renew_stripe_event_lease(uuid,uuid,integer,interval)') is not null, 'lease renewal RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_stripe_payment_event(uuid,uuid,integer)') is not null, 'owned payment event RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_stripe_subscription_event(uuid,uuid,integer)') is not null, 'owned subscription event RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_stripe_subscription_payment_event(uuid,uuid,integer)') is not null, 'owned subscription payment event RPC exists');
select pg_temp.assert_true(to_regprocedure('public.recorrido_apply_stripe_reversal_event(uuid,uuid,integer)') is not null, 'owned reversal event RPC exists');
select pg_temp.assert_true((select eligible_plan_code = 'pro' from public.recorrido_price_catalog where product_code = 'pro_extra_once_usd_18'), 'Pro extra has Pro eligibility');
select pg_temp.assert_true((select eligible_plan_code = 'agency' from public.recorrido_price_catalog where product_code = 'agency_extra_once_usd_15'), 'Agency extra has Agency eligibility');

-- Stripe identity and payload stay immutable while processing is RPC-owned.
select pg_temp.recorrido_claim_stripe_event('evt_test_processing', 'checkout.session.completed', null,
  false, '2025-06-30.basil', '{"immutable":true}', interval '2 minutes');
select pg_temp.assert_true(
  (select processing_status = 'processing' and processing_attempts = 1
   from public.recorrido_stripe_events where stripe_event_id = 'evt_test_processing'),
  'Stripe processing state is mutable'
);
do $$
begin
  begin
    update public.recorrido_stripe_events set payload = '{"changed":true}' where stripe_event_id = 'evt_test_processing';
    raise exception 'assertion failed: Stripe payload mutation was accepted';
  exception when sqlstate '55000' then null;
  end;
end;
$$;

-- Shared fixtures for eligibility and credit lifecycle behavior.
create temporary table recorrido_test_ids (
  account_id uuid,
  member_id uuid,
  payment_id uuid,
  payment_bucket_id uuid,
  bucket_id uuid,
  reservation_id uuid
);

with account_row as (
  insert into public.recorrido_customer_accounts(display_name, home_country)
  values ('Test Pro', 'CO')
  returning id
), member_row as (
  insert into public.recorrido_account_members(account_id, full_name, phone_e164, role)
  select id, 'Owner', '+573001234567', 'owner' from account_row returning id, account_id
), entitlement_row as (
  insert into public.recorrido_subscription_entitlements
    (account_id, stripe_subscription_id, stripe_price_id, catalog_product_code, plan_code, billing_interval, status,
     credits_per_month, team_member_limit, current_period_start, current_period_end)
  select account_id, 'sub_test_pro', 'price_test_pro', 'pro_monthly_usd_32', 'pro', 'month', 'active', 4, 1, now(), now() + interval '1 month'
  from member_row
), payment_row as (
  insert into public.recorrido_payment_records
    (account_id, stripe_payment_intent_id, product_code, payment_kind, amount_minor, currency, status)
  select account_id, 'pi_test_extra', 'pro_extra_once_usd_18', 'extra_purchase', 1800, 'usd', 'paid'
  from member_row returning id, account_id
)
insert into recorrido_test_ids(account_id, member_id, payment_id)
select m.account_id, m.id, p.id from member_row m join payment_row p using (account_id);

update public.recorrido_price_catalog
set active = true,
    stripe_price_id = case product_code
      when 'pro_extra_once_usd_18' then 'price_pro_extra'
      when 'agency_extra_once_usd_15' then 'price_agency_extra'
    end
where product_code in ('pro_extra_once_usd_18', 'agency_extra_once_usd_15');

select pg_temp.assert_true(
  public.recorrido_assert_price_eligibility((select account_id from recorrido_test_ids), 'pro_extra_once_usd_18') = 'pro_extra_once_usd_18',
  'Pro account may buy the Pro extra price'
);
do $$
begin
  begin
    perform public.recorrido_assert_price_eligibility((select account_id from recorrido_test_ids), 'agency_extra_once_usd_15');
    raise exception 'assertion failed: Pro account accepted Agency extra price';
  exception when sqlstate '42501' then null;
  end;
end;
$$;

update recorrido_test_ids set payment_bucket_id = public.recorrido_grant_paid_purchase(payment_id);
select pg_temp.assert_true(
  (select public.recorrido_grant_paid_purchase(payment_id) = payment_bucket_id
   from recorrido_test_ids),
  'credit grant is idempotent by payment source'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.recorrido_payment_credit_buckets pcb
    join recorrido_test_ids t on pcb.payment_id = t.payment_id and pcb.bucket_id = t.payment_bucket_id
  ),
  'payment is durably associated with its credit bucket'
);
select pg_temp.assert_true(
  exists (select 1 from public.recorrido_payment_credit_buckets pcb
    join recorrido_test_ids t on pcb.payment_id = t.payment_id and pcb.bucket_id = t.payment_bucket_id),
  'extra grant replay preserves immutable payment-bucket linkage'
);

update recorrido_test_ids t
set reservation_id = (public.recorrido_reserve_generation(t.account_id, t.member_id, 'generation-key')->>'reservation_id')::uuid;
select pg_temp.assert_true(
  (select public.recorrido_available_credits(account_id) = 0 from recorrido_test_ids),
  'reservation spends one granted credit'
);
select pg_temp.assert_true(
  (select (public.recorrido_reserve_generation(account_id, member_id, 'generation-key')->>'reservation_id')::uuid = reservation_id
   from recorrido_test_ids),
  'reservation is idempotent'
);
select pg_temp.assert_true(
  (select not (public.recorrido_reserve_generation(account_id, member_id, 'no-credit-key')->>'allowed')::boolean
   from recorrido_test_ids),
  'a second reservation cannot overspend the grouped bucket balance'
);
select public.recorrido_complete_generation(reservation_id, 12) from recorrido_test_ids;
select public.recorrido_complete_generation(reservation_id, 12) from recorrido_test_ids;
select pg_temp.assert_true(
  (select status = 'consumed' from public.recorrido_generation_reservations r join recorrido_test_ids t on r.id = t.reservation_id),
  'completion is idempotent'
);

-- A separate reservation can be released exactly once.
update recorrido_test_ids
set bucket_id = public.recorrido_grant_credit_bucket(account_id, 'manual_adjustment', 'release-credit', 1);
update recorrido_test_ids t
set reservation_id = (public.recorrido_reserve_generation(t.account_id, t.member_id, 'release-key')->>'reservation_id')::uuid;
select public.recorrido_release_generation(reservation_id, 'test failure') from recorrido_test_ids;
select public.recorrido_release_generation(reservation_id, 'test failure') from recorrido_test_ids;
select pg_temp.assert_true(
  (select count(*) = 1 from public.recorrido_credit_ledger l join recorrido_test_ids t on l.bucket_id = t.bucket_id where l.entry_kind = 'release'),
  'release restores credit exactly once'
);

-- Verified Stripe evidence drives a negative, idempotent revocation.
alter table recorrido_test_ids add column reversal_id uuid;
update recorrido_test_ids set reversal_id=public.recorrido_record_stripe_reversal(
  payment_id,'re_test_verified','refund',1800,'usd',now());
select public.recorrido_revoke_stripe_reversal(reversal_id) from recorrido_test_ids;
select public.recorrido_revoke_stripe_reversal(reversal_id) from recorrido_test_ids;
select pg_temp.assert_true(
  (select count(*) = 1 and min(delta) = -1
   from public.recorrido_credit_ledger l join recorrido_test_ids t on l.bucket_id = t.payment_bucket_id
   where l.entry_kind = 'refund_reversal'),
  'payment revocation is negative and idempotent'
);

-- Suspended and closed accounts cannot reserve, even with an active member and credit.
-- Unsafe replay, isolation, and validation cases.
do $$
declare
  v_account uuid := (select account_id from recorrido_test_ids);
  v_member uuid := (select member_id from recorrido_test_ids);
  v_payment uuid := (select payment_id from recorrido_test_ids);
  v_bucket uuid := (select payment_bucket_id from recorrido_test_ids);
  v_other_account uuid;
  v_other_member uuid;
  v_other_payment uuid;
  v_pending_payment uuid;
  v_first jsonb;
  v_replay jsonb;
begin
  -- Grant replay must compare all immutable grant inputs.
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_payment::text, 2, null, null,
      jsonb_build_object('payment_id', v_payment));
    raise exception 'assertion failed: changed grant credits accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_payment::text, 1, now() + interval '1 day', null,
      jsonb_build_object('payment_id', v_payment));
    raise exception 'assertion failed: changed grant expiration accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_payment::text, 1, null, null, '{"changed":true}');
    raise exception 'assertion failed: changed grant metadata accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_payment::text, 1, null,
      (select id from public.recorrido_subscription_entitlements where account_id = v_account limit 1),
      jsonb_build_object('payment_id', v_payment));
    raise exception 'assertion failed: changed grant entitlement accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', gen_random_uuid()::text, 1);
    raise exception 'assertion failed: extra grant without paid payment accepted';
  exception when sqlstate '42501' then null; end;

  -- Same generation idempotency key is independent per account.
  insert into public.recorrido_customer_accounts(display_name) values ('Other account') returning id into v_other_account;
  insert into public.recorrido_account_members(account_id, full_name, phone_e164, role)
    values (v_other_account, 'Other Owner', '+573009876543', 'owner') returning id into v_other_member;
  insert into public.recorrido_payment_records
    (account_id, product_code, payment_kind, amount_minor, currency, status)
    values (v_other_account, 'pro_extra_once_usd_18', 'extra_purchase', 1800, 'usd', 'paid')
    returning id into v_other_payment;
  insert into public.recorrido_payment_records
    (account_id, product_code, payment_kind, amount_minor, currency, status)
    values (v_account, 'pro_extra_once_usd_18', 'extra_purchase', 1800, 'usd', 'pending')
    returning id into v_pending_payment;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_other_payment::text, 1);
    raise exception 'assertion failed: cross-account payment funded extra grant';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_grant_credit_bucket(v_account, 'extra_purchase', v_pending_payment::text, 1);
    raise exception 'assertion failed: unpaid payment funded extra grant';
  exception when sqlstate '42501' then null; end;
  perform public.recorrido_grant_credit_bucket(v_other_account, 'manual_adjustment', 'other-credit', 1);
  v_first := public.recorrido_reserve_generation(v_other_account, v_other_member, 'generation-key');
  perform pg_temp.assert_true((v_first->>'allowed')::boolean, 'same generation key works for another account');
  perform pg_temp.assert_true(
    (select account_id = v_other_account from public.recorrido_generation_jobs where id = (v_first->>'job_id')::uuid),
    'generation result cannot leak across accounts');

  -- Checkout is created only through an atomic validating operation.
  v_first := public.recorrido_create_checkout_request(v_account, v_member, 'checkout-atomic',
    'pro_extra_once_usd_18', 'fingerprint-1', '{"success_url":"https://example.test/ok"}');
  v_replay := public.recorrido_create_checkout_request(v_account, v_member, 'checkout-atomic',
    'pro_extra_once_usd_18', 'fingerprint-1', '{"success_url":"https://example.test/ok"}');
  perform pg_temp.assert_true(v_first->>'id' = v_replay->>'id', 'matching checkout replay returns original');
  perform pg_temp.assert_true(v_first->>'stripe_price_id'='price_pro_extra'
    and v_first->>'mode'='payment' and (v_first->>'amount_minor')::integer=1800
    and v_first->>'currency'='usd' and v_first ? 'stripe_customer_id',
    'checkout RPC returns authoritative active Stripe terms and optional owned customer');
  begin
    perform public.recorrido_create_checkout_request(v_account, v_member, 'checkout-atomic',
      'pro_extra_once_usd_18', 'fingerprint-2', '{"success_url":"https://evil.test"}');
    raise exception 'assertion failed: conflicting checkout replay accepted';
  exception when sqlstate '22000' then null; end;
  perform public.recorrido_finalize_checkout_request((v_first->>'id')::uuid,v_account,v_member,
    'pro_extra_once_usd_18','cs_expired_recovery','https://checkout.stripe.com/c/pay/expired',
    clock_timestamp()+interval '1 hour');
  -- Test fixture only: simulate Stripe's clock crossing the expiry boundary without
  -- exposing a runtime lifecycle bypass. session_replication_role is superuser-only.
  begin
    set local session_replication_role=replica;
    update public.recorrido_checkout_requests set expires_at=clock_timestamp()-interval '1 second'
      where id=(v_first->>'id')::uuid;
    set local session_replication_role=origin;
  exception when others then
    set local session_replication_role=origin;
    raise;
  end;
  v_replay := public.recorrido_create_checkout_request(v_account, v_member, 'checkout-atomic',
    'pro_extra_once_usd_18', 'fingerprint-1', '{"success_url":"https://example.test/ok"}');
  perform pg_temp.assert_true(v_replay->>'status'='pending' and v_replay->>'checkout_url' is null
    and v_replay->>'stripe_checkout_session_id' is null and v_replay->>'expires_at' is null,
    'expired Stripe Checkout session recovers to a fresh pending request');

  -- Subscription checkouts use the same bounded expiry/replay recovery path.
  -- Isolate this fixture from catalog activation mutations in earlier assertions.
  update public.recorrido_price_catalog
    set active=true, stripe_price_id='price_checkout_recovery_pro'
    where product_code='pro_monthly_usd_32';
  v_first := public.recorrido_create_checkout_request(v_account, v_member, 'checkout-subscription-recovery',
    'pro_monthly_usd_32', 'subscription-fingerprint', '{"success_url":"https://example.test/subscription"}');
  perform public.recorrido_finalize_checkout_request((v_first->>'id')::uuid,v_account,v_member,
    'pro_monthly_usd_32','cs_expired_subscription','https://checkout.stripe.com/c/pay/subscription-expired',
    clock_timestamp()+interval '1 hour');
  begin
    set local session_replication_role=replica;
    update public.recorrido_checkout_requests set expires_at=clock_timestamp()-interval '1 second'
      where id=(v_first->>'id')::uuid;
    set local session_replication_role=origin;
  exception when others then
    set local session_replication_role=origin;
    raise;
  end;
  v_replay := public.recorrido_create_checkout_request(v_account, v_member, 'checkout-subscription-recovery',
    'pro_monthly_usd_32', 'subscription-fingerprint', '{"success_url":"https://example.test/subscription"}');
  perform pg_temp.assert_true(v_replay->>'id'=v_first->>'id' and v_replay->>'status'='pending'
    and v_replay->>'stripe_checkout_session_id' is null and v_replay->>'checkout_url' is null
    and v_replay->>'expires_at' is null and v_replay->>'last_error' is null,
    'expired subscription Checkout replay recovers the same request to pending');
  begin
    perform public.recorrido_create_checkout_request(v_account, v_other_member, 'checkout-cross-member',
      'pro_extra_once_usd_18', 'fp', '{}');
    raise exception 'assertion failed: cross-account checkout member accepted';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_create_checkout_request(v_account, v_member, 'checkout-wrong-plan',
      'agency_extra_once_usd_15', 'fp', '{}');
    raise exception 'assertion failed: Pro account accepted Agency extra checkout';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.recorrido_create_checkout_request(v_account, v_member, 'checkout-no-catalog',
      'missing_product', 'fp', '{}');
    raise exception 'assertion failed: missing catalog checkout accepted';
  exception when sqlstate 'P0002' then null; end;

  -- Refund evidence cannot exceed the immutable payment amount.
  begin
    perform public.recorrido_record_stripe_reversal(v_payment,'re_too_much','refund',1,'usd',now());
    raise exception 'assertion failed: cumulative Stripe reversal exceeded payment';
  exception when sqlstate '22003' then null; end;
end;
$$;

-- Stripe event identity is immutable; claims and terminal transitions are atomic.
do $$
declare
  v_claim jsonb;
  v_event_id uuid;
  v_first_started_at timestamptz;
begin
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_atomic', 'payment_intent.succeeded', 'pi_atomic', false,
    '2025-06-30.basil', '{"id":"evt_atomic"}');
  v_event_id := (v_claim->>'id')::uuid;
  perform pg_temp.assert_true((v_claim->>'claimed')::boolean, 'first Stripe claim owns processing');
  perform pg_temp.assert_true(
    (select stripe_api_version = '2025-06-30.basil' and processing_attempts = 1 and processing_started_at is not null
     from public.recorrido_stripe_events where id = v_event_id), 'Stripe claim retains API version and timestamps attempt');
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_atomic', 'payment_intent.succeeded', 'pi_atomic', false,
    '2025-06-30.basil', '{"id":"evt_atomic"}');
  perform pg_temp.assert_true(not (v_claim->>'claimed')::boolean and
    (select processing_attempts = 1 from public.recorrido_stripe_events where id = v_event_id),
    'in-progress replay is not claimed or counted twice');
  begin
    perform pg_temp.recorrido_claim_stripe_event('evt_atomic', 'payment_intent.succeeded', 'pi_atomic', false,
      '2025-06-30.basil', '{"changed":true}');
    raise exception 'assertion failed: changed Stripe payload accepted';
  exception when sqlstate '22000' then null; end;
  perform public.recorrido_finish_stripe_event(v_event_id, (v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer, true, null);
  perform pg_temp.assert_true((select processing_status = 'processed' and processed_at is not null
    from public.recorrido_stripe_events where id = v_event_id), 'Stripe processing reaches processed monotonically');
  begin
    perform public.recorrido_finish_stripe_event(v_event_id, (v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer, false, 'late failure');
    raise exception 'assertion failed: processed Stripe event regressed';
  exception when sqlstate '55000' then null; end;

  v_claim := pg_temp.recorrido_claim_stripe_event('evt_retry', 'payment_intent.payment_failed', 'pi_retry', false,
    '2025-06-30.basil', '{"id":"evt_retry"}');
  v_event_id := (v_claim->>'id')::uuid;
  select processing_started_at into v_first_started_at from public.recorrido_stripe_events where id = v_event_id;
  perform public.recorrido_finish_stripe_event(v_event_id, (v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer, false, 'temporary');
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_retry', 'payment_intent.payment_failed', 'pi_retry', false,
    '2025-06-30.basil', '{"id":"evt_retry"}');
  perform pg_temp.assert_true((v_claim->>'claimed')::boolean and
    (select processing_attempts = 2 and processing_started_at >= v_first_started_at and processing_error is null
     from public.recorrido_stripe_events where id = v_event_id),
    'failed Stripe event retry increments attempts and refreshes processing state');

  v_claim := pg_temp.recorrido_claim_stripe_event('evt_stale', 'charge.refunded', 'ch_stale', false,
    '2025-06-30.basil', '{"id":"evt_stale"}', interval '1 millisecond');
  perform pg_sleep(0.01);
  declare
    v_stale_token uuid := (v_claim->>'claim_token')::uuid;
    v_stale_attempt integer := (v_claim->>'processing_attempts')::integer;
  begin
    v_claim := pg_temp.recorrido_claim_stripe_event('evt_stale', 'charge.refunded', 'ch_stale', false,
      '2025-06-30.basil', '{"id":"evt_stale"}', interval '2 minutes');
    begin
      perform public.recorrido_finish_stripe_event((v_claim->>'id')::uuid,v_stale_token,v_stale_attempt,true,null);
      raise exception 'assertion failed: stale Stripe finisher accepted';
    exception when sqlstate '55000' then null; end;
    perform public.recorrido_finish_stripe_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer,true,null);
  end;
  begin
    perform pg_temp.recorrido_claim_stripe_event('evt_wrong_mode','test',null,true,
      '2025-06-30.basil','{}',interval '2 minutes');
    raise exception 'assertion failed: unexpected Stripe livemode accepted';
  exception when sqlstate '42501' then null; end;
end;
$$;

-- Actual NOLOGIN workers can complete the checkout and webhook lifecycle without table DML.
do $$
declare
  v_account uuid;
  v_other_account uuid;
  v_member uuid;
  v_member_phone text;
  v_request jsonb;
  v_subscription_request jsonb;
  v_finished jsonb;
  v_claim jsonb;
  v_payment uuid;
  v_reversal uuid;
  v_now timestamptz := date_trunc('second', clock_timestamp());
begin
  update public.recorrido_price_catalog set active=true, stripe_price_id=case product_code
    when 'single_listing_once_usd_22' then 'price_single_22'
    when 'pro_monthly_usd_32' then 'price_pro_monthly_32'
    else stripe_price_id end
  where product_code in ('single_listing_once_usd_22','pro_monthly_usd_32');
  insert into public.recorrido_customer_accounts(display_name, home_country)
    values ('Worker lifecycle', 'CO') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Worker Owner','+573001110099','owner') returning id,phone_e164 into v_member,v_member_phone;
  perform pg_temp.assert_true(not exists (select 1 from public.recorrido_stripe_customers where account_id=v_account),
    'new subscription checkout lifecycle starts without a Stripe customer binding');

  execute 'set local role recorrido_billing_checkout_worker';
  v_request := public.recorrido_create_checkout_request(v_account,v_member,'worker-checkout',
    'single_listing_once_usd_22','worker-fingerprint','{"success_url":"https://example.test/success"}');
  v_finished := public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
    'single_listing_once_usd_22','cs_worker_exact','https://checkout.stripe.com/c/pay/worker',v_now+interval '30 minutes');
  perform pg_temp.assert_true(v_finished->>'status'='created','checkout worker finalizes pending request');
  perform public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
    'single_listing_once_usd_22','cs_worker_exact','https://checkout.stripe.com/c/pay/worker',v_now+interval '30 minutes');
  begin
    perform public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
      'single_listing_once_usd_22','cs_changed','https://checkout.stripe.com/c/pay/worker',v_now+interval '30 minutes');
    raise exception 'assertion failed: conflicting checkout finalization replay accepted';
  exception when sqlstate '22000' then null; end;
  begin
    perform public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
      'single_listing_once_usd_22','cs_changed','https://checkout.stripe.com.evil.test/session',v_now+interval '30 minutes');
    raise exception 'assertion failed: non-Stripe Checkout hostname accepted';
  exception when sqlstate '22023' then null; end;

  v_subscription_request := public.recorrido_create_checkout_request(v_account,v_member,'worker-subscription-checkout',
    'pro_monthly_usd_32','worker-subscription-fingerprint','{"success_url":"https://example.test/success"}');
  perform public.recorrido_finalize_checkout_request((v_subscription_request->>'id')::uuid,v_account,v_member,
    'pro_monthly_usd_32','cs_worker_subscription','https://checkout.stripe.com/c/pay/subscription',v_now+interval '30 minutes');

  execute 'reset role';
  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_checkout','checkout.session.completed','cs_worker_exact',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','cs_worker_exact','payment_intent','pi_worker_checkout','customer','cus_worker_subscription','amount_total',2200,
      'currency','usd','payment_status','paid','status','complete','mode','payment',
      'created',extract(epoch from v_now)::bigint,'client_reference_id',v_request->>'id',
      'metadata',jsonb_build_object('account_id',v_account,'product_code','single_listing_once_usd_22',
        'member_id',v_member,
        'purchase_type','single_listing','internal_price_code','single_listing_once_usd_22',
        'normalized_whatsapp_phone',v_member_phone,
        'country','CO','checkout_request_id',v_request->>'id')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  execute 'reset role';
  perform pg_temp.assert_true((select stripe_checkout_session_id='cs_worker_exact'
    from public.recorrido_payment_records where stripe_payment_intent_id='pi_worker_checkout'),
    'completed Checkout Session is accepted as owned payment evidence');

  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_subscription_checkout','checkout.session.completed','cs_worker_subscription',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','cs_worker_subscription','customer','cus_worker_subscription','amount_total',3200,
      'currency','usd','payment_status','paid','status','complete','mode','subscription',
      'created',extract(epoch from v_now)::bigint,'client_reference_id',v_subscription_request->>'id',
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32',
        'member_id',v_member,
        'purchase_type','subscription','internal_price_code','pro_monthly_usd_32',
        'normalized_whatsapp_phone',v_member_phone,
        'country','CO','checkout_request_id',v_subscription_request->>'id')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  execute 'reset role';
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_stripe_customers
    where account_id=v_account and stripe_customer_id='cus_worker_subscription'),
    'verified subscription Checkout binds its Stripe customer to the request account');
  insert into public.recorrido_customer_accounts(display_name) values ('Worker cross-account customer') returning id into v_other_account;
  insert into public.recorrido_stripe_customers(account_id,stripe_customer_id) values(v_other_account,'cus_worker_cross_account');
  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_subscription_checkout_cross','checkout.session.completed','cs_worker_subscription',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','cs_worker_subscription','customer','cus_worker_cross_account','amount_total',3200,
      'currency','usd','payment_status','paid','status','complete','mode','subscription',
      'created',extract(epoch from v_now)::bigint,'client_reference_id',v_subscription_request->>'id',
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32',
        'checkout_request_id',v_subscription_request->>'id')))),interval '2 minutes');
  begin
    perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,
      (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: cross-account subscription Checkout customer replay accepted';
  exception when sqlstate '22000' then null; end;
  execute 'reset role';

  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_payment','payment_intent.succeeded','pi_worker_checkout',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','pi_worker_checkout','customer','cus_worker_subscription','amount_received',2200,'currency','usd','status','succeeded',
      'created',extract(epoch from v_now)::bigint,
      'metadata',jsonb_build_object('account_id',v_account,'product_code','single_listing_once_usd_22',
        'member_id',v_member,'internal_price_code','single_listing_once_usd_22',
        'normalized_whatsapp_phone',v_member_phone,'country','CO','purchase_type','single_listing',
        'checkout_request_id',v_request->>'id')))),interval '2 minutes');
  v_payment := (public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer)->>'payment_id')::uuid;
  perform pg_temp.assert_true(public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer)->>'payment_id'=v_payment::text,
    'matching payment application replays exactly');
  begin
    perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,gen_random_uuid(),
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: foreign claim applied payment';
  exception when sqlstate '55000' then null; end;
  execute 'reset role';
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_payment_credit_buckets where payment_id=v_payment),
    'verified payment has exactly one linked bucket');

  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_subscription','customer.subscription.created','sub_worker',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_worker','customer','cus_worker_subscription','status','active','cancel_at_period_end',false,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_worker',
        'current_period_start',extract(epoch from v_now)::bigint,'current_period_end',extract(epoch from v_now+interval '1 month')::bigint,
        'price',jsonb_build_object('id','price_pro_monthly_32')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  execute 'reset role';
  perform pg_temp.assert_true((select credits_per_month=4 and team_member_limit=1 and catalog_product_code='pro_monthly_usd_32'
    from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_worker'),
    'subscription terms derive from verified active catalog evidence');

  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_reversal','charge.refunded','ch_worker',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','ch_worker','payment_intent','pi_worker_checkout','amount',2200,'amount_refunded',500,'currency','usd',
      'refunds',jsonb_build_object('object','list','data',jsonb_build_array(jsonb_build_object(
        'id','re_worker_partial','object','refund','charge','ch_worker','payment_intent','pi_worker_checkout',
        'amount',500,'currency','usd','created',extract(epoch from v_now)::bigint,
        'status','succeeded','kind','attacker-controlled')))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_reversal_second','charge.refunded','ch_worker',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','ch_worker','payment_intent','pi_worker_checkout','amount',2200,'amount_refunded',2200,'currency','usd',
      'refunds',jsonb_build_object('object','list','data',jsonb_build_array(
        jsonb_build_object('id','re_worker_partial','object','refund','charge','ch_worker','payment_intent','pi_worker_checkout',
          'amount',500,'currency','usd','created',extract(epoch from v_now)::bigint,'status','succeeded'),
        jsonb_build_object('id','re_worker_rest','object','refund','charge','ch_worker','payment_intent','pi_worker_checkout',
          'amount',1700,'currency','usd','created',extract(epoch from v_now+interval '1 minute')::bigint,'status','succeeded')))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  execute 'reset role';
  perform pg_temp.assert_true((select count(*)=2 and sum(amount_minor)=2200
      and bool_and(reversal_kind='refund') from public.recorrido_stripe_reversals where payment_id=v_payment),
    'partial and multiple refunds create one durable server-derived record per re_ object');
  perform pg_temp.assert_true((select count(*)=1 and sum(delta)=-1 from public.recorrido_credit_ledger
      where bucket_id in (select bucket_id from public.recorrido_payment_credit_buckets where payment_id=v_payment)
        and entry_kind='refund_reversal'),
    'repeated and multiple refunds revoke the indivisible purchase only once');

  execute 'set local role recorrido_billing_webhook_worker';
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_worker_dispute','charge.dispute.created','dp_worker',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','dp_worker','object','dispute','charge','ch_worker_checkout','payment_intent','pi_worker_checkout',
      'amount',600,'currency','usd','created',extract(epoch from v_now)::bigint,
      'status','needs_response','kind','refund'))),interval '2 minutes');
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,
    (v_claim->>'claim_token')::uuid,(v_claim->>'processing_attempts')::integer);
  execute 'reset role';
  perform pg_temp.assert_true((select count(*)=1 and bool_and(reversal_kind='dispute' and amount_minor=600)
      from public.recorrido_stripe_reversals where stripe_reversal_id='dp_worker'),
    'actual dispute schema stores dp_ evidence with server-derived dispute kind and amount');
end;
$$;

-- Signed subscription lifecycle and paid-period credit evidence are independent:
-- creation never mints, invoice payment mints exact catalog credits once.
do $$
declare
  v_account uuid;
  v_agency_account uuid;
  v_annual_account uuid;
  v_claim jsonb;
  v_result jsonb;
  v_invoice_payload jsonb;
  v_t0 timestamptz := date_trunc('month', clock_timestamp()) + interval '1 month';
  v_t1 timestamptz := date_trunc('month', clock_timestamp()) + interval '2 months';
  v_t2 timestamptz := date_trunc('month', clock_timestamp()) + interval '3 months';
begin
  update public.recorrido_price_catalog set active=true, stripe_price_id=case product_code
    when 'pro_monthly_usd_32' then 'price_lifecycle_pro'
    when 'agency_monthly_usd_79' then 'price_lifecycle_agency'
    when 'pro_annual_usd_320' then 'price_lifecycle_annual'
    else stripe_price_id end
  where product_code in ('pro_monthly_usd_32','agency_monthly_usd_79','pro_annual_usd_320');

  insert into public.recorrido_customer_accounts(display_name) values ('Lifecycle Pro') returning id into v_account;
  insert into public.recorrido_stripe_customers(account_id,stripe_customer_id) values(v_account,'cus_lifecycle_pro');

  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_created','customer.subscription.created','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t0)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','incomplete','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t0)::bigint,'current_period_end',extract(epoch from v_t1)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  v_result:=public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select count(*)=0 from public.recorrido_credit_buckets where account_id=v_account),
    'subscription.created mints no credits');

  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_active','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t0)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t0)::bigint,'current_period_end',extract(epoch from v_t1)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select status='active' and latest_event_id='evt_lifecycle_active'
    from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle'),
    'equal-second created to active uses semantic state, not opaque event ID ordering');

  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_1','invoice.paid','in_pro_1',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','in_pro_1','customer','cus_lifecycle_pro','payment_intent','pi_lifecycle_pro_1','status','paid','paid',true,
      'amount_paid',3200,'currency','usd','billing_reason','subscription_create',
      'parent',jsonb_build_object('type','subscription_details','subscription_details',jsonb_build_object('subscription','sub_lifecycle')),
      'lines',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'parent',jsonb_build_object('type','subscription_item_details','subscription_item_details',jsonb_build_object(
          'proration',false,'subscription_item','si_fixture')),
        'pricing',jsonb_build_object('type','price_details','price_details',jsonb_build_object('price','price_lifecycle_pro')),
        'currency','usd','amount',3200,
        'period',jsonb_build_object('start',extract(epoch from v_t0)::bigint,'end',extract(epoch from v_t1)::bigint))))))),interval '2 minutes');
  v_result:=public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_1_related','invoice.payment_succeeded','in_pro_1',false,
    '2025-06-30.basil',v_claim->'payload',interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  v_invoice_payload:=v_claim->'payload';
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_bad_amount','invoice.paid','in_pro_bad_amount',false,
    '2025-06-30.basil',jsonb_set(jsonb_set(jsonb_set(v_invoice_payload,'{data,object,id}','"in_pro_bad_amount"'),
      '{data,object,amount_paid}','3199'),'{data,object,lines,data,0,amount}','3199'),interval '2 minutes');
  begin
    perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: partial invoice amount accepted';
  exception when sqlstate '22000' then null; end;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_proration','invoice.paid','in_pro_proration',false,
    '2025-06-30.basil',jsonb_set(jsonb_set(v_invoice_payload,'{data,object,id}','"in_pro_proration"'),
      '{data,object,lines,data,0,parent,subscription_item_details,proration}','true'),interval '2 minutes');
  begin
    perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: prorated invoice accepted';
  exception when sqlstate '22000' then null; end;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_change','invoice.paid','in_pro_change',false,
    '2025-06-30.basil',jsonb_set(jsonb_set(v_invoice_payload,'{data,object,id}','"in_pro_change"'),
      '{data,object,lines,data,0,pricing,price_details,price}','"price_lifecycle_agency"'),interval '2 minutes');
  begin
    perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: subscription change invoice accepted';
  exception when sqlstate '22000' then null; end;
  reset role;
  perform pg_temp.assert_true((select count(*)=1 and sum(credits_granted)=4 from public.recorrido_credit_buckets
    where account_id=v_account and source_kind='subscription'), 'Pro paid period grants exactly four credits once');
  perform pg_temp.assert_true((select count(*)=1 and bool_and(payment_kind='subscription' and status='paid'
      and amount_minor=3200 and currency='usd' and product_code='pro_monthly_usd_32'
      and stripe_payment_intent_id='pi_lifecycle_pro_1' and stripe_subscription_id='sub_lifecycle'
      and service_period_start=v_t0 and service_period_end=v_t1)
    from public.recorrido_payment_records where stripe_invoice_id='in_pro_1'),
    'paid subscription invoice creates one durable payment record');
  perform pg_temp.assert_true((select count(*)=1 and sum(delta)=4 from public.recorrido_credit_ledger
    where account_id=v_account and entry_kind='grant' and source_type='subscription'), 'Pro grant ledger delta is exactly four');

  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_renewed','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t1)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t1)::bigint,'current_period_end',extract(epoch from v_t2)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_pro_2','invoice.payment_succeeded','in_pro_2',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','in_pro_2','customer','cus_lifecycle_pro','payment_intent','pi_lifecycle_pro_2','status','paid','paid',true,
      'amount_paid',3200,'currency','usd','billing_reason','subscription_cycle',
      'parent',jsonb_build_object('type','subscription_details','subscription_details',jsonb_build_object('subscription','sub_lifecycle')),
      'lines',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'parent',jsonb_build_object('type','subscription_item_details','subscription_item_details',jsonb_build_object(
          'proration',false,'subscription_item','si_fixture')),
        'pricing',jsonb_build_object('type','price_details','price_details',jsonb_build_object('price','price_lifecycle_pro')),
        'currency','usd','amount',3200,
        'period',jsonb_build_object('start',extract(epoch from v_t1)::bigint,'end',extract(epoch from v_t2)::bigint))))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select count(*)=2 and sum(credits_granted)=8 from public.recorrido_credit_buckets
    where account_id=v_account and source_kind='subscription'), 'Pro renewal creates one next-period grant');

  -- A stale period and a catalog/price mutation both fail closed.
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_regression','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','past_due','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t0)::bigint,'current_period_end',extract(epoch from v_t1)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  v_result:=public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  perform pg_temp.assert_true((v_result->>'ignored')::boolean,
    'subscription period regression is durably ignored without webhook retry');
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_price_change','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t1)::bigint,'current_period_end',extract(epoch from v_t2)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_agency')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','agency_monthly_usd_79')))),interval '2 minutes');
  begin
    perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: subscription price/catalog mutation accepted';
  exception when sqlstate '22000' then null; end;

  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_canceled','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',true,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t1)::bigint,'current_period_end',extract(epoch from v_t2)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select status='active' and cancel_at_period_end
    from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle'),
    'same-period cancellation intent advances monotonically without forcing terminal state');
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_zz_cancel_reverse','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t1)::bigint,'current_period_end',extract(epoch from v_t2)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  v_result:=public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((v_result->>'ignored')::boolean and
    (select cancel_at_period_end from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle'),
    'equal-second cancellation reversal is ignored even with a lexically later opaque event ID');
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_deleted','customer.subscription.deleted','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','canceled','cancel_at_period_end',true,'canceled_at',extract(epoch from v_t2)::bigint,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t1)::bigint,'current_period_end',extract(epoch from v_t2)::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select status='canceled' and latest_event_id='evt_lifecycle_deleted'
    from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle'),
    'equal-second active to deleted honors terminal precedence');

  -- A terminal subscription cannot be resurrected, but a replacement ID can be live.
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_resurrect','customer.subscription.updated','sub_lifecycle',false,
    '2025-06-30.basil',jsonb_build_object('created',extract(epoch from v_t2)::bigint,'data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle',
        'current_period_start',extract(epoch from v_t2)::bigint,'current_period_end',extract(epoch from v_t2+interval '1 month')::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  v_result:=public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((v_result->>'ignored')::boolean and
    (select status='canceled' from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle'),
    'terminal subscription resurrection is durably ignored');
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_lifecycle_replacement','customer.subscription.created','sub_lifecycle_2',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','sub_lifecycle_2','customer','cus_lifecycle_pro','status','active','cancel_at_period_end',false,'canceled_at',null,
      'items',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'id','si_fixture','subscription','sub_lifecycle_2',
        'current_period_start',extract(epoch from v_t2)::bigint,'current_period_end',extract(epoch from v_t2+interval '1 month')::bigint,
        'price',jsonb_build_object('id','price_lifecycle_pro')))),
      'metadata',jsonb_build_object('account_id',v_account,'product_code','pro_monthly_usd_32')))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_subscription_entitlements
    where account_id=v_account and status in ('trialing','active','past_due','paused')), 'terminal cancellation permits one live replacement');

  -- Agency payment derives 12; annual payment derives 4 now and schedules monthly, never 48 upfront.
  insert into public.recorrido_customer_accounts(display_name) values ('Lifecycle Agency') returning id into v_agency_account;
  insert into public.recorrido_stripe_customers(account_id,stripe_customer_id) values(v_agency_account,'cus_lifecycle_agency');
  insert into public.recorrido_subscription_entitlements(account_id,stripe_subscription_id,stripe_customer_id,stripe_price_id,catalog_product_code,
    plan_code,billing_interval,status,credits_per_month,team_member_limit,current_period_start,current_period_end)
  values(v_agency_account,'sub_lifecycle_agency','cus_lifecycle_agency','price_lifecycle_agency','agency_monthly_usd_79','agency','month','active',12,3,v_t0,v_t1);
  insert into public.recorrido_customer_accounts(display_name) values ('Lifecycle Annual') returning id into v_annual_account;
  insert into public.recorrido_stripe_customers(account_id,stripe_customer_id) values(v_annual_account,'cus_lifecycle_annual');
  insert into public.recorrido_subscription_entitlements(account_id,stripe_subscription_id,stripe_customer_id,stripe_price_id,catalog_product_code,
    plan_code,billing_interval,status,credits_per_month,team_member_limit,current_period_start,current_period_end)
  values(v_annual_account,'sub_lifecycle_annual','cus_lifecycle_annual','price_lifecycle_annual','pro_annual_usd_320','pro','year','active',4,1,v_t0,v_t0+interval '1 year');
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_agency','invoice.paid','in_agency_1',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','in_agency_1','customer','cus_lifecycle_agency',
      'payment_intent','pi_lifecycle_agency','status','paid','paid',true,'amount_paid',7900,'currency','usd','billing_reason','subscription_create',
      'parent',jsonb_build_object('type','subscription_details','subscription_details',jsonb_build_object('subscription','sub_lifecycle_agency')),
      'lines',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'parent',jsonb_build_object('type','subscription_item_details','subscription_item_details',jsonb_build_object('proration',false,'subscription_item','si_agency')),
        'pricing',jsonb_build_object('type','price_details','price_details',jsonb_build_object('price','price_lifecycle_agency')),
        'currency','usd','amount',7900,'period',jsonb_build_object('start',extract(epoch from v_t0)::bigint,'end',extract(epoch from v_t1)::bigint))))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_invoice_annual','invoice.paid','in_annual_1',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','in_annual_1','customer','cus_lifecycle_annual',
      'payment_intent','pi_lifecycle_annual','status','paid','paid',true,'amount_paid',32000,'currency','usd','billing_reason','subscription_create',
      'parent',jsonb_build_object('type','subscription_details','subscription_details',jsonb_build_object('subscription','sub_lifecycle_annual')),
      'lines',jsonb_build_object('data',jsonb_build_array(jsonb_build_object(
        'parent',jsonb_build_object('type','subscription_item_details','subscription_item_details',jsonb_build_object('proration',false,'subscription_item','si_annual')),
        'pricing',jsonb_build_object('type','price_details','price_details',jsonb_build_object('price','price_lifecycle_annual')),
        'currency','usd','amount',32000,'period',jsonb_build_object('start',extract(epoch from v_t0)::bigint,'end',extract(epoch from v_t0+interval '1 year')::bigint))))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_subscription_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select count(*)=1 and sum(credits_granted)=12 from public.recorrido_credit_buckets
    where account_id=v_agency_account and source_kind='subscription'), 'Agency paid period grants exactly twelve credits');
  perform pg_temp.assert_true((select count(*)=1 and sum(credits_granted)=4 from public.recorrido_credit_buckets
    where account_id=v_annual_account and source_kind='subscription'), 'annual Pro paid invoice grants four, not 48 upfront');
  perform pg_temp.assert_true((select count(*)=1 and bool_and(payment_kind='subscription' and amount_minor=32000)
    from public.recorrido_payment_records where stripe_invoice_id='in_annual_1'),
    'annual invoice payment is durably recorded');
  set local role recorrido_billing_quota_worker;
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas()=0,
    'quota worker server clock cannot accelerate a future monthly quota');
  reset role;
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_t1)=1,
    'annual scheduler grants exactly the next monthly quota');
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_t1)=0,
    'annual scheduler replay does not duplicate a monthly grant');
  perform pg_temp.assert_true((select count(*)=2 and sum(credits_granted)=8 from public.recorrido_credit_buckets
    where account_id=v_annual_account and source_kind='subscription'), 'annual subscription has two distinct four-credit monthly buckets');
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_t0+interval '1 year')=1,
    'even a far-future owner test clock grants only one monthly period per invocation');
  perform pg_temp.assert_true((select count(*)=3 and sum(credits_granted)=12 from public.recorrido_credit_buckets
    where account_id=v_annual_account and source_kind='subscription'), 'annual catch-up still grants exactly four, never 48 upfront');
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_annual_refund','charge.refunded','ch_annual_refund',false,
    '2025-06-30.basil',jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id','ch_annual_refund','payment_intent','pi_lifecycle_annual','amount',32000,'amount_refunded',32000,'currency','usd',
      'refunds',jsonb_build_object('object','list','data',jsonb_build_array(jsonb_build_object(
        'id','re_annual_refund','object','refund','charge','ch_annual_refund','payment_intent','pi_lifecycle_annual',
        'amount',32000,'currency','usd','created',extract(epoch from v_t1)::bigint,'status','succeeded')))))),interval '2 minutes');
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true((select status='unpaid' and next_credit_grant_at is null
    from public.recorrido_subscription_entitlements where stripe_subscription_id='sub_lifecycle_annual'),
    'annual invoice refund stops every future scheduled grant');
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_t0+interval '2 years')=0,
    'refunded annual subscription cannot grant again');
end;
$$;

-- Annual quota boundaries stay anchored to the paid annual period. A January
-- 31 start must not drift permanently to the 29th after February, and the
-- paid year contains exactly twelve grants.
do $$
declare
  v_account uuid;
  v_entitlement uuid;
  v_start timestamptz := '2028-01-31 12:00:00+00';
  v_end timestamptz := '2029-01-31 12:00:00+00';
  v_index integer;
begin
  update public.recorrido_price_catalog set active=true, stripe_price_id='price_boundary_annual'
    where product_code='pro_annual_usd_320';
  insert into public.recorrido_customer_accounts(display_name)
    values('Annual boundary') returning id into v_account;
  insert into public.recorrido_stripe_customers(account_id,stripe_customer_id)
    values(v_account,'cus_boundary_annual');
  insert into public.recorrido_subscription_entitlements(
    account_id,stripe_subscription_id,stripe_customer_id,stripe_price_id,catalog_product_code,
    plan_code,billing_interval,status,credits_per_month,team_member_limit,current_period_start,
    current_period_end,next_credit_grant_at)
  values(v_account,'sub_boundary_annual','cus_boundary_annual','price_boundary_annual',
    'pro_annual_usd_320','pro','year','active',4,1,v_start,v_end,v_start+interval '1 month')
  returning id into v_entitlement;
  perform public.recorrido_grant_credit_bucket(v_account,'subscription',
    'sub_boundary_annual:'||extract(epoch from v_start)::bigint::text,4,
    v_start+interval '1 month',v_entitlement,
    jsonb_build_object('period_start',v_start,'period_end',v_start+interval '1 month'));
  for v_index in 1..11 loop
    perform pg_temp.assert_true(
      public.recorrido_grant_due_annual_quotas_internal(
        (v_start at time zone 'UTC' + v_index*interval '1 month') at time zone 'UTC')=1,
      'each anchored annual boundary grants once');
  end loop;
  perform pg_temp.assert_true((select count(*)=12 and sum(credits_granted)=48
    from public.recorrido_credit_buckets where entitlement_id=v_entitlement),
    'annual paid period creates exactly twelve four-credit grants');
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_credit_buckets
    where entitlement_id=v_entitlement
      and (metadata->>'period_start')::timestamptz='2028-03-31 12:00:00+00'),
    'annual quota boundaries remain anchored after February');
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_end)=0,
    'annual paid-period boundary never creates a thirteenth grant');
end;
$$;

-- The same anchored twelve-grant invariant holds when February has 28 days.
do $$
declare
  v_account uuid; v_entitlement uuid; v_index integer;
  v_start timestamptz := '2027-01-31 12:00:00+00';
  v_end timestamptz := '2028-01-31 12:00:00+00';
begin
  insert into public.recorrido_customer_accounts(display_name) values('Annual non-leap boundary') returning id into v_account;
  insert into public.recorrido_subscription_entitlements(
    account_id,stripe_subscription_id,stripe_price_id,catalog_product_code,plan_code,billing_interval,
    status,credits_per_month,team_member_limit,current_period_start,current_period_end,next_credit_grant_at)
  values(v_account,'sub_boundary_nonleap','price_boundary_annual','pro_annual_usd_320','pro','year',
    'active',4,1,v_start,v_end,v_start+interval '1 month') returning id into v_entitlement;
  perform public.recorrido_grant_credit_bucket(v_account,'subscription',
    'sub_boundary_nonleap:'||extract(epoch from v_start)::bigint::text,4,
    v_start+interval '1 month',v_entitlement,jsonb_build_object('period_start',v_start,'period_end',v_start+interval '1 month'));
  for v_index in 1..11 loop
    perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(
      (v_start at time zone 'UTC' + v_index*interval '1 month') at time zone 'UTC')=1,
      'each non-leap anchored annual boundary grants once');
  end loop;
  perform pg_temp.assert_true((select count(*)=12 from public.recorrido_credit_buckets
    where entitlement_id=v_entitlement),'non-leap annual paid period creates exactly twelve grants');
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_credit_buckets
    where entitlement_id=v_entitlement and
      (metadata->>'period_start')::timestamptz='2027-03-31 12:00:00+00'),
    'non-leap February does not drift the March boundary');
  perform pg_temp.assert_true(public.recorrido_grant_due_annual_quotas_internal(v_end)=0,
    'non-leap annual boundary never creates a thirteenth grant');
end;
$$;

-- Expiry is authoritative without a reclaimer; renewal is bounded and ownership-fenced.
do $$
declare v_claim jsonb; v_renewed jsonb;
begin
  set local role recorrido_billing_webhook_worker;
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_expiry_only','test','obj_expiry',false,
    '2025-06-30.basil','{"data":{"object":{}}}',interval '1 millisecond');
  perform pg_sleep(0.01);
  begin
    perform public.recorrido_finish_stripe_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer,true,null);
    raise exception 'assertion failed: expired lease finished without reclamation';
  exception when sqlstate '55000' then null; end;
  v_claim := pg_temp.recorrido_claim_stripe_event('evt_renew','test','obj_renew',false,
    '2025-06-30.basil','{"data":{"object":{}}}',interval '1 minute');
  v_renewed := public.recorrido_renew_stripe_event_lease((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer,interval '2 minutes');
  perform pg_temp.assert_true((v_renewed->>'lease_expires_at')::timestamptz>(v_claim->>'lease_expires_at')::timestamptz,
    'owned attempt renews its live lease');
  begin
    perform public.recorrido_renew_stripe_event_lease((v_claim->>'id')::uuid,gen_random_uuid(),
      (v_claim->>'processing_attempts')::integer,interval '1 minute');
    raise exception 'assertion failed: foreign owner renewed lease';
  exception when sqlstate '55000' then null; end;
end;
$$;
reset role;

-- A nonpositive account total blocks reservation despite a positive individual bucket.
do $$
declare
  v_account uuid;
  v_member uuid;
  v_negative_bucket uuid;
  v_result jsonb;
begin
  insert into public.recorrido_customer_accounts(display_name) values ('Net zero') returning id into v_account;
  insert into public.recorrido_account_members(account_id, full_name, phone_e164, role)
    values (v_account, 'Net Owner', '+573004445566', 'owner') returning id into v_member;
  perform public.recorrido_grant_credit_bucket(v_account, 'manual_adjustment', 'net-positive', 1);
  insert into public.recorrido_credit_buckets(account_id, source_kind, source_id, credits_granted)
    values (v_account, 'refund', 'net-negative', 1) returning id into v_negative_bucket;
  insert into public.recorrido_credit_ledger(account_id, bucket_id, delta, entry_kind, source_type, source_id)
    values (v_account, v_negative_bucket, -1, 'refund_reversal', 'test', 'net-negative');
  v_result := public.recorrido_reserve_generation(v_account, v_member, 'net-zero-reserve');
  perform pg_temp.assert_true(not (v_result->>'allowed')::boolean, 'nonpositive account balance blocks reservation');
end;
$$;

update public.recorrido_customer_accounts set status = 'suspended'
where id = (select account_id from recorrido_test_ids);
do $$
begin
  begin
    perform public.recorrido_reserve_generation((select account_id from recorrido_test_ids), (select member_id from recorrido_test_ids), 'suspended-key');
    raise exception 'assertion failed: suspended account reserved credit';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.recorrido_create_checkout_request(
      (select account_id from recorrido_test_ids), (select member_id from recorrido_test_ids),
      'suspended-checkout', 'pro_extra_once_usd_18', 'fp', '{}');
    raise exception 'assertion failed: suspended account created checkout';
  exception when sqlstate '42501' then null;
  end;
end;
$$;
update public.recorrido_customer_accounts set status = 'closed'
where id = (select account_id from recorrido_test_ids);
do $$
begin
  begin
    perform public.recorrido_reserve_generation((select account_id from recorrido_test_ids), (select member_id from recorrido_test_ids), 'closed-key');
    raise exception 'assertion failed: closed account reserved credit';
  exception when sqlstate '42501' then null;
  end;
end;
$$;

-- Production owner-approval and dispatcher contract.
do $$
declare
  v_account uuid; v_owner_member uuid; v_approved uuid; v_edit uuid; v_expired uuid;
  v_opted uuid; v_retry uuid; v_reject uuid; v_claim jsonb; v_item jsonb; v_attempt uuid; v_token uuid; v_before integer;
  v_edit_result jsonb; v_rotated_token text;
begin
  -- Isolate the dispatcher queue from valid approved rows created by earlier test blocks.
  update public.recorrido_pending_outbound
    set status='failed', last_error='test_fixture_isolation'
    where status in ('approved','sending');
  insert into public.recorrido_customer_accounts(display_name) values('Outbound contract') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Dispatch Owner','+573007770001','owner') returning id into v_owner_member;
  insert into public.recorrido_pending_outbound
    (account_id,member_id,recipient_phone_e164,message_type,payload,preview_text,idempotency_key,approval_token_hash,approval_expires_at)
  values
    (v_account,v_owner_member,'+573007770101','text','{"body":"Approved exact body"}','Approved exact body','approval-ok',encode(digest('approve_token','sha256'),'hex'),clock_timestamp()+interval '1 hour'),
    (v_account,v_owner_member,'+573007770102','text','{"body":"Before edit"}','Before edit','approval-edit',encode(digest('edit_token','sha256'),'hex'),clock_timestamp()+interval '1 hour'),
    (v_account,v_owner_member,'+573007770103','text','{"body":"Expired"}','Expired','approval-expired',encode(digest('expired_token','sha256'),'hex'),clock_timestamp()-interval '1 second'),
    (v_account,v_owner_member,'+573007770104','text','{"body":"Opted out"}','Opted out','approval-opted',encode(digest('opted_token','sha256'),'hex'),clock_timestamp()+interval '1 hour'),
    (v_account,v_owner_member,'+573007770105','text','{"body":"Retry body"}','Retry body','approval-retry',encode(digest('retry_token','sha256'),'hex'),clock_timestamp()+interval '1 hour'),
    (v_account,v_owner_member,'+573007770106','text','{"body":"Reject body"}','Reject body','approval-reject',encode(digest('reject_token','sha256'),'hex'),clock_timestamp()+interval '1 hour');
  select id into v_approved from public.recorrido_pending_outbound where idempotency_key='approval-ok';
  select id into v_edit from public.recorrido_pending_outbound where idempotency_key='approval-edit';
  select id into v_expired from public.recorrido_pending_outbound where idempotency_key='approval-expired';
  select id into v_opted from public.recorrido_pending_outbound where idempotency_key='approval-opted';
  select id into v_retry from public.recorrido_pending_outbound where idempotency_key='approval-retry';
  select id into v_reject from public.recorrido_pending_outbound where idempotency_key='approval-reject';

  v_before := (select count(*) from public.recorrido_approval_actions);
  begin
    perform public.recorrido_apply_owner_action('+573007770001','+573007770002','approve','approve_token');
    raise exception 'assertion failed: wrong sender approved'; exception when sqlstate '42501' then null; end;
  perform pg_temp.assert_true((select status='pending' from public.recorrido_pending_outbound where id=v_approved)
    and (select count(*) from public.recorrido_approval_actions)=v_before,'wrong owner fails without mutation');
  begin
    perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve','expired_token');
    raise exception 'assertion failed: expired token approved'; exception when sqlstate '42501' then null; end;
  perform pg_temp.assert_true((select status='pending' from public.recorrido_pending_outbound where id=v_expired),'expired token fails closed');

  perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve','approve_token');
  perform pg_temp.assert_true((select status='approved' and approved_by_phone_e164='+573007770001'
    and approved_revision=edit_revision and approved_at is not null from public.recorrido_pending_outbound where id=v_approved),
    'approve atomically records exact owner, revision and time');
  begin
    perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve','approve_token');
    raise exception 'assertion failed: approval token replayed'; exception when sqlstate '42501' then null; end;
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_approval_actions where pending_outbound_id=v_approved),
    'approval replay creates no second immutable action');
  perform public.recorrido_apply_owner_action('+573007770001','+573007770001','reject','reject_token');
  perform pg_temp.assert_true((select status='rejected' and rejected_at is not null and approved_at is null
    from public.recorrido_pending_outbound where id=v_reject),'reject atomically blocks the outbound');

  v_edit_result:=public.recorrido_apply_owner_edit('+573007770001','+573007770001','edit_token','Replacement body');
  v_rotated_token:=v_edit_result->>'approvalToken';
  perform pg_temp.assert_true((v_edit_result->>'decision')='need_new_review',
    'edit requires a new review');
  perform pg_temp.assert_true((select status='pending' and edit_revision=2 and approved_revision is null
    and payload='{"body":"Replacement body"}' and preview_text='Replacement body'
    and approval_expires_at>clock_timestamp()
    and approval_token_hash=encode(digest(v_rotated_token,'sha256'),'hex')
    and approval_token_hash<>encode(digest('edit_token','sha256'),'hex')
    from public.recorrido_pending_outbound where id=v_edit),
    'edit rotates to a fresh live token and increments the draft revision');
  begin
    perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve','edit_token');
    raise exception 'assertion failed: consumed edit token reapproved'; exception when sqlstate '42501' then null; end;
  perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve',v_rotated_token);
  perform pg_temp.assert_true((select status='approved' and approved_revision=2
    from public.recorrido_pending_outbound where id=v_edit),
    'only the rotated token approves the edited revision');
  update public.recorrido_pending_outbound set status='failed',last_error='test_fixture_isolation'
    where id=v_edit;

  perform public.recorrido_apply_owner_action('+573007770001','+573007770001','approve','opted_token');
  insert into public.recorrido_consent_events(account_id,member_id,phone_e164,event_kind,source)
    values(null,null,('+57'||'3007770104'),'opt_out','test');

  v_claim := public.recorrido_claim_approved_outbound(1,('+57'||'3007770001'));
  perform pg_temp.assert_true(jsonb_array_length(v_claim)=1,'batch claim respects limit');
  v_item:=v_claim->0; v_attempt:=(v_item->>'attemptId')::uuid; v_token:=(v_item->>'claimToken')::uuid;
  perform pg_temp.assert_true(v_item->>'id'=v_approved::text and
    (select array_agg(key order by key) from jsonb_object_keys(v_item) key)=array[
      'approvalExpiresAt','approvedAt','approvedBy','approvedVersion','attemptId','body','claimToken','currentDraftVersion',
      'draftId','id','leaseExpiresAt','messageType','optedOut','ownerWhatsAppE164','payload','previewText',
      'providerMessageId','recipientConsented','recipientE164','sentAt','status','tokenValid'],
    'claim returns only the exact camelCase send-instruction shape');
  perform pg_temp.assert_true(v_item->>'status'='approved' and (v_item->>'optedOut')::boolean=false
    and v_item->>'body'='Approved exact body','claim is directly accepted by outbound runtime contract');
  perform pg_temp.assert_true((select status='claimed' and claim_token=v_token and lease_expires_at>clock_timestamp()
    and lease_expires_at<=clock_timestamp()+interval '3 minutes' from public.recorrido_outbound_delivery_attempts where id=v_attempt),
    'claim is a random-token bounded lease');
  perform public.recorrido_begin_outbound_send(v_approved,v_attempt,v_token);
  begin perform public.recorrido_mark_outbound_delivered(v_approved,v_attempt,v_token,'   ');
    raise exception 'assertion failed: blank provider id accepted'; exception when sqlstate '22023' then null; end;
  perform pg_temp.assert_true((public.recorrido_mark_outbound_delivered(v_approved,v_attempt,v_token,'wamid.contract')->>'marked')::boolean,
    'matching attempt marks delivered');
  perform pg_temp.assert_true((public.recorrido_mark_outbound_delivered(v_approved,v_attempt,v_token,'wamid.contract')->>'marked')::boolean
    and (select status='sent' and sent_at is not null from public.recorrido_pending_outbound where id=v_approved),
    'exact delivered replay is idempotent');

  perform public.recorrido_apply_owner_action(('+57'||'3007770001'),('+57'||'3007770001'),'approve','retry_token');
  v_claim:=public.recorrido_claim_approved_outbound(10,('+57'||'3007770001'));
  perform pg_temp.assert_true(jsonb_array_length(v_claim)=1 and v_claim->0->>'id'=v_retry::text,
    'claim excludes edited and opted-out rows');
  v_attempt:=(v_claim->0->>'attemptId')::uuid; v_token:=(v_claim->0->>'claimToken')::uuid;
  begin perform public.recorrido_mark_outbound_delivered(v_retry,v_attempt,gen_random_uuid(),'wamid.wrong');
    raise exception 'assertion failed: stale token marked delivered'; exception when sqlstate '40001' then null; end;
  perform public.recorrido_mark_outbound_failed(v_retry,v_attempt,v_token,'provider_rejected',true);
  perform public.recorrido_mark_outbound_failed(v_retry,v_attempt,v_token,'provider_rejected',true);
  perform pg_temp.assert_true((select status='approved' and sent_at is null from public.recorrido_pending_outbound where id=v_retry)
    and (select status='failed' from public.recorrido_outbound_delivery_attempts where id=v_attempt),
    'safe rejection and exact replay reset approval');
  v_claim:=public.recorrido_claim_approved_outbound(1,('+57'||'3007770001'));
  perform pg_temp.assert_true((v_claim->0->>'attemptId')::uuid<>v_attempt,
    'retry claim creates a monotonic fresh attempt');
  v_attempt:=(v_claim->0->>'attemptId')::uuid; v_token:=(v_claim->0->>'claimToken')::uuid;
  perform public.recorrido_begin_outbound_send(v_retry,v_attempt,v_token);
  perform public.recorrido_mark_outbound_ambiguous(v_retry,v_attempt,v_token,'timeout',null);
  perform public.recorrido_mark_outbound_ambiguous(v_retry,v_attempt,v_token,'timeout',null);
  perform pg_temp.assert_true(jsonb_array_length(public.recorrido_claim_approved_outbound(10,('+57'||'3007770001')))=0
    and (select status='ambiguous' from public.recorrido_pending_outbound where id=v_retry),
    'ambiguous attempt is idempotent and never automatically resent');
  begin perform public.recorrido_reconcile_outbound_not_accepted(v_retry,v_attempt,gen_random_uuid(),'confirmed_not_accepted');
    raise exception 'assertion failed: foreign token reconciled ambiguous attempt'; exception when sqlstate '40001' then null; end;
  begin perform public.recorrido_reconcile_outbound_accepted(v_retry,v_attempt,gen_random_uuid(),'wamid.foreign',false);
    raise exception 'assertion failed: foreign token accepted ambiguous attempt'; exception when sqlstate '40001' then null; end;
  perform public.recorrido_reconcile_outbound_not_accepted(v_retry,v_attempt,v_token,'confirmed_not_accepted');
  perform public.recorrido_reconcile_outbound_not_accepted(v_retry,v_attempt,v_token,'confirmed_not_accepted');
  v_claim:=public.recorrido_claim_approved_outbound(1,('+57'||'3007770001'));
  v_attempt:=(v_claim->0->>'attemptId')::uuid; v_token:=(v_claim->0->>'claimToken')::uuid;
  perform public.recorrido_begin_outbound_send(v_retry,v_attempt,v_token);
  perform public.recorrido_mark_outbound_ambiguous(v_retry,v_attempt,v_token,'ack_failed','wamid.reconciled');
  perform public.recorrido_reconcile_outbound_accepted(v_retry,v_attempt,v_token,'wamid.reconciled',true);
  perform public.recorrido_reconcile_outbound_accepted(v_retry,v_attempt,v_token,'wamid.reconciled',true);
  perform pg_temp.assert_true((select status='sent' and sent_at is not null from public.recorrido_pending_outbound where id=v_retry)
    and (select status='delivered' from public.recorrido_outbound_delivery_attempts where id=v_attempt),
    'ambiguous attempts reconcile both ways with exact replay');
end;
$$;

rollback;
