import type { CatalogCode } from '@/lib/site/catalog';

const productCodes: Record<CatalogCode, string> = {
  single: 'single_listing_once_usd_22',
  pro_monthly: 'pro_monthly_usd_32',
  pro_annual: 'pro_annual_usd_320',
  agency_monthly: 'agency_monthly_usd_79',
};

export function canonicalProductCode(plan: CatalogCode) {
  return productCodes[plan];
}

export function checkoutSessionMode(plan: CatalogCode): 'payment' | 'subscription' {
  return plan === 'single' ? 'payment' : 'subscription';
}

export function purchaseType(plan: CatalogCode): 'single_listing' | 'subscription' {
  return plan === 'single' ? 'single_listing' : 'subscription';
}
