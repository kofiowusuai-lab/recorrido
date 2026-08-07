import { parseJsonResponse } from "./http.ts";

function chunkedResponse(chunks: Uint8Array[]): Response {
  let index = 0;
  return new Response(
    new ReadableStream({
      pull(controller) {
        if (index === chunks.length) return controller.close();
        controller.enqueue(chunks[index++]);
      },
    }),
  );
}

Deno.test("shared JSON response parsing rejects chunked oversized bodies", async () => {
  const chunks = Array.from(
    { length: 17 },
    () => new Uint8Array(64 * 1024).fill(0x20),
  );
  let message = "";
  try {
    await parseJsonResponse(chunkedResponse(chunks), "Provider");
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  if (!/too large/i.test(message)) {
    throw new Error(`unexpected error: ${message}`);
  }
});
