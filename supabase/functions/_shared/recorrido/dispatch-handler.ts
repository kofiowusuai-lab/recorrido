import { getSendInstruction } from "./outbound.ts";
import { normalizeE164, WhatsAppRejectedError } from "./whatsapp.ts";
import type { JsonValue } from "./supabase.ts";

const MAX_BODY = 4_096;
const OPAQUE = /^[A-Za-z0-9_-]{1,256}$/;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ERROR_CODE = /^[A-Za-z0-9_.:-]{1,128}$/;
const encoder = new TextEncoder();

export class ProviderRejectedError extends WhatsAppRejectedError {
  constructor(
    override readonly code: string,
    override readonly retryable: boolean,
  ) {
    super(400);
    this.name = "ProviderRejectedError";
    this.code = ERROR_CODE.test(code) ? code : "provider_rejected";
    this.retryable = retryable;
  }
}

export interface DispatchConfig {
  internalSecret: string;
  ownerE164: string;
}
export interface DispatchDependencies {
  rpc(name: string, args: Record<string, JsonValue>): Promise<unknown>;
  sendText(to: string, body: string): Promise<{ messageId: string }>;
}
function constantEqual(left: string, right: string) {
  const a = encoder.encode(left), b = encoder.encode(right);
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    difference |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return difference === 0;
}
function json(status: number, value: unknown) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}
async function body(request: Request): Promise<string | null> {
  const length = request.headers.get("content-length");
  if (length && (!/^\d+$/.test(length) || Number(length) > MAX_BODY)) {
    return null;
  }
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
function field(row: unknown, name: string, pattern: RegExp) {
  const value = (row as Record<string, unknown> | null)?.[name];
  return typeof value === "string" && pattern.test(value) ? value : null;
}

const CLAIM_KEYS = [
  "approvalExpiresAt",
  "approvedAt",
  "approvedBy",
  "approvedVersion",
  "attemptId",
  "body",
  "claimToken",
  "currentDraftVersion",
  "draftId",
  "id",
  "leaseExpiresAt",
  "messageType",
  "optedOut",
  "ownerWhatsAppE164",
  "payload",
  "previewText",
  "providerMessageId",
  "recipientConsented",
  "recipientE164",
  "sentAt",
  "status",
  "tokenValid",
].sort();

function exactClaim(row: unknown): boolean {
  if (!row || typeof row !== "object" || Array.isArray(row)) return false;
  const value = row as Record<string, unknown>;
  if (
    JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(CLAIM_KEYS)
  ) return false;
  const payload = value.payload as Record<string, unknown> | null;
  return field(row, "attemptId", UUID) !== null &&
    field(row, "claimToken", UUID) !== null &&
    typeof value.leaseExpiresAt === "string" &&
    Number.isFinite(Date.parse(value.leaseExpiresAt)) &&
    typeof value.approvalExpiresAt === "string" &&
    Number.isFinite(Date.parse(value.approvalExpiresAt)) &&
    value.messageType === "text" && value.tokenValid === true &&
    value.recipientConsented === true &&
    payload !== null && typeof payload === "object" &&
    !Array.isArray(payload) &&
    JSON.stringify(Object.keys(payload).sort()) === JSON.stringify(["body"]) &&
    payload.body === value.body && value.previewText === value.body;
}

export function createDispatchHandler(
  config: DispatchConfig,
  dependencies: DispatchDependencies,
) {
  if (!config.internalSecret?.trim()) {
    throw new Error("Invalid dispatch configuration");
  }
  let owner: string;
  try {
    owner = normalizeE164(config.ownerE164);
  } catch {
    throw new Error("Invalid dispatch configuration");
  }
  return async (request: Request): Promise<Response> => {
    const authorization = request.headers.get("authorization") ?? "";
    const supplied = authorization.startsWith("Bearer ")
      ? authorization.slice(7)
      : "";
    if (
      request.method !== "POST" || !supplied ||
      !constantEqual(config.internalSecret, supplied)
    ) return json(401, { ok: false });
    const raw = await body(request);
    if (raw === null) return json(413, { ok: false });
    let input: unknown;
    try {
      input = JSON.parse(raw);
    } catch {
      return json(400, { ok: false });
    }
    if (
      !input || typeof input !== "object" || Array.isArray(input) ||
      Object.keys(input).length !== 1 ||
      !Number.isSafeInteger((input as { limit?: unknown }).limit) ||
      (input as { limit: number }).limit < 1 ||
      (input as { limit: number }).limit > 100
    ) return json(400, { ok: false });
    let claimed: unknown;
    try {
      claimed = await dependencies.rpc("recorrido_claim_approved_outbound", {
        p_limit: (input as { limit: number }).limit,
        p_owner_phone_e164: owner,
      });
    } catch {
      return json(503, { ok: false, error: "claim_failed" });
    }
    if (!Array.isArray(claimed)) {
      return json(503, { ok: false, error: "claim_failed" });
    }

    let delivered = 0, failed = 0, retryable = 0, ambiguous = 0;
    const ids: string[] = [];
    for (const row of claimed) {
      const id = field(row, "id", OPAQUE),
        attemptId = field(row, "attemptId", UUID);
      const claimToken = field(row, "claimToken", UUID);
      if (id) ids.push(id);
      const instruction = getSendInstruction(row);
      if (
        !id || !attemptId || !claimToken || !exactClaim(row) || !instruction ||
        (row as Record<string, unknown>).ownerWhatsAppE164 !== owner
      ) {
        if (id && attemptId && claimToken) {
          try {
            await dependencies.rpc("recorrido_mark_outbound_failed", {
              p_pending_outbound_id: id,
              p_attempt_id: attemptId,
              p_claim_token: claimToken,
              p_error_code: "invalid_claim",
              p_retryable: false,
            });
            failed++;
          } catch {
            retryable++;
          }
        } else retryable++;
        continue;
      }
      try {
        const begun = await dependencies.rpc("recorrido_begin_outbound_send", {
          p_pending_outbound_id: id,
          p_attempt_id: attemptId,
          p_claim_token: claimToken,
        });
        if ((begun as { begun?: unknown } | null)?.begun !== true) {
          throw new Error("not begun");
        }
      } catch {
        retryable++;
        continue;
      }

      let provider: { messageId: string };
      try {
        provider = await dependencies.sendText(
          instruction.recipientE164,
          instruction.body,
        );
      } catch (error) {
        if (error instanceof WhatsAppRejectedError) {
          try {
            await dependencies.rpc("recorrido_mark_outbound_failed", {
              p_pending_outbound_id: id,
              p_attempt_id: attemptId,
              p_claim_token: claimToken,
              p_error_code: error.code,
              p_retryable: error.retryable,
            });
            failed++;
            if (error.retryable) retryable++;
          } catch {
            ambiguous++;
          }
        } else {
          ambiguous++;
          try {
            await dependencies.rpc("recorrido_mark_outbound_ambiguous", {
              p_pending_outbound_id: id,
              p_attempt_id: attemptId,
              p_claim_token: claimToken,
              p_error_code: "provider_error",
              p_provider_message_id: null,
            });
          } catch { /* local outcome remains ambiguous */ }
        }
        continue;
      }
      const messageId = typeof provider.messageId === "string" &&
          provider.messageId.length >= 1 && provider.messageId.length <= 512
        ? provider.messageId
        : null;
      if (!messageId) {
        ambiguous++;
        try {
          await dependencies.rpc("recorrido_mark_outbound_ambiguous", {
            p_pending_outbound_id: id,
            p_attempt_id: attemptId,
            p_claim_token: claimToken,
            p_error_code: "provider_error",
            p_provider_message_id: null,
          });
        } catch { /* local outcome remains ambiguous */ }
        continue;
      }
      try {
        const marked = await dependencies.rpc(
          "recorrido_mark_outbound_delivered",
          {
            p_pending_outbound_id: id,
            p_attempt_id: attemptId,
            p_claim_token: claimToken,
            p_provider_message_id: messageId,
          },
        );
        if ((marked as { marked?: unknown } | null)?.marked !== true) {
          throw new Error("not acknowledged");
        }
        delivered++;
      } catch {
        ambiguous++;
        try {
          await dependencies.rpc("recorrido_mark_outbound_ambiguous", {
            p_pending_outbound_id: id,
            p_attempt_id: attemptId,
            p_claim_token: claimToken,
            p_error_code: "ack_failed",
            p_provider_message_id: messageId,
          });
        } catch { /* reconciliation can use provider id from logs/provider */ }
      }
    }
    return json(200, {
      ok: true,
      claimed: claimed.length,
      delivered,
      failed,
      retryable,
      ambiguous,
      ids,
    });
  };
}
