import { beforeEach, describe, expect, it, vi } from "vitest";
import worker, { handleQueue, handleScheduled, safeLog, type Env } from "../src/index";

type StoredObject = { bytes: Uint8Array; customMetadata?: Record<string, string>; contentType?: string };

class MemoryR2 {
  objects = new Map<string, StoredObject>();
  async head(key: string) {
    const value = this.objects.get(key);
    return value ? { key, size: value.bytes.length, customMetadata: value.customMetadata } : null;
  }
  async get(key: string) {
    const value = this.objects.get(key);
    if (!value) return null;
    const buffer = value.bytes.buffer.slice(value.bytes.byteOffset, value.bytes.byteOffset + value.bytes.byteLength) as ArrayBuffer;
    return {
      key,
      size: value.bytes.length,
      body: new Blob([buffer]).stream(),
      arrayBuffer: async () => buffer,
      httpEtag: `\"${key}\"`,
      customMetadata: value.customMetadata,
      writeHttpMetadata: (headers: Headers) => headers.set("content-type", value.contentType || (key.endsWith(".json") ? "application/json" : "application/octet-stream")),
    };
  }
  async put(
    key: string,
    value: ReadableStream | ArrayBuffer | Uint8Array | string,
    options: { customMetadata?: Record<string, string>; httpMetadata?: { contentType?: string }; onlyIf?: { etagDoesNotMatch?: string } } = {},
  ) {
    if (options.onlyIf?.etagDoesNotMatch === "*" && this.objects.has(key)) return null;
    let bytes: Uint8Array;
    if (typeof value === "string") bytes = new TextEncoder().encode(value);
    else if (value instanceof Uint8Array) bytes = value;
    else if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
    else bytes = new Uint8Array(await new Response(value).arrayBuffer());
    this.objects.set(key, { bytes, customMetadata: options.customMetadata, contentType: options.httpMetadata?.contentType });
    return { key };
  }
  async delete(key: string) { this.objects.delete(key); }
  async createMultipartUpload(key: string, options: { customMetadata?: Record<string, string>; httpMetadata?: { contentType?: string } } = {}) {
    let partBytes: Uint8Array | null = null;
    return {
      uploadId: "mock-upload",
      key,
      uploadPart: async (partNumber: number, value: ArrayBuffer | Uint8Array) => {
        partBytes = value instanceof Uint8Array ? value : new Uint8Array(value);
        return { partNumber, etag: "mock-etag" };
      },
      complete: async () => {
        if (!partBytes) throw new Error("missing_part");
        this.objects.set(key, { bytes: partBytes, customMetadata: options.customMetadata, contentType: options.httpMetadata?.contentType });
        return { key };
      },
      abort: async () => undefined,
    };
  }
}

class MemoryQueue {
  sent: unknown[] = [];
  async send(value: unknown) { this.sent.push(value); }
}

const uuidA = "11111111-1111-4111-8111-111111111111";
const uuidM = "22222222-2222-4222-8222-222222222222";
const uuidJ = "33333333-3333-4333-8333-333333333333";
const uuidR = "44444444-4444-4444-8444-444444444444";
const leaseToken = "55555555-5555-4555-8555-555555555555";
const deliveryId = "66666666-6666-4666-8666-666666666666";
const leaseVersion = 7;
const manifestKey = `accounts/${uuidA}/jobs/idempotent-1/manifest.json`;
const manifestSha256 = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
const deliveryManifest = '{"output_format":"9:16","source_listing_id":"listing-001"}';
const deliveryManifestSha256 = "be6d8c27875aa74e8aff5d43bcc0785e20dbfe20da2e053e826273ee78a2cdef";
const generationMessage = {
  version: 1 as const,
  environment: "staging" as const,
  job_id: uuidJ,
  reservation_id: uuidR,
  account_id: uuidA,
  idempotency_key: "idempotent-1",
  input_manifest_key: manifestKey,
  manifest_sha256: manifestSha256,
  output_format: "9:16" as const,
  source_listing_id: "listing-001",
};

function env(overrides: Partial<Env> = {}): Env {
  return {
    ENVIRONMENT: "staging",
    RELEASE: "test-release",
    INGRESS_API_TOKEN: "ingress-secret",
    LOCAL_WORKER_TOKEN: "worker-secret",
    SUPABASE_URL: "https://example.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "service-secret",
    INPUTS: new MemoryR2() as unknown as R2Bucket,
    OUTPUTS: new MemoryR2() as unknown as R2Bucket,
    TEMP: new MemoryR2() as unknown as R2Bucket,
    GENERATION_QUEUE: new MemoryQueue() as unknown as Queue,
    ...overrides,
  };
}

function request(path: string, init: RequestInit = {}) {
  return new Request(`https://worker.example${path}`, init);
}

function auth(token: string, body?: unknown): RequestInit {
  return {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  };
}

function rpcResult(result: unknown, status = 200) {
  return new Response(JSON.stringify(result), { status, headers: { "content-type": "application/json" } });
}

function rpcBody(fetchSpy: { mock: { calls: unknown[][] } }, call = 0) {
  const init = fetchSpy.mock.calls[call][1] as RequestInit | undefined;
  return JSON.parse(String(init?.body));
}

beforeEach(() => vi.restoreAllMocks());

describe("health and privacy", () => {
  it("returns a privacy-safe health document without requiring auth", async () => {
    const response = await worker.fetch(request("/health"), env());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, environment: "staging", release: "test-release", database: "supabase", storage: "r2", queue: "cloudflare-queues" });
  });

  it("redacts payload, lease credentials, and secret-shaped fields from structured logs", () => {
    expect(safeLog("dispatch_failed", { job_id: uuidJ, worker_id: "renderer", lease_token: leaseToken, phone: "+155****4567", payload: { address: "private" }, token: "secret", error_code: "upstream_503" })).toEqual({
      event: "dispatch_failed", job_id: uuidJ, error_code: "upstream_503",
    });
  });
});

describe("immutable input and job ingress", () => {
  it("stores a manifest create-only with its computed SHA-256 metadata", async () => {
    const e = env();
    const response = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(manifestKey)}`, {
      method: "PUT",
      headers: { authorization: "Bearer ingress-secret", "content-type": "application/json", "content-length": "2" },
      body: "{}",
    }), e);
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ stored: true, key: manifestKey, sha256: manifestSha256 });
    expect((await e.INPUTS.head(manifestKey))?.customMetadata).toEqual({ sha256: manifestSha256 });
  });

  it("refuses an adversarial overwrite and preserves the original manifest digest", async () => {
    const e = env();
    const first = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(manifestKey)}`, {
      method: "PUT", headers: { authorization: "Bearer ingress-secret", "content-type": "application/json", "content-length": "2" }, body: "{}",
    }), e);
    const second = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(manifestKey)}`, {
      method: "PUT", headers: { authorization: "Bearer ingress-secret", "content-type": "application/json", "content-length": "13" }, body: "{\"evil\":true}",
    }), e);
    expect(first.status).toBe(201);
    expect(second.status).toBe(409);
    expect(await second.json()).toEqual({ error: "immutable_object" });
    expect((await e.INPUTS.head(manifestKey))?.customMetadata).toEqual({ sha256: manifestSha256 });
  });

  it("rejects dot-segment and cross-namespace input keys with a canonical parser", async () => {
    const e = env();
    for (const key of [
      `accounts/${uuidA}/jobs/idempotent-1/assets/../manifest.json`,
      `accounts/${uuidA}/jobs/idempotent-1/assets/.hidden/file.jpg`,
      `accounts/${uuidA}/jobs/idempotent-1/assets//file.jpg`,
    ]) {
      const response = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(key)}`, {
        method: "PUT", headers: { authorization: "Bearer ingress-secret", "content-type": "image/jpeg", "content-length": "1" }, body: "x",
      }), e);
      expect(response.status).toBe(422);
    }
    expect((e.INPUTS as unknown as MemoryR2).objects.size).toBe(0);
  });

  it("accepts video/mp4 assets but enforces the 25 MB per-input quota", async () => {
    const e = env();
    const key = `accounts/${uuidA}/jobs/idempotent-1/assets/source.mp4`;
    const ok = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(key)}`, {
      method: "PUT", headers: { authorization: "Bearer ingress-secret", "content-type": "video/mp4", "content-length": "3" }, body: "mp4",
    }), e);
    expect(ok.status).toBe(201);
    const tooLargeKey = `accounts/${uuidA}/jobs/idempotent-1/assets/large.mp4`;
    const tooLarge = await worker.fetch(request(`/v1/objects/input?key=${encodeURIComponent(tooLargeKey)}`, {
      method: "PUT", headers: { authorization: "Bearer ingress-secret", "content-type": "video/mp4", "content-length": "25000001" }, body: "x",
    }), e);
    expect(tooLarge.status).toBe(422);
  });

  it("requires the private R2 manifest before reserving a credit", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const response = await worker.fetch(request("/v1/jobs", auth("ingress-secret", { account_id: uuidA, member_id: uuidM, idempotency_key: "idempotent-1", input_manifest_key: manifestKey })), env());
    expect(response.status).toBe(422);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("prepares the authoritative outbox but never sends directly to Queue", async () => {
    const e = env();
    await e.INPUTS.put(manifestKey, deliveryManifest, { customMetadata: { sha256: deliveryManifestSha256 } });
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ allowed: true, job_id: uuidJ, reservation_id: uuidR, status: "queued", dispatch_status: "pending" }));
    const response = await worker.fetch(request("/v1/jobs", auth("ingress-secret", { account_id: uuidA, member_id: uuidM, idempotency_key: "idempotent-1", input_manifest_key: manifestKey })), e);
    expect(response.status).toBe(202);
    expect(rpcBody(fetchSpy)).toMatchObject({ p_manifest_sha256: deliveryManifestSha256, p_environment: "staging", p_output_format: "9:16", p_source_listing_id: "listing-001" });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect((e.GENERATION_QUEUE as unknown as MemoryQueue).sent).toEqual([]);
  });

  it.each(["dispatching", "enqueued", "delivered"])("does not re-enqueue a live idempotent replay in %s state", async (dispatchStatus) => {
    const e = env();
    await e.INPUTS.put(manifestKey, deliveryManifest, { customMetadata: { sha256: deliveryManifestSha256 } });
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ allowed: true, job_id: uuidJ, reservation_id: uuidR, status: "queued", dispatch_status: dispatchStatus }));
    const response = await worker.fetch(request("/v1/jobs", auth("ingress-secret", { account_id: uuidA, member_id: uuidM, idempotency_key: "idempotent-1", input_manifest_key: manifestKey })), e);
    expect(response.status).toBe(200);
    expect((e.GENERATION_QUEUE as unknown as MemoryQueue).sent).toHaveLength(0);
  });

  it("rejects dead replay instead of claiming it was dispatched", async () => {
    const e = env();
    await e.INPUTS.put(manifestKey, deliveryManifest, { customMetadata: { sha256: deliveryManifestSha256 } });
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ allowed: true, job_id: uuidJ, reservation_id: uuidR, status: "failed", dispatch_status: "dead" }));
    const response = await worker.fetch(request("/v1/jobs", auth("ingress-secret", { account_id: uuidA, member_id: uuidM, idempotency_key: "idempotent-1", input_manifest_key: manifestKey })), e);
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "dispatch_dead", dispatched: false });
  });
});

describe("lease-fenced local worker boundary", () => {
  it("returns the environment-scoped token and version claim contract", async () => {
    const claim = { ...generationMessage, lease_token: leaseToken, lease_version: leaseVersion, lease_expires_at: "2026-08-15T00:00:00Z" };
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult(claim));
    const response = await worker.fetch(request("/v1/leases/next", auth("worker-secret", { worker_id: "mac-render-01" })), env());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(claim);
    expect(rpcBody(fetchSpy)).toMatchObject({ p_environment: "staging" });
  });

  it("heartbeats with environment, worker identity, token, and monotonic version", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ status: "running", lease_expires_at: "later" }));
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/heartbeat`, auth("worker-secret", { environment: "staging", worker_id: "mac-render-01", lease_token: leaseToken, lease_version: leaseVersion })), env());
    expect(response.status).toBe(200);
    expect(String(fetchSpy.mock.calls[0][0])).toContain("recorrido_heartbeat_generation_job");
    expect(rpcBody(fetchSpy)).toEqual({ p_job_id: uuidJ, p_environment: "staging", p_worker_id: "mac-render-01", p_lease_token: leaseToken, p_lease_version: leaseVersion, p_lease_seconds: 900 });
  });

  it("asserts the full lease before immutable output upload and verifies hash on completion", async () => {
    const e = env();
    const outputKey = `accounts/${uuidA}/jobs/${uuidJ}/leases/${leaseToken}/output.mp4`;
    const outputSha = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ leased: true }))
      .mockResolvedValueOnce(rpcResult({ status: "consumed" }));
    const upload = await worker.fetch(request(`/v1/jobs/${uuidJ}/output?account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}`, {
      method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "content-length": "3", "x-content-sha256": outputSha }, body: new Uint8Array([1, 2, 3]),
    }), e);
    expect(upload.status).toBe(201);
    expect((await e.OUTPUTS.head(outputKey))?.customMetadata).toEqual({ sha256: outputSha });
    expect(rpcBody(fetchSpy, 0)).toMatchObject({ p_environment: "staging", p_lease_version: leaseVersion, p_output_sha256: outputSha });

    const completion = await worker.fetch(request(`/v1/jobs/${uuidJ}/complete`, auth("worker-secret", {
      reservation_id: uuidR, account_id: uuidA, environment: "staging", worker_id: "mac-render-01", lease_token: leaseToken, lease_version: leaseVersion,
      output_object_key: outputKey, output_sha256: outputSha, duration_seconds: 30,
    })), e);
    expect(completion.status).toBe(200);
    expect(rpcBody(fetchSpy, 1)).toMatchObject({ p_environment: "staging", p_lease_version: leaseVersion, p_output_sha256: outputSha });
  });

  it("replays an identical checksum-bound output but rejects conflicting bytes at the same lease key", async () => {
    const e = env();
    const path = `/v1/jobs/${uuidJ}/output?account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}`;
    const original = new Uint8Array([1, 2, 3]);
    const originalSha = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    const conflicting = new Uint8Array([3, 2, 1]);
    const conflictingSha = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", conflicting))).map((byte) => byte.toString(16).padStart(2, "0")).join("");
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ leased: true }))
      .mockResolvedValueOnce(rpcResult({ leased: true }))
      .mockResolvedValueOnce(rpcResult({ leased: true }));
    const upload = (bytes: Uint8Array, sha: string) => {
      const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      return worker.fetch(request(path, {
        method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "content-length": String(bytes.byteLength), "x-content-sha256": sha }, body,
      }), e);
    };

    const first = await upload(original, originalSha);
    const replay = await upload(original, originalSha);
    const conflict = await upload(conflicting, conflictingSha);

    expect(first.status).toBe(201);
    expect(replay.status).toBe(200);
    expect(await replay.json()).toMatchObject({ stored: false, replayed: true });
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "immutable_object" });
  });

  it("returns a retryable privacy-safe response when R2 output storage is unavailable", async () => {
    class UnavailableR2 extends MemoryR2 {
      async put(): Promise<never> { throw new Error("network details must not escape"); }
    }
    const e = env({ OUTPUTS: new UnavailableR2() as unknown as R2Bucket });
    const outputSha = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ leased: true }));
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/output?account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}`, {
      method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "content-length": "3", "x-content-sha256": outputSha }, body: new Uint8Array([1, 2, 3]),
    }), e);
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "storage_unavailable" });
  });

  it("assembles authenticated immutable output parts and verifies the full digest before final storage", async () => {
    const e = env();
    const chunks = [new Uint8Array([1, 2, 3]), new Uint8Array([4, 5, 6])];
    const full = new Uint8Array([1, 2, 3, 4, 5, 6]);
    const digest = async (bytes: Uint8Array) => {
      const source = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", source))).map((byte) => byte.toString(16).padStart(2, "0")).join("");
    };
    const outputSha = await digest(full);
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ leased: true }))
      .mockResolvedValueOnce(rpcResult({ leased: true }))
      .mockResolvedValueOnce(rpcResult({ leased: true }));
    for (let index = 0; index < chunks.length; index += 1) {
      const chunk = chunks[index];
      const body = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength) as ArrayBuffer;
      const query = `account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}&output_sha256=${outputSha}`;
      const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/output-parts/${index + 1}?${query}`, {
        method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "content-length": String(chunk.byteLength), "x-content-sha256": await digest(chunk) }, body,
      }), e);
      expect(response.status).toBe(201);
    }
    const finalized = await worker.fetch(request(`/v1/jobs/${uuidJ}/output-finalize`, auth("worker-secret", {
      account_id: uuidA, environment: "staging", worker_id: "mac-render-01", lease_token: leaseToken, lease_version: leaseVersion,
      output_sha256: outputSha, part_count: 2, total_size: full.byteLength,
    })), e);
    expect(finalized.status).toBe(201);
    const outputKey = `accounts/${uuidA}/jobs/${uuidJ}/leases/${leaseToken}/output.mp4`;
    expect(new Uint8Array(await (await e.OUTPUTS.get(outputKey))!.arrayBuffer())).toEqual(full);
    expect((e.TEMP as unknown as MemoryR2).objects.size).toBe(0);
  });

  it("rejects stale token/version completion and never settles the old lease", async () => {
    const e = env();
    const outputKey = `accounts/${uuidA}/jobs/${uuidJ}/leases/${leaseToken}/output.mp4`;
    const outputSha = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    await e.OUTPUTS.put(outputKey, new Uint8Array([1, 2, 3]), { customMetadata: { sha256: outputSha } });
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ message: "stale lease" }, 409));
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/complete`, auth("worker-secret", {
      reservation_id: uuidR, account_id: uuidA, environment: "staging", worker_id: "old-renderer", lease_token: leaseToken, lease_version: leaseVersion - 1,
      output_object_key: outputKey, output_sha256: outputSha, duration_seconds: 30,
    })), e);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "lease_conflict" });
    expect(rpcBody(fetchSpy)).toMatchObject({ p_worker_id: "old-renderer", p_lease_token: leaseToken, p_lease_version: leaseVersion - 1 });
  });

  it("requires the entire lease fence on terminal render failure", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ status: "released" }));
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/fail`, auth("worker-secret", {
      reservation_id: uuidR, environment: "staging", worker_id: "mac-render-01", lease_token: leaseToken, lease_version: leaseVersion, error_code: "renderer_exit_1",
    })), env());
    expect(response.status).toBe(200);
    expect(rpcBody(fetchSpy)).toMatchObject({ p_environment: "staging", p_worker_id: "mac-render-01", p_lease_token: leaseToken, p_lease_version: leaseVersion });
  });

  it("rejects upload without a matching SHA-256 header before touching authority or R2", async () => {
    const e = env();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/output?account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}`, {
      method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "content-length": "3" }, body: new Uint8Array([1, 2, 3]),
    }), e);
    expect(response.status).toBe(422);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect((e.OUTPUTS as unknown as MemoryR2).objects.size).toBe(0);
  });

  it("computes the output digest server-side and rejects a forged checksum", async () => {
    const e = env();
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ leased: true }));
    const response = await worker.fetch(request(`/v1/jobs/${uuidJ}/output?account_id=${uuidA}&environment=staging&worker_id=mac-render-01&lease_token=${leaseToken}&lease_version=${leaseVersion}`, {
      method: "PUT", headers: { authorization: "Bearer worker-secret", "content-type": "video/mp4", "x-content-sha256": "0".repeat(64) }, body: new Uint8Array([1, 2, 3]),
    }), e);
    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "output_digest_mismatch" });
    expect(fetchSpy).toHaveBeenCalledOnce();
    expect((e.OUTPUTS as unknown as MemoryR2).objects.size).toBe(0);
  });
});

describe("recipient-bound customer delivery API", () => {
  const fence = { environment: "staging", worker_id: "mac-delivery-01", claim_token: leaseToken, attempt: 1 };

  it("rejects every operator-supplied recipient override before authority access", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const response = await worker.fetch(request("/v1/deliveries/next", auth("worker-secret", { worker_id: "mac-delivery-01", recipient_phone_e164: "+155****9999" })), env());
    expect(response.status).toBe(422);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("claims only by environment and worker identity", async () => {
    const claim = { delivery_id: deliveryId, phase: "media", attempt: 1, claim_token: leaseToken,
      recipient_phone_e164: "+155****1111", expected_sender_identity_hash: "a".repeat(64), output_format: "9:16", source_listing_id: "listing-001" };
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult(claim));
    const response = await worker.fetch(request("/v1/deliveries/next", auth("worker-secret", { worker_id: "mac-delivery-01" })), env());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(claim);
    expect(rpcBody(fetchSpy)).toEqual({ p_environment: "staging", p_worker_id: "mac-delivery-01" });
  });

  it("streams only the hash-bound R2 output after a full lease assertion", async () => {
    const e = env(); const bytes = new Uint8Array([1, 2, 3]);
    const digest = "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81";
    const key = `accounts/${uuidA}/jobs/${uuidJ}/leases/${leaseToken}/output.mp4`;
    await e.OUTPUTS.put(key, bytes, { customMetadata: { sha256: digest }, httpMetadata: { contentType: "video/mp4" } });
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ authorized: true, output_object_key: key, output_sha256: digest }));
    const query = new URLSearchParams({ environment: "staging", worker_id: "mac-delivery-01", claim_token: leaseToken, attempt: "1" });
    const response = await worker.fetch(request(`/v1/deliveries/${deliveryId}/media?${query}` , { headers: { authorization: "Bearer worker-secret" } }), e);
    expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes);
    expect(response.headers.get("x-content-sha256")).toBe(digest);
    expect(rpcBody(fetchSpy)).toEqual({ p_delivery_id: deliveryId, p_environment: "staging", p_worker_id: "mac-delivery-01", p_claim_token: leaseToken, p_attempt: 1 });
  });

  it("checkpoints before sends and persists provider ids through phase-specific acceptance", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ status: "media_sending" }))
      .mockResolvedValueOnce(rpcResult({ status: "notice_pending", remaining_generations: 3 }))
      .mockResolvedValueOnce(rpcResult({ status: "delivered", remaining_generations: 3 }));
    const checkpoint = await worker.fetch(request(`/v1/deliveries/${deliveryId}/checkpoint`, auth("worker-secret", { ...fence, phase: "media" })), env());
    const media = await worker.fetch(request(`/v1/deliveries/${deliveryId}/media-accepted`, auth("worker-secret", { ...fence, provider_message_id: "media.123" })), env());
    const notice = await worker.fetch(request(`/v1/deliveries/${deliveryId}/notice-accepted`, auth("worker-secret", { ...fence, provider_message_id: "notice.123" })), env());
    expect([checkpoint.status, media.status, notice.status]).toEqual([200, 200, 200]);
    expect(String(fetchSpy.mock.calls[0][0])).toContain("recorrido_checkpoint_customer_delivery");
    expect(String(fetchSpy.mock.calls[1][0])).toContain("recorrido_accept_customer_delivery_media");
    expect(String(fetchSpy.mock.calls[2][0])).toContain("recorrido_accept_customer_delivery_notice");
    expect(rpcBody(fetchSpy, 1)).toMatchObject({ p_provider_message_id: "media.123", p_claim_token: leaseToken, p_attempt: 1 });
  });
});

describe("main queue, DLQ, recovery, and alerts", () => {
  it("marks main queue delivery and acknowledges only after authority success", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(rpcResult({ dispatch_status: "delivered" }));
    const ack = vi.fn(); const retry = vi.fn();
    await handleQueue({ queue: "recorrido-generation-queue", messages: [{ body: generationMessage, attempts: 1, ack, retry }] } as never, env());
    expect(String(fetchSpy.mock.calls[0][0])).toContain("recorrido_mark_generation_queue_delivered");
    expect(rpcBody(fetchSpy)).toEqual({
      p_job_id: uuidJ, p_reservation_id: uuidR, p_account_id: uuidA,
      p_environment: "staging", p_idempotency_key: generationMessage.idempotency_key,
      p_input_manifest_key: generationMessage.input_manifest_key,
      p_manifest_sha256: generationMessage.manifest_sha256,
    });
    expect(ack).toHaveBeenCalledOnce();
    expect(retry).not.toHaveBeenCalled();
  });

  it("retries transient main-queue authority failure for Cloudflare DLQ routing", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response("unavailable", { status: 503 }));
    const ack = vi.fn(); const retry = vi.fn();
    await handleQueue({ queue: "recorrido-generation-queue", messages: [{ body: generationMessage, attempts: 2, ack, retry }] } as never, env());
    expect(retry).toHaveBeenCalledOnce();
    expect(ack).not.toHaveBeenCalled();
  });

  it("terminalizes a DLQ message, emits a privacy-safe optional alert, then acknowledges", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult({ dispatch_status: "dead" }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    const ack = vi.fn(); const retry = vi.fn();
    await handleQueue({ queue: "recorrido-generation-dlq", messages: [{ body: generationMessage, attempts: 4, ack, retry }] } as never, env({ ALERT_WEBHOOK_URL: "https://alerts.example/hook" }));
    expect(String(fetchSpy.mock.calls[0][0])).toContain("recorrido_terminalize_generation_dispatch");
    expect(rpcBody(fetchSpy, 0)).toEqual({
      p_job_id: uuidJ, p_reservation_id: uuidR, p_account_id: uuidA,
      p_environment: "staging", p_idempotency_key: generationMessage.idempotency_key,
      p_input_manifest_key: generationMessage.input_manifest_key,
      p_manifest_sha256: generationMessage.manifest_sha256,
      p_error_code: "queue_dlq",
    });
    const alert = JSON.parse(String(fetchSpy.mock.calls[1][1]?.body));
    expect(alert).toEqual({ event: "generation_dispatch_dead", environment: "staging", release: "test-release", error_code: "queue_dlq" });
    expect(JSON.stringify(alert)).not.toContain(uuidJ);
    expect(JSON.stringify(alert)).not.toContain(leaseToken);
    expect(ack).toHaveBeenCalledOnce();
    expect(retry).not.toHaveBeenCalled();
  });

  it("retries DLQ terminalization rather than losing terminal evidence", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response("unavailable", { status: 503 }));
    const ack = vi.fn(); const retry = vi.fn();
    await handleQueue({ queue: "recorrido-generation-dlq", messages: [{ body: generationMessage, attempts: 1, ack, retry }] } as never, env());
    expect(retry).toHaveBeenCalledOnce();
    expect(ack).not.toHaveBeenCalled();
  });

  it("re-enqueues explicitly dispatching recovery rows and marks them dispatched", async () => {
    const e = env();
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult([{ job_id: uuidJ, message: generationMessage, attempts: 1, dispatch_status: "dispatching" }]))
      .mockResolvedValueOnce(rpcResult({ dispatch_status: "enqueued" }));
    await handleScheduled(e);
    expect((e.GENERATION_QUEUE as unknown as MemoryQueue).sent).toEqual([generationMessage]);
    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(rpcBody(fetchSpy)).toMatchObject({ p_environment: "staging" });
  });

  it("terminalizes a max-attempt cron row instead of dispatching it again", async () => {
    const e = env();
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(rpcResult([{ job_id: uuidJ, message: generationMessage, attempts: 10, dispatch_status: "dead" }]))
      .mockResolvedValueOnce(rpcResult({ dispatch_status: "dead" }));
    await handleScheduled(e);
    expect((e.GENERATION_QUEUE as unknown as MemoryQueue).sent).toHaveLength(0);
    expect(String(fetchSpy.mock.calls[1][0])).toContain("recorrido_terminalize_generation_dispatch");
  });
});
