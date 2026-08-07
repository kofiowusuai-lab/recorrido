import { createCheckoutResultHandler } from "./checkout-result.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("checkout result accepts only explicit success and cancelled GETs", async () => {
  const handler = createCheckoutResultHandler();
  for (const status of ["success", "cancelled"]) {
    const response = handler(
      new Request(`https://example.test/?status=${status}`),
    );
    assert(response.status === 200, `${status} must return 200`);
    const text = await response.text();
    assert(
      text.includes(
        status === "success" ? "Payment received" : "Checkout cancelled",
      ),
      "wrong result copy",
    );
    assert(
      response.headers.get("cache-control") === "no-store",
      "must not cache",
    );
    assert(
      response.headers.get("content-security-policy")?.includes(
        "default-src 'none'",
      ),
      "strict CSP required",
    );
  }
  assert(
    handler(new Request("https://example.test/")).status === 400,
    "missing status must fail",
  );
  assert(
    handler(new Request("https://example.test/?status=other")).status === 400,
    "unknown status must fail",
  );
  const post = handler(
    new Request("https://example.test/?status=success", { method: "POST" }),
  );
  assert(
    post.status === 405 && post.headers.get("allow") === "GET",
    "non-GET must fail",
  );
});

Deno.test("checkout result exposes no session or payment data", async () => {
  const handler = createCheckoutResultHandler();
  const response = handler(
    new Request("https://example.test/?status=success&session_id=cs_secret"),
  );
  const text = await response.text();
  assert(!text.includes("cs_secret"), "must not echo query data");
  assert(!text.includes("session_id"), "must not expose query names");
});
