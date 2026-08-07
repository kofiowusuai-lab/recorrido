const E164 = /^\+[1-9]\d{7,14}$/;
const ACTIONS = new Set(["approve", "edit", "reject"]);
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const OPAQUE_TOKEN_ID = /^[A-Za-z0-9_-]{1,256}$/;
const ISO_8601_TIMESTAMP =
  /^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/;
const MAX_WHATSAPP_TEXT_LENGTH = 4_096;

function isValidIsoTimestamp(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = ISO_8601_TIMESTAMP.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  if (month < 1 || month > 12) return false;
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day >= 1 && day <= daysInMonth && Number.isFinite(Date.parse(value));
}

function normalizeInternationalPhone(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const compact = value.trim().replace(/[()\s.-]/g, "");
  return E164.test(compact) ? compact : null;
}

export interface ActionTokenMetadata {
  opaqueId: string;
  signatureValid: boolean;
  action: "approve" | "edit" | "reject";
  draftId: string;
  draftVersion: number;
  expiresAt: number;
  consumedAt: number | null;
}

export interface OwnerActionInput {
  ownerWhatsAppE164: string;
  actorWhatsApp: string;
  draftId: string;
  currentDraftVersion: number;
  status: "pending";
  now: number;
  token: ActionTokenMetadata;
}

export type OwnerActionDecision =
  | Readonly<{ accepted: false; reason: string }>
  | Readonly<
    Record<string, unknown> & {
      accepted: true;
      decision: "approve" | "need_new_review" | "reject";
    }
  >;

export function decideOwnerAction(
  input: OwnerActionInput,
): OwnerActionDecision {
  const reject = (reason: string): OwnerActionDecision =>
    Object.freeze({ accepted: false, reason });
  if (!input || typeof input !== "object") return reject("invalid_input");
  const owner = normalizeInternationalPhone(input.ownerWhatsAppE164);
  const actor = normalizeInternationalPhone(input.actorWhatsApp);
  if (!owner || !actor || !constantStringEqual(owner, actor)) {
    return reject("not_owner");
  }
  const token = input.token;
  if (
    !token || typeof token !== "object" || token.signatureValid !== true ||
    typeof token.opaqueId !== "string" ||
    !OPAQUE_TOKEN_ID.test(token.opaqueId) ||
    typeof token.draftId !== "string" || !UUID.test(token.draftId) ||
    !Number.isSafeInteger(token.draftVersion) || token.draftVersion <= 0 ||
    !Number.isFinite(token.expiresAt) ||
    (token.consumedAt !== null && !Number.isFinite(token.consumedAt))
  ) return reject("invalid_token");
  if (token.consumedAt !== null) return reject("consumed_token");
  if (
    !Number.isFinite(input.now) ||
    input.now >= token.expiresAt
  ) return reject("expired_token");
  if (typeof token.action !== "string" || !ACTIONS.has(token.action)) {
    return reject("invalid_action");
  }
  if (typeof input.draftId !== "string" || !UUID.test(input.draftId)) {
    return reject("draft_mismatch");
  }
  if (input.status !== "pending") return reject("not_pending");
  if (token.draftId !== input.draftId) return reject("draft_mismatch");
  if (
    !Number.isSafeInteger(input.currentDraftVersion) ||
    input.currentDraftVersion <= 0 ||
    token.draftVersion !== input.currentDraftVersion
  ) return reject("version_mismatch");
  if (token.action === "approve") {
    return Object.freeze({
      accepted: true,
      decision: "approve",
      draftId: input.draftId,
      approvedBy: owner,
      approvedVersion: input.currentDraftVersion,
      consumeToken: true,
    });
  }
  if (token.action === "edit") {
    return Object.freeze({
      accepted: true,
      decision: "need_new_review",
      draftId: input.draftId,
      invalidateCurrentToken: true,
      consumeToken: true,
    });
  }
  return Object.freeze({
    accepted: true,
    decision: "reject",
    draftId: input.draftId,
    blocked: true,
    consumeToken: true,
  });
}

function constantStringEqual(left: string, right: string): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index++) {
    difference |= (left.charCodeAt(index) || 0) ^
      (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

export interface SendInstruction {
  readonly outboundId: string;
  readonly recipientE164: string;
  readonly body: string;
}

export function getSendInstruction(
  row: unknown,
): Readonly<SendInstruction> | null {
  if (!row || typeof row !== "object" || Array.isArray(row)) return null;
  const value = row as Record<string, unknown>;
  if (
    typeof value.id !== "string" || !UUID.test(value.id) ||
    typeof value.draftId !== "string" || !UUID.test(value.draftId) ||
    value.status !== "approved" || !isValidIsoTimestamp(value.approvedAt) ||
    typeof value.ownerWhatsAppE164 !== "string" ||
    typeof value.approvedBy !== "string" ||
    !constantStringEqual(value.ownerWhatsAppE164, value.approvedBy) ||
    !E164.test(value.approvedBy) ||
    !Number.isSafeInteger(value.currentDraftVersion) ||
    (value.currentDraftVersion as number) <= 0 ||
    !Number.isSafeInteger(value.approvedVersion) ||
    (value.approvedVersion as number) <= 0 ||
    value.approvedVersion !== value.currentDraftVersion ||
    value.optedOut !== false ||
    value.sentAt !== null || value.providerMessageId !== null ||
    typeof value.recipientE164 !== "string" ||
    !E164.test(value.recipientE164) ||
    typeof value.body !== "string" || !value.body.trim() ||
    value.body.length > MAX_WHATSAPP_TEXT_LENGTH
  ) return null;
  return Object.freeze({
    outboundId: value.id,
    recipientE164: value.recipientE164,
    body: value.body,
  });
}
