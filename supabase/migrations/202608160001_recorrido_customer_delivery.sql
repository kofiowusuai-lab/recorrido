-- Recipient-bound customer delivery. Render completion stages delivery;
-- provider-confirmed media acceptance is the only settlement point.

alter table public.recorrido_generation_jobs
  add column if not exists output_format text,
  add column if not exists source_listing_id text;

do $$ begin
  alter table public.recorrido_generation_jobs
    add constraint recorrido_generation_jobs_output_format_check
    check (output_format is null or output_format in ('9:16','16:9'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.recorrido_generation_jobs
    add constraint recorrido_generation_jobs_source_listing_id_check
    check (source_listing_id is null or source_listing_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
exception when duplicate_object then null; end $$;

alter table public.recorrido_generation_reservations
  add column if not exists output_format text,
  add column if not exists source_listing_id text;
do $$ begin
  alter table public.recorrido_generation_reservations
    add constraint recorrido_generation_reservations_output_format_check
    check (output_format is null or output_format in ('9:16','16:9'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.recorrido_generation_reservations
    add constraint recorrido_generation_reservations_source_listing_id_check
    check (source_listing_id is null or source_listing_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
exception when duplicate_object then null; end $$;

create or replace function public.recorrido_prevent_manifest_sha256_change()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if old.input_manifest_key is not null and new.input_manifest_key is distinct from old.input_manifest_key then
    raise exception 'input manifest key is immutable' using errcode = '55000';
  end if;
  if old.manifest_sha256 is not null and new.manifest_sha256 is distinct from old.manifest_sha256 then
    raise exception 'manifest sha256 is immutable' using errcode = '55000';
  end if;
  if old.output_format is not null and new.output_format is distinct from old.output_format then
    raise exception 'output format is immutable' using errcode = '55000';
  end if;
  if old.source_listing_id is not null and new.source_listing_id is distinct from old.source_listing_id then
    raise exception 'source listing id is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;
drop trigger if exists recorrido_generation_jobs_manifest_sha256_immutable on public.recorrido_generation_jobs;
create trigger recorrido_generation_jobs_manifest_sha256_immutable
before update of input_manifest_key, manifest_sha256, output_format, source_listing_id
on public.recorrido_generation_jobs for each row execute function public.recorrido_prevent_manifest_sha256_change();

create table public.recorrido_customer_delivery_runtime (
  environment text primary key check (environment in ('staging','production')),
  delivery_enabled boolean not null default false,
  expected_sender_identity_hash text check (expected_sender_identity_hash is null or expected_sender_identity_hash ~ '^[0-9a-f]{64}$'),
  lease_seconds integer not null default 300 check (lease_seconds between 60 and 900),
  updated_at timestamptz not null default now()
);
insert into public.recorrido_customer_delivery_runtime(environment) values ('staging'),('production')
on conflict (environment) do nothing;

create table public.recorrido_customer_delivery_outbox (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.recorrido_generation_jobs(id),
  reservation_id uuid not null references public.recorrido_generation_reservations(id),
  account_id uuid not null references public.recorrido_customer_accounts(id),
  member_id uuid not null references public.recorrido_account_members(id),
  environment text not null check (environment in ('staging','production')),
  output_format text not null check (output_format in ('9:16','16:9')),
  source_listing_id text not null check (source_listing_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'),
  recipient_phone_e164 text not null check (recipient_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  output_object_key text not null,
  output_sha256 text not null check (output_sha256 ~ '^[0-9a-f]{64}$'),
  duration_seconds integer not null check (duration_seconds > 0),
  expected_sender_identity_hash text not null check (expected_sender_identity_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending' check (status in (
    'pending','media_claimed','media_sending','media_ambiguous',
    'notice_pending','notice_claimed','notice_sending','notice_ambiguous','delivered','failed'
  )),
  media_attempts integer not null default 0 check (media_attempts >= 0),
  notice_attempts integer not null default 0 check (notice_attempts >= 0),
  claim_token uuid,
  claim_attempt integer,
  lease_owner text,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  media_provider_message_id text,
  media_accepted_at timestamptz,
  remaining_generations integer check (remaining_generations is null or remaining_generations >= 0),
  notice_text text,
  notice_provider_message_id text,
  notice_accepted_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (reservation_id),
  unique (job_id),
  check ((claim_token is null and claim_attempt is null and lease_owner is null and lease_expires_at is null)
      or (claim_token is not null and claim_attempt is not null and lease_owner is not null and lease_expires_at is not null))
);
create index recorrido_customer_delivery_claim_idx
on public.recorrido_customer_delivery_outbox(environment,next_attempt_at,created_at)
where status in ('pending','media_claimed','notice_pending','notice_claimed');

create table public.recorrido_customer_delivery_attempts (
  id bigint generated always as identity primary key,
  delivery_id uuid not null references public.recorrido_customer_delivery_outbox(id),
  phase text not null check (phase in ('media','notice')),
  attempt_number integer not null check (attempt_number > 0),
  claim_token uuid not null,
  worker_id text not null,
  status text not null check (status in ('claimed','sending','accepted','abandoned','ambiguous')),
  provider_message_id text,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(delivery_id,phase,attempt_number),
  unique(delivery_id,claim_token)
);

create or replace function public.recorrido_prevent_customer_delivery_binding_change()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.job_id is distinct from old.job_id or new.reservation_id is distinct from old.reservation_id
     or new.account_id is distinct from old.account_id or new.member_id is distinct from old.member_id
     or new.environment is distinct from old.environment or new.output_format is distinct from old.output_format
     or new.source_listing_id is distinct from old.source_listing_id
     or new.recipient_phone_e164 is distinct from old.recipient_phone_e164
     or new.output_object_key is distinct from old.output_object_key
     or new.output_sha256 is distinct from old.output_sha256
     or new.expected_sender_identity_hash is distinct from old.expected_sender_identity_hash then
    raise exception 'customer delivery binding is immutable' using errcode = '55000';
  end if;
  if old.media_provider_message_id is not null and new.media_provider_message_id is distinct from old.media_provider_message_id then
    raise exception 'media provider id is immutable' using errcode = '55000';
  end if;
  if old.notice_provider_message_id is not null and new.notice_provider_message_id is distinct from old.notice_provider_message_id then
    raise exception 'notice provider id is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;
create trigger recorrido_customer_delivery_binding_immutable
before update on public.recorrido_customer_delivery_outbox for each row
execute function public.recorrido_prevent_customer_delivery_binding_change();

create or replace function public.recorrido_protect_reservation_delivery_binding()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.output_format is not null and new.output_format is distinct from old.output_format then raise exception 'reservation output format is immutable'; end if;
  if old.source_listing_id is not null and new.source_listing_id is distinct from old.source_listing_id then raise exception 'reservation source listing is immutable'; end if;
  return new;
end;
$$;

drop trigger if exists recorrido_generation_reservations_delivery_binding_immutable on public.recorrido_generation_reservations;
create trigger recorrido_generation_reservations_delivery_binding_immutable
before update of output_format, source_listing_id on public.recorrido_generation_reservations
for each row execute function public.recorrido_protect_reservation_delivery_binding();

create or replace function public.recorrido_configure_customer_delivery(
  p_environment text, p_enabled boolean, p_expected_sender_identity_hash text
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_row public.recorrido_customer_delivery_runtime;
begin
  if p_environment not in ('staging','production') or p_expected_sender_identity_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid delivery runtime configuration' using errcode = '22023';
  end if;
  update public.recorrido_customer_delivery_runtime
  set delivery_enabled=p_enabled, expected_sender_identity_hash=p_expected_sender_identity_hash, updated_at=now()
  where environment=p_environment returning * into v_row;
  return jsonb_build_object('environment',v_row.environment,'delivery_enabled',v_row.delivery_enabled,
    'expected_sender_identity_hash',v_row.expected_sender_identity_hash);
end;
$$;

-- Replace ingress reservation binding with required native format and source identity.
drop function if exists public.recorrido_prepare_generation_dispatch(uuid,uuid,text,text,text,text);
create function public.recorrido_prepare_generation_dispatch(
  p_account_id uuid, p_member_id uuid, p_idempotency_key text,
  p_input_manifest_key text, p_manifest_sha256 text, p_environment text,
  p_output_format text, p_source_listing_id text
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_reserved jsonb; v_job public.recorrido_generation_jobs;
  v_reservation_id uuid; v_outbox public.recorrido_generation_dispatch_outbox;
  v_expected_key text;
begin
  select * into v_runtime from public.recorrido_cloudflare_generation_runtime where singleton for share;
  if not found or not v_runtime.cloudflare_generation_enabled or v_runtime.active_environment is distinct from p_environment then
    raise exception 'cloudflare generation disabled for environment' using errcode='55000';
  end if;
  if p_environment not in ('staging','production') or p_output_format not in ('9:16','16:9')
     or p_source_listing_id is null or p_source_listing_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' then
    raise exception 'invalid delivery binding' using errcode='22023';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
     or p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid generation request' using errcode='22023';
  end if;
  v_expected_key:=format('accounts/%s/jobs/%s/manifest.json',p_account_id,p_idempotency_key);
  if p_input_manifest_key is distinct from v_expected_key then raise exception 'invalid input manifest key' using errcode='22023'; end if;
  v_reserved:=public.recorrido_reserve_generation(p_account_id,p_member_id,p_idempotency_key);
  select * into v_job from public.recorrido_generation_jobs where id=(v_reserved->>'job_id')::uuid for update;
  if not found or v_job.account_id is distinct from p_account_id or v_job.member_id is distinct from p_member_id
     or (v_job.cloudflare_environment is not null and v_job.cloudflare_environment is distinct from p_environment)
     or (v_job.input_manifest_key is not null and v_job.input_manifest_key is distinct from p_input_manifest_key)
     or (v_job.manifest_sha256 is not null and v_job.manifest_sha256 is distinct from p_manifest_sha256)
     or (v_job.output_format is not null and v_job.output_format is distinct from p_output_format)
     or (v_job.source_listing_id is not null and v_job.source_listing_id is distinct from p_source_listing_id) then
    raise exception 'conflicting generation replay' using errcode='22000';
  end if;
  update public.recorrido_generation_jobs set
    input_manifest_key=coalesce(input_manifest_key,p_input_manifest_key), manifest_sha256=coalesce(manifest_sha256,p_manifest_sha256),
    cloudflare_managed=true, cloudflare_environment=coalesce(cloudflare_environment,p_environment),
    output_format=coalesce(output_format,p_output_format), source_listing_id=coalesce(source_listing_id,p_source_listing_id)
  where id=v_job.id returning * into v_job;
  if not coalesce((v_reserved->>'allowed')::boolean,false) then
    return v_reserved||jsonb_build_object('should_dispatch',false,'dispatch_status',null,'environment',p_environment);
  end if;
  v_reservation_id:=(v_reserved->>'reservation_id')::uuid;
  update public.recorrido_generation_reservations
  set output_format=coalesce(output_format,p_output_format),source_listing_id=coalesce(source_listing_id,p_source_listing_id)
  where id=v_reservation_id and job_id=v_job.id
    and (output_format is null or output_format=p_output_format)
    and (source_listing_id is null or source_listing_id=p_source_listing_id);
  if not found then raise exception 'conflicting reservation delivery binding' using errcode='22000'; end if;
  insert into public.recorrido_generation_dispatch_outbox(job_id,account_id,reservation_id,cloudflare_environment,message)
  values(v_job.id,p_account_id,v_reservation_id,p_environment,jsonb_build_object(
    'version',1,'environment',p_environment,'job_id',v_job.id,'reservation_id',v_reservation_id,'account_id',p_account_id,
    'idempotency_key',p_idempotency_key,'input_manifest_key',p_input_manifest_key,'manifest_sha256',p_manifest_sha256,
    'output_format',p_output_format,'source_listing_id',p_source_listing_id)) on conflict(job_id) do nothing;
  select * into v_outbox from public.recorrido_generation_dispatch_outbox where job_id=v_job.id for update;
  if v_outbox.account_id is distinct from p_account_id or v_outbox.reservation_id is distinct from v_reservation_id
     or v_outbox.cloudflare_environment is distinct from p_environment
     or v_outbox.message->>'output_format' is distinct from p_output_format
     or v_outbox.message->>'source_listing_id' is distinct from p_source_listing_id then
    raise exception 'conflicting dispatch replay' using errcode='22000';
  end if;
  return v_reserved||jsonb_build_object('should_dispatch',v_outbox.status='pending','dispatch_status',v_outbox.status,
    'environment',p_environment,'manifest_sha256',p_manifest_sha256,'output_format',p_output_format,'source_listing_id',p_source_listing_id);
end;
$$;

-- Render completion records immutable output and stages delivery; reservation stays reserved.
create or replace function public.recorrido_complete_generation_dispatch(
  p_job_id uuid,p_reservation_id uuid,p_environment text,p_worker_id text,p_lease_token uuid,p_lease_version bigint,
  p_output_object_key text,p_output_sha256 text,p_duration_seconds integer
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_generation_runtime public.recorrido_cloudflare_generation_runtime;
  v_delivery_runtime public.recorrido_customer_delivery_runtime;
  v_reservation public.recorrido_generation_reservations; v_job public.recorrido_generation_jobs;
  v_account_id uuid; v_expected_key text; v_phone text; v_outbox public.recorrido_customer_delivery_outbox;
begin
  select * into v_generation_runtime from public.recorrido_cloudflare_generation_runtime where singleton for share;
  if not found or p_environment not in ('staging','production') then raise exception 'invalid cloudflare environment' using errcode='22023'; end if;
  select * into v_delivery_runtime from public.recorrido_customer_delivery_runtime where environment=p_environment for share;
  if not found or v_delivery_runtime.expected_sender_identity_hash is null then
    raise exception 'customer delivery runtime not configured' using errcode='55000';
  end if;
  select account_id into v_account_id from public.recorrido_generation_reservations where id=p_reservation_id and job_id=p_job_id;
  if not found then raise exception 'reservation mismatch' using errcode='22000'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_account_id::text,0));
  select * into v_reservation from public.recorrido_generation_reservations where id=p_reservation_id and job_id=p_job_id for update;
  if not found or v_reservation.status<>'reserved' then raise exception 'reservation not reserved' using errcode='55000'; end if;
  select * into v_job from public.recorrido_generation_jobs where id=p_job_id and account_id=v_reservation.account_id
    and cloudflare_managed and cloudflare_environment=p_environment and status='running' and lease_owner=p_worker_id
    and lease_token=p_lease_token and lease_version=p_lease_version and lease_expires_at>=now()
    and output_upload_sha256=p_output_sha256 for update;
  if not found then raise exception 'generation lease lost' using errcode='55000'; end if;
  if v_job.output_format not in ('9:16','16:9') or v_job.source_listing_id is null then raise exception 'delivery binding missing' using errcode='55000'; end if;
  if v_reservation.output_format is distinct from v_job.output_format or v_reservation.source_listing_id is distinct from v_job.source_listing_id then
    raise exception 'reservation delivery binding mismatch' using errcode='55000';
  end if;
  v_expected_key:=format('accounts/%s/jobs/%s/leases/%s/output.mp4',v_job.account_id,p_job_id,p_lease_token);
  if p_output_object_key is distinct from v_expected_key or p_output_sha256 !~ '^[0-9a-f]{64}$' or p_duration_seconds<=0 then
    raise exception 'invalid output binding' using errcode='22023';
  end if;
  select w.phone_e164 into v_phone from public.recorrido_account_members m
    join public.recorrido_whatsapp_identities w on w.member_id=m.id and w.account_id=m.account_id
    where m.id=v_job.member_id and m.account_id=v_job.account_id and m.status='active'
      and w.phone_e164=m.phone_e164 and w.phone_e164 ~ '^\+[1-9][0-9]{7,14}$';
  if not found then raise exception 'active recipient binding missing' using errcode='55000'; end if;
  update public.recorrido_generation_jobs set status='completed',completed_at=coalesce(completed_at,now()),duration_seconds=p_duration_seconds,
    output_object_key=p_output_object_key,output_sha256=p_output_sha256,lease_owner=null,lease_expires_at=null,lease_token=null,updated_at=now()
    where id=p_job_id;
  insert into public.recorrido_customer_delivery_outbox(job_id,reservation_id,account_id,member_id,environment,output_format,
    source_listing_id,recipient_phone_e164,output_object_key,output_sha256,duration_seconds,expected_sender_identity_hash)
  values(p_job_id,p_reservation_id,v_job.account_id,v_job.member_id,p_environment,v_job.output_format,v_job.source_listing_id,
    v_phone,p_output_object_key,p_output_sha256,p_duration_seconds,v_delivery_runtime.expected_sender_identity_hash)
  on conflict(job_id) do nothing;
  select * into v_outbox from public.recorrido_customer_delivery_outbox where job_id=p_job_id for update;
  if v_outbox.reservation_id is distinct from p_reservation_id or v_outbox.recipient_phone_e164 is distinct from v_phone
     or v_outbox.output_object_key is distinct from p_output_object_key or v_outbox.output_sha256 is distinct from p_output_sha256 then
    raise exception 'conflicting delivery replay' using errcode='22000';
  end if;
  return jsonb_build_object('status','delivery_pending','job_id',p_job_id,'reservation_id',p_reservation_id,
    'delivery_id',v_outbox.id,'output_format',v_outbox.output_format,'source_listing_id',v_outbox.source_listing_id);
end;
$$;

create or replace function public.recorrido_claim_customer_delivery(p_environment text,p_worker_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_runtime public.recorrido_customer_delivery_runtime; v_row public.recorrido_customer_delivery_outbox;
  v_phone text; v_phase text; v_attempt integer; v_token uuid:=gen_random_uuid();
begin
  if p_worker_id !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then raise exception 'invalid worker id' using errcode='22023'; end if;
  select * into v_runtime from public.recorrido_customer_delivery_runtime where environment=p_environment for share;
  if not found or not v_runtime.delivery_enabled or v_runtime.expected_sender_identity_hash is null then return null; end if;
  select * into v_row from public.recorrido_customer_delivery_outbox where environment=p_environment
    and ((status in ('pending','notice_pending') and next_attempt_at<=now())
      or (status in ('media_claimed','notice_claimed') and lease_expires_at<now()))
    order by created_at for update skip locked limit 1;
  if not found then return null; end if;
  select w.phone_e164 into v_phone from public.recorrido_account_members m join public.recorrido_whatsapp_identities w
    on w.member_id=m.id and w.account_id=m.account_id
    where m.id=v_row.member_id and m.account_id=v_row.account_id and m.status='active'
      and w.phone_e164=m.phone_e164 and w.phone_e164=v_row.recipient_phone_e164;
  if not found or v_runtime.expected_sender_identity_hash is distinct from v_row.expected_sender_identity_hash then
    raise exception 'recipient or sender binding changed' using errcode='55000';
  end if;
  if v_row.status in ('media_claimed','notice_claimed') then
    update public.recorrido_customer_delivery_attempts set status='abandoned',error_code='lease_expired',updated_at=now()
    where delivery_id=v_row.id and claim_token=v_row.claim_token and status='claimed';
  end if;
  v_phase:=case when v_row.status in ('pending','media_claimed') then 'media' else 'notice' end;
  if v_phase='media' then v_attempt:=v_row.media_attempts+1; else v_attempt:=v_row.notice_attempts+1; end if;
  update public.recorrido_customer_delivery_outbox set
    status=case when v_phase='media' then 'media_claimed' else 'notice_claimed' end,
    media_attempts=case when v_phase='media' then v_attempt else media_attempts end,
    notice_attempts=case when v_phase='notice' then v_attempt else notice_attempts end,
    claim_token=v_token,claim_attempt=v_attempt,lease_owner=p_worker_id,
    lease_expires_at=now()+make_interval(secs=>v_runtime.lease_seconds),updated_at=now()
  where id=v_row.id returning * into v_row;
  insert into public.recorrido_customer_delivery_attempts(delivery_id,phase,attempt_number,claim_token,worker_id,status)
  values(v_row.id,v_phase,v_attempt,v_token,p_worker_id,'claimed');
  return jsonb_build_object('delivery_id',v_row.id,'phase',v_phase,'environment',v_row.environment,'attempt',v_attempt,'claim_token',v_token,
    'lease_expires_at',v_row.lease_expires_at,'account_id',v_row.account_id,'member_id',v_row.member_id,
    'recipient_phone_e164',v_row.recipient_phone_e164,'expected_sender_identity_hash',v_row.expected_sender_identity_hash,
    'output_format',v_row.output_format,'source_listing_id',v_row.source_listing_id,'output_sha256',v_row.output_sha256,
    'duration_seconds',v_row.duration_seconds,'notice_text',v_row.notice_text);
end;
$$;

create or replace function public.recorrido_heartbeat_customer_delivery(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_runtime public.recorrido_customer_delivery_runtime; v_row public.recorrido_customer_delivery_outbox;
begin
  select * into v_runtime from public.recorrido_customer_delivery_runtime where environment=p_environment for share;
  if not found then raise exception 'delivery runtime missing' using errcode='55000'; end if;
  update public.recorrido_customer_delivery_outbox set lease_expires_at=now()+make_interval(secs=>v_runtime.lease_seconds),updated_at=now()
  where id=p_delivery_id and environment=p_environment and lease_owner=p_worker_id and claim_token=p_claim_token
    and claim_attempt=p_attempt and lease_expires_at>=now() and status in ('media_claimed','notice_claimed') returning * into v_row;
  if not found then raise exception 'delivery lease lost' using errcode='55000'; end if;
  return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status,'lease_expires_at',v_row.lease_expires_at);
end;
$$;

create or replace function public.recorrido_checkpoint_customer_delivery(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer,p_phase text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row public.recorrido_customer_delivery_outbox; v_phone text; v_sender text;
begin
  if p_phase not in ('media','notice') then raise exception 'invalid delivery phase' using errcode='22023'; end if;
  select * into v_row from public.recorrido_customer_delivery_outbox where id=p_delivery_id and environment=p_environment
    and lease_owner=p_worker_id and claim_token=p_claim_token and claim_attempt=p_attempt and lease_expires_at>=now()
    and status=case when p_phase='media' then 'media_claimed' else 'notice_claimed' end for update;
  if not found then raise exception 'delivery lease lost' using errcode='55000'; end if;
  select w.phone_e164 into v_phone from public.recorrido_account_members m join public.recorrido_whatsapp_identities w
    on w.member_id=m.id and w.account_id=m.account_id
    where m.id=v_row.member_id and m.account_id=v_row.account_id and m.status='active'
      and w.phone_e164=m.phone_e164 and w.phone_e164=v_row.recipient_phone_e164;
  select expected_sender_identity_hash into v_sender from public.recorrido_customer_delivery_runtime
    where environment=p_environment and delivery_enabled for share;
  if v_phone is null or v_sender is distinct from v_row.expected_sender_identity_hash then
    raise exception 'recipient or sender binding changed' using errcode='55000';
  end if;
  update public.recorrido_customer_delivery_outbox set status=case when p_phase='media' then 'media_sending' else 'notice_sending' end,updated_at=now()
  where id=p_delivery_id and environment=p_environment and lease_owner=p_worker_id and claim_token=p_claim_token
    and claim_attempt=p_attempt and lease_expires_at>=now()
    and status=case when p_phase='media' then 'media_claimed' else 'notice_claimed' end returning * into v_row;
  if not found then raise exception 'delivery lease lost' using errcode='55000'; end if;
  update public.recorrido_customer_delivery_attempts set status='sending',updated_at=now()
    where delivery_id=p_delivery_id and phase=p_phase and attempt_number=p_attempt and claim_token=p_claim_token;
  return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status);
end;
$$;

create or replace function public.recorrido_assert_customer_delivery_media(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row public.recorrido_customer_delivery_outbox;
begin
  select * into v_row from public.recorrido_customer_delivery_outbox where id=p_delivery_id and environment=p_environment
    and lease_owner=p_worker_id and claim_token=p_claim_token and claim_attempt=p_attempt and lease_expires_at>=now()
    and status in ('media_claimed','media_sending') for share;
  if not found then raise exception 'delivery lease lost' using errcode='55000'; end if;
  return jsonb_build_object('authorized',true,'output_object_key',v_row.output_object_key,'output_sha256',v_row.output_sha256);
end;
$$;

create or replace function public.recorrido_accept_customer_delivery_media(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer,p_provider_message_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row public.recorrido_customer_delivery_outbox; v_result jsonb; v_remaining integer; v_country text; v_notice text;
begin
  if p_provider_message_id is null or p_provider_message_id !~ '^[A-Za-z0-9._:@/-]{1,255}$' then raise exception 'invalid provider message id' using errcode='22023'; end if;
  select * into v_row from public.recorrido_customer_delivery_outbox where id=p_delivery_id for update;
  if not found then raise exception 'delivery missing' using errcode='22000'; end if;
  if v_row.status in ('notice_pending','notice_claimed','notice_sending','delivered') and v_row.media_provider_message_id=p_provider_message_id then
    return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status,'remaining_generations',v_row.remaining_generations,'notice_text',v_row.notice_text);
  end if;
  if v_row.environment<>p_environment or v_row.status<>'media_sending' or v_row.lease_owner<>p_worker_id
     or v_row.claim_token<>p_claim_token or v_row.claim_attempt<>p_attempt or v_row.lease_expires_at<now() then
    raise exception 'delivery lease lost' using errcode='55000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_row.account_id::text,0));
  v_result:=public.recorrido_complete_generation(v_row.reservation_id,v_row.duration_seconds);
  v_remaining:=public.recorrido_available_credits(v_row.account_id);
  select home_country into v_country from public.recorrido_customer_accounts where id=v_row.account_id;
  if v_country='BR' then v_notice:=format('Você tem %s gerações disponíveis restantes neste mês.',v_remaining);
  else v_notice:=format('Te quedan %s generaciones disponibles este mes.',v_remaining); end if;
  update public.recorrido_customer_delivery_outbox set status='notice_pending',media_provider_message_id=p_provider_message_id,
    media_accepted_at=now(),remaining_generations=v_remaining,notice_text=v_notice,claim_token=null,claim_attempt=null,
    lease_owner=null,lease_expires_at=null,next_attempt_at=now(),updated_at=now() where id=v_row.id returning * into v_row;
  update public.recorrido_customer_delivery_attempts set status='accepted',provider_message_id=p_provider_message_id,updated_at=now()
    where delivery_id=p_delivery_id and phase='media' and attempt_number=p_attempt and claim_token=p_claim_token;
  return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status,'remaining_generations',v_remaining,'notice_text',v_notice);
end;
$$;

create or replace function public.recorrido_accept_customer_delivery_notice(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer,p_provider_message_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row public.recorrido_customer_delivery_outbox;
begin
  if p_provider_message_id is null or p_provider_message_id !~ '^[A-Za-z0-9._:@/-]{1,255}$' then raise exception 'invalid provider message id' using errcode='22023'; end if;
  select * into v_row from public.recorrido_customer_delivery_outbox where id=p_delivery_id for update;
  if not found then raise exception 'delivery missing' using errcode='22000'; end if;
  if v_row.status='delivered' and v_row.notice_provider_message_id=p_provider_message_id then
    return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status,'remaining_generations',v_row.remaining_generations);
  end if;
  if v_row.environment<>p_environment or v_row.status<>'notice_sending' or v_row.lease_owner<>p_worker_id
    or v_row.claim_token<>p_claim_token or v_row.claim_attempt<>p_attempt or v_row.lease_expires_at<now() then
    raise exception 'delivery lease lost' using errcode='55000';
  end if;
  update public.recorrido_customer_delivery_outbox set status='delivered',notice_provider_message_id=p_provider_message_id,
    notice_accepted_at=now(),claim_token=null,claim_attempt=null,lease_owner=null,lease_expires_at=null,updated_at=now()
    where id=v_row.id returning * into v_row;
  update public.recorrido_customer_delivery_attempts set status='accepted',provider_message_id=p_provider_message_id,updated_at=now()
    where delivery_id=p_delivery_id and phase='notice' and attempt_number=p_attempt and claim_token=p_claim_token;
  return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status,'remaining_generations',v_row.remaining_generations);
end;
$$;

create or replace function public.recorrido_abandon_customer_delivery_claim(p_delivery_id uuid,p_environment text,p_worker_id text,p_claim_token uuid,p_attempt integer,p_error_code text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_row public.recorrido_customer_delivery_outbox; v_phase text; v_error text;
begin
  v_error:=left(coalesce(nullif(btrim(p_error_code),''),'pre_send_unavailable'),80);
  if v_error !~ '^[A-Za-z0-9_.:-]+$' then v_error:='pre_send_unavailable'; end if;
  select * into v_row from public.recorrido_customer_delivery_outbox where id=p_delivery_id and environment=p_environment
    and lease_owner=p_worker_id and claim_token=p_claim_token and claim_attempt=p_attempt and lease_expires_at>=now()
    and status in ('media_claimed','notice_claimed') for update;
  if not found then raise exception 'delivery lease lost' using errcode='55000'; end if;
  v_phase:=case when v_row.status='media_claimed' then 'media' else 'notice' end;
  update public.recorrido_customer_delivery_outbox set status=case when v_phase='media' then 'pending' else 'notice_pending' end,
    claim_token=null,claim_attempt=null,lease_owner=null,lease_expires_at=null,next_attempt_at=now()+interval '30 seconds',
    last_error_code=v_error,updated_at=now() where id=v_row.id returning * into v_row;
  update public.recorrido_customer_delivery_attempts set status='abandoned',error_code=v_error,updated_at=now()
    where delivery_id=p_delivery_id and phase=v_phase and attempt_number=p_attempt and claim_token=p_claim_token;
  return jsonb_build_object('delivery_id',v_row.id,'status',v_row.status);
end;
$$;

alter table public.recorrido_customer_delivery_runtime enable row level security;
alter table public.recorrido_customer_delivery_outbox enable row level security;
alter table public.recorrido_customer_delivery_attempts enable row level security;
revoke all on table public.recorrido_customer_delivery_runtime from public, anon, authenticated;
revoke all on table public.recorrido_customer_delivery_outbox from public, anon, authenticated;
revoke all on table public.recorrido_customer_delivery_attempts from public, anon, authenticated;
revoke all on function public.recorrido_configure_customer_delivery(text,boolean,text) from public,anon,authenticated,service_role;
revoke all on function public.recorrido_prepare_generation_dispatch(uuid,uuid,text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer) from public,anon,authenticated;
revoke all on function public.recorrido_claim_customer_delivery(text,text) from public,anon,authenticated;
revoke all on function public.recorrido_heartbeat_customer_delivery(uuid,text,text,uuid,integer) from public,anon,authenticated;
revoke all on function public.recorrido_checkpoint_customer_delivery(uuid,text,text,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.recorrido_assert_customer_delivery_media(uuid,text,text,uuid,integer) from public,anon,authenticated;
revoke all on function public.recorrido_accept_customer_delivery_media(uuid,text,text,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.recorrido_accept_customer_delivery_notice(uuid,text,text,uuid,integer,text) from public,anon,authenticated;
revoke all on function public.recorrido_abandon_customer_delivery_claim(uuid,text,text,uuid,integer,text) from public,anon,authenticated;
revoke execute on function public.recorrido_complete_generation(uuid,integer) from recorrido_billing_generation_worker;
grant execute on function public.recorrido_prepare_generation_dispatch(uuid,uuid,text,text,text,text,text,text),
  public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer),
  public.recorrido_claim_customer_delivery(text,text),
  public.recorrido_heartbeat_customer_delivery(uuid,text,text,uuid,integer),
  public.recorrido_checkpoint_customer_delivery(uuid,text,text,uuid,integer,text),
  public.recorrido_assert_customer_delivery_media(uuid,text,text,uuid,integer),
  public.recorrido_accept_customer_delivery_media(uuid,text,text,uuid,integer,text),
  public.recorrido_accept_customer_delivery_notice(uuid,text,text,uuid,integer,text),
  public.recorrido_abandon_customer_delivery_claim(uuid,text,text,uuid,integer,text)
to service_role;
