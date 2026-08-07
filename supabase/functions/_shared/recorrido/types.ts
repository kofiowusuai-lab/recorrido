export type Currency =
  | "ARS"
  | "BRL"
  | "CLP"
  | "COP"
  | "DOP"
  | "PEN"
  | "PYG"
  | "USD";

export type CountrySource =
  | "lead"
  | "office"
  | "phone"
  | "confirmation"
  | "fallback";
export type CountryConfidence = "verified" | "inferred" | "unknown";

export interface CountryResolutionInput {
  leadCountryCode?: string | null;
  leadCountryVerified?: boolean;
  officeCountryCode?: string | null;
  officeCountryVerified?: boolean;
  phone?: string | null;
  confirmedCountryCode?: string | null;
  countryConfirmationVerified?: boolean;
}

export interface CountryResolution {
  countryCode: string | null;
  currency: Currency;
  source: CountrySource;
  confidence: CountryConfidence;
}

export type Plan = "pro" | "agency";

export interface PlanState {
  active: boolean;
  plan: string;
}

export type CatalogCode =
  | "single_listing_once_usd_22"
  | "pro_monthly_usd_32"
  | "pro_annual_usd_320"
  | "agency_monthly_usd_79"
  | "pro_extra_once_usd_18"
  | "agency_extra_once_usd_15";

export interface OneTimeCatalogItem {
  readonly kind: "one_time";
  readonly currency: "USD";
  readonly unitAmount: number;
  readonly credits: number;
  readonly requiredPlan: Plan | null;
}

export interface SubscriptionCatalogItem {
  readonly kind: "subscription";
  readonly interval: "month" | "year";
  readonly currency: "USD";
  readonly unitAmount: number;
  readonly monthlyCredits: number;
  readonly memberLimit: number;
  readonly plan: Plan;
  readonly shared?: true;
}

export type CatalogItem = OneTimeCatalogItem | SubscriptionCatalogItem;

export type CheckoutEligibility =
  | { eligible: true }
  | {
    eligible: false;
    reason: "unknown_code" | "inactive_plan" | "plan_mismatch";
  };
