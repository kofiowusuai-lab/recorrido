import type { CheckoutInput } from '@/lib/checkout/validation';

export type PreparedCheckout = {
  id: string;
  accountId: string;
  memberId: string;
  productCode: string;
  stripePriceId: string;
  mode: 'payment' | 'subscription';
  amountMinor: number;
  currency: string;
  normalizedWhatsappPhone: string;
  country: string;
  stripeCustomerId: string | null;
  status: 'pending' | 'created';
  checkoutUrl: string | null;
  expiresAt: string | null;
  reservationExpiresAt: string;
};

export type FinalizeCheckoutInput = {
  requestId: string;
  accountId: string;
  memberId: string;
  productCode: string;
  stripeSessionId: string;
  checkoutUrl: string;
  expiresAt: number;
};

function configuration() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url?.startsWith('https://') || !key) throw new Error('checkout_not_configured');
  return { url: url.replace(/\/$/, ''), key };
}

async function rpc<T>(name: string, body: unknown): Promise<T> {
  const { url, key } = configuration();
  const response = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
    cache: 'no-store',
  });
  if (!response.ok) throw new Error('checkout_store_failed');
  return response.json() as Promise<T>;
}

type PreparedRow = {
  id: string; account_id: string; member_id: string; product_code: string; stripe_price_id: string;
  mode: 'payment' | 'subscription'; amount_minor: number; currency: string; normalized_whatsapp_phone: string;
  country: string; stripe_customer_id: string | null; status: 'pending' | 'created'; checkout_url: string | null;
  expires_at: string | null;
  reservation_expires_at: string;
};

export const checkoutStore = {
  async prepare(input: CheckoutInput, successUrl: string, cancelUrl: string): Promise<PreparedCheckout> {
    const row = await rpc<PreparedRow>('recorrido_prepare_public_checkout', {
      p_plan_code: input.plan, p_locale: input.locale, p_name: input.name, p_email: input.email,
      p_phone_e164: `${input.countryCode}${input.whatsapp}`, p_country: input.country, p_office: input.office,
      p_success_url: successUrl, p_cancel_url: cancelUrl,
    });
    return {
      id: row.id, accountId: row.account_id, memberId: row.member_id, productCode: row.product_code,
      stripePriceId: row.stripe_price_id, mode: row.mode, amountMinor: row.amount_minor, currency: row.currency,
      normalizedWhatsappPhone: row.normalized_whatsapp_phone, country: row.country,
      stripeCustomerId: row.stripe_customer_id, status: row.status, checkoutUrl: row.checkout_url,
      expiresAt: row.expires_at,
      reservationExpiresAt: row.reservation_expires_at,
    };
  },
  async finalize(input: FinalizeCheckoutInput) {
    const row = await rpc<{ checkout_url: string; expires_at: string }>('recorrido_finalize_public_checkout', {
      p_request_id: input.requestId, p_account_id: input.accountId, p_member_id: input.memberId,
      p_product_code: input.productCode, p_stripe_checkout_session_id: input.stripeSessionId,
      p_checkout_url: input.checkoutUrl, p_expires_at: new Date(input.expiresAt * 1000).toISOString(),
    });
    return { checkoutUrl: row.checkout_url, expiresAt: row.expires_at };
  },
};
