import {
  createSupabaseClient,
  type JsonValue,
} from "../_shared/recorrido/supabase.ts";
import { createWebhookHandler } from "../_shared/recorrido/webhook.ts";
import { createWhatsAppSender } from "../_shared/recorrido/whatsapp.ts";

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}
function livemode(value: string): boolean {
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error("RECORRIDO_STRIPE_LIVEMODE must be exactly true or false");
}

export function buildHandler(fetcher: typeof fetch = fetch) {
  const supabase = createSupabaseClient({
    baseUrl: env("SUPABASE_URL"),
    serviceRoleKey: env("SUPABASE_ANON_KEY"),
    accessToken: env("RECORRIDO_WEBHOOK_WORKER_JWT"),
    fetch: fetcher,
  });
  const whatsapp = createWhatsAppSender({
    graphVersion: Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "v23.0",
    phoneNumberId: env("WHATSAPP_PHONE_NUMBER_ID"),
    accessToken: env("WHATSAPP_ACCESS_TOKEN"),
    fetch: fetcher,
  });
  return createWebhookHandler({
    webhookSecret: env("STRIPE_WEBHOOK_SECRET"),
    expectedLivemode: livemode(env("RECORRIDO_STRIPE_LIVEMODE")),
    expectedApiVersion: env("STRIPE_API_VERSION"),
    ownerE164: env("RECORRIDO_OWNER_E164"),
    claimEvent: (value) =>
      supabase.rpc("recorrido_claim_stripe_event", {
        p_stripe_event_id: value.stripeEventId as string,
        p_event_type: value.eventType as string,
        p_stripe_object_id: value.stripeObjectId as string,
        p_livemode: value.livemode as boolean,
        p_stripe_api_version: value.apiVersion as string,
        p_payload: value.payload as JsonValue,
        p_lease_duration: "2 minutes",
        p_payload_raw: value.payloadRaw as string,
      }),
    applyEvent: async (route, ownership) => {
      return await supabase.rpc(route, {
        p_event_id: ownership.eventId as string,
        p_claim_token: ownership.claimToken as string,
        p_attempt: ownership.attempt as number,
      });
    },
    sendReview: ({ to, body }) =>
      whatsapp.send({ to, text: body }).then(() => undefined),
    finishEvent: async (value) => {
      await supabase.rpc("recorrido_finish_stripe_event", {
        p_event_id: value.eventId as string,
        p_claim_token: value.claimToken as string,
        p_attempt: value.attempt as number,
        p_succeeded: value.succeeded as boolean,
        p_error: value.error as string | null,
      });
    },
  });
}

if (import.meta.main) Deno.serve(buildHandler());
