import type {
  CatalogCode,
  CatalogItem,
  CheckoutEligibility,
  PlanState,
} from "./types.ts";

export const CATALOG: Readonly<Record<CatalogCode, CatalogItem>> = Object
  .freeze({
    single_listing_once_usd_22: Object.freeze({
      kind: "one_time",
      currency: "USD",
      unitAmount: 2200,
      credits: 1,
      requiredPlan: null,
    }),
    pro_monthly_usd_32: Object.freeze({
      kind: "subscription",
      interval: "month",
      currency: "USD",
      unitAmount: 3200,
      monthlyCredits: 4,
      memberLimit: 1,
      plan: "pro",
    }),
    pro_annual_usd_320: Object.freeze({
      kind: "subscription",
      interval: "year",
      currency: "USD",
      unitAmount: 32000,
      monthlyCredits: 4,
      memberLimit: 1,
      plan: "pro",
    }),
    agency_monthly_usd_79: Object.freeze({
      kind: "subscription",
      interval: "month",
      currency: "USD",
      unitAmount: 7900,
      monthlyCredits: 12,
      memberLimit: 3,
      plan: "agency",
      shared: true,
    }),
    pro_extra_once_usd_18: Object.freeze({
      kind: "one_time",
      currency: "USD",
      unitAmount: 1800,
      credits: 1,
      requiredPlan: "pro",
    }),
    agency_extra_once_usd_15: Object.freeze({
      kind: "one_time",
      currency: "USD",
      unitAmount: 1500,
      credits: 1,
      requiredPlan: "agency",
    }),
  });

function isCatalogCode(code: string): code is CatalogCode {
  return Object.hasOwn(CATALOG, code);
}

export function getCatalogItem(code: string): CatalogItem | null {
  return isCatalogCode(code) ? CATALOG[code] : null;
}

export function getCheckoutEligibility(
  code: string,
  planState: PlanState | null,
): CheckoutEligibility {
  const item = getCatalogItem(code);
  if (item === null) return { eligible: false, reason: "unknown_code" };
  if (item.kind !== "one_time" || item.requiredPlan === null) {
    return { eligible: true };
  }
  if (planState === null || !planState.active) {
    return { eligible: false, reason: "inactive_plan" };
  }
  if (planState.plan !== item.requiredPlan) {
    return { eligible: false, reason: "plan_mismatch" };
  }
  return { eligible: true };
}

export function extraCodeForPlan(
  planState: PlanState | null,
): CatalogCode | null {
  if (planState === null || !planState.active) return null;
  if (planState.plan === "pro") return "pro_extra_once_usd_18";
  if (planState.plan === "agency") return "agency_extra_once_usd_15";
  return null;
}

export function monthlyGrantQuantity(code: string): number {
  const item = getCatalogItem(code);
  return item?.kind === "subscription" ? item.monthlyCredits : 0;
}
