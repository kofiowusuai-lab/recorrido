export class TransportError extends Error {
  readonly status?: number;

  constructor(message: string, status?: number) {
    super(message);
    this.name = "TransportError";
    this.status = status;
  }
}

const MAX_JSON_RESPONSE_BYTES = 1024 * 1024;

async function readBoundedText(
  response: Response,
  service: string,
): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_JSON_RESPONSE_BYTES) {
        await reader.cancel();
        throw new TransportError(
          `${service} response is too large`,
          response.status,
        );
      }
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    reader.releaseLock();
  }
}

export async function parseJsonResponse<T>(
  response: Response,
  service: string,
): Promise<T> {
  if (!response.ok) {
    throw new TransportError(
      `${service} request failed with HTTP ${response.status}`,
      response.status,
    );
  }

  try {
    return JSON.parse(await readBoundedText(response, service)) as T;
  } catch (error) {
    if (error instanceof TransportError) throw error;
    throw new TransportError(
      `${service} returned malformed JSON`,
      response.status,
    );
  }
}

export function requireNonEmpty(value: string, label: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new TransportError(`${label} is required`);
  }
  return value;
}
