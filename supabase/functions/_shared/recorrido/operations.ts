import type { JsonValue } from "./supabase.ts";

type Rpc = (name: string, args: Record<string, JsonValue>) => Promise<unknown>;

function authorized(request: Request, secret: string) {
  return request.headers.get("authorization") === `Bearer ${secret}`;
}
function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}

export function createQuotaHandler(secret: string, rpc: Rpc) {
  if (!secret.trim()) throw new Error("Invalid quota configuration");
  return async (request: Request) => {
    if (request.method !== "POST" || !authorized(request, secret)) {
      return json(401, { ok: false });
    }
    try {
      return json(200, {
        ok: true,
        result: await rpc("recorrido_grant_due_annual_quotas", {}),
      });
    } catch {
      return json(503, { ok: false, error: "quota_unavailable" });
    }
  };
}

export function createHealthHandler(
  secret: string,
  load: () => Promise<unknown>,
) {
  if (!secret.trim()) throw new Error("Invalid health configuration");
  return async (request: Request) => {
    if (request.method !== "GET" || !authorized(request, secret)) {
      return json(401, { ok: false });
    }
    try {
      const value = await load() as Record<string, unknown>;
      const body = {
        status: value.status === "ok" ? "ok" : "degraded",
        stale_webhooks: Number(value.stale_webhooks) || 0,
        payment_without_entitlement:
          Number(value.payment_without_entitlement) || 0,
        newest_webhook_at: typeof value.newest_webhook_at === "string"
          ? value.newest_webhook_at
          : null,
      };
      return json(body.status === "ok" ? 200 : 503, body);
    } catch {
      return json(503, { status: "degraded", error: "health_unavailable" });
    }
  };
}
