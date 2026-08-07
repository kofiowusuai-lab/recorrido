import { getCatalogItem } from "./catalog.ts";

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SAFE_KEY = /^[A-Za-z0-9._:-]{1,256}$/;
const MAX_BODY = 8_192;

type CheckoutRow = Record<string, unknown>;
export interface CheckoutDependencies {
  internalSecret: string;
  successUrl: string;
  cancelUrl: string;
  createRequest(args: Record<string, unknown>): Promise<CheckoutRow>;
  createStripeSession(
    body: Record<string, unknown>,
    idempotencyKey: string,
  ): Promise<CheckoutRow>;
  finalizeRequest(args: Record<string, unknown>): Promise<CheckoutRow>;
  observeAuthIterations?: (count: number) => void;
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function constantEqual(
  left: string,
  right: string,
  observe?: (count: number) => void,
): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    difference |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  observe?.(length);
  return difference === 0;
}

async function boundedText(request: Request): Promise<string | null> {
  const declared = request.headers.get("content-length");
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_BODY)) {
    return null;
  }
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(merged);
  } catch {
    return null;
  }
}

function validUrl(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password;
  } catch {
    return false;
  }
}

function validStripeCheckoutUrl(value: unknown): value is string {
  if (!validUrl(value)) return false;
  return new URL(value).hostname === "checkout.stripe.com";
}

export function createCheckoutHandler(
  deps: CheckoutDependencies,
): (request: Request) => Promise<Response> {
  if (
    !deps.internalSecret || !validUrl(deps.successUrl) ||
    !validUrl(deps.cancelUrl)
  ) throw new Error("Invalid checkout configuration");
  return async (request) => {
    try {
      if (request.method !== "POST") {
        return json(405, { error: "method_not_allowed" });
      }
      if (request.headers.get("content-type") !== "application/json") {
        return json(415, { error: "unsupported_media_type" });
      }
      const authorization = request.headers.get("authorization") ?? "";
      const token = authorization.startsWith("Bearer ")
        ? authorization.slice(7)
        : "";
      if (
        !constantEqual(token, deps.internalSecret, deps.observeAuthIterations)
      ) return json(401, { error: "unauthorized" });
      const raw = await boundedText(request);
      if (raw === null) return json(413, { error: "invalid_request" });
      let input: Record<string, unknown>;
      try {
        input = JSON.parse(raw);
      } catch {
        return json(400, { error: "invalid_request" });
      }
      if (
        !input || Array.isArray(input) || typeof input !== "object" ||
        JSON.stringify(Object.keys(input).sort()) !==
          JSON.stringify(
            [
              "accountId",
              "idempotencyKey",
              "memberId",
              "productCode",
              "requestFingerprint",
            ].sort(),
          ) ||
        typeof input.accountId !== "string" || !UUID.test(input.accountId) ||
        typeof input.memberId !== "string" || !UUID.test(input.memberId) ||
        typeof input.productCode !== "string" ||
        !getCatalogItem(input.productCode) ||
        typeof input.idempotencyKey !== "string" ||
        !SAFE_KEY.test(input.idempotencyKey) ||
        typeof input.requestFingerprint !== "string" ||
        !SAFE_KEY.test(input.requestFingerprint)
      ) return json(400, { error: "invalid_request" });

      const catalog = getCatalogItem(input.productCode)!;
      const row = await deps.createRequest({
        accountId: input.accountId,
        memberId: input.memberId,
        productCode: input.productCode,
        idempotencyKey: input.idempotencyKey,
        requestFingerprint: input.requestFingerprint,
        requestPayload: {
          success_url: deps.successUrl,
          cancel_url: deps.cancelUrl,
        },
      });
      if (row.status === "created") {
        if (
          !validStripeCheckoutUrl(row.checkout_url) ||
          typeof row.expires_at !== "string"
        ) {
          throw new Error("Invalid checkout replay");
        }
        return json(200, { url: row.checkout_url, expiresAt: row.expires_at });
      }
      const expectedMode = catalog.kind === "subscription"
        ? "subscription"
        : "payment";
      if (
        row.status !== "pending" || typeof row.id !== "string" ||
        !UUID.test(row.id) || typeof row.stripe_price_id !== "string" ||
        !/^price_[A-Za-z0-9_]+$/.test(row.stripe_price_id) ||
        row.mode !== expectedMode || row.amount_minor !== catalog.unitAmount ||
        row.currency !== catalog.currency.toLowerCase() ||
        typeof row.normalized_whatsapp_phone !== "string" ||
        !/^\+[1-9][0-9]{7,14}$/.test(row.normalized_whatsapp_phone) ||
        typeof row.country !== "string" || !/^[A-Z]{2}$/.test(row.country) ||
        !(row.stripe_customer_id === null ||
          (typeof row.stripe_customer_id === "string" &&
            /^cus_[A-Za-z0-9_]+$/.test(row.stripe_customer_id)))
      ) throw new Error("Invalid checkout authority");
      const metadata = {
        account_id: input.accountId,
        member_id: input.memberId,
        product_code: input.productCode,
        purchase_type: expectedMode === "subscription"
          ? "subscription"
          : input.productCode.startsWith("single_listing_")
          ? "single_listing"
          : "extra_credits",
        internal_price_code: input.productCode,
        normalized_whatsapp_phone: row.normalized_whatsapp_phone,
        country: row.country,
        checkout_request_id: row.id,
      };
      const body: Record<string, unknown> = {
        mode: expectedMode,
        success_url: deps.successUrl,
        cancel_url: deps.cancelUrl,
        client_reference_id: row.id,
        line_items: [{ price: row.stripe_price_id, quantity: 1 }],
        metadata,
        adaptive_pricing: { enabled: true },
      };
      if (row.stripe_customer_id) body.customer = row.stripe_customer_id;
      if (expectedMode === "subscription") {
        body.subscription_data = { metadata };
      } else {
        body.payment_intent_data = { metadata };
        if (!row.stripe_customer_id) body.customer_creation = "always";
      }
      const session = await deps.createStripeSession(
        body,
        `recorrido-checkout:${row.id}`,
      );
      if (
        typeof session.id !== "string" ||
        !/^cs_[A-Za-z0-9_]+$/.test(session.id) ||
        !validStripeCheckoutUrl(session.url) ||
        !Number.isSafeInteger(session.expires_at) ||
        (session.expires_at as number) <= Date.now() / 1000
      ) throw new Error("Invalid Stripe session");
      const expiresAt = new Date((session.expires_at as number) * 1000)
        .toISOString();
      const finalized = await deps.finalizeRequest({
        requestId: row.id,
        accountId: input.accountId,
        memberId: input.memberId,
        productCode: input.productCode,
        stripeSessionId: session.id,
        checkoutUrl: session.url,
        expiresAt,
      });
      if (
        finalized.status !== "created" ||
        finalized.checkout_url !== session.url ||
        typeof finalized.expires_at !== "string"
      ) throw new Error("Invalid checkout finalization");
      return json(200, {
        url: finalized.checkout_url,
        expiresAt: finalized.expires_at,
      });
    } catch {
      return json(502, { error: "checkout_unavailable" });
    }
  };
}
