import { describe, expect, it } from 'vitest';

import { parseOptOutFragment, validOptOutResponse } from '@/lib/site/optout';
import { sitemapRoutes } from '@/lib/site/routes';

describe('Recorrido opt-out web contract', () => {
  it('accepts only bounded opaque fragment tokens and clears locale aliases', () => {
    const token = 'A'.repeat(32);
    expect(parseOptOutFragment(`#token=${token}&locale=pt-BR`)).toEqual({ token, locale: 'pt' });
    expect(parseOptOutFragment(`#${token}`)).toEqual({ token, locale: undefined });
    for (const fragment of ['', '#token=short', '#token=' + 'x'.repeat(257), '#token=unsafe%20token', '#token=' + 'a'.repeat(32) + '&extra=1']) {
      expect(parseOptOutFragment(fragment)).toBeNull();
    }
  });

  it('accepts only the exact successful localized response envelope', () => {
    expect(validOptOutResponse({ status: 'success', message: 'Done' })).toBe(true);
    expect(validOptOutResponse({ status: 'success', message: 'Done', token: 'leak' })).toBe(false);
    expect(validOptOutResponse({ status: 'suppressed', message: 'Done' })).toBe(false);
    expect(validOptOutResponse(null)).toBe(false);
  });

  it('keeps tokenized opt-out pages out of the sitemap', () => {
    expect(sitemapRoutes.some((route) => route.includes('baja') || route.includes('descadastro') || route.includes('opt-out'))).toBe(false);
  });
});
