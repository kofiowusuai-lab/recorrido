import { parseJsonResponse, requireNonEmpty, TransportError } from "./http.ts";

export interface SupabaseClientOptions {
  baseUrl: string;
  serviceRoleKey: string;
  accessToken?: string;
  fetch?: typeof fetch;
}

type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | {
  [key: string]: JsonValue;
};
export type FilterValue = string | number | boolean;

function identifier(value: string, label: string): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) {
    throw new TransportError(`Invalid Supabase ${label}`);
  }
  return value;
}

function appendFilters(
  params: URLSearchParams,
  filters: Record<string, FilterValue> = {},
): URLSearchParams {
  for (const key of Object.keys(filters).sort()) {
    params.set(identifier(key, "filter column"), `eq.${String(filters[key])}`);
  }
  return params;
}

function requireFilters(
  filters: Record<string, FilterValue>,
): Record<string, FilterValue> {
  if (Object.keys(filters).length === 0) {
    throw new TransportError("Supabase update requires at least one filter");
  }
  return filters;
}

export function createSupabaseClient(options: SupabaseClientOptions) {
  const key = requireNonEmpty(
    options.serviceRoleKey,
    "Supabase service-role key",
  );
  const accessToken = options.accessToken === undefined
    ? key
    : requireNonEmpty(options.accessToken, "Supabase scoped access token");
  let base: URL;
  try {
    base = new URL(requireNonEmpty(options.baseUrl, "Supabase base URL"));
  } catch {
    throw new TransportError("Invalid Supabase base URL");
  }
  if (
    base.protocol !== "https:" || base.username || base.password ||
    base.search || base.hash
  ) {
    throw new TransportError("Invalid Supabase base URL");
  }
  base.pathname = `${base.pathname.replace(/\/+$/, "")}/rest/v1/`;
  const fetcher = options.fetch ?? fetch;

  async function request<T>(
    method: string,
    path: string,
    body?: JsonValue,
    params?: URLSearchParams,
    representation = false,
  ): Promise<T> {
    const url = new URL(path, base);
    if (params) url.search = params.toString();
    const headers = new Headers({
      apikey: key,
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    });
    if (representation) headers.set("Prefer", "return=representation");
    try {
      const response = await fetcher(url, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      return await parseJsonResponse<T>(response, "Supabase");
    } catch (error) {
      if (error instanceof TransportError) throw error;
      throw new TransportError("Supabase transport request failed");
    }
  }

  return {
    rpc: <T = unknown>(
      functionName: string,
      args: Record<string, JsonValue>,
    ): Promise<T> =>
      request<T>(
        "POST",
        `rpc/${identifier(functionName, "RPC function")}`,
        args,
      ),
    select: <T = unknown[]>(
      table: string,
      options: { select?: string[]; filters?: Record<string, FilterValue> } =
        {},
    ): Promise<T> => {
      const params = new URLSearchParams();
      if (options.select) {
        params.set(
          "select",
          options.select.map((column) => identifier(column, "select column"))
            .join(","),
        );
      }
      appendFilters(params, options.filters);
      return request<T>("GET", identifier(table, "table"), undefined, params);
    },
    insert: <T = unknown[]>(table: string, rows: JsonValue): Promise<T> =>
      request<T>("POST", identifier(table, "table"), rows, undefined, true),
    update: <T = unknown[]>(
      table: string,
      values: JsonValue,
      filters: Record<string, FilterValue>,
    ): Promise<T> =>
      request<T>(
        "PATCH",
        identifier(table, "table"),
        values,
        appendFilters(new URLSearchParams(), requireFilters(filters)),
        true,
      ),
  };
}
