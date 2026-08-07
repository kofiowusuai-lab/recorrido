import { parseJsonResponse, requireNonEmpty, TransportError } from "./http.ts";

export interface StripeWebhookOptions {
  now?: number;
  toleranceSeconds?: number;
}

function decodeHex(value: string): Uint8Array | null {
  if (!/^[0-9a-fA-F]{64}$/.test(value)) return null;
  const result = new Uint8Array(32);
  for (let index = 0; index < result.length; index++) {
    result[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return result;
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index++) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export async function verifyStripeWebhook<T = unknown>(
  rawBody: string,
  signatureHeader: string,
  webhookSecret: string,
  options: StripeWebhookOptions = {},
): Promise<T> {
  requireNonEmpty(webhookSecret, "Stripe webhook secret");
  if (typeof signatureHeader !== "string" || signatureHeader.length === 0) {
    throw new TransportError("Malformed Stripe signature header");
  }

  let timestampText: string | undefined;
  const signatures: Uint8Array[] = [];
  for (const item of signatureHeader.split(",")) {
    const separator = item.indexOf("=");
    if (separator <= 0 || separator === item.length - 1) {
      throw new TransportError("Malformed Stripe signature header");
    }
    const key = item.slice(0, separator).trim();
    const value = item.slice(separator + 1).trim();
    if (!key || !value) {
      throw new TransportError("Malformed Stripe signature header");
    }
    if (key === "t") {
      if (timestampText !== undefined) {
        throw new TransportError("Malformed Stripe signature header");
      }
      timestampText = value;
    } else if (key === "v1") {
      const decoded = decodeHex(value);
      if (!decoded) throw new TransportError("Invalid Stripe signature");
      signatures.push(decoded);
    }
  }

  if (timestampText === undefined || signatures.length === 0) {
    throw new TransportError(
      "Stripe signature header requires timestamp and v1 signature",
    );
  }
  if (!/^\d+$/.test(timestampText)) {
    throw new TransportError("Invalid Stripe signature timestamp");
  }
  const timestamp = Number(timestampText);
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0) {
    throw new TransportError("Invalid Stripe signature timestamp");
  }
  const now = options.now ?? Date.now() / 1000;
  const tolerance = options.toleranceSeconds ?? 300;
  if (!Number.isFinite(now) || !Number.isFinite(tolerance) || tolerance < 0) {
    throw new TransportError("Invalid Stripe signature tolerance");
  }
  if (Math.abs(now - timestamp) > tolerance) {
    throw new TransportError("Stripe signature timestamp outside tolerance");
  }

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(webhookSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      encoder.encode(`${timestampText}.${rawBody}`),
    ),
  );
  let verified = false;
  for (const candidate of signatures) {
    verified = constantTimeEqual(expected, candidate) || verified;
  }
  if (!verified) throw new TransportError("Invalid Stripe signature");

  try {
    return JSON.parse(rawBody) as T;
  } catch {
    throw new TransportError("Stripe webhook body contains malformed JSON");
  }
}

type FormScalar = string | number | boolean | null | undefined;
export type StripeFormValue = FormScalar | StripeFormValue[] | {
  [key: string]: StripeFormValue;
};

function appendForm(
  entries: [string, string][],
  key: string,
  value: StripeFormValue,
): void {
  if (value === undefined) return;
  if (value === null) {
    entries.push([key, ""]);
  } else if (Array.isArray(value)) {
    value.forEach((item, index) =>
      appendForm(entries, `${key}[${index}]`, item)
    );
  } else if (typeof value === "object") {
    for (const child of Object.keys(value).sort()) {
      appendForm(entries, `${key}[${child}]`, value[child]);
    }
  } else {
    entries.push([key, String(value)]);
  }
}

function encodeForm(body: Record<string, StripeFormValue>): string {
  const entries: [string, string][] = [];
  for (const key of Object.keys(body).sort()) {
    appendForm(entries, key, body[key]);
  }
  const params = new URLSearchParams();
  for (const [key, value] of entries) params.append(key, value);
  return params.toString();
}

function encodedPath(path: string): string {
  const parts = path.replace(/^\/+|\/+$/g, "").split("/");
  if (parts.some((part) => !part)) {
    throw new TransportError("Invalid Stripe API path");
  }
  return parts.map(encodeURIComponent).join("/");
}

export interface StripeClientOptions {
  secretKey: string;
  stripeVersion: string;
  fetch?: typeof fetch;
  baseUrl?: string;
  timeoutMs?: number;
}

export interface StripeRequestOptions {
  signal?: AbortSignal;
  timeoutMs?: number;
}

export interface StripePostRequestOptions extends StripeRequestOptions {
  idempotencyKey: string;
}

function idempotencyKey(value: string | undefined): string {
  if (
    typeof value !== "string" || value.length > 255 ||
    !/^[\x21-\x7e]+$/.test(value)
  ) {
    throw new TransportError(
      "Stripe POST requires a valid operation-scoped idempotency key",
    );
  }
  return value;
}

function requestSignal(
  signal: AbortSignal | undefined,
  timeoutMs: number,
): { signal: AbortSignal; cleanup: () => void } {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  if (signal?.aborted) abort();
  else signal?.addEventListener("abort", abort, { once: true });
  const timer = setTimeout(
    () =>
      controller.abort(new DOMException("Request timed out", "TimeoutError")),
    timeoutMs,
  );
  return {
    signal: controller.signal,
    cleanup: () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
    },
  };
}

export function createStripeClient(options: StripeClientOptions) {
  const secretKey = requireNonEmpty(options.secretKey, "Stripe secret key");
  const stripeVersion = requireNonEmpty(
    options.stripeVersion,
    "Stripe version",
  );
  const fetcher = options.fetch ?? fetch;
  const baseUrl = (options.baseUrl ?? "https://api.stripe.com/v1").replace(
    /\/+$/,
    "",
  );
  const defaultTimeout = options.timeoutMs ?? 10_000;

  async function request<T>(
    method: "GET" | "POST",
    path: string,
    body?: Record<string, StripeFormValue>,
    requestOptions: StripeRequestOptions & { idempotencyKey?: string } = {},
  ): Promise<T> {
    const normalizedPath = encodedPath(path);
    const encodedBody = body ? encodeForm(body) : "";
    const headers = new Headers({
      Authorization: `Basic ${btoa(`${secretKey}:`)}`,
      "Stripe-Version": stripeVersion,
    });
    if (method === "POST") {
      headers.set("Content-Type", "application/x-www-form-urlencoded");
      headers.set(
        "Idempotency-Key",
        idempotencyKey(requestOptions.idempotencyKey),
      );
    }
    const managed = requestSignal(
      requestOptions.signal,
      requestOptions.timeoutMs ?? defaultTimeout,
    );
    try {
      const response = await fetcher(`${baseUrl}/${normalizedPath}`, {
        method,
        headers,
        body: method === "POST" ? encodedBody : undefined,
        signal: managed.signal,
      });
      return await parseJsonResponse<T>(response, "Stripe");
    } catch (error) {
      if (error instanceof TransportError) throw error;
      throw new TransportError(
        error instanceof DOMException && error.name === "AbortError"
          ? "Stripe request aborted"
          : "Stripe transport request failed",
      );
    } finally {
      managed.cleanup();
    }
  }

  return {
    get: <T = unknown>(path: string, requestOptions?: StripeRequestOptions) =>
      request<T>("GET", path, undefined, requestOptions),
    post: <T = unknown>(
      path: string,
      body: Record<string, StripeFormValue>,
      requestOptions: StripePostRequestOptions,
    ) => request<T>("POST", path, body, requestOptions),
  };
}
