\set ON_ERROR_STOP on

create or replace function pg_temp.assert_true(condition boolean, message text)
returns void language plpgsql as $$
begin
  if condition is not true then raise exception 'assertion failed: %', message; end if;
end;
$$;

create or replace function pg_temp.recorrido_claim_stripe_event(
  p_stripe_event_id text,p_event_type text,p_stripe_object_id text,p_livemode boolean,
  p_stripe_api_version text,p_payload jsonb,p_lease_duration interval default interval '2 minutes')
returns jsonb language sql as $$
  select public.recorrido_claim_stripe_event($1,$2,$3,$4,$5,$6,$7,$6::text)
$$;

select pg_temp.assert_true(to_regclass('public.recorrido_stripe_reversals') is not null,
  'durable Stripe refund/dispute evidence exists');
select pg_temp.assert_true(to_regclass('public.recorrido_billing_runtime_config') is not null,
  'server-controlled Stripe livemode configuration exists');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_grant_paid_purchase(uuid)') is not null,
  'paid purchase grant derives all grant inputs');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_record_stripe_reversal(uuid,text,text,bigint,text,timestamptz)') is not null,
  'refund/dispute evidence RPC exists');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_revoke_stripe_reversal(uuid)') is not null,
  'reversal derives revocation from verified evidence');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_claim_stripe_event(text,text,text,boolean,text,jsonb,interval,text)') is not null,
  'Stripe claim accepts a bounded lease duration');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_finish_stripe_event(uuid,uuid,integer,boolean,text)') is not null,
  'Stripe finish requires claim token and attempt');

select pg_temp.assert_true(
  exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='recorrido_stripe_events' and column_name='claim_token'),
  'Stripe attempts carry an ownership token');
select pg_temp.assert_true(
  exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='recorrido_stripe_events' and column_name='lease_expires_at'),
  'Stripe attempts carry an expiring lease');
select pg_temp.assert_true(
  exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='recorrido_subscription_entitlements' and column_name='latest_event_created')
  and exists (select 1 from information_schema.columns where table_schema='public'
    and table_name='recorrido_subscription_entitlements' and column_name='latest_event_id'),
  'subscription mirror stores an authoritative Stripe lifecycle watermark');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_create_outbound_draft(uuid,uuid,text,text,text,interval)') is not null,
  'producer can create a reviewable draft through a narrow RPC');
select pg_temp.assert_true(
  to_regprocedure('public.recorrido_apply_stripe_failed_payment_event(uuid,uuid,integer)') is not null,
  'required failed-payment events have a durable application RPC');

select pg_temp.assert_true(
  (select count(*) = 6 from public.recorrido_price_catalog),
  'catalog remains exactly six rows');
select pg_temp.assert_true(
  exists (select 1 from pg_extension where extname='pgcrypto'),
  'pgcrypto supplies digest for one-way approval-token lookup');

select pg_temp.assert_true(
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      'recorrido_apply_owner_action','recorrido_apply_owner_edit','recorrido_claim_approved_outbound',
      'recorrido_begin_outbound_send','recorrido_mark_outbound_delivered','recorrido_mark_outbound_failed',
      'recorrido_mark_outbound_ambiguous','recorrido_reconcile_outbound_accepted',
      'recorrido_reconcile_outbound_not_accepted')
      and (not p.prosecdef or p.proconfig is distinct from array['search_path=pg_catalog, public']::text[])),
  'approval and dispatcher RPCs are security definer with fixed search_path');

select pg_temp.assert_true(
  not exists (
    select 1 from (values('public'),('anon'),('authenticated')) r(role_name),
      (values
        ('public.recorrido_apply_owner_action(text,text,text,text)'),
        ('public.recorrido_apply_owner_edit(text,text,text,text)'),
        ('public.recorrido_claim_approved_outbound(integer,text)'),
        ('public.recorrido_begin_outbound_send(uuid,uuid,uuid)'),
        ('public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text)'),
        ('public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean)'),
        ('public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text)'),
        ('public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean)'),
        ('public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text)')) f(signature)
    where has_function_privilege(r.role_name,f.signature,'execute')),
  'public JWT roles cannot execute approval or dispatcher RPCs');

select pg_temp.assert_true(
  not exists (
    select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    where p.oid in (
      'public.recorrido_apply_owner_action(text,text,text,text)'::regprocedure,
      'public.recorrido_apply_owner_edit(text,text,text,text)'::regprocedure,
      'public.recorrido_claim_approved_outbound(integer,text)'::regprocedure,
      'public.recorrido_begin_outbound_send(uuid,uuid,uuid)'::regprocedure,
      'public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text)'::regprocedure,
      'public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean)'::regprocedure,
      'public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text)'::regprocedure,
      'public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean)'::regprocedure,
      'public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text)'::regprocedure)
      and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role')))),
  'approval and dispatcher functions have no direct PUBLIC or runtime-role ACL');

select pg_temp.assert_true(
  has_schema_privilege('anon','public','create')
  and has_schema_privilege('authenticated','public','create')
  and has_schema_privilege('service_role','public','create'),
  'migration preserves pre-existing shared public schema CREATE privileges');

select pg_temp.assert_true(
  to_regprocedure('public.recorrido_finalize_checkout_request(uuid,uuid,uuid,text,text,text,timestamptz)') is not null
  and to_regprocedure('public.recorrido_renew_stripe_event_lease(uuid,uuid,integer,interval)') is not null
  and to_regprocedure('public.recorrido_apply_stripe_payment_event(uuid,uuid,integer)') is not null
  and to_regprocedure('public.recorrido_apply_stripe_subscription_event(uuid,uuid,integer)') is not null
  and to_regprocedure('public.recorrido_apply_stripe_subscription_payment_event(uuid,uuid,integer)') is not null
  and to_regprocedure('public.recorrido_apply_stripe_reversal_event(uuid,uuid,integer)') is not null,
  'narrow lifecycle RPC inventory exists');

select pg_temp.assert_true(
  pg_get_functiondef('public.recorrido_create_checkout_request(uuid,uuid,text,text,text,jsonb)'::regprocedure)
    like '%stripe_price_id%stripe_customer_id%',
  'atomic checkout RPC returns authoritative price and same-account customer without handler table reads');

select pg_temp.assert_true(
  to_regprocedure('public.recorrido_revoke_payment_credits(uuid,uuid,integer,text)') is null,
  'unsupported caller-controlled payment revocation path is removed');

select pg_temp.assert_true(
  not exists (
    select 1 from (values
      ('recorrido_billing_webhook_worker'),('recorrido_billing_checkout_worker'),
      ('recorrido_billing_generation_worker'),('recorrido_billing_quota_worker'),
      ('recorrido_billing_dispatcher_worker'),('recorrido_billing_approval_worker'),
      ('recorrido_billing_reconciliation_worker')) expected(role_name)
    left join pg_roles r on r.rolname=expected.role_name
    where r.oid is null or r.rolcanlogin),
  'dedicated workers exist as NOLOGIN roles');

select pg_temp.assert_true(
  not has_function_privilege('service_role',
    'public.recorrido_grant_credit_bucket(uuid,text,text,integer,timestamptz,uuid,jsonb)','execute')
  and not has_function_privilege('service_role',
    'public.recorrido_record_stripe_reversal(uuid,text,text,bigint,text,timestamptz)','execute')
  and not has_function_privilege('service_role',
    'public.recorrido_revoke_stripe_reversal(uuid)','execute'),
  'generic caller-controlled mint and reversal helpers are not executable by service_role');

select pg_temp.assert_true(
  to_regprocedure('public.recorrido_grant_due_annual_quotas()') is not null
  and has_function_privilege('recorrido_billing_quota_worker',
    'public.recorrido_grant_due_annual_quotas()','execute'),
  'quota worker can execute only the server-clock annual grant RPC');

select pg_temp.assert_true(
  to_regprocedure('public.recorrido_grant_due_annual_quotas(timestamptz)') is null
  or not coalesce(has_function_privilege('recorrido_billing_quota_worker',
    to_regprocedure('public.recorrido_grant_due_annual_quotas(timestamptz)'),'execute'), false),
  'quota worker cannot pass a future as_of to accelerate annual grants');

select pg_temp.assert_true(
  not has_function_privilege('service_role',
    'public.recorrido_grant_due_annual_quotas_internal(timestamptz)','execute')
  and not has_function_privilege('recorrido_billing_quota_worker',
    'public.recorrido_grant_due_annual_quotas_internal(timestamptz)','execute'),
  'time-injected annual grant helper is owner-only');

select pg_temp.assert_true(
  has_function_privilege('recorrido_billing_webhook_worker',
    'public.recorrido_claim_stripe_event(text,text,text,boolean,text,jsonb,interval,text)','execute')
  and not has_function_privilege('recorrido_billing_webhook_worker',
    'public.recorrido_create_checkout_request(uuid,uuid,text,text,text,jsonb)','execute')
  and has_function_privilege('recorrido_billing_checkout_worker',
    'public.recorrido_create_checkout_request(uuid,uuid,text,text,text,jsonb)','execute')
  and has_function_privilege('recorrido_billing_checkout_worker',
    'public.recorrido_finalize_checkout_request(uuid,uuid,uuid,text,text,text,timestamptz)','execute')
  and has_function_privilege('recorrido_billing_webhook_worker',
    'public.recorrido_apply_stripe_payment_event(uuid,uuid,integer)','execute')
  and has_function_privilege('recorrido_billing_webhook_worker',
    'public.recorrido_apply_stripe_subscription_payment_event(uuid,uuid,integer)','execute')
  and not has_function_privilege('recorrido_billing_webhook_worker',
    'public.recorrido_grant_paid_purchase(uuid)','execute')
  and has_function_privilege('recorrido_billing_generation_worker',
    'public.recorrido_reserve_generation(uuid,uuid,text)','execute')
  and has_function_privilege('recorrido_billing_quota_worker',
    'public.recorrido_grant_due_annual_quotas()','execute')
  and has_function_privilege('recorrido_billing_approval_worker',
    'public.recorrido_apply_owner_action(text,text,text,text)','execute')
  and has_function_privilege('recorrido_billing_approval_worker',
    'public.recorrido_apply_owner_edit(text,text,text,text)','execute')
  and has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_claim_approved_outbound(integer,text)','execute')
  and has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_begin_outbound_send(uuid,uuid,uuid)','execute')
  and has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_mark_outbound_delivered(uuid,uuid,uuid,text)','execute')
  and has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_mark_outbound_failed(uuid,uuid,uuid,text,boolean)','execute')
  and has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_mark_outbound_ambiguous(uuid,uuid,uuid,text,text)','execute')
  and not has_function_privilege('recorrido_billing_dispatcher_worker',
    'public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean)','execute')
  and has_function_privilege('recorrido_billing_reconciliation_worker',
    'public.recorrido_reconcile_outbound_accepted(uuid,uuid,uuid,text,boolean)','execute')
  and has_function_privilege('recorrido_billing_reconciliation_worker',
    'public.recorrido_reconcile_outbound_not_accepted(uuid,uuid,uuid,text)','execute')
  and not has_function_privilege('recorrido_billing_reconciliation_worker',
    'public.recorrido_claim_approved_outbound(integer,text)','execute'),
  'dedicated workers execute only their intended RPC families');

select pg_temp.assert_true(
  not exists (select 1 from (values
    ('recorrido_billing_webhook_worker'),('recorrido_billing_checkout_worker'),
    ('recorrido_billing_generation_worker'),('recorrido_billing_quota_worker'),
    ('recorrido_billing_dispatcher_worker'),('recorrido_billing_approval_worker'),
    ('recorrido_billing_reconciliation_worker')) v(role_name)
    where has_table_privilege(role_name,'public.recorrido_credit_ledger','insert,update,delete')),
  'dedicated workers have no direct ledger DML');

select pg_temp.assert_true(
  not has_function_privilege('service_role',
    'public.recorrido_claim_stripe_event(text,text,text,boolean,text,jsonb,interval,text)','execute')
  and not has_function_privilege('service_role',
    'public.recorrido_claim_approved_outbound(integer,text)','execute')
  and not has_function_privilege('service_role',
    'public.recorrido_apply_owner_action(text,text,text,text)','execute'),
  'service_role does not effectively inherit any scoped worker RPC');

select pg_temp.assert_true(
  exists (select 1 from pg_constraint where conname='recorrido_ledger_bucket_account_fkey')
  and exists (select 1 from pg_constraint where conname='recorrido_jobs_member_account_fkey')
  and exists (select 1 from pg_constraint where conname='recorrido_checkout_member_account_fkey'),
  'cross-table account consistency is enforced by composite foreign keys');

select pg_temp.assert_true(
  exists (select 1 from pg_indexes where schemaname='public'
    and indexname='recorrido_one_authoritative_live_entitlement'),
  'an account cannot have overlapping authoritative live entitlements');

-- Deny-by-default checks use the actual Supabase runtime roles.
set role anon;
select pg_temp.assert_true(not has_table_privilege(current_user,
  'public.recorrido_payment_records','insert,update,delete'), 'anon table DML denied');
reset role;
set role authenticated;
select pg_temp.assert_true(not has_table_privilege(current_user,
  'public.recorrido_credit_ledger','insert,update,delete'), 'authenticated ledger DML denied');
reset role;
set role service_role;
select pg_temp.assert_true(not has_table_privilege(current_user,
  'public.recorrido_credit_ledger','insert,update,delete'), 'service_role direct ledger DML denied');
reset role;

set role recorrido_billing_webhook_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_stripe_events','insert,update,delete'),
  'webhook worker has no direct event DML');
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_subscription_entitlements','insert,update,delete')
  and not has_table_privilege(current_user,'public.recorrido_credit_buckets','insert,update,delete')
  and not has_table_privilege(current_user,'public.recorrido_credit_ledger','insert,update,delete'),
  'webhook worker has no direct subscription or credit DML');
do $$
begin
  begin
    update public.recorrido_subscription_entitlements set status='canceled' where false;
    raise exception 'assertion failed: webhook worker directly updated subscriptions';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.recorrido_credit_buckets(account_id,source_kind,source_id,credits_granted)
      values(gen_random_uuid(),'subscription','forbidden-worker-mint',4);
    raise exception 'assertion failed: webhook worker directly inserted credits';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set role recorrido_billing_checkout_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_checkout_requests','insert,update,delete'),
  'checkout worker has no direct checkout DML');
select pg_temp.assert_true(
  not has_function_privilege(current_user,
    'public.recorrido_expire_checkout_requests(uuid)','execute')
  and not has_function_privilege(current_user,
    'public.recorrido_recover_checkout_request(uuid)','execute'),
  'checkout worker cannot execute private lifecycle helpers');
do $$
begin
  begin
    update public.recorrido_checkout_requests
      set status='expired',last_error='stripe_session_expired'
      where status='created';
    raise exception 'assertion failed: checkout worker forged expiry';
  exception when insufficient_privilege then null; end;
  begin
    update public.recorrido_checkout_requests
      set status='pending',stripe_checkout_session_id=null,checkout_url=null,expires_at=null,last_error=null
      where status='expired';
    raise exception 'assertion failed: checkout worker reopened arbitrary checkout';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set role recorrido_billing_generation_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_generation_jobs','insert,update,delete'),
  'generation worker has no direct job DML');
reset role;
set role recorrido_billing_quota_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_subscription_entitlements','insert,update,delete'),
  'quota worker has no direct entitlement DML');
reset role;
set role recorrido_billing_dispatcher_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_outbound_delivery_attempts','insert,update,delete'),
  'dispatcher worker has no direct attempt DML');
reset role;
set role recorrido_billing_approval_worker;
select pg_temp.assert_true(not has_table_privilege(current_user,'public.recorrido_pending_outbound','select,insert,update,delete')
  and not has_table_privilege(current_user,'public.recorrido_approval_actions','select,insert,update,delete'),
  'approval worker has no direct outbound or action table access');
reset role;

select pg_temp.assert_true(
  has_table_privilege('anon','public.non_recorrido_privilege_sentinel','select')
  and has_table_privilege('authenticated','public.non_recorrido_privilege_sentinel','select'),
  'non-Recorrido sentinel grants survive migration');
