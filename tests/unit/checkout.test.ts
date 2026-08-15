import { describe, expect, it } from 'vitest';
import { checkoutRequestSchema, isStripeCheckoutUrl, normalizeCheckoutInput } from '@/lib/checkout/validation';
import { canonicalProductCode, checkoutSessionMode, purchaseType } from '@/lib/checkout/catalog';

describe('checkout boundary', () => {
  it('accepts only internal catalog codes and required customer fields', () => {
    const result = checkoutRequestSchema.safeParse({
      plan: 'pro_monthly', locale: 'es', name: ' Ana ', email: 'ANA@example.com ',
      countryCode: '+57', whatsapp: '300 123 4567', country: 'CO', office: '',
    });
    expect(result.success).toBe(true);
    expect(checkoutRequestSchema.safeParse({ plan: 'price_123', locale: 'es' }).success).toBe(false);
  });

  it('normalizes customer-controlled text without accepting extra fields', () => {
    expect(normalizeCheckoutInput({
      plan: 'single', locale: 'pt', name: '  Bia  Lima ', email: ' BIA@EXAMPLE.COM ',
      countryCode: '+55', whatsapp: '(11) 99999-9999', country: 'br', office: '  Casa  Sul ',
    })).toMatchObject({ name: 'Bia Lima', email: 'bia@example.com', whatsapp: '11999999999', country: 'BR' });
  });

  it('accepts redirects only from the exact Stripe Checkout host', () => {
    expect(isStripeCheckoutUrl('https://checkout.stripe.com/c/pay/cs_test_123')).toBe(true);
    expect(isStripeCheckoutUrl('http://checkout.stripe.com/x')).toBe(false);
    expect(isStripeCheckoutUrl('https://checkout.stripe.com.evil.test/x')).toBe(false);
    expect(isStripeCheckoutUrl('https://stripe.com/x')).toBe(false);
  });

  it('maps the five public plans to canonical billing products and Stripe semantics', () => {
    expect(canonicalProductCode('single')).toBe('single_listing_once_usd_22');
    expect(canonicalProductCode('pro_monthly')).toBe('pro_monthly_usd_32');
    expect(canonicalProductCode('pro_annual')).toBe('pro_annual_usd_320');
    expect(canonicalProductCode('agency_monthly')).toBe('agency_monthly_usd_79');
    expect(canonicalProductCode('agency_annual')).toBe('agency_annual_usd_790');
    expect(checkoutSessionMode('single')).toBe('payment');
    expect(checkoutSessionMode('agency_monthly')).toBe('subscription');
    expect(purchaseType('single')).toBe('single_listing');
    expect(purchaseType('pro_monthly')).toBe('subscription');
  });
});
