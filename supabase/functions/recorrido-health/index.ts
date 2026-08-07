import { createHealthHandler } from "../_shared/recorrido/operations.ts";
import { createSupabaseClient } from "../_shared/recorrido/supabase.ts";
const required = (name: string) => {
  const value = Deno.env.get(name);
  if (!value?.trim()) throw new Error("Invalid health configuration");
  return value;
};
const db = createSupabaseClient({
  baseUrl: required("SUPABASE_URL"),
  serviceRoleKey: required("SUPABASE_ANON_KEY"),
  accessToken: required("RECORRIDO_HEALTH_WORKER_JWT"),
});
Deno.serve(
  createHealthHandler(
    required("RECORRIDO_HEALTH_SECRET"),
    () => db.rpc("recorrido_billing_health", {}),
  ),
);
