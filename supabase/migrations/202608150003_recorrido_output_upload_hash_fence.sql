-- Forward hardening for live staging: bind output SHA to one active lease before multipart finalization.
alter table public.recorrido_generation_jobs
  add column if not exists output_upload_sha256 text;

create or replace function public.recorrido_claim_generation_job(
  p_environment text,
  p_worker_id text,
  p_lease_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_job public.recorrido_generation_jobs;
  v_reservation_id uuid;
  v_lease_seconds integer;
begin
  if p_worker_id !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then
    raise exception 'invalid worker id' using errcode = '22023';
  end if;

  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found
     or not v_runtime.cloudflare_generation_enabled
     or v_runtime.active_environment is distinct from p_environment then
    raise exception 'cloudflare generation disabled for environment' using errcode = '55000';
  end if;
  v_lease_seconds := least(
    greatest(coalesce(p_lease_seconds, v_runtime.lease_seconds), 60),
    3600
  );

  select j.* into v_job
  from public.recorrido_generation_jobs j
  where j.cloudflare_managed
    and j.cloudflare_environment = p_environment
    and j.queue_delivered_at is not null
    and exists (
      select 1
      from public.recorrido_generation_dispatch_outbox o
      where o.job_id = j.id
        and o.cloudflare_environment = p_environment
        and o.status = 'delivered'
    )
    and (
      j.status = 'queued'
      or (j.status = 'running' and j.lease_expires_at < now())
    )
  order by j.created_at
  for update skip locked
  limit 1;
  if not found then return null; end if;

  update public.recorrido_generation_jobs
  set status = 'running',
      started_at = coalesce(started_at, now()),
      lease_owner = p_worker_id,
      lease_expires_at = now() + make_interval(secs => v_lease_seconds),
      lease_token = gen_random_uuid(),
      lease_version = lease_version + 1,
      output_upload_sha256 = null
  where id = v_job.id
  returning * into v_job;

  select o.reservation_id into v_reservation_id
  from public.recorrido_generation_dispatch_outbox o
  where o.job_id = v_job.id
    and o.cloudflare_environment = p_environment;

  return jsonb_build_object(
    'version', 1,
    'environment', v_job.cloudflare_environment,
    'job_id', v_job.id,
    'account_id', v_job.account_id,
    'reservation_id', v_reservation_id,
    'idempotency_key', v_job.idempotency_key,
    'input_manifest_key', v_job.input_manifest_key,
    'manifest_sha256', v_job.manifest_sha256,
    'lease_owner', v_job.lease_owner,
    'lease_expires_at', v_job.lease_expires_at,
    'lease_token', v_job.lease_token,
    'lease_version', v_job.lease_version
  );
end;
$$;

create or replace function public.recorrido_assert_generation_output_lease(
  p_job_id uuid,
  p_account_id uuid,
  p_environment text,
  p_worker_id text,
  p_lease_token uuid,
  p_lease_version bigint,
  p_output_object_key text,
  p_output_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_job public.recorrido_generation_jobs;
  v_expected_key text;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found or p_environment not in ('staging','production') then
    raise exception 'invalid cloudflare environment' using errcode = '22023';
  end if;
  if p_output_sha256 is null or p_output_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid output sha256' using errcode = '22023';
  end if;
  v_expected_key := format(
    'accounts/%s/jobs/%s/leases/%s/output.mp4',
    p_account_id, p_job_id, p_lease_token
  );
  if p_output_object_key is distinct from v_expected_key then
    raise exception 'invalid output object key' using errcode = '22023';
  end if;

  select * into v_job
  from public.recorrido_generation_jobs
  where id = p_job_id
    and account_id = p_account_id
    and cloudflare_managed
    and cloudflare_environment = p_environment
    and status = 'running'
    and lease_owner = p_worker_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and lease_expires_at >= now()
  for update;
  if not found then
    raise exception 'generation lease lost' using errcode = '55000';
  end if;
  if v_job.output_upload_sha256 is not null
     and v_job.output_upload_sha256 is distinct from p_output_sha256 then
    raise exception 'generation output hash conflict' using errcode = '55000';
  end if;
  update public.recorrido_generation_jobs
  set output_upload_sha256 = p_output_sha256,
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object(
    'leased', true,
    'job_id', v_job.id,
    'environment', v_job.cloudflare_environment,
    'lease_token', v_job.lease_token,
    'lease_version', v_job.lease_version,
    'output_object_key', p_output_object_key,
    'output_sha256', p_output_sha256
  );
end;
$$;

create or replace function public.recorrido_complete_generation_dispatch(
  p_job_id uuid,
  p_reservation_id uuid,
  p_environment text,
  p_worker_id text,
  p_lease_token uuid,
  p_lease_version bigint,
  p_output_object_key text,
  p_output_sha256 text,
  p_duration_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_reservation public.recorrido_generation_reservations;
  v_job public.recorrido_generation_jobs;
  v_account_id uuid;
  v_result jsonb;
  v_expected_key text;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found or p_environment not in ('staging','production') then
    raise exception 'invalid cloudflare environment' using errcode = '22023';
  end if;

  -- Match the effective legacy global order: account advisory -> reservation -> job.
  select account_id into v_account_id
  from public.recorrido_generation_reservations
  where id = p_reservation_id and job_id = p_job_id;
  if not found then
    raise exception 'reservation mismatch' using errcode = '22000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_account_id::text, 0)
  );
  select * into v_reservation
  from public.recorrido_generation_reservations
  where id = p_reservation_id and job_id = p_job_id
  for update;
  if not found or v_reservation.account_id is distinct from v_account_id then
    raise exception 'reservation identity changed' using errcode = '40001';
  end if;
  select * into v_job
  from public.recorrido_generation_jobs
  where id = p_job_id
    and account_id = v_reservation.account_id
    and cloudflare_managed
    and cloudflare_environment = p_environment
    and status = 'running'
    and lease_owner = p_worker_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and lease_expires_at >= now()
    and output_upload_sha256 = p_output_sha256
  for update;
  if not found then
    raise exception 'generation lease lost' using errcode = '55000';
  end if;

  v_expected_key := format(
    'accounts/%s/jobs/%s/leases/%s/output.mp4',
    v_job.account_id, p_job_id, p_lease_token
  );
  if p_output_object_key is distinct from v_expected_key then
    raise exception 'invalid output object key' using errcode = '22023';
  end if;
  if p_output_sha256 is null or p_output_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid output sha256' using errcode = '22023';
  end if;
  if v_job.output_object_key is not null
     and v_job.output_object_key is distinct from p_output_object_key then
    raise exception 'conflicting output replay' using errcode = '22000';
  end if;
  if v_job.output_sha256 is not null
     and v_job.output_sha256 is distinct from p_output_sha256 then
    raise exception 'conflicting output digest replay' using errcode = '22000';
  end if;

  v_result := public.recorrido_complete_generation(p_reservation_id, p_duration_seconds);
  update public.recorrido_generation_jobs
  set output_object_key = p_output_object_key,
      output_sha256 = p_output_sha256,
      lease_expires_at = null
  where id = p_job_id;
  return v_result || jsonb_build_object(
    'job_id', p_job_id,
    'environment', p_environment,
    'output_object_key', p_output_object_key,
    'output_sha256', p_output_sha256
  );
end;
$$;

notify pgrst, 'reload schema';
