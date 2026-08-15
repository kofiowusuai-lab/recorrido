-- Cloudflare generation control plane. Supabase remains authoritative.
-- Fail closed by default; cutover explicitly enables one environment.

alter table public.recorrido_generation_jobs
  add column if not exists input_manifest_key text,
  add column if not exists manifest_sha256 text,
  add column if not exists output_object_key text,
  add column if not exists output_sha256 text,
  add column if not exists output_upload_sha256 text,
  add column if not exists queue_delivered_at timestamptz,
  add column if not exists lease_owner text,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists lease_token uuid,
  add column if not exists lease_version bigint not null default 0,
  add column if not exists dispatch_attempt_count integer not null default 0,
  add column if not exists last_error_code text,
  add column if not exists cloudflare_managed boolean not null default false,
  add column if not exists cloudflare_environment text;

alter table public.recorrido_generation_jobs
  drop constraint if exists recorrido_generation_jobs_manifest_sha256_check,
  drop constraint if exists recorrido_generation_jobs_output_sha256_check,
  drop constraint if exists recorrido_generation_jobs_cloudflare_environment_check,
  drop constraint if exists recorrido_generation_jobs_cloudflare_binding_check;
alter table public.recorrido_generation_jobs
  add constraint recorrido_generation_jobs_manifest_sha256_check
    check (manifest_sha256 is null or manifest_sha256 ~ '^[0-9a-f]{64}$'),
  add constraint recorrido_generation_jobs_output_sha256_check
    check (output_sha256 is null or output_sha256 ~ '^[0-9a-f]{64}$'),
  add constraint recorrido_generation_jobs_cloudflare_environment_check
    check (cloudflare_environment is null or cloudflare_environment in ('staging','production')),
  add constraint recorrido_generation_jobs_cloudflare_binding_check
    check (not cloudflare_managed or cloudflare_environment in ('staging','production'));

create or replace function public.recorrido_prevent_manifest_sha256_change()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if old.input_manifest_key is not null
     and new.input_manifest_key is distinct from old.input_manifest_key then
    raise exception 'input_manifest_key is immutable' using errcode = '22000';
  end if;
  if old.manifest_sha256 is not null
     and new.manifest_sha256 is distinct from old.manifest_sha256 then
    raise exception 'manifest_sha256 is immutable' using errcode = '22000';
  end if;
  return new;
end;
$$;

drop trigger if exists recorrido_prevent_manifest_sha256_change
  on public.recorrido_generation_jobs;
create trigger recorrido_prevent_manifest_sha256_change
before update of input_manifest_key, manifest_sha256 on public.recorrido_generation_jobs
for each row execute function public.recorrido_prevent_manifest_sha256_change();

create index if not exists recorrido_generation_jobs_cloudflare_claim_idx
  on public.recorrido_generation_jobs(cloudflare_environment, status, queue_delivered_at, lease_expires_at, created_at)
  where cloudflare_managed;

create table if not exists public.recorrido_cloudflare_generation_runtime (
  singleton boolean primary key default true check (singleton),
  cloudflare_generation_enabled boolean not null default false,
  active_environment text not null default 'off'
    check (active_environment in ('off','staging','production')),
  max_dispatch_attempts integer not null default 10
    check (max_dispatch_attempts between 1 and 50),
  lease_seconds integer not null default 900
    check (lease_seconds between 60 and 3600),
  updated_at timestamptz not null default now(),
  check (cloudflare_generation_enabled = (active_environment <> 'off'))
);
insert into public.recorrido_cloudflare_generation_runtime(singleton)
values (true)
on conflict (singleton) do nothing;

create table if not exists public.recorrido_generation_dispatch_outbox (
  job_id uuid primary key references public.recorrido_generation_jobs(id) on delete restrict,
  account_id uuid not null references public.recorrido_customer_accounts(id) on delete restrict,
  reservation_id uuid not null unique references public.recorrido_generation_reservations(id) on delete restrict,
  cloudflare_environment text not null
    check (cloudflare_environment in ('staging','production')),
  message jsonb not null,
  status text not null default 'pending'
    check (status in ('pending','dispatching','enqueued','delivered','dead')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  claimed_at timestamptz,
  enqueued_at timestamptz,
  delivered_at timestamptz,
  terminalized_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recorrido_generation_dispatch_outbox_account_job_fkey
    foreign key (account_id, job_id)
    references public.recorrido_generation_jobs(account_id, id) on delete restrict
);
create index if not exists recorrido_generation_dispatch_outbox_pending_idx
  on public.recorrido_generation_dispatch_outbox(cloudflare_environment, next_attempt_at, created_at)
  where status in ('pending','dispatching','enqueued','dead');

alter table public.recorrido_cloudflare_generation_runtime enable row level security;
alter table public.recorrido_generation_dispatch_outbox enable row level security;

create or replace function public.recorrido_prepare_generation_dispatch(
  p_account_id uuid,
  p_member_id uuid,
  p_idempotency_key text,
  p_input_manifest_key text,
  p_manifest_sha256 text,
  p_environment text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_reserved jsonb;
  v_job public.recorrido_generation_jobs;
  v_reservation_id uuid;
  v_outbox public.recorrido_generation_dispatch_outbox;
  v_expected_key text;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found
     or not v_runtime.cloudflare_generation_enabled
     or v_runtime.active_environment is distinct from p_environment then
    raise exception 'cloudflare generation disabled for environment' using errcode = '55000';
  end if;
  if p_environment not in ('staging','production') then
    raise exception 'invalid cloudflare environment' using errcode = '22023';
  end if;
  if nullif(btrim(p_idempotency_key), '') is null
     or p_idempotency_key !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  if p_manifest_sha256 is null or p_manifest_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid manifest sha256' using errcode = '22023';
  end if;
  v_expected_key := format('accounts/%s/jobs/%s/manifest.json', p_account_id, p_idempotency_key);
  if p_input_manifest_key is distinct from v_expected_key then
    raise exception 'invalid input manifest key' using errcode = '22023';
  end if;

  v_reserved := public.recorrido_reserve_generation(p_account_id, p_member_id, p_idempotency_key);

  select * into v_job
  from public.recorrido_generation_jobs
  where id = (v_reserved->>'job_id')::uuid
  for update;
  if not found
     or v_job.account_id is distinct from p_account_id
     or v_job.member_id is distinct from p_member_id then
    raise exception 'conflicting generation replay' using errcode = '22000';
  end if;
  if v_job.cloudflare_environment is not null
     and v_job.cloudflare_environment is distinct from p_environment then
    raise exception 'conflicting generation environment replay' using errcode = '22000';
  end if;
  if v_job.input_manifest_key is not null
     and v_job.input_manifest_key is distinct from p_input_manifest_key then
    raise exception 'conflicting input manifest replay' using errcode = '22000';
  end if;
  if v_job.manifest_sha256 is not null
     and v_job.manifest_sha256 is distinct from p_manifest_sha256 then
    raise exception 'conflicting manifest replay' using errcode = '22000';
  end if;

  update public.recorrido_generation_jobs
  set input_manifest_key = coalesce(input_manifest_key, p_input_manifest_key),
      manifest_sha256 = coalesce(manifest_sha256, p_manifest_sha256),
      cloudflare_managed = true,
      cloudflare_environment = coalesce(cloudflare_environment, p_environment)
  where id = v_job.id
  returning * into v_job;

  if not coalesce((v_reserved->>'allowed')::boolean, false) then
    return v_reserved || jsonb_build_object(
      'should_dispatch', false,
      'dispatch_status', null,
      'environment', p_environment
    );
  end if;

  v_reservation_id := (v_reserved->>'reservation_id')::uuid;
  insert into public.recorrido_generation_dispatch_outbox(
    job_id, account_id, reservation_id, cloudflare_environment, message
  ) values (
    v_job.id,
    p_account_id,
    v_reservation_id,
    p_environment,
    jsonb_build_object(
      'version', 1,
      'environment', p_environment,
      'job_id', v_job.id,
      'reservation_id', v_reservation_id,
      'account_id', p_account_id,
      'idempotency_key', p_idempotency_key,
      'input_manifest_key', p_input_manifest_key,
      'manifest_sha256', p_manifest_sha256
    )
  )
  on conflict (job_id) do nothing;

  select * into v_outbox
  from public.recorrido_generation_dispatch_outbox
  where job_id = v_job.id
  for update;
  if v_outbox.account_id is distinct from p_account_id
     or v_outbox.reservation_id is distinct from v_reservation_id
     or v_outbox.cloudflare_environment is distinct from p_environment
     or v_outbox.message->>'environment' is distinct from p_environment
     or v_outbox.message->>'idempotency_key' is distinct from p_idempotency_key
     or v_outbox.message->>'input_manifest_key' is distinct from p_input_manifest_key
     or v_outbox.message->>'manifest_sha256' is distinct from p_manifest_sha256 then
    raise exception 'conflicting dispatch replay' using errcode = '22000';
  end if;

  return v_reserved || jsonb_build_object(
    'should_dispatch', v_outbox.status = 'pending',
    'dispatch_status', v_outbox.status,
    'environment', p_environment,
    'manifest_sha256', p_manifest_sha256
  );
end;
$$;

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

create or replace function public.recorrido_claim_generation_dispatches(
  p_environment text,
  p_limit integer default 20
)
returns table(job_id uuid, message jsonb, attempts integer, dispatch_status text)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_limit integer;
  v_dead_count integer := 0;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found
     or not v_runtime.cloudflare_generation_enabled
     or v_runtime.active_environment is distinct from p_environment then
    return;
  end if;
  v_limit := least(greatest(coalesce(p_limit, 20), 1), 100);

  -- An enqueued row is ambiguous after the Queue acknowledgement window. It is
  -- never automatically sent again. Exhausted pending/dispatching rows also wait
  -- in dead until explicit atomic terminalization releases their reservation.
  with terminal_candidates as (
    select o.job_id
    from public.recorrido_generation_dispatch_outbox o
    where o.cloudflare_environment = p_environment
      and o.terminalized_at is null
      and (
        (
          o.status = 'enqueued'
          and exists (
            select 1
            from public.recorrido_generation_jobs j
            where j.id = o.job_id
              and j.cloudflare_environment = p_environment
              and j.queue_delivered_at is null
          )
          and o.enqueued_at < now() - interval '5 minutes'
        )
        or (
          o.status in ('pending','dispatching')
          and o.attempts >= v_runtime.max_dispatch_attempts
          and (o.status = 'pending' or o.claimed_at < now() - interval '5 minutes')
        )
      )
    order by o.updated_at, o.created_at
    for update skip locked
    limit v_limit
  )
  update public.recorrido_generation_dispatch_outbox o
  set status = 'dead',
      claimed_at = null,
      last_error_code = case
        when o.status = 'enqueued' then 'stale_enqueued'
        else 'dispatch_attempts_exhausted'
      end,
      updated_at = now()
  from terminal_candidates c
  where o.job_id = c.job_id;

  return query
  select o.job_id, o.message, o.attempts, o.status as dispatch_status
  from public.recorrido_generation_dispatch_outbox o
  where o.cloudflare_environment = p_environment
    and o.status = 'dead'
    and o.terminalized_at is null
  order by o.updated_at, o.created_at
  limit v_limit;
  get diagnostics v_dead_count = row_count;

  if v_dead_count >= v_limit then
    return;
  end if;

  return query
  with candidates as (
    select o.job_id
    from public.recorrido_generation_dispatch_outbox o
    where o.cloudflare_environment = p_environment
      and o.attempts < v_runtime.max_dispatch_attempts
      and (
        (o.status = 'pending' and o.next_attempt_at <= now())
        or (o.status = 'dispatching' and o.claimed_at < now() - interval '5 minutes')
      )
    order by o.next_attempt_at, o.created_at
    for update skip locked
    limit (v_limit - v_dead_count)
  ), claimed as (
    update public.recorrido_generation_dispatch_outbox o
    set status = 'dispatching',
        attempts = o.attempts + 1,
        claimed_at = now(),
        enqueued_at = null,
        updated_at = now()
    from candidates c
    where o.job_id = c.job_id
    returning o.job_id, o.message, o.attempts, o.status
  )
  select c.job_id, c.message, c.attempts, c.status as dispatch_status
  from claimed c;
end;
$$;

create or replace function public.recorrido_mark_generation_queue_delivered(
  p_job_id uuid,
  p_reservation_id uuid,
  p_account_id uuid,
  p_environment text,
  p_idempotency_key text,
  p_input_manifest_key text,
  p_manifest_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_job public.recorrido_generation_jobs;
  v_outbox public.recorrido_generation_dispatch_outbox;
begin
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found then
    raise exception 'cloudflare runtime missing' using errcode = '55000';
  end if;

  -- Job before outbox matches terminalization and avoids a job/outbox inversion.
  select * into v_job
  from public.recorrido_generation_jobs
  where id = p_job_id
    and account_id = p_account_id
    and cloudflare_managed
    and cloudflare_environment = p_environment
    and idempotency_key = p_idempotency_key
    and input_manifest_key = p_input_manifest_key
    and manifest_sha256 = p_manifest_sha256
    and status in ('queued','running')
  for update;
  if not found then
    raise exception 'generation job not queue-deliverable' using errcode = '55000';
  end if;

  select * into v_outbox
  from public.recorrido_generation_dispatch_outbox
  where job_id = p_job_id
    and account_id = p_account_id
    and reservation_id = p_reservation_id
    and cloudflare_environment = p_environment
    and message->>'idempotency_key' = p_idempotency_key
    and message->>'input_manifest_key' = p_input_manifest_key
    and message->>'manifest_sha256' = p_manifest_sha256
  for update;
  if not found or v_outbox.status not in ('enqueued','delivered') then
    raise exception 'dispatch outbox not deliverable' using errcode = '55000';
  end if;

  update public.recorrido_generation_jobs
  set queue_delivered_at = coalesce(queue_delivered_at, now()),
      dispatch_attempt_count = dispatch_attempt_count
        + case when queue_delivered_at is null then 1 else 0 end,
      last_error_code = null
  where id = p_job_id
  returning * into v_job;

  update public.recorrido_generation_dispatch_outbox
  set status = 'delivered',
      delivered_at = coalesce(delivered_at, now()),
      claimed_at = null,
      last_error_code = null,
      updated_at = now()
  where job_id = p_job_id
  returning * into v_outbox;

  return jsonb_build_object(
    'job_id', v_job.id,
    'environment', v_job.cloudflare_environment,
    'dispatch_status', v_outbox.status
  );
end;
$$;

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

create or replace function public.recorrido_heartbeat_generation_job(
  p_job_id uuid,
  p_environment text,
  p_worker_id text,
  p_lease_token uuid,
  p_lease_version bigint,
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
  v_lease_seconds integer;
begin
  if p_worker_id !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then
    raise exception 'invalid worker id' using errcode = '22023';
  end if;
  select * into v_runtime
  from public.recorrido_cloudflare_generation_runtime
  where singleton
  for share;
  if not found or p_environment not in ('staging','production') then
    raise exception 'invalid cloudflare environment' using errcode = '22023';
  end if;
  v_lease_seconds := least(
    greatest(coalesce(p_lease_seconds, v_runtime.lease_seconds), 60),
    3600
  );

  update public.recorrido_generation_jobs
  set lease_expires_at = now() + make_interval(secs => v_lease_seconds)
  where id = p_job_id
    and cloudflare_managed
    and cloudflare_environment = p_environment
    and status = 'running'
    and lease_owner = p_worker_id
    and lease_token = p_lease_token
    and lease_version = p_lease_version
    and lease_expires_at >= now()
  returning * into v_job;
  if not found then
    raise exception 'generation lease lost' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'job_id', v_job.id,
    'environment', v_job.cloudflare_environment,
    'status', v_job.status,
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

create or replace function public.recorrido_terminalize_generation_dispatch(
  p_job_id uuid,
  p_reservation_id uuid,
  p_account_id uuid,
  p_environment text,
  p_idempotency_key text,
  p_input_manifest_key text,
  p_manifest_sha256 text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_runtime public.recorrido_cloudflare_generation_runtime;
  v_hint public.recorrido_generation_dispatch_outbox;
  v_outbox public.recorrido_generation_dispatch_outbox;
  v_reservation public.recorrido_generation_reservations;
  v_job public.recorrido_generation_jobs;
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
  v_error := left(coalesce(nullif(btrim(p_error_code), ''), 'dispatch_terminal'), 80);
  if v_error !~ '^[a-zA-Z0-9_.:-]+$' then v_error := 'dispatch_terminal'; end if;

  -- Read identity without locking. The durable lock order remains the legacy
  -- settlement order, and the outbox is locked only after the job.
  select * into v_hint
  from public.recorrido_generation_dispatch_outbox
  where job_id = p_job_id
    and reservation_id = p_reservation_id
    and account_id = p_account_id
    and cloudflare_environment = p_environment
    and message->>'idempotency_key' = p_idempotency_key
    and message->>'input_manifest_key' = p_input_manifest_key
    and message->>'manifest_sha256' = p_manifest_sha256;
  if not found then
    raise exception 'dispatch outbox not found' using errcode = 'P0002';
  end if;

  select * into v_reservation
  from public.recorrido_generation_reservations
  where id = v_hint.reservation_id
    and job_id = v_hint.job_id
    and account_id = v_hint.account_id
  for update;
  if not found then
    raise exception 'reservation mismatch' using errcode = '22000';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_reservation.account_id::text, 0)
  );
  select * into v_job
  from public.recorrido_generation_jobs
  where id = v_reservation.job_id
    and account_id = v_reservation.account_id
    and cloudflare_environment = p_environment
    and idempotency_key = p_idempotency_key
    and input_manifest_key = p_input_manifest_key
    and manifest_sha256 = p_manifest_sha256
  for update;
  if not found or not v_job.cloudflare_managed then
    raise exception 'generation job not found' using errcode = 'P0002';
  end if;
  select * into v_outbox
  from public.recorrido_generation_dispatch_outbox
  where job_id = p_job_id
    and reservation_id = v_reservation.id
    and cloudflare_environment = p_environment
  for update;
  if not found then
    raise exception 'dispatch outbox changed' using errcode = '22000';
  end if;
  if v_outbox.status = 'delivered' then
    raise exception 'delivered dispatch cannot be terminalized' using errcode = '55000';
  end if;
  if v_reservation.status = 'consumed' then
    raise exception 'consumed reservation cannot be terminalized' using errcode = '55000';
  end if;

  update public.recorrido_generation_dispatch_outbox
  set status = 'dead',
      claimed_at = null,
      last_error_code = v_error,
      updated_at = now()
  where job_id = p_job_id
  returning * into v_outbox;

  if v_outbox.terminalized_at is null and v_reservation.status = 'reserved' then
    v_result := public.recorrido_release_generation(v_reservation.id, v_error);
  elsif v_reservation.status = 'released' then
    v_result := jsonb_build_object('reservation_id', v_reservation.id, 'status', 'released');
  else
    raise exception 'reservation is not terminalizable' using errcode = '55000';
  end if;

  update public.recorrido_generation_dispatch_outbox
  set terminalized_at = coalesce(terminalized_at, now()),
      updated_at = now()
  where job_id = p_job_id
  returning * into v_outbox;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'job_id', p_job_id,
    'environment', p_environment,
    'dispatch_status', v_outbox.status,
    'terminalized_at', v_outbox.terminalized_at,
    'error_code', v_error
  );
end;
$$;

revoke all on table public.recorrido_cloudflare_generation_runtime from public, anon, authenticated;
revoke all on table public.recorrido_generation_dispatch_outbox from public, anon, authenticated;
grant select, insert, update on table public.recorrido_generation_dispatch_outbox to service_role;
grant select, update on table public.recorrido_cloudflare_generation_runtime to service_role;

revoke all on function public.recorrido_prevent_manifest_sha256_change() from public, anon, authenticated;
revoke all on function public.recorrido_prepare_generation_dispatch(uuid,uuid,text,text,text,text) from public, anon, authenticated;
revoke all on function public.recorrido_mark_generation_dispatched(uuid,text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_mark_generation_dispatch_failed(uuid,text,integer,text) from public, anon, authenticated;
revoke all on function public.recorrido_claim_generation_dispatches(text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_mark_generation_queue_delivered(uuid,uuid,uuid,text,text,text,text) from public, anon, authenticated;
revoke all on function public.recorrido_claim_generation_job(text,text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_heartbeat_generation_job(uuid,text,text,uuid,bigint,integer) from public, anon, authenticated;
revoke all on function public.recorrido_assert_generation_output_lease(uuid,uuid,text,text,uuid,bigint,text,text) from public, anon, authenticated;
revoke all on function public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer) from public, anon, authenticated;
revoke all on function public.recorrido_release_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.recorrido_terminalize_generation_dispatch(uuid,uuid,uuid,text,text,text,text,text) from public, anon, authenticated;

grant execute on function public.recorrido_prepare_generation_dispatch(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.recorrido_mark_generation_dispatched(uuid,text,integer) to service_role;
grant execute on function public.recorrido_mark_generation_dispatch_failed(uuid,text,integer,text) to service_role;
grant execute on function public.recorrido_claim_generation_dispatches(text,integer) to service_role;
grant execute on function public.recorrido_mark_generation_queue_delivered(uuid,uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.recorrido_claim_generation_job(text,text,integer) to service_role;
grant execute on function public.recorrido_heartbeat_generation_job(uuid,text,text,uuid,bigint,integer) to service_role;
grant execute on function public.recorrido_assert_generation_output_lease(uuid,uuid,text,text,uuid,bigint,text,text) to service_role;
grant execute on function public.recorrido_complete_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text,text,integer) to service_role;
grant execute on function public.recorrido_release_generation_dispatch(uuid,uuid,text,text,uuid,bigint,text) to service_role;
grant execute on function public.recorrido_terminalize_generation_dispatch(uuid,uuid,uuid,text,text,text,text,text) to service_role;
