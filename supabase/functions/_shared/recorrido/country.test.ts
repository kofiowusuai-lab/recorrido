import { resolveCountry } from "./country.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("verified lead country has precedence over every other source", () => {
  assertEquals(
    resolveCountry({
      leadCountryCode: "CO",
      leadCountryVerified: true,
      officeCountryCode: "AR",
      officeCountryVerified: true,
      phone: "+56912345678",
      confirmedCountryCode: "PE",
      countryConfirmationVerified: true,
    }),
    {
      countryCode: "CO",
      currency: "COP",
      source: "lead",
      confidence: "verified",
    },
  );
});

for (
  const [countryCode, currency] of [
    ["BR", "BRL"],
    ["CL", "CLP"],
    ["PE", "PEN"],
    ["PY", "PYG"],
    ["DO", "DOP"],
  ] as const
) {
  Deno.test(`verified ${countryCode} lead resolves to ${currency}`, () => {
    assertEquals(
      resolveCountry({
        leadCountryCode: countryCode,
        leadCountryVerified: true,
      }),
      {
        countryCode,
        currency,
        source: "lead",
        confidence: "verified",
      },
    );
  });
}

Deno.test("verified office country beats phone inference", () => {
  assertEquals(
    resolveCountry({
      officeCountryCode: "AR",
      officeCountryVerified: true,
      phone: "+573001234567",
    }),
    {
      countryCode: "AR",
      currency: "ARS",
      source: "office",
      confidence: "verified",
    },
  );
});

Deno.test("unambiguous normalized E.164 phone is inferred before confirmation", () => {
  assertEquals(
    resolveCountry({
      phone: " +57 300 123 4567 ",
      confirmedCountryCode: "PE",
      countryConfirmationVerified: true,
    }),
    {
      countryCode: "CO",
      currency: "COP",
      source: "phone",
      confidence: "inferred",
    },
  );
});

Deno.test("verified customer confirmation is used after phone inference", () => {
  assertEquals(
    resolveCountry({
      confirmedCountryCode: "EC",
      countryConfirmationVerified: true,
    }),
    {
      countryCode: "EC",
      currency: "USD",
      source: "confirmation",
      confidence: "verified",
    },
  );
});

Deno.test("unsupported verified country retains country and falls back to USD", () => {
  assertEquals(
    resolveCountry({ leadCountryCode: "CA", leadCountryVerified: true }),
    {
      countryCode: "CA",
      currency: "USD",
      source: "lead",
      confidence: "verified",
    },
  );
});

Deno.test("ambiguous +1 phone does not infer a country", () => {
  assertEquals(resolveCountry({ phone: "+14165551234" }), {
    countryCode: null,
    currency: "USD",
    source: "fallback",
    confidence: "unknown",
  });
});

Deno.test("ambiguous +1 permits explicit verified confirmation", () => {
  assertEquals(
    resolveCountry({
      phone: "+12025550123",
      confirmedCountryCode: "US",
      countryConfirmationVerified: true,
    }),
    {
      countryCode: "US",
      currency: "USD",
      source: "confirmation",
      confidence: "verified",
    },
  );
});

Deno.test("malformed phone is rejected rather than guessed", () => {
  assertEquals(resolveCountry({ phone: "57300CALLNOW" }), {
    countryCode: null,
    currency: "USD",
    source: "fallback",
    confidence: "unknown",
  });
});

Deno.test("invalid lowercase ISO country code is ignored", () => {
  assertEquals(
    resolveCountry({ leadCountryCode: "co", leadCountryVerified: true }),
    {
      countryCode: null,
      currency: "USD",
      source: "fallback",
      confidence: "unknown",
    },
  );
});
