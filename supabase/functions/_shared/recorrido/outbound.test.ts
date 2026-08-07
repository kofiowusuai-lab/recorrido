import { decideOwnerAction, getSendInstruction } from "./outbound.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const owner = "+573001234567";
const draftId = "2d7f4e26-5ad0-4ce1-97d7-4cc72f4f62dc";
const pending = {
  ownerWhatsAppE164: owner,
  actorWhatsApp: " +57 300 123 4567 ",
  draftId,
  currentDraftVersion: 3,
  status: "pending" as const,
  now: 2_000,
  token: {
    opaqueId: "opaque-action-token",
    signatureValid: true,
    action: "approve" as const,
    draftId,
    draftVersion: 3,
    expiresAt: 3_000,
    consumedAt: null,
  },
};

Deno.test("exact normalized owner approval records owner and current version", () => {
  assertEquals(decideOwnerAction(pending), {
    accepted: true,
    decision: "approve",
    draftId,
    approvedBy: owner,
    approvedVersion: 3,
    consumeToken: true,
  });
});

Deno.test("non-owner and invalid signed token metadata are rejected", () => {
  assertEquals(
    decideOwnerAction({ ...pending, actorWhatsApp: "+573001234568" }),
    { accepted: false, reason: "not_owner" },
  );
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, signatureValid: false },
    }),
    { accepted: false, reason: "invalid_token" },
  );
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, opaqueId: "" },
    }),
    { accepted: false, reason: "invalid_token" },
  );
});

Deno.test("runtime-cast malformed action gate values fail closed", () => {
  const invalidTokens = [
    { signatureValid: "true" },
    { opaqueId: "   " },
    { opaqueId: " opaque-action-token " },
    { opaqueId: "unsafe token" },
    { opaqueId: "a".repeat(257) },
    { draftId: "" },
    { draftId: "draft-7" },
    { draftVersion: 0 },
    { draftVersion: 1.5 },
    { draftVersion: Number.MAX_SAFE_INTEGER + 1 },
    { expiresAt: Number.NaN },
    { expiresAt: Number.POSITIVE_INFINITY },
    { consumedAt: "never" },
  ];
  for (const changes of invalidTokens) {
    assertEquals(
      decideOwnerAction(
        {
          ...pending,
          token: { ...pending.token, ...changes },
        } as typeof pending,
      ),
      { accepted: false, reason: "invalid_token" },
    );
  }

  const invalidInputs = [
    { draftId: "" },
    { draftId: "not-a-uuid" },
    { currentDraftVersion: 0 },
    { currentDraftVersion: 1.5 },
    { currentDraftVersion: Number.MAX_SAFE_INTEGER + 1 },
    { now: Number.NaN },
    { now: Number.NEGATIVE_INFINITY },
  ];
  for (const changes of invalidInputs) {
    const decision = decideOwnerAction(
      {
        ...pending,
        ...changes,
      } as typeof pending,
    );
    assert(!decision.accepted, "malformed input must not be accepted");
    assert(
      !("draftId" in decision) || decision.draftId !== "",
      "a decision must never contain an empty draftId",
    );
  }
  assertEquals(
    decideOwnerAction(null as unknown as typeof pending),
    { accepted: false, reason: "invalid_input" },
  );
});

Deno.test("expired and replayed action tokens are rejected", () => {
  assertEquals(decideOwnerAction({ ...pending, now: 3_000 }), {
    accepted: false,
    reason: "expired_token",
  });
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, consumedAt: 1_900 },
    }),
    { accepted: false, reason: "consumed_token" },
  );
});

Deno.test("wrong token draft, version, action, or state is rejected", () => {
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: {
        ...pending.token,
        draftId: "85938c06-f86c-4028-b84f-b1274662e8de",
      },
    }),
    { accepted: false, reason: "draft_mismatch" },
  );
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, draftVersion: 2 },
    }),
    { accepted: false, reason: "version_mismatch" },
  );
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, action: "archive" as "approve" },
    }),
    { accepted: false, reason: "invalid_action" },
  );
  assertEquals(
    decideOwnerAction({ ...pending, status: "approved" as "pending" }),
    { accepted: false, reason: "not_pending" },
  );
});

Deno.test("edit consumes the token but never approves or sends", () => {
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, action: "edit" },
    }),
    {
      accepted: true,
      decision: "need_new_review",
      draftId,
      invalidateCurrentToken: true,
      consumeToken: true,
    },
  );
});

Deno.test("reject consumes the token and blocks the draft", () => {
  assertEquals(
    decideOwnerAction({
      ...pending,
      token: { ...pending.token, action: "reject" },
    }),
    {
      accepted: true,
      decision: "reject",
      draftId,
      blocked: true,
      consumeToken: true,
    },
  );
});

const approvedRow = {
  id: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
  draftId,
  status: "approved",
  approvedAt: "2026-08-05T12:00:00.000Z",
  approvedBy: owner,
  ownerWhatsAppE164: owner,
  approvedVersion: 3,
  currentDraftVersion: 3,
  optedOut: false,
  sentAt: null,
  providerMessageId: null,
  recipientE164: "+573109876543",
  body: "Approved listing message",
};

Deno.test("dispatcher returns a minimal deeply immutable send instruction", () => {
  const instruction = getSendInstruction(approvedRow);
  assertEquals(instruction, {
    outboundId: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
    recipientE164: "+573109876543",
    body: "Approved listing message",
  });
  assert(instruction !== null && Object.isFrozen(instruction));
});

Deno.test("dispatcher blocks opt-out and every missing approval invariant", () => {
  const variants = [
    { status: "pending" },
    { approvedAt: null },
    { approvedBy: "+573001234568" },
    { approvedVersion: 2 },
    { optedOut: true },
    { sentAt: "2026-08-05T12:01:00Z" },
    { providerMessageId: "wamid.1" },
    { recipientE164: "3109876543" },
    { body: "" },
    { body: "   " },
    { id: "" },
    { draftId: "" },
    { currentDraftVersion: 0 },
  ];
  for (const changes of variants) {
    assertEquals(getSendInstruction({ ...approvedRow, ...changes }), null);
  }
});

Deno.test("dispatcher rejects malformed runtime-cast gate row metadata", () => {
  const malformed = [
    { id: "outbound-1" },
    { id: 42 },
    { draftId: "draft-1" },
    { draftId: 42 },
    { status: true },
    { approvedAt: "today" },
    { approvedAt: "2026-02-30T12:00:00.000Z" },
    { approvedAt: "2026-08-05 12:00:00Z" },
    { approvedAt: "2026-08-05T12:00:00" },
    { approvedAt: Number.POSITIVE_INFINITY },
    { approvedBy: true },
    { ownerWhatsAppE164: 57_300_123_4567 },
    { currentDraftVersion: "3" },
    { currentDraftVersion: 1.5 },
    { currentDraftVersion: Number.MAX_SAFE_INTEGER + 1 },
    { approvedVersion: "3" },
    { approvedVersion: 0 },
    { approvedVersion: 1.5 },
    { approvedVersion: Number.MAX_SAFE_INTEGER + 1 },
    { optedOut: 0 },
    { optedOut: "false" },
    { sentAt: undefined },
    { sentAt: false },
    { providerMessageId: undefined },
    { providerMessageId: false },
    { recipientE164: 57_310_987_6543 },
    { body: 42 },
    { body: "x".repeat(4_097) },
  ];
  for (const changes of malformed) {
    assertEquals(
      getSendInstruction({ ...approvedRow, ...changes }),
      null,
    );
  }
});

Deno.test("dispatcher accepts strict boundary metadata without rewriting the body", () => {
  const body = ` ${"x".repeat(4_094)} `;
  assertEquals(
    getSendInstruction({
      ...approvedRow,
      approvedAt: "2024-02-29T23:59:59.123456+05:30",
      approvedVersion: Number.MAX_SAFE_INTEGER,
      currentDraftVersion: Number.MAX_SAFE_INTEGER,
      body,
    }),
    {
      outboundId: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
      recipientE164: "+573109876543",
      body,
    },
  );
});

Deno.test("dispatcher accepts only a loaded row and ignores no arbitrary request input", () => {
  assertEquals(
    getSendInstruction({
      recipientE164: "+573109876543",
      body: "attacker text",
    }),
    null,
  );
  const instruction = getSendInstruction({
    ...approvedRow,
    requestRecipient: "+573000000000",
    requestText: "attacker text",
  });
  assertEquals(instruction, {
    outboundId: "a54e5c7a-3854-44b8-bb08-6f96ac7073e3",
    recipientE164: "+573109876543",
    body: "Approved listing message",
  });
});
