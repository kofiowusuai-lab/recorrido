import {
  createWhatsAppSender,
  normalizeE164,
  verifyMetaChallenge,
  verifyMetaSignature,
  WhatsAppRejectedError,
} from "./whatsapp.ts";

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

function assertThrows(operation: () => unknown, pattern: RegExp): void {
  try {
    operation();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    assert(pattern.test(message), `Expected ${pattern}, got ${message}`);
    return;
  }
  throw new Error("Expected operation to throw");
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
    for (const secret of forbidden) {
      assert(!message.includes(secret), `Error leaked ${secret}`);
    }
    return;
  }
  throw new Error("Expected operation to reject");
}

async function metaSignature(
  secret: string,
  bytes: Uint8Array,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const exactBytes = Uint8Array.from(bytes);
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, exactBytes),
  );
  return `sha256=${
    [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("")
  }`;
}

Deno.test("Meta signature verifies the exact raw bytes", async () => {
  const raw = new TextEncoder().encode('{"message":"café"}');
  const signature = await metaSignature("app_secret", raw);
  assert(await verifyMetaSignature(raw, signature, "app_secret"));
  assert(
    !(await verifyMetaSignature(
      new TextEncoder().encode('{"message":"cafe"}'),
      signature,
      "app_secret",
    )),
  );
});

Deno.test("Meta signature accepts strict upper or lowercase hex and rejects malformed input", async () => {
  const raw = new Uint8Array([0, 1, 2, 255]);
  const signature = await metaSignature("app_secret", raw);
  assert(
    await verifyMetaSignature(
      raw,
      signature.toUpperCase().replace("SHA256=", "sha256="),
      "app_secret",
    ),
  );
  for (
    const malformed of [
      null,
      "",
      signature.slice(0, -1),
      `sha256= ${signature.slice(7)}`,
      `SHA256=${signature.slice(7)}`,
      `sha256=${"g".repeat(64)}`,
    ]
  ) {
    assert(!(await verifyMetaSignature(raw, malformed, "app_secret")));
  }
});

Deno.test("phone normalization requires explicit calling context only for national numbers", () => {
  assertEquals(normalizeE164(" +57 300 123 4567 "), "+573001234567");
  assertEquals(
    normalizeE164("300 123 4567", { countryCallingCode: "57" }),
    "+573001234567",
  );
  assertEquals(
    normalizeE164("(11) 91234-5678", { countryCallingCode: "+55" }),
    "+5511912345678",
  );
  assertEquals(
    normalizeE164("202 555 0123", { countryCallingCode: "+1" }),
    "+12025550123",
  );
  assertThrows(() => normalizeE164("3001234567"), /context|ambiguous/i);
  for (
    const malformed of [
      "+",
      "+0123",
      "+57abc",
      "00573001234567",
      "+123456",
      "+5730012345678901",
    ]
  ) {
    assertThrows(() => normalizeE164(malformed), /phone|E\.164/i);
  }
});

Deno.test("challenge returns only on exact verify-token match", () => {
  assertEquals(
    verifyMetaChallenge("hub-token", "hub-token", "challenge-value"),
    "challenge-value",
  );
  assertEquals(
    verifyMetaChallenge("hub-token", "Hub-token", "challenge-value"),
    null,
  );
  assertEquals(
    verifyMetaChallenge("hub-token", "hub-token ", "challenge-value"),
    null,
  );
  assertEquals(verifyMetaChallenge("hub-token", null, "challenge-value"), null);
});

Deno.test("challenge fails closed for empty or malformed verify tokens", () => {
  for (const empty of ["", " ", "\t\n"]) {
    assertEquals(
      verifyMetaChallenge(empty, empty, "challenge-value"),
      null,
    );
    assertEquals(
      verifyMetaChallenge("hub-token", empty, "challenge-value"),
      null,
    );
  }
  for (const malformed of [42, true, {}, []]) {
    assertEquals(
      verifyMetaChallenge(
        malformed as unknown as string,
        "hub-token",
        "challenge-value",
      ),
      null,
    );
    assertEquals(
      verifyMetaChallenge(
        "hub-token",
        malformed as unknown as string,
        "challenge-value",
      ),
      null,
    );
  }
});

Deno.test("challenge requires a nonempty bounded runtime string and echoes it unchanged", () => {
  for (const invalid of ["", " ", "\t\n", "x".repeat(1_025)]) {
    assertEquals(
      verifyMetaChallenge(
        "hub-token",
        "hub-token",
        invalid as unknown as string,
      ),
      null,
    );
  }
  for (const invalid of [null, undefined, 42, true, {}, []]) {
    assertEquals(
      verifyMetaChallenge(
        "hub-token",
        "hub-token",
        invalid as unknown as string,
      ),
      null,
    );
  }
  const exactChallenge = "  challenge-value  ";
  assertEquals(
    verifyMetaChallenge("hub-token", "hub-token", exactChallenge),
    exactChallenge,
  );
  const maximumChallenge = "x".repeat(1_024);
  assertEquals(
    verifyMetaChallenge("hub-token", "hub-token", maximumChallenge),
    maximumChallenge,
  );
});

Deno.test("sender emits exact text and template requests", async () => {
  const requests: Request[] = [];
  const fetcher: typeof fetch = (input, init) => {
    requests.push(new Request(input, init));
    return Promise.resolve(
      new Response('{"messages":[{"id":"wamid.1"}]}', { status: 200 }),
    );
  };
  const sender = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123456789",
    accessToken: "token-local",
    fetch: fetcher,
    timeoutMs: 1_000,
  });
  assertEquals(
    await sender.send({ to: "+573001234567", text: "Review ready" }),
    { messageId: "wamid.1" },
  );
  assertEquals(
    await sender.send({
      to: "+573001234567",
      template: {
        name: "review_ready",
        languageCode: "es_CO",
        components: [{
          type: "body",
          parameters: [{ type: "text", text: "Draft 7" }],
        }],
      },
    }),
    { messageId: "wamid.1" },
  );
  assertEquals(
    requests[0].url,
    "https://graph.facebook.com/v23.0/123456789/messages",
  );
  assertEquals(requests[0].headers.get("authorization"), "Bearer token-local");
  assertEquals(await requests[0].json(), {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: "+573001234567",
    type: "text",
    text: { preview_url: false, body: "Review ready" },
  });
  assertEquals(await requests[1].json(), {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: "+573001234567",
    type: "template",
    template: {
      name: "review_ready",
      language: { code: "es_CO" },
      components: [{
        type: "body",
        parameters: [{ type: "text", text: "Draft 7" }],
      }],
    },
  });
});

Deno.test("sender validates configuration and payload", async () => {
  for (
    const config of [
      { graphVersion: "23.0", phoneNumberId: "123", accessToken: "token" },
      {
        graphVersion: "v23.0/path",
        phoneNumberId: "123",
        accessToken: "token",
      },
      { graphVersion: "v23.0", phoneNumberId: "abc", accessToken: "token" },
      { graphVersion: "v23.0", phoneNumberId: "123", accessToken: "" },
    ]
  ) assertThrows(() => createWhatsAppSender(config), /configuration/i);
  const sender = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123",
    accessToken: "token",
    fetch: () => Promise.resolve(new Response('{"messages":[{"id":"id"}]}')),
  });
  await assertRejects(
    () => sender.send({ to: "3001234567", text: "hello" }),
    /recipient/i,
  );
  await assertRejects(
    () => sender.send({ to: "+573001234567", text: "" }),
    /text/i,
  );
});

Deno.test("sender fails closed and sanitizes provider, request, recipient, and token data", async () => {
  const token = "super-secret-token";
  const recipient = "+573001234567";
  const body = "private review text";
  const responseBody = "provider-secret-body";
  for (
    const response of [
      new Response(responseBody, { status: 400 }),
      new Response("not-json", { status: 200 }),
      new Response('{"messages":[]}', { status: 200 }),
    ]
  ) {
    const sender = createWhatsAppSender({
      graphVersion: "v23.0",
      phoneNumberId: "123",
      accessToken: token,
      fetch: () => Promise.resolve(response),
    });
    await assertRejects(
      () => sender.send({ to: recipient, text: body }),
      /WhatsApp (?:request failed|provider explicitly rejected request)/i,
      [token, recipient, body, responseBody],
    );
  }
});

Deno.test("sender rejects a chunked oversized provider response", async () => {
  const chunks = Array.from(
    { length: 17 },
    () => new Uint8Array(64 * 1024).fill(0x20),
  );
  const sender = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123",
    accessToken: "token",
    fetch: () => {
      let index = 0;
      return Promise.resolve(
        new Response(
          new ReadableStream({
            pull(controller) {
              if (index === chunks.length) return controller.close();
              controller.enqueue(chunks[index++]);
            },
          }),
        ),
      );
    },
  });
  await assertRejects(
    () => sender.send({ to: "+573001234567", text: "hello" }),
    /request failed/i,
  );
});

Deno.test("sender distinguishes explicit HTTP rejection from ambiguous transport failure", async () => {
  const rejected = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123",
    accessToken: "token",
    fetch: () => Promise.resolve(new Response("rejected", { status: 429 })),
  });
  try {
    await rejected.send({ to: "+573001234567", text: "hello" });
    throw new Error("expected rejection");
  } catch (error) {
    assert(error instanceof WhatsAppRejectedError);
    assertEquals(error.code, "provider_http_429");
    assertEquals(error.retryable, true);
  }

  const ambiguous = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123",
    accessToken: "token",
    fetch: () => Promise.reject(new TypeError("network timeout")),
  });
  try {
    await ambiguous.send({ to: "+573001234567", text: "hello" });
    throw new Error("expected failure");
  } catch (error) {
    assert(!(error instanceof WhatsAppRejectedError));
  }
});

Deno.test("408 and 5xx responses are ambiguous, while 4xx and 429 are explicit rejections", async () => {
  for (const status of [408, 500, 502, 503]) {
    const sender = createWhatsAppSender({
      graphVersion: "v23.0",
      phoneNumberId: "123",
      accessToken: "token",
      fetch: () => Promise.resolve(new Response("uncertain", { status })),
    });
    try {
      await sender.send({ to: "+573001234567", text: "hello" });
      throw new Error("expected failure");
    } catch (error) {
      assert(
        !(error instanceof WhatsAppRejectedError),
        `${status} must be ambiguous`,
      );
    }
  }
  for (const status of [400, 403, 404, 429]) {
    const sender = createWhatsAppSender({
      graphVersion: "v23.0",
      phoneNumberId: "123",
      accessToken: "token",
      fetch: () => Promise.resolve(new Response("rejected", { status })),
    });
    try {
      await sender.send({ to: "+573001234567", text: "hello" });
      throw new Error("expected rejection");
    } catch (error) {
      assert(
        error instanceof WhatsAppRejectedError,
        `${status} must be explicit`,
      );
      assertEquals(error.retryable, status === 429);
    }
  }
});

Deno.test("sender combines caller cancellation with automatic timeout", async () => {
  let signal: AbortSignal | undefined;
  const fetcher: typeof fetch = (input, init) => {
    signal = new Request(input, init).signal;
    if (signal.aborted) {
      return Promise.reject(new DOMException("aborted", "AbortError"));
    }
    return new Promise((_resolve, reject) =>
      signal?.addEventListener(
        "abort",
        () => reject(new DOMException("aborted", "AbortError")),
        { once: true },
      )
    );
  };
  const sender = createWhatsAppSender({
    graphVersion: "v23.0",
    phoneNumberId: "123",
    accessToken: "token",
    fetch: fetcher,
    timeoutMs: 5,
  });
  await assertRejects(
    () => sender.send({ to: "+573001234567", text: "hello" }),
    /WhatsApp request failed/i,
    ["token", "+573001234567", "hello"],
  );
  assert(signal?.aborted, "timeout must abort fetch");
  const controller = new AbortController();
  controller.abort();
  await assertRejects(
    () =>
      sender.send({
        to: "+573001234567",
        text: "hello",
        signal: controller.signal,
      }),
    /WhatsApp request failed/i,
  );
});
