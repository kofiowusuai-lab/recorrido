import { canonicalProductCode, checkoutSessionMode, purchaseType } from '@/lib/checkout/catalog';
import { checkoutRequestSchema, isStripeCheckoutUrl, normalizeCheckoutInput } from '@/lib/checkout/validation';
import { checkoutStore, type PreparedCheckout } from '@/lib/checkout/store';
import { createStripeCheckoutSession, type StripeSessionInput } from '@/lib/checkout/stripe';
import { catalog } from '@/lib/site/catalog';

type Dependencies = {
  prepare(input: ReturnType<typeof normalizeCheckoutInput>, successUrl: string, cancelUrl: string): Promise<PreparedCheckout>;
  createSession(input: StripeSessionInput): Promise<{ id: string; url: string; expiresAt: number }>;
  finalize(input: Parameters<typeof checkoutStore.finalize>[0]): Promise<{ checkoutUrl: string; expiresAt: string }>;
};

const defaultDependencies: Dependencies = {
  prepare: checkoutStore.prepare,
  createSession: createStripeCheckoutSession,
  finalize: checkoutStore.finalize,
};

const paths = {
  es: { success: 'compra/exito', cancel: 'compra/cancelada' },
  pt: { success: 'compra/sucesso', cancel: 'compra/cancelada' },
  en: { success: 'purchase/success', cancel: 'purchase/canceled' },
} as const;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function validAuthority(prepared: PreparedCheckout, plan: keyof typeof catalog) {
  return UUID.test(prepared.id) && UUID.test(prepared.accountId) && UUID.test(prepared.memberId)
    && prepared.productCode === canonicalProductCode(plan)
    && /^price_[A-Za-z0-9_]+$/.test(prepared.stripePriceId)
    && prepared.mode === checkoutSessionMode(plan)
    && prepared.amountMinor === catalog[plan].usdCents && prepared.currency === 'usd'
    && /^\+[1-9][0-9]{7,14}$/.test(prepared.normalizedWhatsappPhone)
    && /^[A-Z]{2}$/.test(prepared.country)
    && (prepared.stripeCustomerId === null || /^cus_[A-Za-z0-9_]+$/.test(prepared.stripeCustomerId));
}

export async function createCheckoutResponse(raw: unknown, origin: string, deps: Dependencies = defaultDependencies) {
  const parsed = checkoutRequestSchema.safeParse(raw);
  if (!parsed.success) return { status: 400, body: { code: 'invalid_request' } } as const;
  const input = normalizeCheckoutInput(parsed.data);
  try {
    const returnPaths = paths[input.locale];
    const successUrl = `${origin}/${input.locale}/${returnPaths.success}?session_id={CHECKOUT_SESSION_ID}`;
    const cancelUrl = `${origin}/${input.locale}/${returnPaths.cancel}`;
    const prepared = await deps.prepare(input, successUrl, cancelUrl);
    if (!validAuthority(prepared, input.plan)) throw new Error('invalid_checkout_authority');
    if (prepared.status === 'created' && prepared.checkoutUrl && isStripeCheckoutUrl(prepared.checkoutUrl)) {
      return { status: 200, body: { url: prepared.checkoutUrl } } as const;
    }
    if (prepared.status !== 'pending') throw new Error('invalid_checkout_authority');
    const reservationExpiresAt = Date.parse(prepared.reservationExpiresAt);
    if (!Number.isFinite(reservationExpiresAt)) throw new Error('invalid_checkout_authority');
    const metadata = {
      account_id: prepared.accountId, member_id: prepared.memberId, product_code: prepared.productCode,
      purchase_type: purchaseType(input.plan), internal_price_code: prepared.productCode,
      normalized_whatsapp_phone: prepared.normalizedWhatsappPhone, country: prepared.country,
      checkout_request_id: prepared.id,
    };
    const session = await deps.createSession({
      priceId: prepared.stripePriceId, mode: prepared.mode, clientReferenceId: prepared.id,
      customerEmail: input.email, customerId: prepared.stripeCustomerId, successUrl, cancelUrl, metadata,
      expiresAt: Math.floor(reservationExpiresAt / 1000),
    });
    if (!isStripeCheckoutUrl(session.url)) throw new Error('invalid_checkout_url');
    const finalized = await deps.finalize({ requestId: prepared.id, accountId: prepared.accountId,
      memberId: prepared.memberId, productCode: prepared.productCode, stripeSessionId: session.id,
      checkoutUrl: session.url, expiresAt: session.expiresAt });
    if (!isStripeCheckoutUrl(finalized.checkoutUrl)) throw new Error('invalid_checkout_finalization');
    return { status: 200, body: { url: finalized.checkoutUrl } } as const;
  } catch {
    return { status: 503, body: { code: 'checkout_unavailable' } } as const;
  }
}
