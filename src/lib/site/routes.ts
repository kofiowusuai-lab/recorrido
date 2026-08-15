export const routeSlugs = {
  es: { privacy: 'privacidad', terms: 'terminos', refunds: 'reembolsos', success: 'compra/exito', canceled: 'compra/cancelada', optout: 'baja' },
  pt: { privacy: 'privacidade', terms: 'termos', refunds: 'reembolsos', success: 'compra/sucesso', canceled: 'compra/cancelada', optout: 'descadastro' },
  en: { privacy: 'privacy', terms: 'terms', refunds: 'refunds', success: 'purchase/success', canceled: 'purchase/canceled', optout: 'opt-out' },
} as const;

export const publicRoutes = Object.entries(routeSlugs).flatMap(([locale, slugs]) => [
  `/${locale}`, ...Object.values(slugs).map((slug) => `/${locale}/${slug}`),
]);

export const sitemapRoutes = Object.entries(routeSlugs).flatMap(([locale, slugs]) => [
  `/${locale}`, ...Object.entries(slugs).filter(([kind]) => kind !== 'optout').map(([, slug]) => `/${locale}/${slug}`),
]);
