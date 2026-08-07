-- One-time worker-token bootstrap. A following migration drops this function
-- after the signed tokens are installed in Supabase Edge Function secrets.
create or replace function public.recorrido_bootstrap_worker_tokens()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, extensions
as $$
declare
  v_secret text := current_setting('app.settings.jwt_secret', true);
  v_now bigint := extract(epoch from clock_timestamp())::bigint;
  v_result jsonb;
begin
  if coalesce(length(v_secret), 0) < 32 then
    raise exception using errcode='55000', message='legacy JWT signing secret is unavailable';
  end if;

  select jsonb_object_agg(env_name,
    extensions.sign(
      json_build_object(
        'iss','supabase',
        'aud','authenticated',
        'role',role_name,
        'iat',v_now,
        'exp',v_now + 7776000
      ),
      v_secret,
      'HS256'
    ))
  into v_result
  from (values
    ('RECORRIDO_WEBHOOK_WORKER_JWT','recorrido_billing_webhook_worker'),
    ('RECORRIDO_CHECKOUT_WORKER_JWT','recorrido_billing_checkout_worker'),
    ('RECORRIDO_DISPATCHER_WORKER_JWT','recorrido_billing_dispatcher_worker'),
    ('RECORRIDO_APPROVAL_WORKER_JWT','recorrido_billing_approval_worker'),
    ('RECORRIDO_QUOTA_WORKER_JWT','recorrido_billing_quota_worker'),
    ('RECORRIDO_HEALTH_WORKER_JWT','recorrido_billing_health_worker')
  ) as worker(env_name, role_name);

  return v_result;
end;
$$;

revoke all on function public.recorrido_bootstrap_worker_tokens() from public, anon, authenticated;
grant execute on function public.recorrido_bootstrap_worker_tokens() to service_role;
