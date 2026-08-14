import { NextRequest, NextResponse } from 'next/server';
import { validOptOutResponse } from '@/lib/site/optout';

const TOKEN = /^[A-Za-z0-9_-]{32,256}$/;
const LOCALES = new Set(['en', 'es', 'pt-BR']);
const MAX_BODY_BYTES = 4_096;

const response = (status: number, body: unknown) => NextResponse.json(body, {
  status,
  headers: { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff' },
});

function upstream(): string | null {
  const configured = process.env.RECORRIDO_OPTOUT_EDGE_URL?.trim();
  if (!configured) return null;
  try {
    const url = new URL(configured);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || !url.pathname.endsWith('/functions/v1/recorrido-outreach-optout')) return null;
    return url.toString();
  } catch {
    return null;
  }
}

export async function POST(request: NextRequest) {
  if ((request.headers.get('content-type') ?? '').toLowerCase() !== 'application/json') return response(415, { status: 'unavailable' });
  const declared = request.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_BODY_BYTES)) return response(400, { status: 'unavailable' });
  const raw = await request.text();
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return response(400, { status: 'unavailable' });
  let input: unknown;
  try { input = JSON.parse(raw); } catch { return response(400, { status: 'unavailable' }); }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return response(400, { status: 'unavailable' });
  const body = input as Record<string, unknown>;
  if (JSON.stringify(Object.keys(body).sort()) !== JSON.stringify(['locale', 'token']) || typeof body.token !== 'string' || !TOKEN.test(body.token) || typeof body.locale !== 'string' || !LOCALES.has(body.locale)) return response(400, { status: 'unavailable' });
  const endpoint = upstream();
  if (!endpoint) return response(503, { status: 'unavailable' });
  try {
    const result = await fetch(endpoint, {
      method: 'POST', headers: { 'content-type': 'application/json' }, cache: 'no-store', redirect: 'error',
      signal: AbortSignal.timeout(8_000), body: JSON.stringify({ token: body.token, locale: body.locale }),
    });
    if (!result.ok || result.status !== 200 || !(result.headers.get('content-type') ?? '').toLowerCase().startsWith('application/json')) return response(503, { status: 'unavailable' });
    const payload: unknown = await result.json();
    if (!validOptOutResponse(payload)) return response(503, { status: 'unavailable' });
    return response(200, payload);
  } catch {
    return response(503, { status: 'unavailable' });
  }
}
