do $$
declare
  v_account uuid := '11111111-1111-4111-8111-111111111111';
  v_member uuid := '22222222-2222-4222-8222-222222222222';
  v_bucket uuid := '33333333-3333-4333-8333-333333333333';
  v_identity uuid := '44444444-4444-4444-8444-444444444444';
  v_lease uuid := '55555555-5555-4555-8555-555555555555';
  v_hash text := repeat('a',64);
  v_prepare jsonb; v_job uuid; v_reservation uuid; v_delivery uuid;
  v_claim jsonb; v_notice_claim jsonb; v_result jsonb; v_key text;
  v_available integer; v_status text;
begin
  insert into public.recorrido_customer_accounts(id,display_name,home_country) values(v_account,'Delivery Test','CO');
  insert into public.recorrido_account_members(id,account_id,full_name,phone_e164,role,status)
    values(v_member,v_account,'Delivery Owner','+12025550123','owner','active');
  insert into public.recorrido_whatsapp_identities(id,account_id,member_id,phone_e164,verified_at)
    values(v_identity,v_account,v_member,'+12025550123',now());
  insert into public.recorrido_credit_buckets(id,account_id,source_kind,source_id,credits_granted)
    values(v_bucket,v_account,'manual_adjustment','delivery-test',4);
  insert into public.recorrido_credit_ledger(account_id,bucket_id,delta,entry_kind,source_type,source_id)
    values(v_account,v_bucket,4,'grant','test','delivery-test');
  update public.recorrido_cloudflare_generation_runtime
    set cloudflare_generation_enabled=true,active_environment='staging',updated_at=now() where singleton;
  update public.recorrido_customer_delivery_runtime
    set delivery_enabled=true,expected_sender_identity_hash=repeat('b',64),updated_at=now() where environment='staging';

  v_prepare := public.recorrido_prepare_generation_dispatch(
    v_account,v_member,'delivery-test-1',
    format('accounts/%s/jobs/delivery-test-1/manifest.json',v_account),v_hash,'staging','9:16','listing-001');
  if not (v_prepare->>'allowed')::boolean then raise exception 'prepare unexpectedly denied'; end if;
  v_job := (v_prepare->>'job_id')::uuid;
  v_reservation := (v_prepare->>'reservation_id')::uuid;

  select output_format,source_listing_id into strict v_status,v_key
    from public.recorrido_generation_reservations where id=v_reservation;
  if v_status<>'9:16' or v_key<>'listing-001' then raise exception 'reservation binding missing'; end if;
  if public.recorrido_available_credits(v_account)<>3 then raise exception 'reservation did not hold one credit'; end if;

  update public.recorrido_generation_jobs set status='running',lease_owner='mac-render-01',lease_token=v_lease,
    lease_version=1,lease_expires_at=now()+interval '15 minutes',output_upload_sha256=v_hash,started_at=now()
    where id=v_job;
  v_key := format('accounts/%s/jobs/%s/leases/%s/output.mp4',v_account,v_job,v_lease);
  v_result := public.recorrido_complete_generation_dispatch(v_job,v_reservation,'staging','mac-render-01',v_lease,1,v_key,v_hash,47);
  v_delivery := (v_result->>'delivery_id')::uuid;
  select status into v_status from public.recorrido_generation_reservations where id=v_reservation;
  if v_status<>'reserved' then raise exception 'render completion settled before delivery'; end if;
  if exists(select 1 from public.recorrido_customer_delivery_outbox where id=v_delivery and status<>'pending') then raise exception 'delivery not pending'; end if;

  v_claim := public.recorrido_claim_customer_delivery('staging','mac-delivery-01');
  if v_claim->>'recipient_phone_e164'<>'+12025550123' or v_claim->>'environment'<>'staging' or v_claim->>'phase'<>'media' then
    raise exception 'claim binding wrong';
  end if;
  begin
    update public.recorrido_account_members set phone_e164='+12025550124' where id=v_member;
    update public.recorrido_whatsapp_identities set phone_e164='+12025550124' where id=v_identity;
    perform public.recorrido_checkpoint_customer_delivery(v_delivery,'staging','mac-delivery-01',(v_claim->>'claim_token')::uuid,(v_claim->>'attempt')::integer,'media');
    raise exception 'recipient drift checkpoint unexpectedly succeeded';
  exception when sqlstate '55000' then null;
  end;
  perform public.recorrido_checkpoint_customer_delivery(v_delivery,'staging','mac-delivery-01',(v_claim->>'claim_token')::uuid,(v_claim->>'attempt')::integer,'media');
  select status into v_status from public.recorrido_generation_reservations where id=v_reservation;
  if v_status<>'reserved' then raise exception 'checkpoint settled before provider acceptance'; end if;

  v_result := public.recorrido_accept_customer_delivery_media(v_delivery,'staging','mac-delivery-01',(v_claim->>'claim_token')::uuid,(v_claim->>'attempt')::integer,'media.123');
  if v_result->>'status'<>'notice_pending' or (v_result->>'remaining_generations')::integer<>3 then raise exception 'media acceptance result wrong'; end if;
  select status into v_status from public.recorrido_generation_reservations where id=v_reservation;
  if v_status<>'consumed' then raise exception 'provider acceptance did not settle'; end if;
  select remaining_generations into v_available from public.recorrido_customer_delivery_outbox where id=v_delivery;
  if v_available<>3 then raise exception 'post-settlement balance was not persisted'; end if;

  v_notice_claim := public.recorrido_claim_customer_delivery('staging','mac-delivery-01');
  if v_notice_claim->>'phase'<>'notice' or v_notice_claim->>'notice_text'<>'Te quedan 3 generaciones disponibles este mes.' then
    raise exception 'notice claim wrong';
  end if;
  perform public.recorrido_checkpoint_customer_delivery(v_delivery,'staging','mac-delivery-01',(v_notice_claim->>'claim_token')::uuid,(v_notice_claim->>'attempt')::integer,'notice');
  v_result := public.recorrido_accept_customer_delivery_notice(v_delivery,'staging','mac-delivery-01',(v_notice_claim->>'claim_token')::uuid,(v_notice_claim->>'attempt')::integer,'notice.123');
  if v_result->>'status'<>'delivered' then raise exception 'notice not delivered'; end if;

  v_result := public.recorrido_accept_customer_delivery_media(v_delivery,'staging','wrong-worker',(v_claim->>'claim_token')::uuid,(v_claim->>'attempt')::integer,'media.123');
  if v_result->>'status'<>'delivered' then raise exception 'media provider id replay not idempotent'; end if;
  v_result := public.recorrido_accept_customer_delivery_notice(v_delivery,'staging','wrong-worker',(v_notice_claim->>'claim_token')::uuid,(v_notice_claim->>'attempt')::integer,'notice.123');
  if v_result->>'status'<>'delivered' then raise exception 'notice provider id replay not idempotent'; end if;

  if (select count(*) from public.recorrido_credit_ledger where account_id=v_account and entry_kind='reserve')<>1 then raise exception 'wrong reserve count'; end if;
  if (select count(*) from public.recorrido_customer_delivery_attempts where delivery_id=v_delivery and status='accepted')<>2 then raise exception 'provider ids not traced'; end if;
  raise notice 'delivery_behavior_ok';
end
$$;
