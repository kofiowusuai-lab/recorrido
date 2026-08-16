export type EnvironmentName = "staging" | "production";

export interface Env {
  ENVIRONMENT: string;
  RELEASE: string;
  INGRESS_API_TOKEN?: string;
  LOCAL_WORKER_TOKEN?: string;
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  ALERT_WEBHOOK_URL?: string;
  INPUTS: R2Bucket;
  OUTPUTS: R2Bucket;
  TEMP: R2Bucket;
  GENERATION_QUEUE: Queue<GenerationMessage>;
}

interface GenerationMessage {
  version: 1;
  environment: EnvironmentName;
  job_id: string;
  reservation_id: string;
  account_id: string;
  idempotency_key: string;
  input_manifest_key: string;
  manifest_sha256: string;
  output_format: "9:16" | "16:9";
  source_listing_id: string;
}

interface IngressBody {
  account_id: string;
  member_id: string;
  idempotency_key: string;
  input_manifest_key: string;
}

type DispatchStatus = "pending" | "dispatching" | "enqueued" | "delivered" | "dead";
type LeaseFence = { environment: EnvironmentName; workerId: string; leaseToken: string; leaseVersion: number };
type DeliveryFence = { environment: EnvironmentName; workerId: string; claimToken: string; attempt: number };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const WORKER_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const IDEMPOTENCY = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const KEY_SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const SHA256 = /^[a-f0-9]{64}$/;
const SOURCE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const PROVIDER_ID = /^[A-Za-z0-9._:@/-]{1,255}$/;
const MAX_INPUT_OBJECT_BYTES = 25_000_000;
const MAX_MANIFEST_BYTES = 1_000_000;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const OUTPUT_PART_BYTES = 512 * 1024;
const MAX_OUTPUT_PARTS = MAX_OUTPUT_BYTES / OUTPUT_PART_BYTES;
const SAFE_LOG_FIELDS = new Set(["job_id", "account_id", "reservation_id", "error_code", "attempt", "environment", "release"]);
const INPUT_CONTENT_TYPES = new Set(["application/json", "image/jpeg", "image/png", "image/webp", "video/mp4", "application/zip", "application/octet-stream"]);

export function safeLog(event: string, values: Record<string, unknown> = {}): Record<string, unknown> {
  const output: Record<string, unknown> = { event };
  for (const [key, value] of Object.entries(values)) {
    if (SAFE_LOG_FIELDS.has(key) && (typeof value === "string" || typeof value === "number" || typeof value === "boolean")) output[key] = value;
  }
  return output;
}

function log(event: string, values: Record<string, unknown> = {}) {
  console.log(JSON.stringify(safeLog(event, values)));
}

function json(value: unknown, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

function environmentName(env: Env): EnvironmentName | null {
  return env.ENVIRONMENT === "staging" || env.ENVIRONMENT === "production" ? env.ENVIRONMENT : null;
}

function constantTimeEqual(left: string, right: string): boolean {
  const size = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < size; index += 1) difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  return difference === 0;
}

function authorized(request: Request, secret?: string): boolean {
  if (!secret) return false;
  const header = request.headers.get("authorization") || "";
  return header.startsWith("Bearer ") && constantTimeEqual(header.slice(7), secret);
}

function authorityReady(env: Env): env is Env & { SUPABASE_URL: string; SUPABASE_SERVICE_ROLE_KEY: string } {
  return Boolean(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY);
}

async function rpc<T>(env: Env, name: string, body: Record<string, unknown>): Promise<T> {
  if (!authorityReady(env)) throw new Error("authority_unavailable");
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const error = new Error(`authority_${response.status}`);
    Object.assign(error, { status: response.status });
    throw error;
  }
  return response.json() as Promise<T>;
}

function authorityStatus(error: unknown): number | undefined {
  return typeof error === "object" && error !== null && "status" in error && typeof error.status === "number" ? error.status : undefined;
}

function leaseError(error: unknown): Response {
  const status = authorityStatus(error);
  if (status === 400 || status === 404 || status === 409) return json({ error: "lease_conflict" }, 409);
  return json({ error: "authority_unavailable" }, 503);
}

async function parseObject(request: Request): Promise<Record<string, unknown> | null> {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) return null;
  try {
    const value = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

function ingressBody(value: Record<string, unknown> | null): IngressBody | null {
  if (!value) return null;
  const { account_id, member_id, idempotency_key, input_manifest_key } = value;
  if (typeof account_id !== "string" || !UUID.test(account_id)) return null;
  if (typeof member_id !== "string" || !UUID.test(member_id)) return null;
  if (typeof idempotency_key !== "string" || !IDEMPOTENCY.test(idempotency_key)) return null;
  if (typeof input_manifest_key !== "string" || input_manifest_key !== `accounts/${account_id}/jobs/${idempotency_key}/manifest.json`) return null;
  return { account_id, member_id, idempotency_key, input_manifest_key };
}

function dispatchStatus(value: unknown): DispatchStatus | null {
  return value === "pending" || value === "dispatching" || value === "enqueued" || value === "delivered" || value === "dead" ? value : null;
}

function parseInputKey(key: string): { accountId: string; idempotencyKey: string; manifest: boolean } | null {
  if (!key || key.length > 512 || key.includes("\\") || key.includes("//")) return null;
  const parts = key.split("/");
  if (parts.some((part) => part === "" || part === "." || part === ".." || part.startsWith(".") || !KEY_SEGMENT.test(part))) return null;
  if (parts[0] !== "accounts" || !UUID.test(parts[1] || "") || parts[2] !== "jobs" || !IDEMPOTENCY.test(parts[3] || "")) return null;
  if (parts.length === 5 && parts[4] === "manifest.json") return { accountId: parts[1], idempotencyKey: parts[3], manifest: true };
  if (parts.length >= 6 && parts[4] === "assets") return { accountId: parts[1], idempotencyKey: parts[3], manifest: false };
  return null;
}

function validObjectLength(request: Request, maximum: number): boolean {
  const raw = request.headers.get("content-length");
  if (raw === null) return request.body !== null;
  const length = Number(raw);
  return Number.isInteger(length) && length > 0 && length <= maximum;
}

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

async function createJob(request: Request, env: Env): Promise<Response> {
  if (!authorized(request, env.INGRESS_API_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  const body = ingressBody(await parseObject(request));
  if (!body) return json({ error: "invalid_request" }, 422);
  const manifest = await env.INPUTS.get(body.input_manifest_key);
  if (!manifest) return json({ error: "input_manifest_missing" }, 422);
  if (manifest.size > MAX_MANIFEST_BYTES) return json({ error: "invalid_manifest" }, 422);
  const manifestBytes = await manifest.arrayBuffer();
  const computedManifestSha256 = hex(await crypto.subtle.digest("SHA-256", manifestBytes));
  const manifestSha256 = manifest.customMetadata?.sha256;
  if (!manifestSha256 || !SHA256.test(manifestSha256)) return json({ error: "manifest_digest_missing" }, 422);
  if (computedManifestSha256 !== manifestSha256) return json({ error: "manifest_digest_mismatch" }, 422);
  let manifestDocument: Record<string, unknown>;
  try {
    const parsed = JSON.parse(new TextDecoder().decode(manifestBytes));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid");
    manifestDocument = parsed as Record<string, unknown>;
  } catch {
    return json({ error: "invalid_manifest" }, 422);
  }
  const outputFormat = manifestDocument.output_format;
  const sourceListingId = manifestDocument.source_listing_id;
  if ((outputFormat !== "9:16" && outputFormat !== "16:9") || typeof sourceListingId !== "string" || !SOURCE_ID.test(sourceListingId)) return json({ error: "delivery_binding_missing" }, 422);

  type Prepared = { allowed: boolean; job_id: string; reservation_id?: string | null; status: string; dispatch_status?: string; reason?: string };
  let prepared: Prepared;
  try {
    prepared = await rpc<Prepared>(env, "recorrido_prepare_generation_dispatch", {
      p_account_id: body.account_id,
      p_member_id: body.member_id,
      p_idempotency_key: body.idempotency_key,
      p_input_manifest_key: body.input_manifest_key,
      p_manifest_sha256: manifestSha256,
      p_environment: environment,
      p_output_format: outputFormat,
      p_source_listing_id: sourceListingId,
    });
  } catch (error) {
    log("generation_prepare_failed", { account_id: body.account_id, environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return json({ error: "authority_unavailable" }, 503);
  }
  if (!prepared.allowed || !prepared.reservation_id) {
    return json({ allowed: false, job_id: prepared.job_id, status: prepared.status, reason: prepared.reason || "denied" }, 403);
  }
  const state = dispatchStatus(prepared.dispatch_status);
  if (!state) return json({ error: "invalid_dispatch_state", job_id: prepared.job_id }, 503);
  if (state === "dead") return json({ error: "dispatch_dead", allowed: true, job_id: prepared.job_id, status: prepared.status, dispatch_status: state, dispatched: false }, 409);
  return json({ allowed: true, job_id: prepared.job_id, status: prepared.status, dispatch_status: state, dispatched: state === "enqueued" || state === "delivered" }, state === "pending" ? 202 : 200);
}

function leaseFence(value: Record<string, unknown> | null, environment: EnvironmentName): LeaseFence | null {
  if (!value) return null;
  const workerId = value.worker_id;
  const leaseToken = value.lease_token;
  const leaseVersion = value.lease_version;
  if (value.environment !== environment || typeof workerId !== "string" || !WORKER_ID.test(workerId) || typeof leaseToken !== "string" || !UUID.test(leaseToken) || typeof leaseVersion !== "number" || !Number.isSafeInteger(leaseVersion) || leaseVersion < 1) return null;
  return { environment, workerId, leaseToken, leaseVersion };
}

async function claimLease(request: Request, env: Env): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  const body = await parseObject(request);
  const workerId = body?.worker_id;
  if (typeof workerId !== "string" || !WORKER_ID.test(workerId)) return json({ error: "invalid_request" }, 422);
  try {
    return json(await rpc(env, "recorrido_claim_generation_job", { p_environment: environment, p_worker_id: workerId, p_lease_seconds: 900 }), 200);
  } catch (error) {
    log("generation_claim_failed", { environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return json({ error: "authority_unavailable" }, 503);
  }
}

async function heartbeatJob(request: Request, env: Env, jobId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  if (!UUID.test(jobId)) return json({ error: "invalid_job" }, 404);
  const fence = leaseFence(await parseObject(request), environment);
  if (!fence) return json({ error: "invalid_request" }, 422);
  try {
    return json(await rpc(env, "recorrido_heartbeat_generation_job", {
      p_job_id: jobId, p_environment: environment, p_worker_id: fence.workerId,
      p_lease_token: fence.leaseToken, p_lease_version: fence.leaseVersion, p_lease_seconds: 900,
    }));
  } catch (error) {
    log("generation_heartbeat_failed", { job_id: jobId, environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return leaseError(error);
  }
}

function deliveryFence(value: Record<string, unknown> | null, environment: EnvironmentName): DeliveryFence | null {
  if (!value) return null;
  const workerId = value.worker_id;
  const claimToken = value.claim_token;
  const attempt = value.attempt;
  if (value.environment !== environment || typeof workerId !== "string" || !WORKER_ID.test(workerId)
      || typeof claimToken !== "string" || !UUID.test(claimToken)
      || typeof attempt !== "number" || !Number.isSafeInteger(attempt) || attempt < 1) return null;
  return { environment, workerId, claimToken, attempt };
}

function deliveryRpcBody(deliveryId: string, fence: DeliveryFence): Record<string, unknown> {
  return { p_delivery_id: deliveryId, p_environment: fence.environment, p_worker_id: fence.workerId,
    p_claim_token: fence.claimToken, p_attempt: fence.attempt };
}

async function claimDelivery(request: Request, env: Env): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  const body = await parseObject(request);
  if (!body || Object.keys(body).length !== 1 || typeof body.worker_id !== "string" || !WORKER_ID.test(body.worker_id)) return json({ error: "invalid_request" }, 422);
  try { return json(await rpc(env, "recorrido_claim_customer_delivery", { p_environment: environment, p_worker_id: body.worker_id })); }
  catch (error) {
    log("customer_delivery_claim_failed", { environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return json({ error: "authority_unavailable" }, 503);
  }
}

async function heartbeatDelivery(request: Request, env: Env, deliveryId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env) || !UUID.test(deliveryId)) return json({ error: "invalid_request" }, 422);
  const fence = deliveryFence(await parseObject(request), environment);
  if (!fence) return json({ error: "invalid_request" }, 422);
  try { return json(await rpc(env, "recorrido_heartbeat_customer_delivery", deliveryRpcBody(deliveryId, fence))); }
  catch (error) { return leaseError(error); }
}

async function getDeliveryMedia(request: Request, env: Env, deliveryId: string, url: URL): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env) || !UUID.test(deliveryId)) return json({ error: "invalid_request" }, 422);
  const fence = deliveryFence({ environment: url.searchParams.get("environment"), worker_id: url.searchParams.get("worker_id"),
    claim_token: url.searchParams.get("claim_token"), attempt: Number(url.searchParams.get("attempt")) }, environment);
  if (!fence) return json({ error: "invalid_request" }, 422);
  try {
    const binding = await rpc<{ authorized?: boolean; output_object_key?: string; output_sha256?: string }>(env, "recorrido_assert_customer_delivery_media", deliveryRpcBody(deliveryId, fence));
    if (!binding.authorized || typeof binding.output_object_key !== "string" || typeof binding.output_sha256 !== "string" || !SHA256.test(binding.output_sha256)) return json({ error: "invalid_delivery_binding" }, 503);
    const object = await env.OUTPUTS.get(binding.output_object_key);
    if (!object || object.customMetadata?.sha256 !== binding.output_sha256 || object.size <= 0 || object.size > MAX_OUTPUT_BYTES) return json({ error: "delivery_media_unavailable" }, 503);
    return new Response(object.body, { status: 200, headers: { "content-type": "video/mp4", "content-length": String(object.size),
      "x-content-sha256": binding.output_sha256, "cache-control": "no-store", "content-disposition": "attachment; filename=recorrido.mp4" } });
  } catch (error) { return leaseError(error); }
}

async function checkpointDelivery(request: Request, env: Env, deliveryId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env) || !UUID.test(deliveryId)) return json({ error: "invalid_request" }, 422);
  const body = await parseObject(request); const fence = deliveryFence(body, environment); const phase = body?.phase;
  if (!fence || (phase !== "media" && phase !== "notice")) return json({ error: "invalid_request" }, 422);
  try { return json(await rpc(env, "recorrido_checkpoint_customer_delivery", { ...deliveryRpcBody(deliveryId, fence), p_phase: phase })); }
  catch (error) { return leaseError(error); }
}

async function acceptDelivery(request: Request, env: Env, deliveryId: string, phase: "media" | "notice"): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env) || !UUID.test(deliveryId)) return json({ error: "invalid_request" }, 422);
  const body = await parseObject(request); const fence = deliveryFence(body, environment); const providerId = body?.provider_message_id;
  if (!fence || typeof providerId !== "string" || !PROVIDER_ID.test(providerId)) return json({ error: "invalid_request" }, 422);
  try {
    const name = phase === "media" ? "recorrido_accept_customer_delivery_media" : "recorrido_accept_customer_delivery_notice";
    return json(await rpc(env, name, { ...deliveryRpcBody(deliveryId, fence), p_provider_message_id: providerId }));
  } catch (error) { return leaseError(error); }
}

async function abandonDelivery(request: Request, env: Env, deliveryId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env) || !UUID.test(deliveryId)) return json({ error: "invalid_request" }, 422);
  const body = await parseObject(request); const fence = deliveryFence(body, environment); const errorCode = body?.error_code;
  if (!fence || typeof errorCode !== "string" || !/^[A-Za-z0-9_.:-]{1,80}$/.test(errorCode)) return json({ error: "invalid_request" }, 422);
  try { return json(await rpc(env, "recorrido_abandon_customer_delivery_claim", { ...deliveryRpcBody(deliveryId, fence), p_error_code: errorCode })); }
  catch (error) { return leaseError(error); }
}

async function putInput(request: Request, env: Env, url: URL): Promise<Response> {
  if (!authorized(request, env.INGRESS_API_TOKEN)) return json({ error: "unauthorized" }, 401);
  const key = url.searchParams.get("key") || "";
  const parsed = parseInputKey(key);
  const maximum = parsed?.manifest ? MAX_MANIFEST_BYTES : MAX_INPUT_OBJECT_BYTES;
  if (!parsed || !validObjectLength(request, maximum) || !request.body) return json({ error: "invalid_object" }, 422);
  const contentType = (request.headers.get("content-type") || "application/octet-stream").split(";", 1)[0].toLowerCase();
  if (!INPUT_CONTENT_TYPES.has(contentType) || (parsed.manifest && contentType !== "application/json")) return json({ error: "unsupported_media_type" }, 415);
  if (await env.INPUTS.head(key)) return json({ error: "immutable_object" }, 409);
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength === 0 || bytes.byteLength > maximum) return json({ error: "invalid_object" }, 422);
  const sha256 = hex(await crypto.subtle.digest("SHA-256", bytes));
  const stored = await env.INPUTS.put(key, bytes, {
    httpMetadata: { contentType }, customMetadata: { sha256 }, onlyIf: { etagDoesNotMatch: "*" },
  });
  if (!stored) return json({ error: "immutable_object" }, 409);
  return json({ stored: true, key, sha256 }, 201);
}

async function getInput(request: Request, env: Env, url: URL): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const key = url.searchParams.get("key") || "";
  if (!parseInputKey(key)) return json({ error: "invalid_object" }, 422);
  const object = await env.INPUTS.get(key);
  if (!object) return json({ error: "object_not_found" }, 404);
  const headers = new Headers({ "cache-control": "private, no-store" });
  object.writeHttpMetadata(headers);
  if (object.httpEtag) headers.set("etag", object.httpEtag);
  if (object.customMetadata?.sha256) headers.set("x-content-sha256", object.customMetadata.sha256);
  return new Response(object.body, { status: 200, headers });
}

async function putOutput(request: Request, env: Env, jobId: string, url: URL): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  const accountId = url.searchParams.get("account_id") || "";
  const workerId = url.searchParams.get("worker_id") || "";
  const leaseToken = url.searchParams.get("lease_token") || "";
  const leaseVersion = Number(url.searchParams.get("lease_version"));
  const requestEnvironment = url.searchParams.get("environment");
  const outputSha256 = request.headers.get("x-content-sha256") || "";
  if (!UUID.test(jobId) || !UUID.test(accountId) || requestEnvironment !== environment || !WORKER_ID.test(workerId) || !UUID.test(leaseToken) || !Number.isSafeInteger(leaseVersion) || leaseVersion < 1 || !SHA256.test(outputSha256) || !validObjectLength(request, MAX_OUTPUT_BYTES) || !request.body) return json({ error: "invalid_object" }, 422);
  if ((request.headers.get("content-type") || "").split(";", 1)[0].toLowerCase() !== "video/mp4") return json({ error: "unsupported_media_type" }, 415);
  const key = `accounts/${accountId}/jobs/${jobId}/leases/${leaseToken}/output.mp4`;
  try {
    await rpc(env, "recorrido_assert_generation_output_lease", {
      p_job_id: jobId, p_account_id: accountId, p_environment: environment, p_worker_id: workerId,
      p_lease_token: leaseToken, p_lease_version: leaseVersion, p_output_object_key: key, p_output_sha256: outputSha256,
    });
  } catch (error) {
    return leaseError(error);
  }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_OUTPUT_BYTES) return json({ error: "invalid_object" }, 422);
  const computedSha256 = hex(await crypto.subtle.digest("SHA-256", bytes));
  if (computedSha256 !== outputSha256) return json({ error: "output_digest_mismatch" }, 422);
  try {
    const stored = await env.OUTPUTS.put(key, new Blob([bytes]).stream(), {
      httpMetadata: { contentType: "video/mp4" }, customMetadata: { sha256: computedSha256 }, onlyIf: { etagDoesNotMatch: "*" },
    });
    if (!stored) {
      const existing = await env.OUTPUTS.head(key);
      if (!existing || existing.size !== bytes.byteLength || existing.customMetadata?.sha256 !== computedSha256) return json({ error: "immutable_object" }, 409);
      return json({ stored: false, replayed: true, key, sha256: outputSha256 }, 200);
    }
  } catch {
    log("generation_output_store_failed", { job_id: jobId, account_id: accountId, environment, error_code: "r2_unavailable" });
    return json({ error: "storage_unavailable" }, 503);
  }
  return json({ stored: true, key, sha256: outputSha256 }, 201);
}

async function putOutputPart(request: Request, env: Env, jobId: string, partNumber: number, url: URL): Promise<Response> {
  const environment = environmentName(env);
  if (!environment || !UUID.test(jobId) || !Number.isInteger(partNumber) || partNumber < 1 || partNumber > MAX_OUTPUT_PARTS) return json({ error: "invalid_request" }, 422);
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const accountId = url.searchParams.get("account_id") || "";
  const workerId = url.searchParams.get("worker_id") || "";
  const leaseToken = url.searchParams.get("lease_token") || "";
  const leaseVersion = Number(url.searchParams.get("lease_version"));
  const suppliedEnvironment = url.searchParams.get("environment");
  const outputSha256 = url.searchParams.get("output_sha256") || "";
  const partSha256 = request.headers.get("x-content-sha256") || "";
  if (suppliedEnvironment !== environment || !UUID.test(accountId) || !WORKER_ID.test(workerId) || !UUID.test(leaseToken) || !Number.isInteger(leaseVersion) || leaseVersion < 1 || !SHA256.test(outputSha256) || !SHA256.test(partSha256)) return json({ error: "invalid_request" }, 422);
  const finalKey = `accounts/${accountId}/jobs/${jobId}/leases/${leaseToken}/output.mp4`;
  try {
    await rpc(env, "recorrido_assert_generation_output_lease", { p_job_id: jobId, p_account_id: accountId, p_environment: environment, p_worker_id: workerId, p_lease_token: leaseToken, p_lease_version: leaseVersion, p_output_object_key: finalKey, p_output_sha256: outputSha256 });
  } catch (error) { return leaseError(error); }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength === 0 || bytes.byteLength > OUTPUT_PART_BYTES) return json({ error: "invalid_object" }, 422);
  const computed = hex(await crypto.subtle.digest("SHA-256", bytes));
  if (computed !== partSha256) return json({ error: "output_digest_mismatch" }, 422);
  const key = `accounts/${accountId}/jobs/${jobId}/leases/${leaseToken}/output-parts/${outputSha256}/${partNumber}.bin`;
  try {
    const stored = await env.TEMP.put(key, bytes, { customMetadata: { sha256: computed, size: String(bytes.byteLength) }, onlyIf: { etagDoesNotMatch: "*" } });
    if (!stored) {
      const existing = await env.TEMP.head(key);
      if (!existing || existing.size !== bytes.byteLength || existing.customMetadata?.sha256 !== computed) return json({ error: "immutable_object" }, 409);
      return json({ stored: false, replayed: true, part_number: partNumber }, 200);
    }
    return json({ stored: true, part_number: partNumber }, 201);
  } catch {
    return json({ error: "storage_unavailable" }, 503);
  }
}

async function finalizeOutput(request: Request, env: Env, jobId: string): Promise<Response> {
  const environment = environmentName(env);
  if (!environment || !UUID.test(jobId)) return json({ error: "invalid_request" }, 422);
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const body = await parseObject(request);
  const fence = leaseFence(body, environment);
  const accountId = body?.account_id;
  const outputSha256 = body?.output_sha256;
  const partCount = body?.part_count;
  const totalSize = body?.total_size;
  if (!fence || typeof accountId !== "string" || !UUID.test(accountId) || typeof outputSha256 !== "string" || !SHA256.test(outputSha256) || typeof partCount !== "number" || !Number.isInteger(partCount) || partCount < 1 || partCount > MAX_OUTPUT_PARTS || typeof totalSize !== "number" || !Number.isInteger(totalSize) || totalSize < 1 || totalSize > MAX_OUTPUT_BYTES) return json({ error: "invalid_request" }, 422);
  const finalKey = `accounts/${accountId}/jobs/${jobId}/leases/${fence.leaseToken}/output.mp4`;
  try {
    await rpc(env, "recorrido_assert_generation_output_lease", { p_job_id: jobId, p_account_id: accountId, p_environment: environment, p_worker_id: fence.workerId, p_lease_token: fence.leaseToken, p_lease_version: fence.leaseVersion, p_output_object_key: finalKey, p_output_sha256: outputSha256 });
  } catch (error) { return leaseError(error); }
  const assembled = new Uint8Array(totalSize);
  let offset = 0;
  const partKeys: string[] = [];
  try {
    for (let part = 1; part <= partCount; part += 1) {
      const key = `accounts/${accountId}/jobs/${jobId}/leases/${fence.leaseToken}/output-parts/${outputSha256}/${part}.bin`;
      const object = await env.TEMP.get(key);
      if (!object) return json({ error: "missing_output_part" }, 409);
      const bytes = new Uint8Array(await object.arrayBuffer());
      const computed = hex(await crypto.subtle.digest("SHA-256", bytes));
      if (computed !== object.customMetadata?.sha256 || offset + bytes.byteLength > totalSize) return json({ error: "invalid_output_part" }, 409);
      assembled.set(bytes, offset); offset += bytes.byteLength; partKeys.push(key);
    }
    if (offset !== totalSize) return json({ error: "invalid_output_size" }, 409);
    const computed = hex(await crypto.subtle.digest("SHA-256", assembled));
    if (computed !== outputSha256) return json({ error: "output_digest_mismatch" }, 422);
    const existing = await env.OUTPUTS.head(finalKey);
    if (existing) {
      if (existing.size !== assembled.byteLength || existing.customMetadata?.sha256 !== computed) return json({ error: "immutable_object" }, 409);
      await Promise.all(partKeys.map((key) => env.TEMP.delete(key)));
      return json({ stored: false, replayed: true, key: finalKey, sha256: computed }, 200);
    }
    const upload = await env.OUTPUTS.createMultipartUpload(finalKey, { httpMetadata: { contentType: "video/mp4" }, customMetadata: { sha256: computed } });
    try {
      const part = await upload.uploadPart(1, assembled);
      await upload.complete([part]);
    } catch (error) {
      await upload.abort().catch(() => undefined);
      throw error;
    }
    await Promise.all(partKeys.map((key) => env.TEMP.delete(key)));
    return json({ stored: true, key: finalKey, sha256: computed }, 201);
  } catch {
    return json({ error: "storage_unavailable" }, 503);
  }
}

async function completeJob(request: Request, env: Env, jobId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  if (!UUID.test(jobId)) return json({ error: "invalid_job" }, 404);
  const body = await parseObject(request);
  const fence = leaseFence(body, environment);
  const reservationId = body?.reservation_id;
  const accountId = body?.account_id;
  const outputKey = body?.output_object_key;
  const outputSha256 = body?.output_sha256;
  const duration = body?.duration_seconds;
  const expectedKey = `accounts/${accountId}/jobs/${jobId}/leases/${fence?.leaseToken}/output.mp4`;
  if (!fence || typeof reservationId !== "string" || !UUID.test(reservationId) || typeof accountId !== "string" || !UUID.test(accountId) || typeof outputKey !== "string" || outputKey !== expectedKey || typeof outputSha256 !== "string" || !SHA256.test(outputSha256) || typeof duration !== "number" || !Number.isInteger(duration) || duration <= 0) return json({ error: "invalid_request" }, 422);
  const output = await env.OUTPUTS.head(outputKey);
  if (!output) return json({ error: "output_missing" }, 422);
  if (output.size <= 0 || output.size > MAX_OUTPUT_BYTES || output.customMetadata?.sha256 !== outputSha256) return json({ error: "output_digest_mismatch" }, 422);
  try {
    const result = await rpc(env, "recorrido_complete_generation_dispatch", {
      p_job_id: jobId, p_reservation_id: reservationId, p_environment: environment,
      p_worker_id: fence.workerId, p_lease_token: fence.leaseToken, p_lease_version: fence.leaseVersion,
      p_output_object_key: outputKey, p_output_sha256: outputSha256, p_duration_seconds: duration,
    });
    log("generation_completed", { job_id: jobId, account_id: accountId, environment });
    return json(result, 200);
  } catch (error) {
    log("generation_completion_failed", { job_id: jobId, account_id: accountId, environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return leaseError(error);
  }
}

async function failJob(request: Request, env: Env, jobId: string): Promise<Response> {
  if (!authorized(request, env.LOCAL_WORKER_TOKEN)) return json({ error: "unauthorized" }, 401);
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) return json({ error: "authority_unavailable" }, 503);
  if (!UUID.test(jobId)) return json({ error: "invalid_job" }, 404);
  const body = await parseObject(request);
  const fence = leaseFence(body, environment);
  const reservationId = body?.reservation_id;
  const errorCode = body?.error_code;
  if (!fence || typeof reservationId !== "string" || !UUID.test(reservationId) || typeof errorCode !== "string" || !/^[A-Za-z0-9_.:-]{1,80}$/.test(errorCode)) return json({ error: "invalid_request" }, 422);
  try {
    const result = await rpc(env, "recorrido_release_generation_dispatch", {
      p_job_id: jobId, p_reservation_id: reservationId, p_environment: environment,
      p_worker_id: fence.workerId, p_lease_token: fence.leaseToken, p_lease_version: fence.leaseVersion, p_error_code: errorCode,
    });
    log("generation_released", { job_id: jobId, reservation_id: reservationId, environment, error_code: errorCode });
    return json(result, 200);
  } catch (error) {
    log("generation_release_failed", { job_id: jobId, environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return leaseError(error);
  }
}

function validMessage(body: GenerationMessage | undefined, environment: EnvironmentName): body is GenerationMessage {
  return Boolean(body && body.version === 1 && body.environment === environment && UUID.test(body.job_id) && UUID.test(body.account_id) && UUID.test(body.reservation_id) && IDEMPOTENCY.test(body.idempotency_key) && SHA256.test(body.manifest_sha256) && (body.output_format === "9:16" || body.output_format === "16:9") && SOURCE_ID.test(body.source_listing_id) && body.input_manifest_key === `accounts/${body.account_id}/jobs/${body.idempotency_key}/manifest.json`);
}

function messageBinding(body: GenerationMessage): Record<string, unknown> {
  return {
    p_job_id: body.job_id,
    p_reservation_id: body.reservation_id,
    p_account_id: body.account_id,
    p_environment: body.environment,
    p_idempotency_key: body.idempotency_key,
    p_input_manifest_key: body.input_manifest_key,
    p_manifest_sha256: body.manifest_sha256,
  };
}

async function alert(env: Env, event: string, errorCode: string): Promise<void> {
  if (!env.ALERT_WEBHOOK_URL) return;
  try {
    await fetch(env.ALERT_WEBHOOK_URL, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ event, environment: env.ENVIRONMENT, release: env.RELEASE, error_code: errorCode }),
    });
  } catch {
    log("generation_alert_failed", { environment: env.ENVIRONMENT, release: env.RELEASE, error_code: "alert_delivery_failed" });
  }
}

async function terminalize(env: Env, body: GenerationMessage, errorCode: string): Promise<void> {
  const result = await rpc<{ dispatch_status?: string }>(env, "recorrido_terminalize_generation_dispatch", {
    ...messageBinding(body), p_error_code: errorCode,
  });
  if (dispatchStatus(result.dispatch_status) !== "dead") throw new Error("invalid_dispatch_state");
  await alert(env, "generation_dispatch_dead", errorCode);
}

export async function handleQueue(batch: MessageBatch<GenerationMessage>, env: Env): Promise<void> {
  const environment = environmentName(env);
  const isDlq = batch.queue.endsWith("-dlq") || batch.queue.includes("-dlq-");
  for (const message of batch.messages) {
    if (!environment || !validMessage(message.body, environment)) {
      log("generation_message_invalid", { attempt: message.attempts, environment: env.ENVIRONMENT, error_code: "invalid_message" });
      message.ack();
      continue;
    }
    const body = message.body;
    try {
      if (isDlq) {
        await terminalize(env, body, "queue_dlq");
        log("generation_queue_dead", { job_id: body.job_id, account_id: body.account_id, attempt: message.attempts, environment, error_code: "queue_dlq" });
      } else {
        const result = await rpc<{ dispatch_status?: string }>(env, "recorrido_mark_generation_queue_delivered", messageBinding(body));
        if (dispatchStatus(result.dispatch_status) !== "delivered") throw new Error("invalid_dispatch_state");
        log("generation_queue_delivered", { job_id: body.job_id, account_id: body.account_id, attempt: message.attempts, environment });
      }
      message.ack();
    } catch (error) {
      log(isDlq ? "generation_dlq_retry" : "generation_queue_retry", { attempt: message.attempts, environment, error_code: error instanceof Error ? error.message : "authority_error" });
      message.retry();
    }
  }
}

export async function handleScheduled(env: Env): Promise<void> {
  const environment = environmentName(env);
  if (!environment || !authorityReady(env)) {
    log("generation_cron_skipped", { environment: env.ENVIRONMENT, error_code: "authority_unavailable" });
    return;
  }
  type Dispatch = { job_id: string; message: GenerationMessage; attempts: number; dispatch_status: string };
  let rows: Dispatch[];
  try {
    rows = await rpc<Dispatch[]>(env, "recorrido_claim_generation_dispatches", { p_environment: environment, p_limit: 20 });
  } catch (error) {
    log("generation_cron_claim_failed", { environment, error_code: error instanceof Error ? error.message : "authority_error" });
    return;
  }
  for (const row of rows || []) {
    const state = dispatchStatus(row.dispatch_status);
    if (state === "dead") {
      try {
        await terminalize(env, row.message, "dispatch_attempts_exhausted");
        log("generation_cron_dead", { job_id: row.job_id, attempt: row.attempts, environment, error_code: "dispatch_attempts_exhausted" });
      } catch (error) {
        log("generation_cron_terminalize_failed", { job_id: row.job_id, attempt: row.attempts, environment, error_code: error instanceof Error ? error.message : "authority_error" });
      }
      continue;
    }
    if (state !== "dispatching") {
      log("generation_cron_invalid_state", { job_id: row.job_id, attempt: row.attempts, environment, error_code: "invalid_dispatch_state" });
      continue;
    }
    try {
      if (!validMessage(row.message, environment)) throw new Error("invalid_message");
      await env.GENERATION_QUEUE.send(row.message);
      const marked = await rpc<{ dispatch_status?: string }>(env, "recorrido_mark_generation_dispatched", { p_job_id: row.job_id, p_environment: environment, p_attempt: row.attempts });
      if (dispatchStatus(marked.dispatch_status) !== "enqueued") throw new Error("invalid_dispatch_state");
      log("generation_cron_dispatched", { job_id: row.job_id, attempt: row.attempts, environment });
    } catch (error) {
      const errorCode = error instanceof Error ? error.message : "dispatch_error";
      try {
        await rpc(env, "recorrido_mark_generation_dispatch_failed", { p_job_id: row.job_id, p_environment: environment, p_attempt: row.attempts, p_error_code: errorCode });
      } catch {
        log("generation_cron_recovery_failed", { job_id: row.job_id, environment, error_code: "authority_error" });
      }
      log("generation_cron_dispatch_failed", { job_id: row.job_id, attempt: row.attempts, environment, error_code: errorCode });
    }
  }
}

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/health") return json({ ok: true, environment: env.ENVIRONMENT, release: env.RELEASE, database: "supabase", storage: "r2", queue: "cloudflare-queues" });
  if (url.pathname === "/v1/objects/input" && request.method === "PUT") return putInput(request, env, url);
  if (url.pathname === "/v1/objects/input" && request.method === "GET") return getInput(request, env, url);
  if (request.method === "POST" && url.pathname === "/v1/jobs") return createJob(request, env);
  if (request.method === "POST" && url.pathname === "/v1/leases/next") return claimLease(request, env);
  if (request.method === "POST" && url.pathname === "/v1/deliveries/next") return claimDelivery(request, env);
  const deliveryHeartbeat = /^\/v1\/deliveries\/([0-9a-f-]+)\/heartbeat$/i.exec(url.pathname);
  if (request.method === "POST" && deliveryHeartbeat) return heartbeatDelivery(request, env, deliveryHeartbeat[1]);
  const deliveryMedia = /^\/v1\/deliveries\/([0-9a-f-]+)\/media$/i.exec(url.pathname);
  if (request.method === "GET" && deliveryMedia) return getDeliveryMedia(request, env, deliveryMedia[1], url);
  const deliveryCheckpoint = /^\/v1\/deliveries\/([0-9a-f-]+)\/checkpoint$/i.exec(url.pathname);
  if (request.method === "POST" && deliveryCheckpoint) return checkpointDelivery(request, env, deliveryCheckpoint[1]);
  const deliveryMediaAccepted = /^\/v1\/deliveries\/([0-9a-f-]+)\/media-accepted$/i.exec(url.pathname);
  if (request.method === "POST" && deliveryMediaAccepted) return acceptDelivery(request, env, deliveryMediaAccepted[1], "media");
  const deliveryNoticeAccepted = /^\/v1\/deliveries\/([0-9a-f-]+)\/notice-accepted$/i.exec(url.pathname);
  if (request.method === "POST" && deliveryNoticeAccepted) return acceptDelivery(request, env, deliveryNoticeAccepted[1], "notice");
  const deliveryAbandon = /^\/v1\/deliveries\/([0-9a-f-]+)\/abandon$/i.exec(url.pathname);
  if (request.method === "POST" && deliveryAbandon) return abandonDelivery(request, env, deliveryAbandon[1]);
  const heartbeat = /^\/v1\/jobs\/([0-9a-f-]+)\/heartbeat$/i.exec(url.pathname);
  if (request.method === "POST" && heartbeat) return heartbeatJob(request, env, heartbeat[1]);
  const outputPart = /^\/v1\/jobs\/([0-9a-f-]+)\/output-parts\/(\d+)$/i.exec(url.pathname);
  if (request.method === "PUT" && outputPart) return putOutputPart(request, env, outputPart[1], Number(outputPart[2]), url);
  const outputFinalize = /^\/v1\/jobs\/([0-9a-f-]+)\/output-finalize$/i.exec(url.pathname);
  if (request.method === "POST" && outputFinalize) return finalizeOutput(request, env, outputFinalize[1]);
  const output = /^\/v1\/jobs\/([0-9a-f-]+)\/output$/i.exec(url.pathname);
  if (request.method === "PUT" && output) return putOutput(request, env, output[1], url);
  const failure = /^\/v1\/jobs\/([0-9a-f-]+)\/fail$/i.exec(url.pathname);
  if (request.method === "POST" && failure) return failJob(request, env, failure[1]);
  const completion = /^\/v1\/jobs\/([0-9a-f-]+)\/complete$/i.exec(url.pathname);
  if (request.method === "POST" && completion) return completeJob(request, env, completion[1]);
  return json({ error: "not_found" }, 404);
}

export default {
  fetch: handleRequest,
  queue: handleQueue,
  scheduled: (_controller: ScheduledController, env: Env) => handleScheduled(env),
} satisfies ExportedHandler<Env, GenerationMessage>;
