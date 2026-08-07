import { createStripeClient, verifyStripeWebhook } from "./stripe.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

async function assertRejects(
  operation: () => unknown | Promise<unknown>,
  pattern: RegExp,
  forbidden: string[] = [],
): Promise<void> {
  try {
    await operation();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    assert(pattern.test(message), `Expected ${pattern}, got ${message}`);
    for (const value of forbidden) {
      assert(!message.includes(value), `Error leaked ${value}`);
    }
    return;
  }
  throw new Error("Expected operation to reject");
}

async function signature(
  secret: string,
  timestamp: number | string,
  body: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(`${timestamp}.${body}`),
    ),
  );
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

Deno.test("webhook verifies a real signature over the exact raw body", async () => {
  const body = '{"type":"checkout.session.completed","data":{"ok":true}}';
  const timestamp = 2_000_000_000;
  const digest = await signature("webhook_test_secret", timestamp, body);
  const result = await verifyStripeWebhook(
    body,
    `t=${timestamp},v1=${digest}`,
    "webhook_test_secret",
    { now: timestamp },
  );
  assertEquals(result, {
    type: "checkout.session.completed",
    data: { ok: true },
  });
});

Deno.test("webhook rejects a correctly signed fractional timestamp", async () => {
  const body = '{"ok":true}';
  const timestamp = "2000000000.5";
  const digest = await signature("webhook_test_secret", timestamp, body);
  await assertRejects(
    () =>
      verifyStripeWebhook(
        body,
        `t=${timestamp},v1=${digest}`,
        "webhook_test_secret",
        { now: 2_000_000_000.5 },
      ),
    /timestamp/i,
  );
});

Deno.test("webhook rejects body tampering", async () => {
  const timestamp = 2_000_000_000;
  const digest = await signature(
    "webhook_test_secret",
    timestamp,
    '{"paid":true}',
  );
  await assertRejects(
    () =>
      verifyStripeWebhook(
        '{"paid":false}',
        `t=${timestamp},v1=${digest}`,
        "webhook_test_secret",
        { now: timestamp },
      ),
    /signature/i,
  );
});

Deno.test("webhook accepts any matching v1 signature", async () => {
  const body = '{"ok":true}';
  const timestamp = 2_000_000_000;
  const digest = await signature("webhook_test_secret", timestamp, body);
  const result = await verifyStripeWebhook(
    body,
    `v1=${"00".repeat(32)},t=${timestamp},v1=${digest}`,
    "webhook_test_secret",
    { now: timestamp },
  );
  assertEquals(result, { ok: true });
});

Deno.test("webhook rejects stale and future timestamps outside tolerance", async () => {
  const body = '{"ok":true}';
  for (const timestamp of [1_999_999_699, 2_000_000_301]) {
    const digest = await signature("webhook_test_secret", timestamp, body);
    await assertRejects(
      () =>
        verifyStripeWebhook(
          body,
          `t=${timestamp},v1=${digest}`,
          "webhook_test_secret",
          { now: 2_000_000_000 },
        ),
      /timestamp|tolerance/i,
    );
  }
});

Deno.test("webhook rejects malformed headers, timestamps, missing v1, and invalid hex", async () => {
  const headers = [
    "",
    "broken",
    "t=2000000000",
    `t=0,v1=${"00".repeat(32)}`,
    `t=2000000000.5,v1=${"00".repeat(32)}`,
    `t=2e9,v1=${"00".repeat(32)}`,
    `t=9007199254740992,v1=${"00".repeat(32)}`,
    `t=NaN,v1=${"00".repeat(32)}`,
    "t=2000000000,v1=xyz",
    "t=2000000000,v1=aa",
    `t=2000000000,v1=${"00".repeat(32)},oops`,
  ];
  for (const header of headers) {
    await assertRejects(
      () =>
        verifyStripeWebhook("{}", header, "webhook_test_secret", {
          now: 2_000_000_000,
        }),
      /signature|timestamp|header/i,
    );
  }
});

Deno.test("webhook parses JSON only after verification and rejects invalid JSON", async () => {
  const body = "not-json";
  const timestamp = 2_000_000_000;
  const digest = await signature("webhook_test_secret", timestamp, body);
  await assertRejects(
    () =>
      verifyStripeWebhook(
        body,
        `t=${timestamp},v1=${digest}`,
        "webhook_test_secret",
        { now: timestamp },
      ),
    /json/i,
  );
});

Deno.test("Stripe POST sends exact encoded body and caller operation key", async () => {
  let captured: { input: RequestInfo | URL; init?: RequestInit } | undefined;
  const fetcher: typeof fetch = (input, init) => {
    captured = { input, init };
    return Promise.resolve(new Response('{"id":"result"}', { status: 200 }));
  };
  const client = createStripeClient({
    secretKey: "sk_test_local_only",
    stripeVersion: "2025-02-24.acacia",
    fetch: fetcher,
    baseUrl: "https://stripe.invalid/v1",
  });
  const body = {
    mode: "payment",
    metadata: { order: "order-local", note: "a & b" },
    line_items: [{ quantity: 2, price_data: { currency: "usd" } }],
  };
  await client.post("/checkout/sessions/", body, {
    idempotencyKey: "checkout-order-local-attempt-1",
  });
  assert(captured);
  assertEquals(
    String(captured.input),
    "https://stripe.invalid/v1/checkout/sessions",
  );
  assertEquals(captured.init?.method, "POST");
  assertEquals(
    captured.init?.body,
    "line_items%5B0%5D%5Bprice_data%5D%5Bcurrency%5D=usd&line_items%5B0%5D%5Bquantity%5D=2&metadata%5Bnote%5D=a+%26+b&metadata%5Border%5D=order-local&mode=payment",
  );
  const headers = new Headers(captured.init?.headers);
  assertEquals(
    headers.get("authorization"),
    `Basic ${btoa("sk_test_local_only:")}`,
  );
  assertEquals(
    headers.get("content-type"),
    "application/x-www-form-urlencoded",
  );
  assertEquals(headers.get("stripe-version"), "2025-02-24.acacia");
  assertEquals(
    headers.get("idempotency-key"),
    "checkout-order-local-attempt-1",
  );
});

Deno.test("Stripe POST requires a valid operation-scoped idempotency key before fetch", async () => {
  let fetchCalls = 0;
  const client = createStripeClient({
    secretKey: "sk_test_local_only",
    stripeVersion: "2025-02-24.acacia",
    fetch: () => {
      fetchCalls++;
      return Promise.resolve(new Response("{}", { status: 200 }));
    },
  });
  const invalid = [
    undefined,
    "",
    "   ",
    "contains\ncontrol",
    "é",
    "x".repeat(256),
  ];
  for (const idempotencyKey of invalid) {
    await assertRejects(
      () =>
        client.post("payment_intents", { amount: 1 }, {
          idempotencyKey: idempotencyKey as string,
        }),
      /idempotency/i,
    );
  }
  assertEquals(fetchCalls, 0);
});

Deno.test("Stripe POST preserves distinct operation keys for identical payloads and replay", async () => {
  const keys: (string | null)[] = [];
  const client = createStripeClient({
    secretKey: "sk_test_local_only",
    stripeVersion: "2025-02-24.acacia",
    fetch: (input, init) => {
      const request = new Request(input, init);
      keys.push(request.headers.get("idempotency-key"));
      return Promise.resolve(new Response("{}", { status: 200 }));
    },
  });
  const body = { amount: 1000, currency: "usd" };
  await client.post("/payment_intents/", body, { idempotencyKey: "order-a" });
  await client.post("payment_intents", body, { idempotencyKey: "order-b" });
  await client.post("payment_intents/", body, { idempotencyKey: "order-a" });
  assertEquals(keys, ["order-a", "order-b", "order-a"]);
});

Deno.test("Stripe GET aborts pending fetch when caller signal aborts", async () => {
  const controller = new AbortController();
  let fetchStarted!: () => void;
  const started = new Promise<void>((resolve) => fetchStarted = resolve);
  const fetcher: typeof fetch = (input, init) => {
    const signal = new Request(input, init).signal;
    fetchStarted();
    return new Promise((_resolve, reject) => {
      signal.addEventListener(
        "abort",
        () => reject(signal.reason),
        { once: true },
      );
    });
  };
  const request = createStripeClient({
    secretKey: "sk_test_local_only",
    stripeVersion: "2025-02-24.acacia",
    fetch: fetcher,
  })
    .get("customers/local", { signal: controller.signal });
  await started;
  controller.abort();
  await assertRejects(() => request, /aborted/i);
});

Deno.test("Stripe automatic timeout aborts pending fetch and sanitizes failure", async () => {
  const secret = "sk_test_timeout_must_not_leak";
  let observedAbort!: () => void;
  const aborted = new Promise<void>((resolve) => observedAbort = resolve);
  const client = createStripeClient({
    secretKey: secret,
    stripeVersion: "2025-02-24.acacia",
    timeoutMs: 1,
    fetch: (input, init) => {
      const signal = new Request(input, init).signal;
      return (
        new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => {
            observedAbort();
            reject(signal.reason);
          }, { once: true });
        })
      );
    },
  });
  const request = assertRejects(
    () => client.get("customers/local"),
    /transport request failed/i,
    [secret, btoa(`${secret}:`), "Request timed out"],
  );
  await aborted;
  await request;
});

Deno.test("Stripe failures sanitize HTTP response and credentials", async () => {
  const secret = "sk_test_must_not_leak";
  const sensitive = "card-sensitive-response";
  const client = createStripeClient({
    secretKey: secret,
    stripeVersion: "2025-02-24.acacia",
    fetch: () =>
      Promise.resolve(
        new Response(sensitive, {
          status: 402,
          statusText: "Payment Required",
        }),
      ),
  });
  await assertRejects(
    () =>
      client.post("payment_intents", { amount: 1 }, {
        idempotencyKey: "payment-operation-local",
      }),
    /402/,
    [secret, btoa(`${secret}:`), sensitive],
  );
});

Deno.test("Stripe rejects malformed success JSON", async () => {
  const client = createStripeClient({
    secretKey: "sk_test_local_only",
    stripeVersion: "2025-02-24.acacia",
    fetch: () => Promise.resolve(new Response("not-json", { status: 200 })),
  });
  await assertRejects(() => client.get("customers/local"), /json/i, [
    "not-json",
  ]);
});
