-- Forward repair for the live-applied Cloudflare generation authority.
-- Runtime must be disabled and drained before application.

drop function if exists public.recorrido_mark_generation_dispatched(uuid,text);
drop function if exists public.recorrido_mark_generation_dispatch_failed(uuid,text,text);

create or replace function public.recorrido_mark_generation_dispatched(
  p_job_id uuid,
  p_environment text,
  p_attempt integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_outbox public.recorrido_generation_dispatch_outbox;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found then
    raise exception 'cloudflare runtime missing' using errcode = '55000';
  end if;

  update public.recorrido_generation_dispatch_outbox
  set status = 'enqueued',
      enqueued_at = coalesce(enqueued_at, now()),
      claimed_at = null,
      last_error_code = null,
      updated_at = now()
  where job_id = p_job_id
    and cloudflare_environment = p_environment
    and attempts = p_attempt
    and status in ('dispatching','enqueued')
  returning * into v_outbox;
  if not found then
    raise exception 'dispatch outbox not enqueueable' using errcode = '55000';
  end if;
  return jsonb_build_object(
    'job_id', v_outbox.job_id,
    'environment', v_outbox.cloudflare_environment,
    'dispatch_status', v_outbox.status
  );
end;
$$;

create or replace function public.recorrido_mark_generation_dispatch_failed(
  p_job_id uuid,
  p_environment text,
  p_attempt integer,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_outbox public.recorrido_generation_dispatch_outbox;
  v_error text;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found then
    raise exception 'cloudflare runtime missing' using errcode = '55000';
  end if;

  v_error := left(coalesce(nullif(btrim(p_error_code), ''), 'dispatch_error'), 80);
  if v_error !~ '^[a-zA-Z0-9_.:-]+$' then v_error := 'dispatch_error'; end if;

  update public.recorrido_generation_dispatch_outbox
  set status = case
        when attempts >= v_runtime.max_dispatch_attempts then 'dead'
        else 'pending'
      end,
      next_attempt_at = now() + make_interval(
        secs => least(900, greatest(5, power(2, least(attempts, 9))::integer))
      ),
      claimed_at = null,
      last_error_code = v_error,
      updated_at = now()
  where job_id = p_job_id
    and cloudflare_environment = p_environment
    and attempts = p_attempt
    and status = 'dispatching'
  returning * into v_outbox;
  if not found then
    select * into v_outbox
    from public.recorrido_generation_dispatch_outbox
    where job_id = p_job_id
      and cloudflare_environment = p_environment
      and attempts = p_attempt
      and status = 'dead';
  end if;
  if not found then
    raise exception 'dispatch outbox not fail-able' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'job_id', v_outbox.job_id,
    'environment', v_outbox.cloudflare_environment,
    'dispatch_status', v_outbox.status,
    'error_code', v_error
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

create or replace function public.recorrido_release_generation_dispatch(
  p_job_id uuid,
  p_reservation_id uuid,
  p_environment text,
  p_worker_id text,
  p_lease_token uuid,
  p_lease_version bigint,
  p_error_code text
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
  v_error text;
  v_result jsonb;
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
  for update;
  if not found then
    raise exception 'generation lease lost' using errcode = '55000';
  end if;

  v_error := left(coalesce(nullif(btrim(p_error_code), ''), 'render_failed'), 80);
  if v_error !~ '^[a-zA-Z0-9_.:-]+$' then v_error := 'render_failed'; end if;
  v_result := public.recorrido_release_generation(p_reservation_id, v_error);
  update public.recorrido_generation_jobs
  set last_error_code = v_error,
      lease_expires_at = null
  where id = p_job_id;
  return v_result || jsonb_build_object(
    'job_id', p_job_id,
    'environment', p_environment,
    'error_code', v_error
  );
end;
$$;

revoke all on function public.recorrido_mark_generation_dispatched(uuid,text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_mark_generation_dispatch_failed(uuid,text,integer,text) from public, anon, authenticated;
revoke all on function public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_release_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text) from public, anon, authenticated;

grant execute on function public.recorrido_mark_generation_dispatched(uuid,text,integer) to service_role;
grant execute on function public.recorrido_mark_generation_dispatch_failed(uuid,text,integer,text) to service_role;
grant execute on function public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer) to service_role;
grant execute on function public.recorrido_release_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text) to service_role;
