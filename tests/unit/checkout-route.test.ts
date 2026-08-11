import { NextRequest } from 'next/server';
import { afterEach, describe, expect, it } from 'vitest';
import { POST } from '@/app/api/checkout/route';
import { createCheckoutResponse } from '@/lib/checkout/server';

const valid = { plan: 'single', locale: 'es', name: 'Ana Ruiz', email: 'ana@example.com', countryCode: '+57', whatsapp: '3001234567', country: 'CO', office: '' } as const;
const request = (body: unknown) => new NextRequest('https://recorrido.example/api/checkout', { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': `${Math.random()}` }, body: JSON.stringify(body) });
const prepared = {
  id: '00000000-0000-4000-8000-000000000003', accountId: '00000000-0000-4000-8000-000000000001',
  memberId: '00000000-0000-4000-8000-000000000002', productCode: 'single_listing_once_usd_22',
  stripePriceId: 'price_authoritative', mode: 'payment' as const, amountMinor: 2200, currency: 'usd',
  normalizedWhatsappPhone: '+573001234567', country: 'CO', stripeCustomerId: null,
  status: 'pending' as const, checkoutUrl: null, expiresAt: null,
  reservationExpiresAt: '2027-01-15T08:30:00.000Z',
};

describe('checkout route', () => {
  afterEach(() => {
    for (const key of ['STRIPE_SECRET_KEY', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY']) delete process.env[key];
  });

  it('rejects malformed or caller-defined financial data', async () => {
    expect((await POST(request({ ...valid, amount: 1 }))).status).toBe(400);
    expect((await POST(request({ ...valid, plan: 'price_external' }))).status).toBe(400);
  });

  it('creates Checkout from authoritative RPC fields with exact metadata', async () => {
    const calls: unknown[] = [];
    const response = await createCheckoutResponse(valid, 'https://recorrido.example', {
      prepare: async (input) => { calls.push(input); return prepared; },
      createSession: async (input) => { calls.push(input); return { id: 'cs_test_123', url: 'https://checkout.stripe.com/c/pay/cs_test_123', expiresAt: 1_800_000_000 }; },
      finalize: async (input) => { calls.push(input); return { checkoutUrl: 'https://checkout.stripe.com/c/pay/cs_test_123', expiresAt: '2027-01-15T08:00:00.000Z' }; },
    });
    expect(response).toEqual({ status: 200, body: { url: 'https://checkout.stripe.com/c/pay/cs_test_123' } });
    expect(calls[1]).toEqual({
      priceId: 'price_authoritative', mode: 'payment', clientReferenceId: prepared.id,
      customerEmail: valid.email, customerId: null, successUrl: 'https://recorrido.example/es/compra/exito?session_id={CHECKOUT_SESSION_ID}',
      cancelUrl: 'https://recorrido.example/es/compra/cancelada',
      expiresAt: Math.floor(new Date(prepared.reservationExpiresAt).getTime() / 1000),
      metadata: {
        account_id: prepared.accountId, member_id: prepared.memberId, product_code: prepared.productCode,
        purchase_type: 'single_listing', internal_price_code: prepared.productCode,
        normalized_whatsapp_phone: prepared.normalizedWhatsappPhone, country: prepared.country,
        checkout_request_id: prepared.id,
      },
    });
    expect(calls[2]).toMatchObject({ requestId: prepared.id, accountId: prepared.accountId, memberId: prepared.memberId, productCode: prepared.productCode, stripeSessionId: 'cs_test_123' });
  });

  it('reuses the authoritative created URL without calling Stripe or finalize', async () => {
    let called = false;
    const response = await createCheckoutResponse(valid, 'https://recorrido.example', {
      prepare: async () => ({ ...prepared, status: 'created', checkoutUrl: 'https://checkout.stripe.com/c/pay/cs_test_old', expiresAt: '2027-01-15T08:00:00Z' }),
      createSession: async () => { called = true; throw new Error('not called'); },
      finalize: async () => { called = true; throw new Error('not called'); },
    });
    expect(response.body).toEqual({ url: 'https://checkout.stripe.com/c/pay/cs_test_old' });
    expect(called).toBe(false);
  });

  it('fails closed when the RPC financial snapshot does not match the public plan', async () => {
    let created = false;
    const response = await createCheckoutResponse(valid, 'https://recorrido.example', {
      prepare: async () => ({ ...prepared, amountMinor: 1 }),
      createSession: async () => { created = true; throw new Error('not called'); },
      finalize: async () => { throw new Error('not called'); },
    });
    expect(response).toEqual({ status: 503, body: { code: 'checkout_unavailable' } });
    expect(created).toBe(false);
  });
});
