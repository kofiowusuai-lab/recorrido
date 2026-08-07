import type {
  CountryResolution,
  CountryResolutionInput,
  CountrySource,
  Currency,
} from "./types.ts";

const CURRENCY_BY_COUNTRY: Readonly<Record<string, Currency>> = Object.freeze({
  AR: "ARS",
  BR: "BRL",
  CL: "CLP",
  CO: "COP",
  DO: "DOP",
  EC: "USD",
  PE: "PEN",
  PY: "PYG",
  US: "USD",
});

const PHONE_COUNTRIES: ReadonlyArray<
  readonly [prefix: string, countryCode: string]
> = [
  ["595", "PY"],
  ["593", "EC"],
  ["57", "CO"],
  ["56", "CL"],
  ["55", "BR"],
  ["54", "AR"],
  ["51", "PE"],
];

function validCountryCode(value: string | null | undefined): value is string {
  return typeof value === "string" && /^[A-Z]{2}$/.test(value);
}

function resolution(
  countryCode: string,
  source: CountrySource,
): CountryResolution {
  return {
    countryCode,
    currency: CURRENCY_BY_COUNTRY[countryCode] ?? "USD",
    source,
    confidence: source === "phone" ? "inferred" : "verified",
  };
}

function inferPhoneCountry(phone: string | null | undefined): string | null {
  if (typeof phone !== "string" || /[^\d+\s().-]/.test(phone)) return null;
  const normalized = phone.replace(/[\s().-]/g, "");
  if (!/^\+[1-9]\d{6,14}$/.test(normalized)) return null;

  const digits = normalized.slice(1);
  if (digits.startsWith("1")) return null;
  return PHONE_COUNTRIES.find(([prefix]) => digits.startsWith(prefix))?.[1] ??
    null;
}

export function resolveCountry(
  input: CountryResolutionInput,
): CountryResolution {
  if (input.leadCountryVerified && validCountryCode(input.leadCountryCode)) {
    return resolution(input.leadCountryCode, "lead");
  }
  if (
    input.officeCountryVerified && validCountryCode(input.officeCountryCode)
  ) {
    return resolution(input.officeCountryCode, "office");
  }

  const phoneCountry = inferPhoneCountry(input.phone);
  if (phoneCountry !== null) return resolution(phoneCountry, "phone");

  if (
    input.countryConfirmationVerified &&
    validCountryCode(input.confirmedCountryCode)
  ) {
    return resolution(input.confirmedCountryCode, "confirmation");
  }

  return {
    countryCode: null,
    currency: "USD",
    source: "fallback",
    confidence: "unknown",
  };
}
