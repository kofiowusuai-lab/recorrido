import { createCheckoutHandler } from "../_shared/recorrido/checkout.ts";
import {
  createStripeClient,
  type StripeFormValue,
} from "../_shared/recorrido/stripe.ts";
import { createSupabaseClient } from "../_shared/recorrido/supabase.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

export function buildHandler(fetcher: typeof fetch = fetch) {
  const supabase = createSupabaseClient({
    baseUrl: env("SUPABASE_URL"),
    serviceRoleKey: env("SUPABASE_ANON_KEY"),
    accessToken: env("RECORRIDO_CHECKOUT_WORKER_JWT"),
    fetch: fetcher,
  });
  const stripe = createStripeClient({
    secretKey: env("STRIPE_SECRET_KEY"),
    stripeVersion: env("STRIPE_API_VERSION"),
    fetch: fetcher,
  });
  return createCheckoutHandler({
    internalSecret: env("RECORRIDO_INTERNAL_API_SECRET"),
    successUrl: env("RECORRIDO_CHECKOUT_SUCCESS_URL"),
    cancelUrl: env("RECORRIDO_CHECKOUT_CANCEL_URL"),
    createRequest: (value) =>
      supabase.rpc("recorrido_create_checkout_request", {
        p_account_id: value.accountId as string,
        p_member_id: value.memberId as string,
        p_idempotency_key: value.idempotencyKey as string,
        p_product_code: value.productCode as string,
        p_request_fingerprint: value.requestFingerprint as string,
        p_request_payload: value.requestPayload as Record<string, string>,
      }),
    createStripeSession: (body, idempotencyKey) =>
      stripe.post(
        "checkout/sessions",
        body as Record<string, StripeFormValue>,
        { idempotencyKey },
      ),
    finalizeRequest: (value) =>
      supabase.rpc("recorrido_finalize_checkout_request", {
        p_request_id: value.requestId as string,
        p_account_id: value.accountId as string,
        p_member_id: value.memberId as string,
        p_product_code: value.productCode as string,
        p_stripe_checkout_session_id: value.stripeSessionId as string,
        p_checkout_url: value.checkoutUrl as string,
        p_expires_at: value.expiresAt as string,
      }),
  });
}

if (import.meta.main) Deno.serve(buildHandler());
