import { createHealthHandler, createQuotaHandler } from "./operations.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("quota handler is scheduler-authenticated and calls only the server-clock RPC", async () => {
  const calls: unknown[] = [];
  const handler = createQuotaHandler("secret", (name, args) => {
    calls.push([name, args]);
    return Promise.resolve({ granted: 2 });
  });
  equal(
    (await handler(new Request("https://x.test", { method: "POST" }))).status,
    401,
  );
  const response = await handler(
    new Request("https://x.test", {
      method: "POST",
      headers: { authorization: "Bearer secret" },
    }),
  );
  equal(response.status, 200);
  equal(calls, [["recorrido_grant_due_annual_quotas", {}]]);
});

Deno.test("health output is redacted and reports operational counters", async () => {
  const handler = createHealthHandler("secret", () =>
    Promise.resolve({
      status: "degraded",
      stale_webhooks: 2,
      payment_without_entitlement: 1,
      newest_webhook_at: "2026-08-05T00:00:00Z",
      token: "must-not-leak",
    }));
  const response = await handler(
    new Request("https://x.test", {
      headers: { authorization: "Bearer secret" },
    }),
  );
  equal(response.status, 503);
  const text = await response.text();
  if (text.includes("token") || text.includes("must-not-leak")) {
    throw new Error("health leaked unknown fields");
  }
});
