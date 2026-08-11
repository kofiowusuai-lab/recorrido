import { describe, expect, it } from 'vitest';
import { currencyForCountry, formatLocalizedPrice, localizedPrice } from '@/lib/site/pricing';

describe('localized pricing', () => {
  it('maps supported visitor countries to their local currencies and defaults to USD', () => {
    expect(currencyForCountry('CO')).toBe('COP');
    expect(currencyForCountry('PY')).toBe('PYG');
    expect(currencyForCountry('GB')).toBe('GBP');
    expect(currencyForCountry('US')).toBe('USD');
    expect(currencyForCountry('BR')).toBe('USD');
    expect(currencyForCountry(undefined)).toBe('USD');
  });

  it('returns integer minor-unit estimates for every supported currency', () => {
    expect(localizedPrice(79000, 'USD')).toBe(79000);
    expect(localizedPrice(79000, 'GBP')).toBeGreaterThan(0);
    expect(localizedPrice(79000, 'COP')).toBeGreaterThan(1_000_000);
    expect(localizedPrice(79000, 'PYG')).toBeGreaterThan(1_000_000);
  });

  it('formats zero-decimal COP and PYG and two-decimal GBP and USD', () => {
    expect(formatLocalizedPrice(2200, 'USD')).toContain('$22');
    expect(formatLocalizedPrice(localizedPrice(2200, 'GBP'), 'GBP')).toContain('£');
    expect(formatLocalizedPrice(localizedPrice(2200, 'COP'), 'COP')).toContain('COP');
    expect(formatLocalizedPrice(localizedPrice(2200, 'PYG'), 'PYG')).toContain('PYG');
  });
});
