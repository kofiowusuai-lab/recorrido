export type StripeSessionInput = {
  priceId: string;
  mode: 'payment' | 'subscription';
  clientReferenceId: string;
  customerEmail: string;
  customerId: string | null;
  successUrl: string;
  cancelUrl: string;
  expiresAt: number;
  metadata: Record<string, string>;
};

export type StripeSession = { id: string; url: string; expiresAt: number };

export async function createStripeCheckoutSession(input: StripeSessionInput): Promise<StripeSession> {
  const secret = process.env.STRIPE_SECRET_KEY;
  if (!secret?.startsWith('sk_')) throw new Error('checkout_not_configured');
  if (!Number.isSafeInteger(input.expiresAt) || input.expiresAt < Math.ceil(Date.now() / 1000) + 300) {
    throw new Error('checkout_expiry_too_short');
  }
  const body = new URLSearchParams({
    mode: input.mode,
    'line_items[0][price]': input.priceId,
    'line_items[0][quantity]': '1',
    client_reference_id: input.clientReferenceId,
    success_url: input.successUrl,
    cancel_url: input.cancelUrl,
    expires_at: String(input.expiresAt),
    'adaptive_pricing[enabled]': 'true',
  });
  if (input.customerId) body.set('customer', input.customerId);
  else body.set('customer_email', input.customerEmail);
  if (input.mode === 'payment' && !input.customerId) body.set('customer_creation', 'always');
  const nestedMetadata = input.mode === 'subscription' ? 'subscription_data[metadata]' : 'payment_intent_data[metadata]';
  for (const [key, value] of Object.entries(input.metadata)) {
    body.set(`metadata[${key}]`, value);
    body.set(`${nestedMetadata}[${key}]`, value);
  }
  const response = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/x-www-form-urlencoded' },
    body,
    cache: 'no-store',
  });
  if (!response.ok) throw new Error('stripe_checkout_failed');
  const result = await response.json() as { id?: unknown; url?: unknown; expires_at?: unknown };
  if (typeof result.id !== 'string' || typeof result.url !== 'string' || typeof result.expires_at !== 'number') {
    throw new Error('stripe_checkout_invalid');
  }
  return { id: result.id, url: result.url, expiresAt: result.expires_at };
}
