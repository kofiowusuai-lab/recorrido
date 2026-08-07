// deno-lint-ignore-file require-await
import { createCheckoutHandler } from "./checkout.ts";

const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const MEMBER = "22222222-2222-4222-8222-222222222222";
const REQUEST = "33333333-3333-4333-8333-333333333333";
const TEST_SECRET = "x".repeat(19);

function equal(actual: unknown, expected: unknown): void {
  const stable = (value: unknown): unknown =>
    Array.isArray(value)
      ? value.map(stable)
      : value && typeof value === "object"
      ? Object.fromEntries(
        Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map((
          [key, child],
        ) => [key, stable(child)]),
      )
      : value;
  if (JSON.stringify(stable(actual)) !== JSON.stringify(stable(expected))) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

function setup(overrides: Record<string, unknown> = {}) {
  const calls: Array<[string, unknown]> = [];
  const deps = {
    internalSecret: TEST_SECRET,
    successUrl: "https://app.recorrido.test/billing/success",
    cancelUrl: "https://app.recorrido.test/billing/cancel",
    createRequest: async (args: unknown) => {
      calls.push(["create", args]);
      return {
        id: REQUEST,
        status: "pending",
        stripe_price_id: "price_authoritative",
        mode: "payment",
        amount_minor: 2200,
        currency: "usd",
        stripe_customer_id: null,
        normalized_whatsapp_phone: "+573001234567",
        country: "CO",
      };
    },
    createStripeSession: async (body: unknown, idempotencyKey: string) => {
      calls.push(["stripe", { body, idempotencyKey }]);
      return {
        id: "cs_test_123",
        url: "https://checkout.stripe.com/c/pay/test",
        expires_at: 1_800_000_000,
      };
    },
    finalizeRequest: async (args: unknown) => {
      calls.push(["finalize", args]);
      return {
        status: "created",
        checkout_url: "https://checkout.stripe.com/c/pay/test",
        expires_at: "2027-01-15T08:00:00.000Z",
      };
    },
    ...overrides,
  };
  return { handler: createCheckoutHandler(deps), calls };
}

function request(body: unknown, init: RequestInit = {}): Request {
  return new Request("https://edge.test/checkout", {
    method: "POST",
    headers: {
      authorization: `Bearer ${TEST_SECRET}`,
      "content-type": "application/json",
      ...init.headers,
    },
    body: JSON.stringify(body),
    ...init,
  });
}

const valid = {
  accountId: ACCOUNT,
  memberId: MEMBER,
  productCode: "single_listing_once_usd_22",
  idempotencyKey: "checkout-key_1",
  requestFingerprint: "sha256:abc_123",
};

Deno.test("checkout rejects non-POST, non-exact JSON, bad bearer, oversized and non-exact bodies", async () => {
  for (
    const req of [
      new Request("https://edge.test", { method: "GET" }),
      request(valid, {
        headers: {
          "content-type": "application/json; charset=utf-8",
          authorization: `Bearer ${TEST_SECRET}`,
        },
      }),
      request(valid, {
        headers: {
          authorization: "Bearer wrong",
          "content-type": "application/json",
        },
      }),
      request({ ...valid, extra: "forbidden" }),
      request({ ...valid, accountId: "not-uuid" }),
      request({ ...valid, productCode: "client_price" }),
      request({ ...valid, idempotencyKey: "unsafe key" }),
      request({ ...valid, requestFingerprint: "x".repeat(257) }),
      new Request("https://edge.test", {
        method: "POST",
        headers: {
          authorization: `Bearer ${TEST_SECRET}`,
          "content-type": "application/json",
          "content-length": "9000",
        },
        body: "{}",
      }),
    ]
  ) {
    const { handler, calls } = setup();
    const response = await handler(req);
    if (response.status < 400 || response.status >= 500) {
      throw new Error(`unexpected ${response.status}`);
    }
    equal(calls, []);
    const payload = await response.json();
    equal(Object.keys(payload), ["error"]);
  }
});

Deno.test("checkout bearer comparison inspects equal work for equal and unequal lengths", async () => {
  let comparisons: number[] = [];
  for (const token of ["x", "y".repeat(19), TEST_SECRET]) {
    comparisons = [];
    const { handler } = setup({
      observeAuthIterations: (count: number) => comparisons.push(count),
    });
    await handler(
      request(valid, {
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
      }),
    );
    equal(comparisons, [19]);
  }
});

Deno.test("created replay returns stored URL and expiry without Stripe", async () => {
  const { handler, calls } = setup({
    createRequest: async () => ({
      id: REQUEST,
      status: "created",
      checkout_url: "https://checkout.stripe.com/replay",
      expires_at: "2027-01-15T08:00:00Z",
      stripe_price_id: "price_authoritative",
      mode: "payment",
      amount_minor: 2200,
      currency: "usd",
      stripe_customer_id: null,
    }),
  });
  const response = await handler(request(valid));
  equal(response.status, 200);
  equal(await response.json(), {
    url: "https://checkout.stripe.com/replay",
    expiresAt: "2027-01-15T08:00:00Z",
  });
  equal(calls, []);
});

Deno.test("checkout rejects replay and new-session URLs outside checkout.stripe.com", async () => {
  for (
    const checkoutUrl of [
      "https://stripe.com.example.test/replay",
      "https://checkout.stripe.com.example.test/replay",
      "https://api.stripe.com/replay",
      "https://evil.test/replay",
    ]
  ) {
    let state = setup({
      createRequest: async () => ({
        id: REQUEST,
        status: "created",
        checkout_url: checkoutUrl,
        expires_at: "2027-01-15T08:00:00Z",
        stripe_price_id: "price_authoritative",
        mode: "payment",
        amount_minor: 2200,
        currency: "usd",
        stripe_customer_id: null,
      }),
    });
    equal((await state.handler(request(valid))).status, 502);

    state = setup({
      createStripeSession: async () => ({
        id: "cs_test_123",
        url: checkoutUrl,
        expires_at: 1_800_000_000,
      }),
    });
    equal((await state.handler(request(valid))).status, 502);
  }
});

Deno.test("pending payment checkout sends only authoritative exact Stripe fields and finalizes", async () => {
  const { handler, calls } = setup();
  const response = await handler(request(valid));
  equal(response.status, 200);
  equal(await response.json(), {
    url: "https://checkout.stripe.com/c/pay/test",
    expiresAt: "2027-01-15T08:00:00.000Z",
  });
  equal(calls[1], ["stripe", {
    idempotencyKey: `recorrido-checkout:${REQUEST}`,
    body: {
      mode: "payment",
      success_url: "https://app.recorrido.test/billing/success",
      cancel_url: "https://app.recorrido.test/billing/cancel",
      client_reference_id: REQUEST,
      line_items: [{ price: "price_authoritative", quantity: 1 }],
      metadata: {
        account_id: ACCOUNT,
        member_id: MEMBER,
        product_code: "single_listing_once_usd_22",
        purchase_type: "single_listing",
        internal_price_code: "single_listing_once_usd_22",
        normalized_whatsapp_phone: "+573001234567",
        country: "CO",
        checkout_request_id: REQUEST,
      },
      payment_intent_data: {
        metadata: {
          account_id: ACCOUNT,
          member_id: MEMBER,
          product_code: "single_listing_once_usd_22",
          purchase_type: "single_listing",
          internal_price_code: "single_listing_once_usd_22",
          normalized_whatsapp_phone: "+573001234567",
          country: "CO",
          checkout_request_id: REQUEST,
        },
      },
      adaptive_pricing: { enabled: true },
      customer_creation: "always",
    },
  }]);
  equal(calls[2][0], "finalize");
});

Deno.test("subscription checkout uses owned customer and subscription metadata without customer creation", async () => {
  const { handler, calls } = setup({
    createRequest: async () => ({
      id: REQUEST,
      status: "pending",
      stripe_price_id: "price_sub",
      mode: "subscription",
      amount_minor: 3200,
      currency: "usd",
      stripe_customer_id: "cus_owned",
      normalized_whatsapp_phone: "+573001234567",
      country: "CO",
    }),
  });
  await handler(request({ ...valid, productCode: "pro_monthly_usd_32" }));
  const stripe = (calls.find(([name]) => name === "stripe")![1] as {
    body: Record<string, unknown>;
  }).body;
  equal(stripe.customer, "cus_owned");
  equal(stripe.subscription_data, {
    metadata: {
      account_id: ACCOUNT,
      member_id: MEMBER,
      product_code: "pro_monthly_usd_32",
      purchase_type: "subscription",
      internal_price_code: "pro_monthly_usd_32",
      normalized_whatsapp_phone: "+573001234567",
      country: "CO",
      checkout_request_id: REQUEST,
    },
  });
  if ("customer_creation" in stripe || "payment_intent_data" in stripe) {
    throw new Error("arbitrary mode fields leaked");
  }
});

Deno.test("checkout rejects malformed RPC/Stripe evidence and sanitizes dependency errors", async () => {
  for (
    const overrides of [
      {
        createRequest: async () => ({
          id: REQUEST,
          status: "pending",
          stripe_price_id: "price_x",
          mode: "payment",
          amount_minor: 999,
          currency: "usd",
          stripe_customer_id: null,
        }),
      },
      {
        createStripeSession: async () => ({
          id: "bad",
          url: "javascript:alert(1)",
          expires_at: 0,
        }),
      },
      {
        createRequest: async () => {
          throw new Error("database PII secret@example.com");
        },
      },
    ]
  ) {
    const { handler } = setup(overrides);
    const response = await handler(request(valid));
    equal(response.status, 502);
    const text = await response.text();
    if (text.includes("secret@example.com")) {
      throw new Error("unsanitized error");
    }
  }
});
