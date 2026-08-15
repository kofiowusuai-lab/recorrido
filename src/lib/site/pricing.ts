export const supportedCurrencies = ['USD', 'COP', 'PYG', 'GBP'] as const;
export type DisplayCurrency = (typeof supportedCurrencies)[number];

const countryCurrencies: Record<string, DisplayCurrency> = { CO: 'COP', PY: 'PYG', GB: 'GBP', US: 'USD' };
const fallbackRates: Record<DisplayCurrency, number> = { USD: 1, COP: 4030, PYG: 7900, GBP: 0.77 };

export function currencyForCountry(country?: string | null): DisplayCurrency {
  return countryCurrencies[country?.toUpperCase() ?? ''] ?? 'USD';
}

export function localizedPrice(usdCents: number, currency: DisplayCurrency, rates: Partial<Record<DisplayCurrency, number>> = fallbackRates): number {
  const rate = rates[currency] ?? fallbackRates[currency];
  const usd = usdCents / 100;
  return currency === 'USD' || currency === 'GBP' ? Math.round(usd * rate * 100) : Math.round(usd * rate);
}

export function formatLocalizedPrice(amount: number, currency: DisplayCurrency, locale = 'en'): string {
  const fractionDigits = currency === 'USD' || currency === 'GBP' ? 2 : 0;
  const major = fractionDigits === 2 ? amount / 100 : amount;
  return new Intl.NumberFormat(locale, { style: 'currency', currency, minimumFractionDigits: fractionDigits, maximumFractionDigits: fractionDigits }).format(major);
}

export async function currentDisplayRates(): Promise<Record<DisplayCurrency, number>> {
  try {
    const response = await fetch('https://open.er-api.com/v6/latest/USD', { next: { revalidate: 3600 } });
    if (!response.ok) return fallbackRates;
    const body = await response.json() as { rates?: Record<string, unknown> };
    const rate = (code: DisplayCurrency) => typeof body.rates?.[code] === 'number' && body.rates[code] > 0 ? body.rates[code] : fallbackRates[code];
    return { USD: 1, COP: rate('COP'), PYG: rate('PYG'), GBP: rate('GBP') };
  } catch {
    return fallbackRates;
  }
}
