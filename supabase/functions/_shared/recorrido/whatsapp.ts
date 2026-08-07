import { parseJsonResponse } from "./http.ts";

const encoder = new TextEncoder();
const E164 = /^\+[1-9]\d{7,14}$/;
const MAX_META_CHALLENGE_LENGTH = 1_024;

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index++) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function decodeHex(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

export async function verifyMetaSignature(
  rawBody: Uint8Array,
  signature: string | null | undefined,
  appSecret: string,
): Promise<boolean> {
  if (!/^sha256=[0-9a-fA-F]{64}$/.test(signature ?? "") || !appSecret) {
    return false;
  }
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      encoder.encode(appSecret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const body = Uint8Array.from(rawBody);
    const expected = new Uint8Array(
      await crypto.subtle.sign("HMAC", key, body),
    );
    return constantTimeEqual(expected, decodeHex(signature!.slice(7)));
  } catch {
    return false;
  }
}

export interface PhoneContext {
  countryCallingCode: string;
}

export function normalizeE164(input: string, context?: PhoneContext): string {
  if (
    typeof input !== "string" || input !== input.trim() && input.trim() === ""
  ) {
    throw new Error("Malformed phone number");
  }
  const value = input.trim();
  if (
    /[^\d+()\s.-]/.test(value) || (value.match(/\+/g)?.length ?? 0) > 1 ||
    value.includes("+", 1)
  ) {
    throw new Error("Malformed phone number");
  }
  const digits = value.replace(/[()\s.-]/g, "");
  let candidate: string;
  if (digits.startsWith("+")) {
    candidate = digits;
  } else {
    if (!context) {
      throw new Error(
        "Phone number is ambiguous without country calling context",
      );
    }
    const callingCode = context.countryCallingCode.replace(/^\+/, "");
    if (!/^[1-9]\d{0,2}$/.test(callingCode)) {
      throw new Error("Malformed phone context");
    }
    if (!/^\d+$/.test(digits)) throw new Error("Malformed phone number");
    if (callingCode === "1" && !/^[2-9]\d{2}[2-9]\d{6}$/.test(digits)) {
      throw new Error("Phone number is not a valid NANP national number");
    }
    candidate = `+${callingCode}${digits.replace(/^0+/, "")}`;
  }
  if (!E164.test(candidate)) throw new Error("Phone number is not valid E.164");
  return candidate;
}

export function verifyMetaChallenge(
  expectedToken: string,
  suppliedToken: string | null | undefined,
  challenge: string,
): string | null {
  if (
    typeof suppliedToken !== "string" || typeof expectedToken !== "string" ||
    typeof challenge !== "string" || !challenge.trim() ||
    challenge.length > MAX_META_CHALLENGE_LENGTH
  ) {
    return null;
  }
  if (!expectedToken.trim() || !suppliedToken.trim()) return null;
  const matches = constantTimeEqual(
    encoder.encode(expectedToken),
    encoder.encode(suppliedToken),
  );
  return matches ? challenge : null;
}

export interface WhatsAppTemplate {
  name: string;
  languageCode: string;
  components?: readonly Record<string, unknown>[];
}

export type WhatsAppMessage =
  & {
    to: string;
    signal?: AbortSignal;
  }
  & ({ text: string; template?: never } | {
    template: WhatsAppTemplate;
    text?: never;
  });

export interface WhatsAppSenderOptions {
  graphVersion: string;
  phoneNumberId: string;
  accessToken: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export interface WhatsAppSender {
  send(message: WhatsAppMessage): Promise<Readonly<{ messageId: string }>>;
}

export class WhatsAppRejectedError extends Error {
  readonly code: string;
  readonly retryable: boolean;

  constructor(status: number) {
    super("WhatsApp provider explicitly rejected request");
    this.name = "WhatsAppRejectedError";
    this.code = `provider_http_${status}`;
    this.retryable = status === 408 || status === 429 || status >= 500;
  }
}

export function createWhatsAppSender(
  options: WhatsAppSenderOptions,
): WhatsAppSender {
  if (
    !/^v\d+\.\d+$/.test(options.graphVersion) ||
    !/^\d+$/.test(options.phoneNumberId) ||
    typeof options.accessToken !== "string" || !options.accessToken ||
    (options.timeoutMs !== undefined &&
      (!Number.isFinite(options.timeoutMs) || options.timeoutMs <= 0))
  ) throw new Error("Invalid WhatsApp configuration");

  const fetcher = options.fetch ?? fetch;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const endpoint =
    `https://graph.facebook.com/${options.graphVersion}/${options.phoneNumberId}/messages`;

  return Object.freeze({
    async send(
      message: WhatsAppMessage,
    ): Promise<Readonly<{ messageId: string }>> {
      let recipient: string;
      try {
        recipient = normalizeE164(message.to);
      } catch {
        throw new Error("Invalid WhatsApp recipient");
      }
      if (
        "text" in message &&
        (typeof message.text !== "string" || !message.text.trim())
      ) {
        throw new Error("Invalid WhatsApp text");
      }
      if (
        "template" in message &&
        (!message.template || !/^[a-z0-9_]+$/.test(message.template.name) ||
          !/^[A-Za-z]{2,3}(?:_[A-Za-z]{2})?$/.test(
            message.template.languageCode,
          ))
      ) throw new Error("Invalid WhatsApp template");

      const payload = "text" in message
        ? {
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: recipient,
          type: "text",
          text: { preview_url: false, body: message.text },
        }
        : {
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: recipient,
          type: "template",
          template: {
            name: message.template.name,
            language: { code: message.template.languageCode },
            ...(message.template.components
              ? { components: message.template.components }
              : {}),
          },
        };
      const timeout = AbortSignal.timeout(timeoutMs);
      const signal = message.signal
        ? AbortSignal.any([message.signal, timeout])
        : timeout;
      let response: Response;
      try {
        response = await fetcher(endpoint, {
          method: "POST",
          headers: {
            authorization: `Bearer ${options.accessToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify(payload),
          signal,
        });
      } catch {
        throw new Error("WhatsApp request failed");
      }
      if (!response.ok) {
        if (response.status === 408 || response.status >= 500) {
          throw new Error("WhatsApp request failed");
        }
        throw new WhatsAppRejectedError(response.status);
      }
      try {
        const data: unknown = await parseJsonResponse(response, "WhatsApp");
        const messageId = (data as { messages?: { id?: unknown }[] })?.messages
          ?.[0]?.id;
        if (typeof messageId !== "string" || !messageId) {
          throw new Error("provider payload");
        }
        return Object.freeze({ messageId });
      } catch {
        throw new Error("WhatsApp request failed");
      }
    },
  });
}
