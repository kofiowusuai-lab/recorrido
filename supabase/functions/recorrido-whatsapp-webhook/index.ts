import { createApprovalHandler } from "../_shared/recorrido/approval-handler.ts";
import { createSupabaseClient } from "../_shared/recorrido/supabase.ts";
import { createWhatsAppSender } from "../_shared/recorrido/whatsapp.ts";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value?.trim()) throw new Error("Invalid webhook configuration");
  return value;
}

const supabase = createSupabaseClient({
  baseUrl: required("SUPABASE_URL"),
  serviceRoleKey: required("SUPABASE_ANON_KEY"),
  accessToken: required("RECORRIDO_APPROVAL_WORKER_JWT"),
});
const whatsapp = createWhatsAppSender({
  graphVersion: Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "v23.0",
  phoneNumberId: required("WHATSAPP_PHONE_NUMBER_ID"),
  accessToken: required("WHATSAPP_ACCESS_TOKEN"),
});
const handler = createApprovalHandler({
  verifyToken: required("RECORRIDO_META_VERIFY_TOKEN"),
  appSecret: required("RECORRIDO_META_APP_SECRET"),
  ownerE164: required("RECORRIDO_OWNER_E164"),
}, {
  rpc: supabase.rpc,
  sendReview: (to, body) =>
    whatsapp.send({ to, text: body }).then(() => undefined),
});

Deno.serve(handler);
