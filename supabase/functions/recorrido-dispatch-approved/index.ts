import { createDispatchHandler } from "../_shared/recorrido/dispatch-handler.ts";
import { createSupabaseClient } from "../_shared/recorrido/supabase.ts";
import { createWhatsAppSender } from "../_shared/recorrido/whatsapp.ts";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value?.trim()) throw new Error("Invalid dispatcher configuration");
  return value;
}

const graphVersion = Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "v23.0";
const supabase = createSupabaseClient({
  baseUrl: required("SUPABASE_URL"),
  serviceRoleKey: required("SUPABASE_ANON_KEY"),
  accessToken: required("RECORRIDO_DISPATCHER_WORKER_JWT"),
});
const whatsapp = createWhatsAppSender({
  accessToken: required("WHATSAPP_ACCESS_TOKEN"),
  phoneNumberId: required("WHATSAPP_PHONE_NUMBER_ID"),
  graphVersion,
});
const handler = createDispatchHandler({
  internalSecret: required("RECORRIDO_INTERNAL_API_SECRET"),
  ownerE164: required("RECORRIDO_OWNER_E164"),
}, {
  rpc: supabase.rpc,
  sendText: (to, text) => whatsapp.send({ to, text }),
});

Deno.serve(handler);
