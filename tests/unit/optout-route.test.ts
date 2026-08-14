import { NextRequest } from 'next/server';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { POST } from '@/app/api/opt-out/route';

const token = 'A'.repeat(32);
const request = (body: unknown, contentType = 'application/json') => new NextRequest('https://recorrido-website.vercel.app/api/opt-out', {
  method: 'POST', headers: { 'content-type': contentType }, body: JSON.stringify(body),
});

describe('opt-out proxy route', () => {
  afterEach(() => {
    delete process.env.RECORRIDO_OPTOUT_EDGE_URL;
    vi.unstubAllGlobals();
  });

  it('stays unavailable until the reviewed Edge Function URL is configured', async () => {
    const response = await POST(request({ token, locale: 'es' }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: 'unavailable' });
  });

  it('rejects malformed bodies without contacting upstream', async () => {
    process.env.RECORRIDO_OPTOUT_EDGE_URL = 'https://project.supabase.co/functions/v1/recorrido-outreach-optout';
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    for (const body of [{ token: 'short', locale: 'es' }, { token, locale: 'fr' }, { token, locale: 'es', recipient: 'leak' }]) {
      expect((await POST(request(body))).status).toBe(400);
    }
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('forwards only the exact token envelope and returns only an exact success response', async () => {
    process.env.RECORRIDO_OPTOUT_EDGE_URL = 'https://project.supabase.co/functions/v1/recorrido-outreach-optout';
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify({ status: 'success', message: 'Done' }), { status: 200, headers: { 'content-type': 'application/json' } }));
    vi.stubGlobal('fetch', fetchSpy);
    const response = await POST(request({ token, locale: 'pt-BR' }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: 'success', message: 'Done' });
    expect(fetchSpy).toHaveBeenCalledWith(process.env.RECORRIDO_OPTOUT_EDGE_URL, expect.objectContaining({
      method: 'POST', redirect: 'error', body: JSON.stringify({ token, locale: 'pt-BR' }),
    }));
  });
});
