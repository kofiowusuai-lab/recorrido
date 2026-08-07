\set ON_ERROR_STOP on
begin;

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

-- Finding 1: configured Kofi is a global operator, not a customer-account member.
do $$
declare v_account uuid; v_member uuid;
begin
  insert into public.recorrido_customer_accounts(display_name) values('Global Kofi approval') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Customer Owner',('+57'||'3001111000'),'owner') returning id into v_member;
  insert into public.recorrido_pending_outbound(account_id,member_id,recipient_phone_e164,message_type,payload,
    preview_text,idempotency_key,approval_token_hash,approval_expires_at)
  values(v_account,v_member,('+57'||'3001111000'),'text','{"body":"Review me"}','Review me','global-kofi-approval',
    encode(digest('global_kofi_token','sha256'),'hex'),clock_timestamp()+interval '1 hour');
  set local role recorrido_billing_approval_worker;
  perform public.recorrido_apply_owner_action(('+57'||'3009999000'),('+57'||'3009999000'),'approve','global_kofi_token');
  reset role;
  perform pg_temp.assert_true((select status='approved' and approved_by_phone_e164=('+57'||'3009999000')
    from public.recorrido_pending_outbound where idempotency_key='global-kofi-approval'),
    'configured Kofi approves without customer membership');
end;
$$;

-- Finding 6: exact bounded signed bytes are immutable evidence, independent of JSON semantics.
do $$
declare v_claim jsonb;
begin
  set local role recorrido_billing_webhook_worker;
  begin
    perform public.recorrido_claim_stripe_event('evt_raw_omitted','product.created','prod_raw_omitted',false,
      '2025-06-30.basil','{"signed":true}');
    raise exception 'assertion failed: omitted raw Stripe evidence accepted';
  exception when sqlstate '22023' then null; end;
  reset role;
  set local role recorrido_billing_webhook_worker;
  v_claim:=public.recorrido_claim_stripe_event('evt_raw_exact','product.created','prod_raw',false,
    '2025-06-30.basil','{"a":1,"b":2}',interval '2 minutes','{ "a": 1, "b": 2 }');
  reset role;
  perform pg_temp.assert_true((select payload_raw='{ "a": 1, "b": 2 }'
    from public.recorrido_stripe_events where id=(v_claim->>'id')::uuid),'exact raw Stripe bytes are retained');
  set local role recorrido_billing_webhook_worker;
  begin
    perform public.recorrido_claim_stripe_event('evt_raw_exact','product.created','prod_raw',false,
      '2025-06-30.basil','{"b":2,"a":1}',interval '2 minutes','{"b":2,"a":1}');
    raise exception 'assertion failed: semantically equal changed raw replay accepted';
  exception when sqlstate '22000' then null; end;
  begin
    perform public.recorrido_claim_stripe_event('evt_raw_oversize','product.created','prod_big',false,
      '2025-06-30.basil','{}',interval '2 minutes',repeat('x',1048577));
    raise exception 'assertion failed: oversized raw Stripe evidence accepted';
  exception when sqlstate '22023' then null; end;
  reset role;
end;
$$;

-- Findings 3 and 4: Checkout and PI converge through one request despite source timestamps/receipt,
-- and every server-issued metadata field is authoritative.
do $$
declare
  v_account uuid; v_member uuid; v_request jsonb; v_claim jsonb; v_payment uuid;
  v_created timestamptz := date_trunc('second',clock_timestamp()-interval '5 minutes');
  v_checkout jsonb; v_pi jsonb; v_bad jsonb;
begin
  update public.recorrido_price_catalog set active=true,stripe_price_id='price_review_single'
    where product_code='single_listing_once_usd_22';
  insert into public.recorrido_customer_accounts(display_name,home_country) values('Canonical evidence','CO') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Billing Member',('+57'||'3002222000'),'owner') returning id into v_member;
  set local role recorrido_billing_checkout_worker;
  v_request:=public.recorrido_create_checkout_request(v_account,v_member,'canonical-order','single_listing_once_usd_22',
    'canonical-fingerprint','{"success_url":"https://example.test/success"}');
  perform public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
    'single_listing_once_usd_22','cs_canonical','https://checkout.stripe.com/c/pay/canonical',clock_timestamp()+interval '1 hour');
  reset role;
  select created_at into v_created from public.recorrido_checkout_requests
    where id=(v_request->>'id')::uuid;
  v_checkout:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id','cs_canonical','payment_intent','pi_canonical','customer','cus_canonical','amount_total',2200,'currency','usd',
    'payment_status','paid','status','complete','mode','payment','created',extract(epoch from v_created+interval '2 minutes')::bigint,
    'client_reference_id',v_request->>'id','metadata',jsonb_build_object(
      'account_id',v_account,'member_id',v_member,'product_code','single_listing_once_usd_22',
      'internal_price_code','single_listing_once_usd_22','checkout_request_id',v_request->>'id',
      'normalized_whatsapp_phone',('+57'||'3002222000'),'country','CO','purchase_type','single_listing'))));
  v_pi:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id','pi_canonical','customer','cus_canonical','amount_received',2200,'currency','usd','status','succeeded',
    'created',extract(epoch from v_created+interval '3 minutes')::bigint,
    'latest_charge',jsonb_build_object('id','ch_canonical','receipt_url','https://pay.stripe.com/receipts/canonical'),
    'metadata',jsonb_build_object('account_id',v_account,'member_id',v_member,'product_code','single_listing_once_usd_22',
      'internal_price_code','single_listing_once_usd_22','checkout_request_id',v_request->>'id',
      'normalized_whatsapp_phone',('+57'||'3002222000'),'country','CO','purchase_type','single_listing'))));
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_checkout','checkout.session.completed','cs_canonical',false,
    '2025-06-30.basil',v_checkout);
  v_payment:=(public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer)->>'payment_id')::uuid;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_pi','payment_intent.succeeded','pi_canonical',false,
    '2025-06-30.basil',v_pi);
  perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true(exists(select 1 from public.recorrido_payment_records where id=v_payment
      and paid_at=v_created and receipt_url='https://pay.stripe.com/receipts/canonical'
      and stripe_checkout_session_id='cs_canonical'),
    'Checkout then PI converges on request time and charge receipt evidence');

  foreach v_bad in array array[
    jsonb_set(v_pi,'{data,object,metadata,member_id}',to_jsonb(gen_random_uuid()::text)),
    jsonb_set(v_pi,'{data,object,metadata,normalized_whatsapp_phone}','"+573009999999"'),
    jsonb_set(v_pi,'{data,object,metadata,country}','"US"'),
    jsonb_set(v_pi,'{data,object,metadata,purchase_type}','"extra_credits"')
  ] loop
    set local role recorrido_billing_webhook_worker;
    v_claim:=pg_temp.recorrido_claim_stripe_event('evt_meta_'||substr(md5(v_bad::text),1,16),'payment_intent.succeeded','pi_canonical',false,
      '2025-06-30.basil',v_bad);
    begin
      perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
        (v_claim->>'processing_attempts')::integer);
      raise exception 'assertion failed: PI metadata mismatch accepted';
    exception when sqlstate '22000' then null; end;
    reset role;
  end loop;
end;
$$;

-- Finding 3, reverse order: PaymentIntent evidence arriving before Checkout
-- must converge on the same server-issued request and preserve the receipt.
do $$
declare v_account uuid; v_member uuid; v_request jsonb; v_created timestamptz;
declare v_pi jsonb; v_checkout jsonb; v_bad jsonb; v_claim jsonb; v_payment uuid;
begin
  insert into public.recorrido_customer_accounts(display_name,home_country)
    values('Canonical PI first','CO') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'PI First Member',('+57'||'3002222111'),'owner') returning id into v_member;
  set local role recorrido_billing_checkout_worker;
  v_request:=public.recorrido_create_checkout_request(v_account,v_member,'canonical-pi-first',
    'single_listing_once_usd_22','canonical-pi-first-fingerprint','{"success_url":"https://example.test/success"}');
  perform public.recorrido_finalize_checkout_request((v_request->>'id')::uuid,v_account,v_member,
    'single_listing_once_usd_22','cs_canonical_pi_first','https://checkout.stripe.com/c/pay/canonical-pi-first',
    clock_timestamp()+interval '1 hour');
  reset role;
  select created_at into v_created from public.recorrido_checkout_requests where id=(v_request->>'id')::uuid;
  v_pi:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id','pi_canonical_first','customer','cus_canonical_first','amount_received',2200,'currency','usd','status','succeeded',
    'created',extract(epoch from v_created+interval '3 minutes')::bigint,
    'latest_charge',jsonb_build_object('id','ch_canonical_first','receipt_url','https://pay.stripe.com/receipts/canonical-first'),
    'metadata',jsonb_build_object('account_id',v_account,'member_id',v_member,'product_code','single_listing_once_usd_22',
      'internal_price_code','single_listing_once_usd_22','checkout_request_id',v_request->>'id',
      'normalized_whatsapp_phone',('+57'||'3002222111'),'country','CO','purchase_type','single_listing'))));
  v_checkout:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id','cs_canonical_pi_first','payment_intent','pi_canonical_first','customer','cus_canonical_first',
    'amount_total',2200,'currency','usd','payment_status','paid','status','complete','mode','payment',
    'created',extract(epoch from v_created+interval '2 minutes')::bigint,'client_reference_id',v_request->>'id',
    'metadata',v_pi#>'{data,object,metadata}')));
  set local role recorrido_billing_webhook_worker;
  v_bad:=jsonb_set(v_pi,'{data,object,amount_received}','2199');
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_bad_amount','payment_intent.succeeded',
    'pi_canonical_first',false,'2025-06-30.basil',v_bad);
  begin
    perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: wrong catalog amount accepted';
  exception when sqlstate '22000' then null; end;
  v_bad:=jsonb_set(v_checkout,'{data,object,currency}','"eur"');
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_bad_currency','checkout.session.completed',
    'cs_canonical_pi_first',false,'2025-06-30.basil',v_bad);
  begin
    perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
    raise exception 'assertion failed: wrong catalog currency accepted';
  exception when sqlstate '22000' then null; end;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_pi_first','payment_intent.succeeded',
    'pi_canonical_first',false,'2025-06-30.basil',v_pi);
  v_payment:=(public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer)->>'payment_id')::uuid;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_canonical_checkout_second','checkout.session.completed',
    'cs_canonical_pi_first',false,'2025-06-30.basil',v_checkout);
  perform public.recorrido_apply_stripe_payment_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform pg_temp.assert_true(exists(select 1 from public.recorrido_payment_records where id=v_payment
      and paid_at=v_created and receipt_url='https://pay.stripe.com/receipts/canonical-first'
      and stripe_checkout_session_id='cs_canonical_pi_first' and stripe_payment_intent_id='pi_canonical_first'),
    'PI then Checkout converges without dropping receipt or canonical request time');
  perform pg_temp.assert_true((select count(*)=1 from public.recorrido_payment_records
      where stripe_payment_intent_id='pi_canonical_first' or stripe_checkout_session_id='cs_canonical_pi_first'),
    'PI then Checkout creates exactly one payment record');
end;
$$;

-- Finding 5: unused refund is not a lock; consumed reversal and unresolved disputes are locks;
-- closing one dispute cannot unlock another unresolved dispute.
do $$
declare v_account uuid; v_member uuid; v_payment uuid; v_bucket uuid; v_claim jsonb; v_result jsonb;
begin
  insert into public.recorrido_customer_accounts(display_name) values('Reversal lock state') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Lock Member',('+57'||'3003333000'),'owner') returning id into v_member;
  insert into public.recorrido_payment_records(account_id,stripe_payment_intent_id,product_code,payment_kind,amount_minor,currency,status,paid_at)
    values(v_account,'pi_lock_state','single_listing_once_usd_22','extra_purchase',2200,'usd','paid',clock_timestamp()) returning id into v_payment;
  v_bucket:=public.recorrido_grant_paid_purchase(v_payment);
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_unused_refund','charge.refunded','ch_unused_refund',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','ch_unused_refund','payment_intent','pi_lock_state',
      'currency','usd','refunds',jsonb_build_object('data',jsonb_build_array(jsonb_build_object('id','re_unused','charge','ch_unused_refund',
        'payment_intent','pi_lock_state','amount',500,'currency','usd','created',extract(epoch from clock_timestamp())::bigint,'status','succeeded')))))));
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform public.recorrido_grant_credit_bucket(v_account,'manual_adjustment','after-unused-refund',1);
  set local role recorrido_billing_generation_worker;
  v_result:=public.recorrido_reserve_generation(v_account,v_member,'after-unused-refund');
  reset role;
  perform pg_temp.assert_true((v_result->>'allowed')::boolean,'unused-credit partial refund does not lock account');

  set local role recorrido_billing_webhook_worker;
  foreach v_result in array array[
    jsonb_build_object('event','evt_dispute_one','id','dp_lock_one'),
    jsonb_build_object('event','evt_dispute_two','id','dp_lock_two')
  ] loop
    v_claim:=pg_temp.recorrido_claim_stripe_event(v_result->>'event','charge.dispute.created',v_result->>'id',false,'2025-06-30.basil',
      jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id',v_result->>'id','object','dispute',
        'charge','ch_lock','payment_intent','pi_lock_state','amount',600,'currency','usd',
        'created',extract(epoch from clock_timestamp())::bigint,'status','needs_response'))));
    perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
      (v_claim->>'processing_attempts')::integer);
  end loop;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_dispute_one_closed','charge.dispute.closed','dp_lock_one',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','dp_lock_one','object','dispute','charge','ch_lock',
      'payment_intent','pi_lock_state','amount',600,'currency','usd','created',extract(epoch from clock_timestamp())::bigint,'status','won'))));
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform public.recorrido_grant_credit_bucket(v_account,'manual_adjustment','while-other-dispute-open',1);
  set local role recorrido_billing_generation_worker;
  v_result:=public.recorrido_reserve_generation(v_account,v_member,'while-other-dispute-open');
  reset role;
  perform pg_temp.assert_true(not (v_result->>'allowed')::boolean and v_result->>'reason'='billing_locked',
    'closing one dispute does not unlock while another is unresolved');

  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_dispute_two_closed','charge.dispute.closed','dp_lock_two',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','dp_lock_two','object','dispute','charge','ch_lock',
      'payment_intent','pi_lock_state','amount',600,'currency','usd','created',extract(epoch from clock_timestamp())::bigint,'status','won'))));
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform public.recorrido_grant_credit_bucket(v_account,'manual_adjustment','after-all-disputes-closed',1);
  set local role recorrido_billing_generation_worker;
  v_result:=public.recorrido_reserve_generation(v_account,v_member,'after-all-disputes-closed');
  reset role;
  perform pg_temp.assert_true((v_result->>'allowed')::boolean,
    'all resolved disputes unlock when no consumed-credit reversal remains');
end;
$$;

-- A reversal after the purchased credit was consumed remains fail-closed even
-- when unrelated replacement credit exists.
do $$
declare v_account uuid; v_member uuid; v_payment uuid; v_bucket uuid; v_claim jsonb; v_result jsonb;
begin
  insert into public.recorrido_customer_accounts(display_name) values('Consumed reversal lock') returning id into v_account;
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
    values(v_account,'Consumed Member',('+57'||'3003333111'),'owner') returning id into v_member;
  insert into public.recorrido_payment_records(account_id,stripe_payment_intent_id,product_code,payment_kind,amount_minor,currency,status,paid_at)
    values(v_account,'pi_consumed_lock','single_listing_once_usd_22','extra_purchase',2200,'usd','paid',clock_timestamp()) returning id into v_payment;
  v_bucket:=public.recorrido_grant_paid_purchase(v_payment);
  set local role recorrido_billing_generation_worker;
  v_result:=public.recorrido_reserve_generation(v_account,v_member,'consume-paid-credit');
  perform public.recorrido_complete_generation((v_result->>'reservation_id')::uuid,1);
  reset role;
  set local role recorrido_billing_webhook_worker;
  v_claim:=pg_temp.recorrido_claim_stripe_event('evt_consumed_refund','charge.refunded','ch_consumed_refund',false,'2025-06-30.basil',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object('id','ch_consumed_refund','payment_intent','pi_consumed_lock',
      'currency','usd','refunds',jsonb_build_object('data',jsonb_build_array(jsonb_build_object('id','re_consumed','charge','ch_consumed_refund',
        'payment_intent','pi_consumed_lock','amount',500,'currency','usd','created',extract(epoch from clock_timestamp())::bigint,'status','succeeded')))))));
  perform public.recorrido_apply_stripe_reversal_event((v_claim->>'id')::uuid,(v_claim->>'claim_token')::uuid,
    (v_claim->>'processing_attempts')::integer);
  reset role;
  perform public.recorrido_grant_credit_bucket(v_account,'manual_adjustment','replacement-after-consumed-refund',1);
  set local role recorrido_billing_generation_worker;
  v_result:=public.recorrido_reserve_generation(v_account,v_member,'replacement-after-consumed-refund');
  reset role;
  perform pg_temp.assert_true(not (v_result->>'allowed')::boolean and v_result->>'reason'='billing_locked',
    'consumed-credit reversal remains billing locked');
end;
$$;

rollback;
