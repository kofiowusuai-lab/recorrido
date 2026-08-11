begin;

insert into public.recorrido_price_catalog (
  product_code, product_kind, plan_code, eligible_plan_code, billing_interval,
  stripe_price_id, amount_usd_minor, credits, team_member_limit,
  adaptive_pricing_enabled, active
)
values (
  'agency_annual_usd_790', 'subscription', 'agency', null, 'year',
  'price_1U3eCzDKzfe4qZvAUPwkWeKl', 79000, 12, 3, true, true
)
on conflict (product_code) do update set
  stripe_price_id = excluded.stripe_price_id,
  amount_usd_minor = excluded.amount_usd_minor,
  credits = excluded.credits,
  team_member_limit = excluded.team_member_limit,
  adaptive_pricing_enabled = excluded.adaptive_pricing_enabled,
  active = excluded.active,
  updated_at = clock_timestamp()
where public.recorrido_price_catalog.product_kind = 'subscription'
  and public.recorrido_price_catalog.plan_code = 'agency'
  and public.recorrido_price_catalog.billing_interval = 'year';

create or replace function public.recorrido_public_plan_product_code(p_plan_code text)
returns text
language sql
immutable
strict
set search_path = pg_catalog, public
as $$
  select case lower(btrim(p_plan_code))
    when 'single' then 'single_listing_once_usd_22'
    when 'pro_monthly' then 'pro_monthly_usd_32'
    when 'pro_annual' then 'pro_annual_usd_320'
    when 'agency_monthly' then 'agency_monthly_usd_79'
    when 'agency_annual' then 'agency_annual_usd_790'
    else null
  end
$$;

revoke all on function public.recorrido_public_plan_product_code(text) from public, anon, authenticated;
grant execute on function public.recorrido_public_plan_product_code(text) to service_role;

-- Rebind the existing public adapter to the forward-compatible symbolic mapper.
create or replace function public.recorrido_prepare_public_checkout(
  p_plan_code text,
  p_locale text,
  p_name text,
  p_email text,
  p_phone_e164 text,
  p_country text,
  p_office text,
  p_success_url text,
  p_cancel_url text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_plan_code text := lower(btrim(coalesce(p_plan_code, '')));
  v_product_code text;
  v_locale text := lower(btrim(coalesce(p_locale, '')));
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '[[:space:]]+', ' ', 'g');
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_phone text := regexp_replace(btrim(coalesce(p_phone_e164, '')), '[^+0-9]', '', 'g');
  v_country text := upper(btrim(coalesce(p_country, '')));
  v_office text := regexp_replace(btrim(coalesce(p_office, '')), '[[:space:]]+', ' ', 'g');
  v_identity public.recorrido_public_checkout_identities;
  v_email_identity public.recorrido_public_checkout_identities;
  v_phone_identity public.recorrido_public_checkout_identities;
  v_account_id uuid;
  v_member_id uuid;
  v_digest text;
  v_request jsonb;
begin
  v_product_code := public.recorrido_public_plan_product_code(v_plan_code);
  if v_product_code is null
    or length(v_name) not between 2 and 160
    or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    or length(v_email) > 160
    or v_phone !~ '^\+[1-9][0-9]{7,14}$'
    or v_country !~ '^[A-Z]{2}$'
    or length(v_office) > 160
    or v_locale not in ('es', 'pt', 'en')
    or p_success_url !~ '^https://[^[:space:]]+$'
    or p_cancel_url !~ '^https://[^[:space:]]+$' then
    raise exception 'invalid public checkout input' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('recorrido-public-email:' || v_email, 0));
  perform pg_advisory_xact_lock(hashtextextended('recorrido-public-phone:' || v_phone, 0));
  perform public.recorrido_cleanup_abandoned_public_checkout(v_email, v_phone);

  select * into v_email_identity from public.recorrido_public_checkout_identities where normalized_email = v_email for update;
  select * into v_phone_identity from public.recorrido_public_checkout_identities where phone_e164 = v_phone for update;
  if v_email_identity.id is not null or v_phone_identity.id is not null then
    if v_email_identity.id is null or v_phone_identity.id is null or v_email_identity.id is distinct from v_phone_identity.id then
      raise exception 'public checkout identity conflict' using errcode = '22000';
    end if;
    v_identity := v_email_identity;
    if v_identity.claimed_at is not null or not (v_identity.expires_at > clock_timestamp()) then
      raise exception 'public checkout identity is established' using errcode = '42501';
    end if;
  else
    if exists (select 1 from public.recorrido_customer_accounts a where lower(btrim(a.billing_email)) = v_email)
      or exists (select 1 from public.recorrido_account_members m where m.phone_e164 = v_phone and m.status in ('invited','active'))
      or exists (select 1 from public.recorrido_whatsapp_identities w where w.phone_e164 = v_phone) then
      raise exception 'public checkout identity is established' using errcode = '42501';
    end if;
    insert into public.recorrido_customer_accounts(display_name, billing_email, home_country)
    values(coalesce(nullif(v_office, ''), v_name), v_email, v_country) returning id into v_account_id;
    insert into public.recorrido_account_members(account_id, full_name, phone_e164, role, status)
    values(v_account_id, v_name, v_phone, 'owner', 'active') returning id into v_member_id;
    insert into public.recorrido_whatsapp_identities(account_id, member_id, phone_e164) values(v_account_id, v_member_id, v_phone);
    insert into public.recorrido_public_checkout_identities(normalized_email, phone_e164, account_id, member_id, full_name, office, country, locale, expires_at)
    values(v_email, v_phone, v_account_id, v_member_id, v_name, v_office, v_country, v_locale, clock_timestamp() + interval '35 minutes')
    returning * into v_identity;
  end if;

  v_digest := encode(digest(concat_ws(e'\n', v_identity.reservation_id::text, v_plan_code, v_locale, v_email, v_phone, p_success_url, p_cancel_url), 'sha256'), 'hex');
  v_request := public.recorrido_create_checkout_request_with_referral(
    v_identity.account_id, v_identity.member_id, 'public:' || v_digest,
    v_product_code, 'sha256:' || v_digest,
    jsonb_build_object('success_url', p_success_url, 'cancel_url', p_cancel_url), 'SKIP');
  return v_request || jsonb_build_object(
    'account_id', v_identity.account_id,
    'member_id', v_identity.member_id,
    'product_code', v_product_code,
    'reservation_id', v_identity.reservation_id,
    'reservation_expires_at', v_identity.expires_at
  );
end;
$$;

revoke all on function public.recorrido_prepare_public_checkout(text,text,text,text,text,text,text,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.recorrido_prepare_public_checkout(text,text,text,text,text,text,text,text,text)
  to service_role;

commit;
