const HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
  "referrer-policy": "no-referrer",
};

function page(cancelled: boolean): string {
  const title = cancelled ? "Checkout cancelled" : "Payment received";
  const body = cancelled
    ? "No payment was completed. You can close this page and return to Recorrido."
    : "Your payment is being verified securely. You can close this page and return to Recorrido.";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} | Recorrido</title><style>html{color-scheme:light}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f1eb;color:#17201d;font:16px/1.5 system-ui,-apple-system,sans-serif}.card{width:min(34rem,calc(100% - 3rem));padding:2.5rem;border-radius:1.25rem;background:#fff;box-shadow:0 1rem 3rem #17201d18}h1{margin:0 0 .75rem;font-size:clamp(1.8rem,6vw,2.6rem);line-height:1.1}p{margin:0;color:#53615c}</style></head><body><main class="card"><h1>${title}</h1><p>${body}</p></main></body></html>`;
}

export function createCheckoutResultHandler() {
  return (request: Request): Response => {
    if (request.method !== "GET") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { ...HEADERS, allow: "GET" },
      });
    }
    const status = new URL(request.url).searchParams.get("status");
    if (status !== "success" && status !== "cancelled") {
      return new Response("Invalid checkout result", {
        status: 400,
        headers: HEADERS,
      });
    }
    return new Response(page(status === "cancelled"), {
      status: 200,
      headers: HEADERS,
    });
  };
}
