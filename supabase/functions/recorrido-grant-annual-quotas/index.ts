import { createQuotaHandler } from "../_shared/recorrido/operations.ts";
import { createSupabaseClient } from "../_shared/recorrido/supabase.ts";
const required = (name: string) => {
  const value = Deno.env.get(name);
  if (!value?.trim()) throw new Error("Invalid quota configuration");
  return value;
};
const db = createSupabaseClient({
  baseUrl: required("SUPABASE_URL"),
  serviceRoleKey: required("SUPABASE_ANON_KEY"),
  accessToken: required("RECORRIDO_QUOTA_WORKER_JWT"),
});
Deno.serve(createQuotaHandler(required("RECORRIDO_SCHEDULER_SECRET"), db.rpc));
