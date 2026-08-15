export const catalogCodes = ['single', 'pro_monthly', 'pro_annual', 'agency_monthly', 'agency_annual'] as const;
export type CatalogCode = (typeof catalogCodes)[number];
export const catalog = {
  single: { usdCents: 2200, cadence: 'once', generations: 1, members: 1 },
  pro_monthly: { usdCents: 3200, cadence: 'month', generations: 4, members: 1 },
  pro_annual: { usdCents: 32000, cadence: 'year', generations: 4, members: 1 },
  agency_monthly: { usdCents: 7900, cadence: 'month', generations: 12, members: 3 },
  agency_annual: { usdCents: 79000, cadence: 'year', generations: 12, members: 3 },
} as const satisfies Record<CatalogCode, { usdCents: number; cadence: 'once' | 'month' | 'year'; generations: number; members: number }>;
