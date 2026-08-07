import { createApprovalHandler } from "./approval-handler.ts";
import { TransportError } from "./http.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const encoder = new TextEncoder();
const env = {
  verifyToken: "verify-secret",
  appSecret: "app-secret",
  ownerE164: "+573001234567",
};
async function signature(body: Uint8Array) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(env.appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, Uint8Array.from(body)),
  );
  return `sha256=${
    [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("")
  }`;
}
function payload(from: string, text: string) {
  return JSON.stringify({
    object: "whatsapp_business_account",
    entry: [{
      changes: [{
        field: "messages",
        value: {
          messaging_product: "whatsapp",
          messages: [{ from, type: "text", text: { body: text } }],
        },
      }],
    }],
  });
}
async function post(text: string, from = "573001234567") {
  const raw = encoder.encode(payload(from, text));
  return new Request("https://example.test/hook", {
    method: "POST",
    headers: {
      "x-hub-signature-256": await signature(raw),
      "content-type": "application/json",
    },
    body: raw,
  });
}

Deno.test("GET verification is strict and returns only the plain challenge", async () => {
  const handler = createApprovalHandler(env, {
    rpc: () => Promise.resolve(null),
  });
  const ok = await handler(
    new Request(
      "https://x.test/?hub.mode=subscribe&hub.verify_token=verify-secret&hub.challenge=abc",
    ),
  );
  equal([ok.status, ok.headers.get("content-type"), await ok.text()], [
    200,
    "text/plain; charset=utf-8",
    "abc",
  ]);
  for (
    const url of [
      "https://x.test/?hub.mode=Subscribe&hub.verify_token=verify-secret&hub.challenge=abc",
      "https://x.test/?hub.mode=subscribe&hub.verify_token=bad&hub.challenge=abc",
      "https://x.test/?hub.mode=subscribe&hub.verify_token=verify-secret&hub.challenge=",
    ]
  ) equal((await handler(new Request(url))).status, 403);
});

Deno.test("signature is checked before parse or DB", async () => {
  let calls = 0;
  const handler = createApprovalHandler(env, {
    rpc: () => {
      calls++;
      return Promise.resolve(null);
    },
  });
  const response = await handler(
    new Request("https://x.test", {
      method: "POST",
      headers: { "x-hub-signature-256": "sha256=" + "0".repeat(64) },
      body: "not-json",
    }),
  );
  equal(response.status, 401);
  equal(calls, 0);
});

Deno.test("only exact owner text messages mutate DB; ignored provider events return 200", async () => {
  const calls: unknown[] = [];
  const handler = createApprovalHandler(env, {
    rpc: (name, args) => {
      calls.push([name, args]);
      return Promise.resolve({ decision: "approve" });
    },
  });
  equal(
    (await handler(await post("APPROVE tok_1", "573001234568"))).status,
    200,
  );
  const statusRaw = encoder.encode(
    JSON.stringify({
      object: "whatsapp_business_account",
      entry: [{
        changes: [{
          field: "messages",
          value: { statuses: [{ id: "secret" }] },
        }],
      }],
    }),
  );
  equal(
    (await handler(
      new Request("https://x.test", {
        method: "POST",
        headers: { "x-hub-signature-256": await signature(statusRaw) },
        body: statusRaw,
      }),
    )).status,
    200,
  );
  equal(calls.length, 0);
});

Deno.test("APPROVE and REJECT use owner-action RPC with owner supplied separately", async () => {
  const calls: unknown[] = [];
  const handler = createApprovalHandler(env, {
    rpc: (name, args) => {
      calls.push([name, args]);
      return Promise.resolve({ decision: "ok" });
    },
  });
  await handler(await post("APPROVE token_ABC-9"));
  await handler(await post("reject token_xyz"));
  equal(calls, [
    ["recorrido_apply_owner_action", {
      p_owner_phone_e164: env.ownerE164,
      p_sender_phone_e164: env.ownerE164,
      p_action: "approve",
      p_token: "token_ABC-9",
    }],
    ["recorrido_apply_owner_action", {
      p_owner_phone_e164: env.ownerE164,
      p_sender_phone_e164: env.ownerE164,
      p_action: "reject",
      p_token: "token_xyz",
    }],
  ]);
});

Deno.test("EDIT delivers a fresh review token only to the configured owner", async () => {
  const calls: unknown[] = [];
  const handler = createApprovalHandler(env, {
    rpc: (name, args) => {
      calls.push([name, args]);
      return Promise.resolve({
        decision: "need_new_review",
        approvalToken: "fresh_token_2",
        currentDraftVersion: 2,
      });
    },
    sendReview: (to, body) => {
      calls.push(["review", { to, body }]);
      return Promise.resolve();
    },
  });
  const response = await handler(
    await post("EDIT token_1 Replacement exact body"),
  );
  equal(await response.json(), { ok: true, decision: "need_new_review" });
  equal(calls, [["recorrido_apply_owner_edit", {
    p_owner_phone_e164: env.ownerE164,
    p_sender_phone_e164: env.ownerE164,
    p_token: "token_1",
    p_replacement: "Replacement exact body",
  }], ["review", {
    to: env.ownerE164,
    body: "Review edited draft v2\nAPPROVE fresh_token_2\nREJECT fresh_token_2",
  }]]);
});

Deno.test("malformed shapes, implicit commands, and oversized bodies fail closed", async () => {
  let calls = 0;
  const handler = createApprovalHandler(env, {
    rpc: () => {
      calls++;
      return Promise.resolve(null);
    },
  });
  for (
    const command of [
      "yes",
      "APPROVE",
      "APPROVE bad token",
      "EDIT token",
      "EDIT token   ",
    ]
  ) {
    equal((await handler(await post(command))).status, 200);
  }
  const huge = new Uint8Array(65_537).fill(120);
  equal(
    (await handler(
      new Request("https://x.test", {
        method: "POST",
        headers: { "x-hub-signature-256": await signature(huge) },
        body: huge,
      }),
    )).status,
    413,
  );
  equal(calls, 0);
});

Deno.test("RPC errors are sanitized and replay transport stays 200", async () => {
  const handler = createApprovalHandler(env, {
    rpc: () =>
      Promise.reject(new Error("token secret recipient +573001234567")),
  });
  const response = await handler(await post("APPROVE token_1"));
  equal(response.status, 200);
  const text = await response.text();
  assert(
    !text.includes("secret") && !text.includes("+573001234567") &&
      !text.includes("token_1"),
  );
});

Deno.test("transient Supabase failures are retryable while business denials are acknowledged", async () => {
  for (
    const error of [
      new TransportError("network"),
      new TransportError("upstream", 503),
    ]
  ) {
    const handler = createApprovalHandler(env, {
      rpc: () => Promise.reject(error),
    });
    equal((await handler(await post("APPROVE token_1"))).status, 503);
  }
  const denied = createApprovalHandler(env, {
    rpc: () => Promise.reject(new TransportError("denied secret", 409)),
  });
  const response = await denied(await post("APPROVE token_1"));
  equal(response.status, 200);
  assert(!(await response.text()).includes("secret"));
});

Deno.test("EDIT fails closed unless the RPC confirms need_new_review", async () => {
  const handler = createApprovalHandler(env, {
    rpc: () => Promise.resolve({ decision: "approve", body: "must-not-leak" }),
  });
  equal(await (await handler(await post("EDIT token_1 Replacement"))).json(), {
    ok: false,
    error: "action_not_applied",
  });
});
