import {
  normalizeE164,
  verifyMetaChallenge,
  verifyMetaSignature,
} from "./whatsapp.ts";
import type { JsonValue } from "./supabase.ts";
import { TransportError } from "./http.ts";

const MAX_BODY = 65_536;
const TOKEN = /^[A-Za-z0-9_-]{1,256}$/;
const MAX_TEXT = 4_096;

export interface ApprovalConfig {
  verifyToken: string;
  appSecret: string;
  ownerE164: string;
}
export interface ApprovalDependencies {
  rpc(name: string, args: Record<string, JsonValue>): Promise<unknown>;
  sendReview?(to: string, body: string): Promise<void>;
}

function response(
  status: number,
  body: string,
  contentType = "application/json; charset=utf-8",
) {
  return new Response(body, {
    status,
    headers: { "content-type": contentType, "cache-control": "no-store" },
  });
}

async function boundedBody(request: Request): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_BODY)) {
    return null;
  }
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.length;
    if (length > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}

function textMessage(value: unknown): { from: string; body: string } | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const root = value as Record<string, unknown>;
  if (
    root.object !== "whatsapp_business_account" || !Array.isArray(root.entry) ||
    root.entry.length !== 1
  ) return null;
  const entry = root.entry[0] as Record<string, unknown> | undefined;
  if (!entry || !Array.isArray(entry.changes) || entry.changes.length !== 1) {
    return null;
  }
  const change = entry.changes[0] as Record<string, unknown> | undefined;
  const content = change?.value as Record<string, unknown> | undefined;
  if (
    change?.field !== "messages" || !content ||
    content.messaging_product !== "whatsapp" ||
    !Array.isArray(content.messages) || content.messages.length !== 1
  ) return null;
  const message = content.messages[0] as Record<string, unknown> | undefined;
  const text = message?.text as Record<string, unknown> | undefined;
  if (
    !message || message.type !== "text" || typeof message.from !== "string" ||
    !text || typeof text.body !== "string" || text.body.length > MAX_TEXT
  ) return null;
  return { from: message.from, body: text.body };
}

function command(
  text: string,
): { action: "approve" | "reject"; token: string } | {
  action: "edit";
  token: string;
  replacement: string;
} | null {
  const action = /^(APPROVE|REJECT) ([A-Za-z0-9_-]{1,256})$/i.exec(text);
  if (action && TOKEN.test(action[2])) {
    return {
      action: action[1].toLowerCase() as "approve" | "reject",
      token: action[2],
    };
  }
  const edit = /^EDIT ([A-Za-z0-9_-]{1,256}) (\S[\s\S]{0,4095})$/i.exec(text);
  if (edit && TOKEN.test(edit[1]) && edit[2].length <= MAX_TEXT) {
    return { action: "edit", token: edit[1], replacement: edit[2] };
  }
  return null;
}

export function createApprovalHandler(
  config: ApprovalConfig,
  dependencies: ApprovalDependencies,
) {
  if (!config.verifyToken?.trim() || !config.appSecret?.trim()) {
    throw new Error("Invalid approval configuration");
  }
  let owner: string;
  try {
    owner = normalizeE164(config.ownerE164);
  } catch {
    throw new Error("Invalid approval configuration");
  }
  return async (request: Request): Promise<Response> => {
    if (request.method === "GET") {
      const url = new URL(request.url);
      const challenge = url.searchParams.get("hub.challenge") ?? "";
      const verified = url.searchParams.get("hub.mode") === "subscribe"
        ? verifyMetaChallenge(
          config.verifyToken,
          url.searchParams.get("hub.verify_token"),
          challenge,
        )
        : null;
      return verified === null
        ? response(403, '{"ok":false}')
        : response(200, verified, "text/plain; charset=utf-8");
    }
    if (request.method !== "POST") return response(405, '{"ok":false}');
    const raw = await boundedBody(request);
    if (raw === null) return response(413, '{"ok":false}');
    if (
      !(await verifyMetaSignature(
        raw,
        request.headers.get("x-hub-signature-256"),
        config.appSecret,
      ))
    ) return response(401, '{"ok":false}');
    let parsed: unknown;
    try {
      parsed = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(raw),
      );
    } catch {
      return response(200, '{"ok":true,"ignored":true}');
    }
    const message = textMessage(parsed);
    if (!message) return response(200, '{"ok":true,"ignored":true}');
    let sender: string;
    try {
      sender = normalizeE164(
        message.from.startsWith("+") ? message.from : `+${message.from}`,
      );
    } catch {
      return response(200, '{"ok":true,"ignored":true}');
    }
    if (sender !== owner) return response(200, '{"ok":true,"ignored":true}');
    const parsedCommand = command(message.body);
    if (!parsedCommand) return response(200, '{"ok":true,"ignored":true}');
    try {
      if (parsedCommand.action === "edit") {
        const result = await dependencies.rpc("recorrido_apply_owner_edit", {
          p_owner_phone_e164: owner,
          p_sender_phone_e164: sender,
          p_token: parsedCommand.token,
          p_replacement: parsedCommand.replacement,
        });
        const edit = result as Record<string, unknown> | null;
        if (
          edit?.decision !== "need_new_review" ||
          typeof edit.approvalToken !== "string" ||
          !TOKEN.test(edit.approvalToken) ||
          !Number.isSafeInteger(edit.currentDraftVersion) ||
          (edit.currentDraftVersion as number) < 2 || !dependencies.sendReview
        ) throw new Error("Unexpected edit decision");
        await dependencies.sendReview(
          owner,
          `Review edited draft v${edit.currentDraftVersion}\nAPPROVE ${edit.approvalToken}\nREJECT ${edit.approvalToken}`,
        );
        return response(
          200,
          JSON.stringify({ ok: true, decision: "need_new_review" }),
        );
      }
      await dependencies.rpc("recorrido_apply_owner_action", {
        p_owner_phone_e164: owner,
        p_sender_phone_e164: sender,
        p_action: parsedCommand.action,
        p_token: parsedCommand.token,
      });
      return response(200, '{"ok":true}');
    } catch (error) {
      if (
        error instanceof TransportError &&
        (error.status === undefined || error.status >= 500)
      ) return response(503, '{"ok":false,"error":"temporarily_unavailable"}');
      return response(200, '{"ok":false,"error":"action_not_applied"}');
    }
  };
}
