import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const migrationPath = resolve('supabase/migrations/202608120001_recorrido_public_checkout_onboarding.sql');
const sql = () => readFileSync(migrationPath, 'utf8').toLowerCase();

describe('public checkout onboarding migration contract', () => {
  it('adds only the private onboarding identity table and checkout adapter functions', () => {
    const source = sql();
    expect([...source.matchAll(/create table(?: if not exists)? public\.([a-z0-9_]+)/g)].map((match) => match[1])).toEqual(['recorrido_public_checkout_identities']);
    for (const authority of ['recorrido_customer_accounts', 'recorrido_account_members', 'recorrido_whatsapp_identities', 'recorrido_checkout_requests', 'recorrido_stripe_events', 'recorrido_credit_buckets', 'recorrido_credit_ledger']) {
      expect(source).not.toMatch(new RegExp(`create table(?: if not exists)? public\\.${authority}\\b`));
    }
    expect(source).not.toContain('webhook');
  });

  it('marks public reservations explicitly and caps their lifetime at 30 minutes', () => {
    const source = sql();
    expect(source).toContain('reservation_id uuid not null unique');
    expect(source).toContain('expires_at timestamptz not null');
    expect(source).toContain('claimed_at timestamptz');
    expect(source).toMatch(/expires_at\s*<=\s*created_at\s*\+\s*interval\s*'35 minutes'/);
    expect(source).toContain("interval '35 minutes'");
    expect(source).toContain("'reservation_expires_at', v_identity.expires_at");
  });

  it('cleans only expired abandoned public reservations under locks before lookup', () => {
    const source = sql();
    expect(source).toContain('recorrido_cleanup_abandoned_public_checkout');
    expect(source.indexOf('perform public.recorrido_cleanup_abandoned_public_checkout')).toBeLessThan(source.indexOf('select * into v_email_identity'));
    expect(source).toContain('pg_advisory_xact_lock');
    expect(source).toMatch(/claimed_at is null[\s\S]*expires_at <= clock_timestamp\(\)/);
    for (const evidence of [
      'recorrido_payment_records', 'recorrido_stripe_customers', 'recorrido_subscription_entitlements',
      'recorrido_credit_buckets', 'recorrido_credit_ledger', 'recorrido_generation_jobs',
      'recorrido_generation_reservations', 'recorrido_referral_attributions', 'recorrido_referral_rewards',
    ]) expect(source).toContain(`exists (select 1 from public.${evidence}`);
    expect(source).toContain("cr.status in ('pending','failed','expired')");
    expect(source).toContain('cr.stripe_payment_intent_id is null');
    expect(source).toContain('recorrido_checkout_referral_choices');
    expect(source).toContain('delete from public.recorrido_whatsapp_identities');
    expect(source).toContain('delete from public.recorrido_account_members');
    expect(source).toContain('delete from public.recorrido_customer_accounts');
  });

  it('never adopts established identities and only replays an exact unexpired pair', () => {
    const source = sql();
    expect(source).toContain('public checkout identity conflict');
    expect(source).toContain('public checkout identity is established');
    expect(source).toMatch(/normalized_email = v_email[\s\S]*phone_e164 = v_phone/);
    expect(source).toMatch(/v_identity\.expires_at > clock_timestamp\(\)/);
    expect(source).not.toContain('update public.recorrido_customer_accounts');
    expect(source).not.toContain('update public.recorrido_account_members');
  });

  it('delegates checkout creation and finalization to the authoritative RPCs', () => {
    const source = sql();
    expect(source).toContain('recorrido_create_checkout_request_with_referral');
    expect(source).toContain("'skip'");
    expect(source).toContain('recorrido_finalize_checkout_request');
    expect(source).toContain('security definer');
  });

  it('exposes every adapter function only to service_role', () => {
    const source = sql();
    for (const fn of ['recorrido_cleanup_abandoned_public_checkout', 'recorrido_prepare_public_checkout', 'recorrido_finalize_public_checkout']) {
      expect(source).toMatch(new RegExp(`revoke all on function public\\.${fn}\\([\\s\\S]*?from public, anon, authenticated, service_role`));
      expect(source).toMatch(new RegExp(`grant execute on function public\\.${fn}\\([\\s\\S]*?to service_role`));
    }
  });
});
