import {
  CATALOG,
  extraCodeForPlan,
  getCatalogItem,
  getCheckoutEligibility,
  monthlyGrantQuantity,
} from "./catalog.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("approved catalog contains every exact immutable product", () => {
  assertEquals(CATALOG, {
    single_listing_once_usd_22: {
      kind: "one_time",
      currency: "USD",
      unitAmount: 2200,
      credits: 1,
      requiredPlan: null,
    },
    pro_monthly_usd_32: {
      kind: "subscription",
      interval: "month",
      currency: "USD",
      unitAmount: 3200,
      monthlyCredits: 4,
      memberLimit: 1,
      plan: "pro",
    },
    pro_annual_usd_320: {
      kind: "subscription",
      interval: "year",
      currency: "USD",
      unitAmount: 32000,
      monthlyCredits: 4,
      memberLimit: 1,
      plan: "pro",
    },
    agency_monthly_usd_79: {
      kind: "subscription",
      interval: "month",
      currency: "USD",
      unitAmount: 7900,
      monthlyCredits: 12,
      memberLimit: 3,
      plan: "agency",
      shared: true,
    },
    pro_extra_once_usd_18: {
      kind: "one_time",
      currency: "USD",
      unitAmount: 1800,
      credits: 1,
      requiredPlan: "pro",
    },
    agency_extra_once_usd_15: {
      kind: "one_time",
      currency: "USD",
      unitAmount: 1500,
      credits: 1,
      requiredPlan: "agency",
    },
  });
  if (!Object.isFrozen(CATALOG)) throw new Error("catalog must be immutable");
});

Deno.test("unknown catalog code fails closed", () => {
  assertEquals(getCatalogItem("not_a_product"), null);
  assertEquals(
    getCheckoutEligibility("not_a_product", { active: true, plan: "pro" }),
    { eligible: false, reason: "unknown_code" },
  );
});

Deno.test("single listing needs no active plan", () => {
  assertEquals(getCheckoutEligibility("single_listing_once_usd_22", null), {
    eligible: true,
  });
});

Deno.test("Pro extra requires an active matching Pro plan", () => {
  assertEquals(
    getCheckoutEligibility("pro_extra_once_usd_18", {
      active: true,
      plan: "pro",
    }),
    { eligible: true },
  );
  assertEquals(
    getCheckoutEligibility("pro_extra_once_usd_18", {
      active: false,
      plan: "pro",
    }),
    { eligible: false, reason: "inactive_plan" },
  );
  assertEquals(
    getCheckoutEligibility("pro_extra_once_usd_18", {
      active: true,
      plan: "agency",
    }),
    { eligible: false, reason: "plan_mismatch" },
  );
});

Deno.test("Agency extra requires an active matching Agency plan", () => {
  assertEquals(
    getCheckoutEligibility("agency_extra_once_usd_15", {
      active: true,
      plan: "agency",
    }),
    { eligible: true },
  );
  assertEquals(getCheckoutEligibility("agency_extra_once_usd_15", null), {
    eligible: false,
    reason: "inactive_plan",
  });
});

Deno.test("extra code selection fails closed for inactive or unknown plans", () => {
  assertEquals(
    extraCodeForPlan({ active: true, plan: "pro" }),
    "pro_extra_once_usd_18",
  );
  assertEquals(
    extraCodeForPlan({ active: true, plan: "agency" }),
    "agency_extra_once_usd_15",
  );
  assertEquals(extraCodeForPlan({ active: false, plan: "pro" }), null);
  assertEquals(extraCodeForPlan({ active: true, plan: "unknown" }), null);
});

Deno.test("annual Pro grants four credits monthly rather than upfront", () => {
  assertEquals(monthlyGrantQuantity("pro_annual_usd_320"), 4);
  assertEquals(monthlyGrantQuantity("pro_monthly_usd_32"), 4);
  assertEquals(monthlyGrantQuantity("agency_monthly_usd_79"), 12);
  assertEquals(monthlyGrantQuantity("single_listing_once_usd_22"), 0);
  assertEquals(monthlyGrantQuantity("not_a_product"), 0);
});
