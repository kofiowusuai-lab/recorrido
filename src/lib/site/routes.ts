export const routeSlugs = {
  es: { privacy: 'privacidad', terms: 'terminos', refunds: 'reembolsos', success: 'compra/exito', canceled: 'compra/cancelada' },
  pt: { privacy: 'privacidade', terms: 'termos', refunds: 'reembolsos', success: 'compra/sucesso', canceled: 'compra/cancelada' },
  en: { privacy: 'privacy', terms: 'terms', refunds: 'refunds', success: 'purchase/success', canceled: 'purchase/canceled' },
} as const;

export const publicRoutes = Object.entries(routeSlugs).flatMap(([locale, slugs]) => [
  `/${locale}`, ...Object.values(slugs).map((slug) => `/${locale}/${slug}`),
]);
