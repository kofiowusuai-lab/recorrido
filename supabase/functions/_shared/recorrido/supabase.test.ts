import { createSupabaseClient } from "./supabase.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

async function assertRejects(
  operation: () => unknown | Promise<unknown>,
  pattern: RegExp,
  forbidden: string[] = [],
): Promise<void> {
  try {
    await operation();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    assert(pattern.test(message), `Expected ${pattern}, got ${message}`);
    for (const value of forbidden) {
      assert(!message.includes(value), `Error leaked ${value}`);
    }
    return;
  }
  throw new Error("Expected operation to reject");
}

Deno.test("Supabase RPC sends exact authenticated JSON request", async () => {
  let request: Request | undefined;
  const fetcher: typeof fetch = (input, init) => {
    request = new Request(input, init);
    return Promise.resolve(new Response('[{"ok":true}]', { status: 200 }));
  };
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co/",
    serviceRoleKey: "service_role_local",
    fetch: fetcher,
  });
  const result = await client.rpc<{ ok: boolean }[]>("claim_listing_credit", {
    p_user_id: "user-local",
    p_count: 1,
  });
  assert(request);
  assertEquals(
    request.url,
    "https://project.supabase.co/rest/v1/rpc/claim_listing_credit",
  );
  assertEquals(request.method, "POST");
  assertEquals(request.headers.get("apikey"), "service_role_local");
  assertEquals(
    request.headers.get("authorization"),
    "Bearer service_role_local",
  );
  assertEquals(request.headers.get("content-type"), "application/json");
  assertEquals(await request.text(), '{"p_user_id":"user-local","p_count":1}');
  assertEquals(result, [{ ok: true }]);
});

Deno.test("Supabase supports a scoped PostgREST bearer distinct from the API key", async () => {
  let request: Request | undefined;
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: "public_api_key",
    accessToken: "scoped_worker_jwt",
    fetch: (input, init) => {
      request = new Request(input, init);
      return Promise.resolve(new Response("{}", { status: 200 }));
    },
  });
  await client.rpc("worker_rpc", {});
  assert(request);
  assertEquals(request.headers.get("apikey"), "public_api_key");
  assertEquals(
    request.headers.get("authorization"),
    "Bearer scoped_worker_jwt",
  );
});

Deno.test("Supabase select safely encodes table, columns, and explicit filters", async () => {
  let url = "";
  const fetcher: typeof fetch = (input) => {
    url = String(input);
    return Promise.resolve(new Response("[]", { status: 200 }));
  };
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: "service_role_local",
    fetch: fetcher,
  });
  await client.select("billing_accounts", {
    select: ["id", "status"],
    filters: { owner_id: "user+local@example.test", status: "active&pending" },
  });
  assertEquals(
    url,
    "https://project.supabase.co/rest/v1/billing_accounts?select=id%2Cstatus&owner_id=eq.user%2Blocal%40example.test&status=eq.active%26pending",
  );
});

Deno.test("Supabase insert and update use representation and exact JSON", async () => {
  const requests: Request[] = [];
  const fetcher: typeof fetch = (input, init) => {
    requests.push(new Request(input, init));
    return Promise.resolve(
      new Response('[{"id":"row-local"}]', { status: 200 }),
    );
  };
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: "service_role_local",
    fetch: fetcher,
  });
  await client.insert("billing_accounts", {
    owner_id: "user-local",
    active: true,
  });
  await client.update("billing_accounts", { active: false }, {
    owner_id: "user-local",
  });
  assertEquals(requests[0].method, "POST");
  assertEquals(requests[0].headers.get("prefer"), "return=representation");
  assertEquals(
    await requests[0].text(),
    '{"owner_id":"user-local","active":true}',
  );
  assertEquals(requests[1].method, "PATCH");
  assertEquals(
    requests[1].url,
    "https://project.supabase.co/rest/v1/billing_accounts?owner_id=eq.user-local",
  );
  assertEquals(requests[1].headers.get("prefer"), "return=representation");
  assertEquals(await requests[1].text(), '{"active":false}');
});

Deno.test("Supabase update rejects empty filters before fetch", async () => {
  let fetchCalls = 0;
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: "service_role_local",
    fetch: () => {
      fetchCalls++;
      return Promise.resolve(new Response("[]", { status: 200 }));
    },
  });
  await assertRejects(
    () => client.update("billing_accounts", { active: false }, {}),
    /filter/i,
  );
  assertEquals(fetchCalls, 0);
});

Deno.test("Supabase non-2xx errors never expose key or sensitive body", async () => {
  const key = "service_role_must_not_leak";
  const sensitive = "private-row-payload";
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: key,
    fetch: () =>
      Promise.resolve(
        new Response(sensitive, { status: 403, statusText: "Forbidden" }),
      ),
  });
  await assertRejects(() => client.select("billing_accounts"), /403/, [
    key,
    `Bearer ${key}`,
    sensitive,
  ]);
});

Deno.test("Supabase rejects malformed success JSON without exposing it", async () => {
  const client = createSupabaseClient({
    baseUrl: "https://project.supabase.co",
    serviceRoleKey: "service_role_local",
    fetch: () =>
      Promise.resolve(
        new Response("private malformed payload", { status: 200 }),
      ),
  });
  await assertRejects(() => client.select("billing_accounts"), /json/i, [
    "private malformed payload",
  ]);
});

Deno.test("Supabase constructor rejects invalid base URLs and empty keys", () => {
  for (
    const baseUrl of [
      "",
      "not-a-url",
      "http://project.supabase.co",
      "ftp://project.supabase.co",
    ]
  ) {
    try {
      createSupabaseClient({ baseUrl, serviceRoleKey: "service_role_local" });
      throw new Error(`accepted invalid URL ${baseUrl}`);
    } catch (error) {
      assert(
        /url/i.test(error instanceof Error ? error.message : String(error)),
      );
    }
  }
  try {
    createSupabaseClient({
      baseUrl: "https://project.supabase.co",
      serviceRoleKey: "",
    });
    throw new Error("accepted empty key");
  } catch (error) {
    assert(/key/i.test(error instanceof Error ? error.message : String(error)));
  }
});
