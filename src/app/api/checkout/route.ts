import { NextRequest, NextResponse } from 'next/server';
import { allowCheckoutAttempt } from '@/lib/checkout/rate-limit';
import { createCheckoutResponse } from '@/lib/checkout/server';

export const runtime = 'nodejs';
const MAX_BODY = 8_192;

export async function POST(request: NextRequest) {
  const length = Number(request.headers.get('content-length') ?? 0);
  if (length > MAX_BODY) return NextResponse.json({ code: 'invalid_request' }, { status: 413 });
  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'local';
  if (!allowCheckoutAttempt(ip)) return NextResponse.json({ code: 'try_later' }, { status: 429 });
  let raw: unknown;
  try { const text = await request.text(); if (text.length > MAX_BODY) throw new Error('large'); raw = JSON.parse(text); }
  catch { return NextResponse.json({ code: 'invalid_request' }, { status: 400 }); }
  const configuredOrigin = process.env.NEXT_PUBLIC_SITE_URL;
  const origin = configuredOrigin?.startsWith('https://')
    ? configuredOrigin.replace(/\/$/, '')
    : process.env.NODE_ENV === 'production' ? '' : request.nextUrl.origin;
  if (!origin) return NextResponse.json({ code: 'checkout_unavailable' }, { status: 503 });
  const result = await createCheckoutResponse(raw, origin);
  return NextResponse.json(result.body, { status: result.status });
}
