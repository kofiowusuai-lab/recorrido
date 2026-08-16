import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");
const read = (relative: string) => readFileSync(resolve(root, relative), "utf8");

describe("Cloudflare deployment contract", () => {
  it("binds private R2, Queue, DLQ, cron recovery, and observability in both environments", () => {
    const config = read("wrangler.jsonc");
    for (const binding of ["INPUTS", "OUTPUTS", "TEMP", "GENERATION_QUEUE"]) expect(config).toContain(binding);
    for (const name of [
      "recorrido-generation-inputs", "recorrido-generation-outputs", "recorrido-generation-temp",
      "recorrido-generation-inputs-staging", "recorrido-generation-outputs-staging", "recorrido-generation-temp-staging",
      "recorrido-generation-queue", "recorrido-generation-dlq", "recorrido-generation-queue-staging", "recorrido-generation-dlq-staging",
    ]) expect(config).toContain(name);
    expect(config).toMatch(/"max_retries"\s*:\s*3/);
    expect(config).toMatch(/"crons"\s*:\s*\["\*\/1 \* \* \* \*"\]/);
    expect(config).toMatch(/"observability"[\s\S]*"enabled"\s*:\s*true/);
    expect(config).not.toContain("d1_databases");
    expect(config).not.toContain("routes");
  });

  it("declares only encrypted runtime secrets by name", () => {
    const docs = read("README.md");
    for (const name of ["INGRESS_API_TOKEN", "LOCAL_WORKER_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "ALERT_WEBHOOK_URL"]) {
      expect(docs).toContain(name);
    }
    expect(docs).toContain("Never commit secret values");
  });
});

describe("Supabase authority contract", () => {
  it("adds a transactional outbox and fenced lease metadata without replacing the existing generation ledger", () => {
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql").toLowerCase();
    for (const field of [
      "input_manifest_key", "manifest_sha256", "output_object_key", "lease_owner", "lease_expires_at",
      "lease_token", "lease_version", "queue_delivered_at", "cloudflare_environment", "output_sha256",
    ]) expect(sql).toContain(field);
    expect(sql).toContain("create table if not exists public.recorrido_generation_dispatch_outbox");
    for (const status of ["pending", "dispatching", "enqueued", "delivered", "dead"]) expect(sql).toContain(`'${status}'`);
    for (const fn of [
      "recorrido_prepare_generation_dispatch", "recorrido_mark_generation_dispatched", "recorrido_claim_generation_dispatches",
      "recorrido_mark_generation_queue_delivered", "recorrido_claim_generation_job", "recorrido_heartbeat_generation_job",
      "recorrido_assert_generation_output_lease", "recorrido_complete_generation_dispatch", "recorrido_release_generation_dispatch",
      "recorrido_terminalize_generation_dispatch",
    ]) expect(sql).toContain(`function public.${fn}`);
    expect(sql).toContain("for update skip locked");
    expect(sql).toContain("public.recorrido_reserve_generation");
    expect(sql).toContain("public.recorrido_complete_generation");
    expect(sql).toContain("public.recorrido_release_generation");
    expect(sql).toMatch(/revoke all on (table|function)[\s\S]*from public/);
  });

  it("fences runtime claims, manifests, leases, and stale queue recovery", () => {
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql").toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";

    for (const name of [
      "recorrido_prepare_generation_dispatch", "recorrido_claim_generation_dispatches", "recorrido_claim_generation_job",
    ]) expect(body(name)).toMatch(/recorrido_cloudflare_generation_runtime[\s\S]*for share/);

    for (const name of [
      "recorrido_prepare_generation_dispatch", "recorrido_mark_generation_dispatched", "recorrido_mark_generation_dispatch_failed",
      "recorrido_claim_generation_dispatches", "recorrido_mark_generation_queue_delivered", "recorrido_claim_generation_job",
    ]) expect(body(name)).toMatch(/p_environment text[\s\S]*cloudflare_environment/);

    expect(sql).toMatch(/active_environment text[\s\S]*check \(active_environment in \('off','staging','production'\)\)/);

    expect(sql).toMatch(/prevent_manifest_sha256_change[\s\S]*manifest_sha256 is distinct from old\.manifest_sha256/);
    expect(body("recorrido_claim_generation_job")).toMatch(/'idempotency_key'[\s\S]*'manifest_sha256'[\s\S]*'lease_token'[\s\S]*'lease_version'/);
    for (const name of ["recorrido_heartbeat_generation_job", "recorrido_assert_generation_output_lease", "recorrido_complete_generation_dispatch", "recorrido_release_generation_dispatch"]) {
      expect(body(name)).toMatch(/p_environment text[\s\S]*p_lease_token uuid[\s\S]*p_lease_version bigint/);
      expect(body(name)).toMatch(/status = 'running'[\s\S]*lease_owner (?:=|is distinct from) p_worker_id[\s\S]*lease_token (?:=|is distinct from) p_lease_token[\s\S]*lease_version (?:=|is distinct from) p_lease_version[\s\S]*lease_expires_at/);
    }
    expect(body("recorrido_claim_generation_dispatches")).toMatch(/status = 'enqueued'[\s\S]*queue_delivered_at is null[\s\S]*interval '5 minutes'/);
  });

  it("matches the effective legacy account-reservation-job order and releases terminal dispatch exactly once", () => {
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql").toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";

    for (const name of ["recorrido_complete_generation_dispatch", "recorrido_release_generation_dispatch"]) {
      const fn = body(name);
      expect(fn).toMatch(/p_worker_id text[\s\S]*p_lease_token uuid/);
      const reservationLock = fn.search(/select \* into v_reservation[\s\S]*?recorrido_generation_reservations[\s\S]*?for update/);
      const accountLock = fn.indexOf("pg_advisory_xact_lock");
      const jobLock = fn.search(/select \* into v_job[\s\S]*?recorrido_generation_jobs[\s\S]*?for update/);
      const legacyCall = fn.lastIndexOf(name.includes("complete") ? "recorrido_complete_generation(" : "recorrido_release_generation(");
      expect(reservationLock).toBeGreaterThan(-1);
      expect(accountLock).toBeGreaterThan(-1);
      expect(reservationLock).toBeGreaterThan(accountLock);
      expect(jobLock).toBeGreaterThan(reservationLock);
      expect(legacyCall).toBeGreaterThan(jobLock);
    }

    const terminal = body("recorrido_terminalize_generation_dispatch");
    expect(terminal).toMatch(/status = 'dead'[\s\S]*status = 'reserved'[\s\S]*recorrido_release_generation\(/);
    expect(body("recorrido_claim_generation_dispatches")).toMatch(/status = 'dead'[\s\S]*terminalized_at is null/);
  });

  it("attempt-fences outbox dispatch callbacks and passes the claim attempt from cron", () => {
    const source = read("src/index.ts");
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql").toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";

    for (const name of ["recorrido_mark_generation_dispatched", "recorrido_mark_generation_dispatch_failed"]) {
      expect(body(name)).toMatch(/p_attempt integer/);
      expect(body(name)).toMatch(/attempts = p_attempt/);
    }
    expect(source).toMatch(/recorrido_mark_generation_dispatched[\s\S]*p_attempt: row\.attempts/);
    expect(source).toMatch(/recorrido_mark_generation_dispatch_failed[\s\S]*p_attempt: row\.attempts/);
  });

  it("ships a forward migration that removes unfenced live callback overloads", () => {
    const forward = read("../../supabase/migrations/202608150002_recorrido_cloudflare_generation_security_fences.sql").toLowerCase();
    expect(forward).toContain("drop function if exists public.recorrido_mark_generation_dispatched(uuid,text)");
    expect(forward).toContain("drop function if exists public.recorrido_mark_generation_dispatch_failed(uuid,text,text)");
    expect(forward).toMatch(/recorrido_mark_generation_dispatched[\s\S]*p_attempt integer[\s\S]*attempts = p_attempt/);
    expect(forward).toMatch(/recorrido_complete_generation_dispatch[\s\S]*pg_advisory_xact_lock[\s\S]*select \* into v_reservation/);
  });

  it("binds one output hash per lease before multipart finalization", () => {
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql");
    const forward = read("../../supabase/migrations/202608150003_recorrido_output_upload_hash_fence.sql");
    const functionBody = (name: string) => sql.split(`create or replace function public.${name}`)[1].split("$$;")[0];
    expect(sql).toContain("output_upload_sha256 text");
    expect(sql).toMatch(/lease_version = lease_version \+ 1,[\s\S]*output_upload_sha256 = null/);
    expect(functionBody("recorrido_assert_generation_output_lease")).toMatch(/for update;[\s\S]*output_upload_sha256 is not null[\s\S]*output_upload_sha256 = p_output_sha256/);
    expect(functionBody("recorrido_complete_generation_dispatch")).toContain("output_upload_sha256 = p_output_sha256");
    expect(forward).toContain("add column if not exists output_upload_sha256 text");
  });

  it("keeps Queue production cron-only and aligns messages, state names, hashes, and output keys", () => {
    const source = read("src/index.ts");
    const sql = read("../../supabase/migrations/202608150001_recorrido_cloudflare_generation_control_plane.sql").toLowerCase();
    const createJob = source.split("async function createJob")[1]?.split("function leaseFence")[0] ?? "";
    expect(createJob).not.toContain("GENERATION_QUEUE.send");
    expect(source).not.toContain('"dispatched"');
    expect(source).toContain("environment: EnvironmentName");
    expect(source).toContain('"x-content-sha256"');
    expect(source).toContain("customMetadata: { sha256");
    expect(sql).toContain("'idempotency_key'");
    expect(sql).toContain("'environment'");
    expect(sql).toMatch(/accounts\/%s\/jobs\/%s\/leases\/%s\/output\.mp4/);
  });

  it("binds the staging queue producer explicitly instead of inheriting production", () => {
    const config = JSON.parse(read("wrangler.jsonc"));
    expect(config.env.staging.queues.producers).toEqual([
      { binding: "GENERATION_QUEUE", queue: "recorrido-generation-queue-staging" },
    ]);
    expect(config.queues.producers).toEqual([
      { binding: "GENERATION_QUEUE", queue: "recorrido-generation-queue" },
    ]);
  });

  it("ships a tested rollback which disables dispatch without dropping ledger data", () => {
    const rollback = read("ROLLBACK.md").toLowerCase();
    expect(rollback).toContain("runtime_control.py off");
    expect(rollback).toContain("active_environment");
    expect(rollback).toContain("wrangler rollback");
    expect(rollback).toContain("do not drop");
  });

  it("keeps agent-activity ranking private, regional, source-grounded, and non-authorizing", () => {
    const ranking = read("../../supabase/migrations/202608150004_recorrido_agent_activity_priority.sql").toLowerCase();
    expect(ranking).toContain("create materialized view public.recorrido_outreach_agent_activity_priority");
    expect(ranking).toContain("raw_payload->>'active_listings'");
    expect(ranking).toContain("raw_payload->>'harvested_at'");
    expect(ranking).toContain("partition by workspace_id, country, department, city");
    expect(ranking).toContain("'most_active_by_region'::text");
    expect(ranking).toContain("revoke all on public.recorrido_outreach_agent_activity_priority from public, anon, authenticated");
    expect(ranking).toContain("does not enroll, assign, authorize, or send outreach");
    expect(ranking).not.toMatch(/insert\s+into\s+public\.recorrido_outreach_(campaigns|message_outbox|send_attempts)/);
  });

  it("packages a secret-free Mac LaunchAgent with explicit enable and disable operations", () => {
    const plist = read("local/com.recorrido.cloudflare-generation-worker.plist");
    const installer = read("local/install.command");
    expect(plist).toContain("recorrido_cloudflare_generation_worker.py");
    expect(plist).toContain("RunAtLoad");
    expect(plist).not.toContain("LOCAL_WORKER_TOKEN=");
    expect(installer).toContain("--enable");
    expect(installer).toContain("--disable");
    expect(installer).toContain("install -m 700");
    expect(installer).toContain("install -m 600");
  });
});

describe("recipient-bound customer delivery authority", () => {
  const deliveryMigration = "../../supabase/migrations/202608160001_recorrido_customer_delivery.sql";

  it("keeps format, source, recipient, output, and sender identity immutable", () => {
    const sql = read(deliveryMigration).toLowerCase();
    for (const field of [
      "output_format", "source_listing_id", "recipient_phone_e164", "output_object_key",
      "output_sha256", "expected_sender_identity_hash", "media_provider_message_id",
      "notice_provider_message_id", "remaining_generations",
    ]) expect(sql).toContain(field);
    expect(sql).toContain("create table public.recorrido_customer_delivery_outbox");
    expect(sql).toContain("create table public.recorrido_customer_delivery_attempts");
    expect(sql).toContain("unique (reservation_id)");
    expect(sql).toContain("unique (job_id)");
    expect(sql).toMatch(/output_format[\s\S]*check \(output_format in \('9:16','16:9'\)\)/);
  });

  it("stages delivery at render completion and consumes only on provider media acceptance", () => {
    const sql = read(deliveryMigration).toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";
    const render = body("recorrido_complete_generation_dispatch");
    expect(render).toContain("recorrido_customer_delivery_outbox");
    expect(render).not.toContain("recorrido_complete_generation(");
    expect(render).toMatch(/status\s*<>\s*'reserved'/);

    const accepted = body("recorrido_accept_customer_delivery_media");
    expect(accepted).toContain("recorrido_complete_generation(");
    expect(accepted).toMatch(/media_provider_message_id[\s\S]*remaining_generations/);
    expect(accepted).toMatch(/recorrido_available_credits/);
  });

  it("uses fenced two-phase media and notice leases and never auto-reclaims sending states", () => {
    const sql = read(deliveryMigration).toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";
    for (const fn of [
      "recorrido_claim_customer_delivery", "recorrido_heartbeat_customer_delivery",
      "recorrido_checkpoint_customer_delivery", "recorrido_assert_customer_delivery_media",
      "recorrido_accept_customer_delivery_media", "recorrido_accept_customer_delivery_notice",
      "recorrido_abandon_customer_delivery_claim",
    ]) expect(sql).toContain(`function public.${fn}`);
    for (const fn of [
      "recorrido_heartbeat_customer_delivery", "recorrido_checkpoint_customer_delivery",
      "recorrido_assert_customer_delivery_media", "recorrido_accept_customer_delivery_media",
      "recorrido_accept_customer_delivery_notice", "recorrido_abandon_customer_delivery_claim",
    ]) expect(body(fn)).toMatch(/p_claim_token uuid[\s\S]*p_attempt integer/);
    expect(body("recorrido_claim_customer_delivery")).toMatch(/status in \('pending','notice_pending'\)/);
    expect(body("recorrido_claim_customer_delivery")).toMatch(/status in \('media_claimed','notice_claimed'\)[\s\S]*lease_expires_at<now\(\)/);
    expect(body("recorrido_claim_customer_delivery")).not.toMatch(/media_sending[\s\S]*(pending|media_claimed)/);
    expect(body("recorrido_claim_customer_delivery")).not.toMatch(/notice_sending[\s\S]*(notice_pending|notice_claimed)/);
  });

  it("re-resolves the active account member identity before claims and binds same-recipient notices", () => {
    const sql = read(deliveryMigration).toLowerCase();
    const body = (name: string) => sql.split(`function public.${name}`)[1]?.split("$$;")[0] ?? "";
    const claim = body("recorrido_claim_customer_delivery");
    expect(claim).toMatch(/recorrido_account_members[\s\S]*status\s*=\s*'active'/);
    expect(claim).toMatch(/recorrido_whatsapp_identities[\s\S]*recipient_phone_e164/);
    expect(body("recorrido_accept_customer_delivery_media")).toMatch(/notice_text[\s\S]*(generaciones|gerações)/);
  });

  it("keeps every delivery table private and grants only narrow RPC execution", () => {
    const sql = read(deliveryMigration).toLowerCase();
    for (const table of ["recorrido_customer_delivery_runtime", "recorrido_customer_delivery_outbox", "recorrido_customer_delivery_attempts"]) {
      expect(sql).toContain(`alter table public.${table} enable row level security`);
      expect(sql).toContain(`revoke all on table public.${table} from public, anon, authenticated`);
    }
    expect(sql).toMatch(/revoke all on function public\.recorrido_claim_customer_delivery[\s\S]*from public\s*,\s*anon\s*,\s*authenticated/);
  });

  it("packages the delivery worker without secrets in process arguments and installs disabled", () => {
    const worker = read("local/delivery_worker.py");
    const plist = read("local/com.recorrido.customer-delivery-worker.plist");
    const installer = read("local/install-delivery.command");
    expect(worker).toContain("accountIdentityHash");
    expect(worker).toContain("provider_accepted");
    expect(plist).toContain("recorrido_customer_delivery_worker.py");
    expect(plist).toContain("cloudflare-generation.env");
    expect(plist).not.toContain("LOCAL_WORKER_TOKEN=");
    expect(installer).toContain("installed but disabled");
    expect(installer).toContain("install -m 700");
    expect(installer).toContain("install -m 600");
  });
});
