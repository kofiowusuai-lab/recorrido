// deno-lint-ignore-file require-await
import { createWebhookHandler } from "./webhook.ts";

function equal(a: unknown, b: unknown): void {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
const event = (type = "checkout.session.completed") => ({
  id: "evt_valid_123",
  type,
  livemode: false,
  api_version: "2025-06-30.basil",
  created: 1_800_000_000,
  data: {
    object: {
      id: type.startsWith("customer.subscription")
        ? "sub_123"
        : type.startsWith("invoice.")
        ? "in_123"
        : type === "charge.refunded"
        ? "ch_123"
        : type === "charge.dispute.created" || type === "charge.dispute.closed"
        ? "dp_123"
        : "cs_123",
    },
  },
});

async function signed(raw: string): Promise<string> {
  const timestamp = 1_800_000_000;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("whsec_test"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(`${timestamp}.${raw}`),
    ),
  );
  return `t=${timestamp},v1=${
    [...bytes].map((x) => x.toString(16).padStart(2, "0")).join("")
  }`;
}

async function req(
  value: unknown,
  raw = JSON.stringify(value),
  signature?: string,
): Promise<Request> {
  return new Request("https://edge.test/webhook", {
    method: "POST",
    headers: {
      "stripe-signature": signature ?? await signed(raw),
      "content-type": "application/json",
    },
    body: raw,
  });
}

function setup(overrides: Record<string, unknown> = {}) {
  const calls: Array<[string, unknown]> = [];
  const deps = {
    webhookSecret: "whsec_test",
    expectedLivemode: false,
    expectedApiVersion: "2025-06-30.basil",
    nowSeconds: () => 1_800_000_000,
    ownerE164: "+573001234567",
    claimEvent: async (args: unknown) => {
      calls.push(["claim", args]);
      return {
        id: "11111111-1111-4111-8111-111111111111",
        claimed: true,
        processing_status: "processing",
        claim_token: "22222222-2222-4222-8222-222222222222",
        processing_attempts: 1,
      };
    },
    applyEvent: async (route: string, ownership: unknown) => {
      calls.push(["apply", { route, ownership }]);
      if (route === "recorrido_apply_stripe_failed_payment_event") {
        return {
          review: {
            required: true,
            approvalToken: "route_review_token",
            currentDraftVersion: 1,
            draftId: "33333333-3333-4333-8333-333333333333",
          },
        };
      }
      return {};
    },
    sendReview: async (review: unknown) => {
      calls.push(["review", review]);
    },
    finishEvent: async (args: unknown) => {
      calls.push(["finish", args]);
    },
    ...overrides,
  };
  return { handler: createWebhookHandler(deps), calls };
}

Deno.test("webhook verifies signature before parse or DB and preserves raw bytes", async () => {
  const { handler, calls } = setup();
  const raw =
    '{ "id":"evt_valid_123", "type":"checkout.session.completed", "created":1800000000, "livemode":false, "api_version":"2025-06-30.basil", "data":{"object":{"id":"cs_123"}} }';
  equal((await handler(await req({}, raw))).status, 200);
  equal((calls[0][1] as Record<string, unknown>).payloadRaw, raw);
  const bad = await handler(
    await req({}, "{bad", "t=1800000000,v1=" + "00".repeat(32)),
  );
  equal(bad.status, 400);
  equal(calls.length, 3);
});

Deno.test("webhook rejects method, missing signature, bounds, malformed identity, version and livemode before DB", async () => {
  const cases = [
    new Request("https://edge.test", { method: "GET" }),
    new Request("https://edge.test", { method: "POST", body: "{}" }),
    new Request("https://edge.test", {
      method: "POST",
      headers: { "stripe-signature": "x", "content-length": "2000000" },
      body: "{}",
    }),
    await req({ ...event(), id: "bad" }),
    await req({ ...event(), type: "bad type" }),
    await req({ ...event(), livemode: true }),
    await req({ ...event(), api_version: "2024-01-01" }),
    await req({ ...event(), data: { object: { id: "bad" } } }),
  ];
  for (const candidate of cases) {
    const { handler, calls } = setup();
    const response = await handler(candidate);
    if (response.status < 400) throw new Error("accepted invalid webhook");
    equal(calls, []);
  }
});

Deno.test("webhook routes every SQL-supported event with exact ownership then finishes", async () => {
  const routes: Record<string, string> = {
    "checkout.session.completed": "recorrido_apply_stripe_payment_event",
    "payment_intent.succeeded": "recorrido_apply_stripe_payment_event",
    "customer.subscription.created":
      "recorrido_apply_stripe_subscription_event",
    "customer.subscription.updated":
      "recorrido_apply_stripe_subscription_event",
    "customer.subscription.deleted":
      "recorrido_apply_stripe_subscription_event",
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
  for (const [type, route] of Object.entries(routes)) {
    const { handler, calls } = setup();
    equal((await handler(await req(event(type)))).status, 200);
    equal(calls.find((call) => call[0] === "apply"), ["apply", {
      route,
      ownership: {
        eventId: "11111111-1111-4111-8111-111111111111",
        claimToken: "22222222-2222-4222-8222-222222222222",
        attempt: 1,
      },
    }]);
    equal(
      (calls.find((call) => call[0] === "finish")?.[1] as Record<
        string,
        unknown
      >).succeeded,
      true,
    );
  }
});

Deno.test("processed replay is 200, live duplicate is retryable, and unknown signed event is finished ignored", async () => {
  let state = setup({
    claimEvent: async () => ({
      claimed: false,
      processing_status: "processed",
    }),
  });
  equal((await state.handler(await req(event()))).status, 200);
  equal(state.calls, []);
  state = setup({
    claimEvent: async () => ({
      claimed: false,
      processing_status: "processing",
    }),
  });
  equal((await state.handler(await req(event()))).status, 409);
  state = setup();
  equal((await state.handler(await req(event("product.created")))).status, 200);
  equal(state.calls.map((x) => x[0]), ["claim", "finish"]);
});

Deno.test("side effect failure records sanitized failure and remains retryable; finish failures remain retryable", async () => {
  let state = setup({
    applyEvent: async () => {
      throw new Error("PII alice@example.com");
    },
  });
  let response = await state.handler(await req(event()));
  equal(response.status, 503);
  const finish = state.calls.find((x) => x[0] === "finish")?.[1] as Record<
    string,
    unknown
  >;
  equal(finish.succeeded, false);
  if (JSON.stringify(finish).includes("alice")) throw new Error("PII leaked");
  state = setup({
    applyEvent: async () => ({}),
    finishEvent: async () => {
      throw new Error("finish failed");
    },
  });
  response = await state.handler(await req(event()));
  equal(response.status, 503);
});

Deno.test("failed-payment review token is sent only to configured Kofi before event finish", async () => {
  const { handler, calls } = setup({
    ownerE164: "+573001234567",
    applyEvent: async () => ({
      review: {
        required: true,
        approvalToken: "one_time_review_token",
        currentDraftVersion: 1,
        draftId: "33333333-3333-4333-8333-333333333333",
      },
    }),
  });
  const response = await handler(
    await req(event("payment_intent.payment_failed")),
  );
  equal(response.status, 200);
  equal(calls.map((call) => call[0]), ["claim", "review", "finish"]);
  equal(calls[1][1], {
    to: "+573001234567",
    body:
      "Review failed-payment draft v1\nAPPROVE one_time_review_token\nREJECT one_time_review_token",
  });
});

Deno.test("failed-payment review send failure fails event closed and never finishes success", async () => {
  const { handler, calls } = setup({
    ownerE164: "+573001234567",
    applyEvent: async () => ({
      review: {
        required: true,
        approvalToken: "one_time_review_token",
        currentDraftVersion: 1,
        draftId: "33333333-3333-4333-8333-333333333333",
      },
    }),
    sendReview: async () => {
      throw new Error("ambiguous provider outcome");
    },
  });
  const response = await handler(await req(event("invoice.payment_failed")));
  equal(response.status, 503);
  const finishes = calls.filter((call) => call[0] === "finish");
  equal(finishes.length, 1);
  equal((finishes[0][1] as Record<string, unknown>).succeeded, false);
});

Deno.test("failed-payment retry finishes after the draft was already reviewed", async () => {
  const { handler, calls } = setup({
    ownerE164: "+573****4567",
    applyEvent: async () => ({
      review: {
        required: false,
        draftId: "33333333-3333-4333-8333-333333333333",
      },
    }),
  });
  const response = await handler(
    await req(event("payment_intent.payment_failed")),
  );
  equal(response.status, 200);
  equal(calls.map((call) => call[0]), ["claim", "finish"]);
  equal(
    (calls.find((call) => call[0] === "finish")?.[1] as Record<string, unknown>)
      .succeeded,
    true,
  );
});

Deno.test("non-failed events cannot trigger review sends from malformed apply results", async () => {
  const { handler, calls } = setup({
    ownerE164: "+573001234567",
    applyEvent: async () => ({
      review: {
        required: true,
        approvalToken: "attacker_token",
        currentDraftVersion: 1,
        draftId: "33333333-3333-4333-8333-333333333333",
      },
    }),
  });
  equal(
    (await handler(await req(event("checkout.session.completed")))).status,
    503,
  );
  equal(calls.some((call) => call[0] === "review"), false);
});
