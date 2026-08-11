import { describe, expect, it } from 'vitest';

import { catalog, catalogCodes } from '@/lib/site/catalog';
import { localeContent, locales } from '@/lib/site/locales';
import { publicRoutes } from '@/lib/site/routes';

describe('Recorrido public contract', () => {
  it('offers exactly the approved locale roster', () => {
    expect(locales).toEqual(['es', 'pt', 'en']);
    expect(Object.keys(localeContent)).toEqual(locales);
    expect(localeContent.pt.htmlLang).toBe('pt-BR');
  });

  it('publishes every localized landing, legal, and purchase-result route', () => {
    expect(publicRoutes).toEqual([
      '/es', '/es/privacidad', '/es/terminos', '/es/reembolsos', '/es/compra/exito', '/es/compra/cancelada',
      '/pt', '/pt/privacidade', '/pt/termos', '/pt/reembolsos', '/pt/compra/sucesso', '/pt/compra/cancelada',
      '/en', '/en/privacy', '/en/terms', '/en/refunds', '/en/purchase/success', '/en/purchase/canceled',
    ]);
  });

  it('uses only the authoritative catalog and allowances', () => {
    expect(catalogCodes).toEqual(['single', 'pro_monthly', 'pro_annual', 'agency_monthly']);
    expect(catalog).toMatchObject({
      single: { usdCents: 2200, cadence: 'once', generations: 1 },
      pro_monthly: { usdCents: 3200, cadence: 'month', generations: 4 },
      pro_annual: { usdCents: 32000, cadence: 'year', generations: 4 },
      agency_monthly: { usdCents: 7900, cadence: 'month', generations: 12, members: 3 },
    });
  });

  it('keeps every locale free of prohibited claims and programs', () => {
    const visibleCopy = JSON.stringify(localeContent).toLowerCase();
    for (const prohibited of ['3d', '360°', '360º', 'walkthrough', 'testimonial', 'referral', 'referidos', 'indicações']) {
      expect(visibleCopy).not.toContain(prohibited);
    }
  });

  it('limits production-language promises to Spanish and Brazilian Portuguese', () => {
    expect(localeContent.es.facts.productionLanguages).toEqual(['Español', 'Português do Brasil']);
    expect(localeContent.pt.facts.productionLanguages).toEqual(['Espanhol', 'Português do Brasil']);
    expect(localeContent.en.facts.productionLanguages).toEqual(['Spanish', 'Brazilian Portuguese']);
  });
});
