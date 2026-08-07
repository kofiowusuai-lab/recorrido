import {
  createDispatchHandler,
  ProviderRejectedError,
} from "./dispatch-handler.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const owner = "+573001234567";
const env = { internalSecret: "internal-secret-long", ownerE164: owner };
const row = {
  id: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
  draftId: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
  attemptId: "2d7f4e26-5ad0-4ce1-97d7-4cc72f4f62dc",
  claimToken: "44444444-4444-4444-8444-444444444444",
  leaseExpiresAt: "2026-08-05T12:02:00Z",
  ownerWhatsAppE164: owner,
  recipientE164: "+573109876543",
  messageType: "text",
  payload: { body: "Approved body" },
  body: "Approved body",
  previewText: "Approved body",
  status: "approved",
  approvedAt: "2026-08-05T12:00:00Z",
  approvedBy: owner,
  approvedVersion: 3,
  currentDraftVersion: 3,
  tokenValid: true,
  approvalExpiresAt: "2026-08-05T13:00:00Z",
  optedOut: false,
  recipientConsented: true,
  sentAt: null,
  providerMessageId: null,
};

function request(body = '{"limit":10}', token = env.internalSecret) {
  return new Request("https://x.test", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body,
  });
}

function chunkedRequest(chunks: string[], poisonAfterChunks = false): Request {
  const encoder = new TextEncoder();
  let index = 0;
  return new Request("https://x.test", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.internalSecret}`,
      "content-type": "application/json",
    },
    body: new ReadableStream({
      pull(controller) {
        if (index < chunks.length) {
          controller.enqueue(encoder.encode(chunks[index++]));
        } else if (poisonAfterChunks) {
          controller.error(new Error("reader consumed past the body limit"));
        } else {
          controller.close();
        }
      },
    }),
  });
}

function rpcWithClaim(
  calls: Array<[string, Record<string, unknown>]>,
  claim: unknown[] = [row],
) {
  return (name: string, args: Record<string, unknown>) => {
    calls.push([name, args]);
    return Promise.resolve(
      name === "recorrido_claim_approved_outbound"
        ? claim
        : name === "recorrido_begin_outbound_send"
        ? { begun: true }
        : { marked: true },
    );
  };
}

Deno.test("auth and request schema fail before database access", async () => {
  let calls = 0;
  const handler = createDispatchHandler(env, {
    rpc: () => {
      calls++;
      return Promise.resolve([]);
    },
    sendText: () => Promise.resolve({ messageId: "x" }),
  });
  equal((await handler(new Request("https://x.test"))).status, 401);
  equal((await handler(request("{}", "wrong"))).status, 401);
  for (
    const invalid of [
      "{}",
      '{"limit":0}',
      '{"limit":101}',
      '{"limit":1,"extra":true}',
      "[]",
      "bad",
    ]
  ) {
    equal((await handler(request(invalid))).status, 400);
  }
  equal((await handler(request("x".repeat(4097)))).status, 413);
  equal(calls, 0);
});

Deno.test("chunked dispatch bodies are bounded while streaming", async () => {
  let calls = 0;
  const handler = createDispatchHandler(env, {
    rpc: () => {
      calls++;
      return Promise.resolve([]);
    },
    sendText: () => Promise.resolve({ messageId: "x" }),
  });
  const response = await handler(chunkedRequest(
    ["x".repeat(2_048), "x".repeat(2_049)],
    true,
  ));
  equal(response.status, 413);
  equal(calls, 0);
});

Deno.test("empty claim reports ambiguous separately", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const handler = createDispatchHandler(env, {
    rpc: rpcWithClaim(calls, []),
    sendText: () => Promise.resolve({ messageId: "x" }),
  });
  equal(await (await handler(request())).json(), {
    ok: true,
    claimed: 0,
    delivered: 0,
    failed: 0,
    retryable: 0,
    ambiguous: 0,
    ids: [],
  });
});

Deno.test("valid claim checkpoints transmission then acknowledges provider success", async () => {
  const events: string[] = [];
  const handler = createDispatchHandler(env, {
    rpc: (name, args) => {
      events.push(name);
      if (name === "recorrido_claim_approved_outbound") {
        return Promise.resolve([row]);
      }
      if (name === "recorrido_begin_outbound_send") {
        return Promise.resolve({ begun: true });
      }
      equal(args, {
        p_pending_outbound_id: row.id,
        p_attempt_id: row.attemptId,
        p_claim_token: row.claimToken,
        p_provider_message_id: "wamid.1",
      });
      return Promise.resolve({ marked: true });
    },
    sendText: (to, text) => {
      equal([to, text], [row.recipientE164, row.body]);
      events.push("send");
      return Promise.resolve({ messageId: "wamid.1" });
    },
  });
  equal(await (await handler(request('{"limit":1}'))).json(), {
    ok: true,
    claimed: 1,
    delivered: 1,
    failed: 0,
    retryable: 0,
    ambiguous: 0,
    ids: [row.id],
  });
  equal(events, [
    "recorrido_claim_approved_outbound",
    "recorrido_begin_outbound_send",
    "send",
    "recorrido_mark_outbound_delivered",
  ]);
});

Deno.test("exact claim shape rejects missing, extra, and malformed lease ownership fields without sending", async () => {
  for (
    const malformed of [
      { ...row, claimToken: "not-a-uuid" },
      { ...row, leaseExpiresAt: "not-a-time" },
      { ...row, unexpected: true },
    ]
  ) {
    let sends = 0;
    const calls: Array<[string, Record<string, unknown>]> = [];
    const handler = createDispatchHandler(env, {
      rpc: rpcWithClaim(calls, [malformed]),
      sendText: () => {
        sends++;
        return Promise.resolve({ messageId: "x" });
      },
    });
    const result = await (await handler(request())).json() as Record<
      string,
      unknown
    >;
    equal([result.failed, result.retryable, result.ambiguous, sends], [
      malformed.claimToken === "not-a-uuid" ? 0 : 1,
      malformed.claimToken === "not-a-uuid" ? 1 : 0,
      0,
      0,
    ]);
  }
});

Deno.test("explicit provider rejection is the only safely retryable send failure", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const handler = createDispatchHandler(env, {
    rpc: rpcWithClaim(calls),
    sendText: () =>
      Promise.reject(new ProviderRejectedError("provider_rejected", true)),
  });
  equal(await (await handler(request())).json(), {
    ok: true,
    claimed: 1,
    delivered: 0,
    failed: 1,
    retryable: 1,
    ambiguous: 0,
    ids: [row.id],
  });
  equal(calls.at(-1), ["recorrido_mark_outbound_failed", {
    p_pending_outbound_id: row.id,
    p_attempt_id: row.attemptId,
    p_claim_token: row.claimToken,
    p_error_code: "provider_rejected",
    p_retryable: true,
  }]);
});

Deno.test("transport failure after checkpoint is ambiguous and never auto-retryable", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const handler = createDispatchHandler(env, {
    rpc: rpcWithClaim(calls),
    sendText: () => Promise.reject(new TypeError("network timeout")),
  });
  equal(await (await handler(request())).json(), {
    ok: true,
    claimed: 1,
    delivered: 0,
    failed: 0,
    retryable: 0,
    ambiguous: 1,
    ids: [row.id],
  });
  equal(calls.at(-1), ["recorrido_mark_outbound_ambiguous", {
    p_pending_outbound_id: row.id,
    p_attempt_id: row.attemptId,
    p_claim_token: row.claimToken,
    p_error_code: "provider_error",
    p_provider_message_id: null,
  }]);
});

Deno.test("provider success followed by acknowledgement failure is ambiguous with provider id", async () => {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const handler = createDispatchHandler(env, {
    rpc: (name, args) => {
      calls.push([name, args]);
      if (name === "recorrido_claim_approved_outbound") {
        return Promise.resolve([row]);
      }
      if (name === "recorrido_begin_outbound_send") {
        return Promise.resolve({ begun: true });
      }
      if (name === "recorrido_mark_outbound_delivered") {
        return Promise.reject(new Error("db unavailable"));
      }
      return Promise.resolve({ marked: true });
    },
    sendText: () => Promise.resolve({ messageId: "wamid.accepted" }),
  });
  const result = await (await handler(request())).json() as Record<
    string,
    unknown
  >;
  equal([result.delivered, result.retryable, result.ambiguous], [0, 0, 1]);
  equal(calls.at(-1), ["recorrido_mark_outbound_ambiguous", {
    p_pending_outbound_id: row.id,
    p_attempt_id: row.attemptId,
    p_claim_token: row.claimToken,
    p_error_code: "ack_failed",
    p_provider_message_id: "wamid.accepted",
  }]);
});

Deno.test("failed transmission checkpoint never calls provider", async () => {
  let sends = 0;
  const handler = createDispatchHandler(env, {
    rpc: (name) =>
      name === "recorrido_claim_approved_outbound"
        ? Promise.resolve([row])
        : Promise.reject(new Error("lease lost")),
    sendText: () => {
      sends++;
      return Promise.resolve({ messageId: "x" });
    },
  });
  const result = await (await handler(request())).json() as Record<
    string,
    unknown
  >;
  equal([result.retryable, result.ambiguous, sends], [1, 0, 0]);
});
