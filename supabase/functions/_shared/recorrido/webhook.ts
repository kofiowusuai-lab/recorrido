import { verifyStripeWebhook } from "./stripe.ts";

const MAX_BODY = 1_048_576;
const EVENT_ID = /^evt_[A-Za-z0-9_]+$/;
const EVENT_TYPE = /^[a-z][a-z0-9_.]{0,127}$/;
const OBJECT_ID = /^[a-z][a-z0-9]*_[A-Za-z0-9_]+$/;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ROUTES: Record<string, string> = {
  "checkout.session.completed": "recorrido_apply_stripe_payment_event",
  "payment_intent.succeeded": "recorrido_apply_stripe_payment_event",
  "customer.subscription.created": "recorrido_apply_stripe_subscription_event",
  "customer.subscription.updated": "recorrido_apply_stripe_subscription_event",
  "customer.subscription.deleted": "recorrido_apply_stripe_subscription_event",
  "invoice.paid": "recorrido_apply_stripe_subscription_payment_event",
  "invoice.payment_succeeded":
    "recorrido_apply_stripe_subscription_payment_event",
  "payment_intent.payment_failed":
    "recorrido_apply_stripe_failed_payment_event",
  "invoice.payment_failed": "recorrido_apply_stripe_failed_payment_event",
  "charge.refunded": "recorrido_apply_stripe_reversal_event",
  "charge.dispute.created": "recorrido_apply_stripe_reversal_event",
  "charge.dispute.closed": "recorrido_apply_stripe_reversal_event",
};

export interface WebhookDependencies {
  webhookSecret: string;
  expectedLivemode: boolean;
  expectedApiVersion: string;
  ownerE164?: string;
  nowSeconds?: () => number;
  claimEvent(args: Record<string, unknown>): Promise<Record<string, unknown>>;
  applyEvent(
    route: string,
    ownership: Record<string, unknown>,
  ): Promise<unknown>;
  sendReview?(review: Readonly<{ to: string; body: string }>): Promise<void>;
  finishEvent(args: Record<string, unknown>): Promise<void>;
}
function response(status: number, error?: string): Response {
  return new Response(error ? JSON.stringify({ error }) : "{}", {
    status,
    headers: { "content-type": "application/json" },
  });
}
async function rawBody(request: Request): Promise<string | null> {
  const length = request.headers.get("content-length");
  if (length && (!/^\d+$/.test(length) || Number(length) > MAX_BODY)) {
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
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.length;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(all);
  } catch {
    return null;
  }
}

export function createWebhookHandler(
  deps: WebhookDependencies,
): (request: Request) => Promise<Response> {
  if (!deps.webhookSecret || !deps.expectedApiVersion) {
    throw new Error("Invalid webhook configuration");
  }
  return async (request) => {
    if (request.method !== "POST") return response(405, "method_not_allowed");
    const signature = request.headers.get("stripe-signature");
    if (!signature) return response(400, "invalid_webhook");
    const raw = await rawBody(request);
    if (raw === null) return response(413, "invalid_webhook");
    let value: unknown;
    try {
      value = await verifyStripeWebhook(raw, signature, deps.webhookSecret, {
        now: deps.nowSeconds?.(),
      });
    } catch {
      return response(400, "invalid_webhook");
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return response(400, "invalid_webhook");
    }
    const event = value as Record<string, unknown>;
    const data = event.data as Record<string, unknown> | undefined;
    const object = data?.object as Record<string, unknown> | undefined;
    if (
      typeof event.id !== "string" || !EVENT_ID.test(event.id) ||
      typeof event.type !== "string" || !EVENT_TYPE.test(event.type) ||
      event.livemode !== deps.expectedLivemode ||
      event.api_version !== deps.expectedApiVersion || !object ||
      !Number.isSafeInteger(event.created) || (event.created as number) <= 0 ||
      typeof object.id !== "string" || !OBJECT_ID.test(object.id)
    ) return response(400, "invalid_webhook");
    let claim: Record<string, unknown>;
    try {
      claim = await deps.claimEvent({
        stripeEventId: event.id,
        eventType: event.type,
        stripeObjectId: object.id,
        livemode: event.livemode,
        apiVersion: event.api_version,
        payload: event,
        payloadRaw: raw,
      });
    } catch {
      return response(503, "webhook_retry");
    }
    if (claim.claimed !== true) {
      return claim.processing_status === "processed"
        ? response(200)
        : response(409, "webhook_in_progress");
    }
    if (
      typeof claim.id !== "string" || !UUID.test(claim.id) ||
      typeof claim.claim_token !== "string" || !UUID.test(claim.claim_token) ||
      !Number.isSafeInteger(claim.processing_attempts) ||
      (claim.processing_attempts as number) <= 0
    ) return response(503, "webhook_retry");
    const ownership = {
      eventId: claim.id,
      claimToken: claim.claim_token,
      attempt: claim.processing_attempts,
    };
    try {
      const route = ROUTES[event.type];
      const applied = route ? await deps.applyEvent(route, ownership) : {};
      const failedPayment = event.type === "payment_intent.payment_failed" ||
        event.type === "invoice.payment_failed";
      const result =
        applied && typeof applied === "object" && !Array.isArray(applied)
          ? applied as Record<string, unknown>
          : null;
      if (failedPayment) {
        const review = result?.review as Record<string, unknown> | undefined;
        if (review?.required === false) {
          if (
            typeof review.draftId !== "string" || !UUID.test(review.draftId)
          ) {
            throw new Error("invalid completed failed-payment review result");
          }
        } else {
          if (
            review?.required !== true ||
            typeof review.approvalToken !== "string" ||
            !/^[A-Za-z0-9_-]{1,256}$/.test(review.approvalToken) ||
            !Number.isSafeInteger(review.currentDraftVersion) ||
            (review.currentDraftVersion as number) <= 0 ||
            typeof review.draftId !== "string" || !UUID.test(review.draftId) ||
            typeof deps.ownerE164 !== "string" ||
            !/^\+[1-9]\d{7,14}$/.test(deps.ownerE164) ||
            !deps.sendReview
          ) throw new Error("invalid failed-payment review result");
          await deps.sendReview({
            to: deps.ownerE164,
            body:
              `Review failed-payment draft v${review.currentDraftVersion}\nAPPROVE ${review.approvalToken}\nREJECT ${review.approvalToken}`,
          });
        }
      } else if (result && "review" in result) {
        throw new Error("unexpected review result");
      }
      await deps.finishEvent({ ...ownership, succeeded: true, error: null });
      return response(200);
    } catch {
      try {
        await deps.finishEvent({
          ...ownership,
          succeeded: false,
          error: "webhook_processing_failed",
        });
      } catch { /* retry */ }
      return response(503, "webhook_retry");
    }
  };
}
