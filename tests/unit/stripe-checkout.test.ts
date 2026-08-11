import { afterEach, describe, expect, it, vi } from 'vitest';
import { createStripeCheckoutSession } from '@/lib/checkout/stripe';

const metadata = {
  account_id: 'account', member_id: 'member', product_code: 'product', purchase_type: 'single_listing',
  internal_price_code: 'product', normalized_whatsapp_phone: '+573001234567', country: 'CO', checkout_request_id: 'request',
};
const base = { priceId: 'price_authority', clientReferenceId: 'request', customerEmail: 'ana@example.com',
  successUrl: 'https://example.com/success', cancelUrl: 'https://example.com/cancel', metadata,
  expiresAt: 1_900_000_000 };

describe('Stripe Checkout request', () => {
  afterEach(() => { vi.unstubAllGlobals(); delete process.env.STRIPE_SECRET_KEY; });

  it('sets exact top-level and payment-intent metadata and creates a customer for one-time checkout', async () => {
    process.env.STRIPE_SECRET_KEY = 'sk_test_value';
    let body = '';
    vi.stubGlobal('fetch', vi.fn(async (_url, init) => {
      body = String(init?.body);
      return new Response(JSON.stringify({ id: 'cs_test_1', url: 'https://checkout.stripe.com/c/pay/cs_test_1', expires_at: 1_900_000_000 }));
    }));
    await createStripeCheckoutSession({ ...base, mode: 'payment', customerId: null });
    const params = new URLSearchParams(body);
    expect(params.get('customer_email')).toBe('ana@example.com');
    expect(params.get('customer_creation')).toBe('always');
    expect(params.get('expires_at')).toBe('1900000000');
    expect(params.get('customer')).toBeNull();
    expect([...params.keys()].filter((key) => key.startsWith('metadata[')).sort()).toEqual(Object.keys(metadata).map((key) => `metadata[${key}]`).sort());
    for (const [key, value] of Object.entries(metadata)) expect(params.get(`payment_intent_data[metadata][${key}]`)).toBe(value);
  });

  it('rejects a reservation expiry that is too close for Stripe Checkout', async () => {
    process.env.STRIPE_SECRET_KEY = 'sk_test_value';
    vi.spyOn(Date, 'now').mockReturnValue(1_899_999_800_000);
    const fetch = vi.fn();
    vi.stubGlobal('fetch', fetch);
    await expect(createStripeCheckoutSession({ ...base, mode: 'payment', customerId: null }))
      .rejects.toThrow('checkout_expiry_too_short');
    expect(fetch).not.toHaveBeenCalled();
    vi.restoreAllMocks();
  });

  it('uses an existing customer for subscriptions and copies metadata to subscription_data', async () => {
    process.env.STRIPE_SECRET_KEY = 'sk_test_value';
    let body = '';
    vi.stubGlobal('fetch', vi.fn(async (_url, init) => {
      body = String(init?.body);
      return new Response(JSON.stringify({ id: 'cs_test_2', url: 'https://checkout.stripe.com/c/pay/cs_test_2', expires_at: 1_900_000_000 }));
    }));
    await createStripeCheckoutSession({ ...base, mode: 'subscription', customerId: 'cus_existing' });
    const params = new URLSearchParams(body);
    expect(params.get('customer')).toBe('cus_existing');
    expect(params.get('customer_email')).toBeNull();
    expect(params.get('customer_creation')).toBeNull();
    for (const [key, value] of Object.entries(metadata)) expect(params.get(`subscription_data[metadata][${key}]`)).toBe(value);
  });
});
