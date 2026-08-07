# Recorrido Billing and Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy an isolated Recorrido billing, entitlement, usage, and
owner-approved WhatsApp messaging backend inside the existing Kofi-Sketch
Supabase project.

**Architecture:** Prefix all database objects with `recorrido_` and all Edge
Functions with `recorrido-` so the shared project remains isolated. Stripe
webhooks authoritatively mirror payments and subscriptions into append-only
credit buckets and ledger entries. Customer outbound messages enter an approval
queue and only a signed, one-use action from Kofi’s allowlisted WhatsApp number
allows the dispatcher to call Meta.

**Tech Stack:** Supabase Postgres, SQL/PLpgSQL, Supabase Edge Functions, Deno
TypeScript, Stripe Checkout/webhooks, Meta WhatsApp Cloud API, pgTAP, Deno tests

---

## File map

- `supabase/config.toml`: local Supabase project configuration
- `supabase/migrations/202608040001_recorrido_core.sql`: isolated schema, RLS,
  constraints, audit triggers, and RPCs
- `supabase/tests/database/recorrido_core_test.sql`: pgTAP tests for credits,
  idempotency, team limits, and approval gates
- `supabase/functions/_shared/recorrido/types.ts`: shared domain types
- `supabase/functions/_shared/recorrido/country.ts`: country and currency
  resolution
- `supabase/functions/_shared/recorrido/catalog.ts`: internal price-code catalog
  and checkout rules
- `supabase/functions/_shared/recorrido/crypto.ts`: signature and opaque-token
  helpers
- `supabase/functions/_shared/recorrido/supabase.ts`: service-role client
  construction
- `supabase/functions/_shared/recorrido/stripe.ts`: Stripe client construction
  and event verification
- `supabase/functions/_shared/recorrido/whatsapp.ts`: Meta signature
  verification and message sending
- `supabase/functions/_shared/recorrido/outbound.ts`: approval state transitions
  and fail-closed dispatch checks
- `supabase/functions/_shared/recorrido/*.test.ts`: Deno unit tests for each
  shared module
- `supabase/functions/recorrido-create-checkout/index.ts`: customer-specific
  Checkout Session endpoint
- `supabase/functions/recorrido-stripe-webhook/index.ts`: signed Stripe webhook
  endpoint
- `supabase/functions/recorrido-whatsapp-webhook/index.ts`: Meta verification,
  inbound identity, and owner action endpoint
- `supabase/functions/recorrido-dispatch-approved/index.ts`: internal
  approved-row-only sender
- `supabase/functions/recorrido-grant-annual-quotas/index.ts`: scheduled
  annual-plan monthly credit grants
- `supabase/functions/recorrido-health/index.ts`: redacted operational health
  endpoint
- `supabase/seed.sql`: test-only launch catalog rows using placeholder Stripe
  IDs
- `docs/operations/recorrido-go-live-runbook.md`: secrets, Stripe products,
  webhook URLs, deployment, rollback, and verification
- `.env.example`: variable names only, with no credentials

### Task 1: Bootstrap and isolate the Supabase project

**Files:**

- Create: `supabase/config.toml`
- Modify: `.gitignore`
- Create: `.env.example`

- [ ] **Step 1: Add a repository guard test**

Create `tests/test_recorrido_secrets.py` to assert tracked files contain no live
Stripe, Supabase service-role, or Meta tokens and `.gitignore` excludes `.env`,
`.env.local`, and `supabase/.temp/`.

- [ ] **Step 2: Run the test and verify RED**

Run: `python3 -m pytest tests/test_recorrido_secrets.py -q` Expected: FAIL
because `.env.example` and `supabase/.temp/` coverage are absent.

- [ ] **Step 3: Initialize Supabase and add safe configuration**

Run `supabase init` if `supabase/config.toml` does not exist. Add
`supabase/.temp/`, `.env.*`, and local Edge Function secret files to
`.gitignore`, with an explicit `!.env.example` exception. Put variable names and
placeholder values only in `.env.example`.

- [ ] **Step 4: Link the local repository**

Run: `supabase link --project-ref stboueshyjvooiftfuxm` Expected: local project
reference written under ignored `supabase/.temp/`; no remote schema change.

- [ ] **Step 5: Verify GREEN and commit**

Run: `python3 -m pytest tests/test_recorrido_secrets.py -q` Expected: PASS.

Commit: `chore: bootstrap isolated Recorrido Supabase backend`

### Task 2: Create the isolated database schema

**Files:**

- Create: `supabase/tests/database/recorrido_core_test.sql`
- Create: `supabase/migrations/202608040001_recorrido_core.sql`

- [ ] **Step 1: Write failing pgTAP schema tests**

Tests assert all required `recorrido_` tables exist, every table has RLS
enabled, normalized WhatsApp numbers are unique for active members, Agency
accounts reject a fourth active member, money uses integer minor units, Stripe
event IDs are unique, and credit-ledger UPDATE/DELETE operations fail.

- [ ] **Step 2: Run the database test and verify RED**

Run: `supabase start && supabase db reset && supabase test db` Expected: FAIL
because the schema does not exist.

- [ ] **Step 3: Implement the minimal schema**

Create enums and the following prefixed tables:

- `recorrido_customer_accounts`
- `recorrido_account_members`
- `recorrido_stripe_price_catalog`
- `recorrido_stripe_events`
- `recorrido_stripe_subscriptions`
- `recorrido_stripe_payments`
- `recorrido_entitlement_periods`
- `recorrido_credit_buckets`
- `recorrido_credit_ledger`
- `recorrido_generation_reservations`
- `recorrido_generation_jobs`
- `recorrido_pending_outbound`
- `recorrido_outbound_action_tokens`
- `recorrido_outbound_approvals`
- `recorrido_outbound_deliveries`
- `recorrido_outbound_audit_log`

Enable RLS and create deny-by-default policies. Add immutable ledger and audit
triggers, partial unique indexes, foreign keys, check constraints, and
`updated_at` triggers.

- [ ] **Step 4: Run schema tests and verify GREEN**

Run: `supabase db reset && supabase test db` Expected: all pgTAP tests pass.

- [ ] **Step 5: Commit**

Commit: `feat: add isolated Recorrido billing schema`

### Task 3: Implement transactional credit accounting

**Files:**

- Modify: `supabase/tests/database/recorrido_core_test.sql`
- Modify: `supabase/migrations/202608040001_recorrido_core.sql`

- [ ] **Step 1: Write failing RPC tests**

Add pgTAP coverage for:

- purchased credit grant is idempotent by payment/source ID
- monthly grant is idempotent by subscription and period start
- available balance excludes expired and revoked buckets
- reservation spends earliest-expiring included credit first
- two reservations against one credit yield one success and one
  `insufficient_credits`
- consume is idempotent
- release restores one credit once
- inactive and past-due-outside-grace accounts cannot reserve

- [ ] **Step 2: Verify RED**

Run: `supabase db reset && supabase test db` Expected: FAIL because RPCs do not
exist.

- [ ] **Step 3: Implement RPCs**

Implement security-definer functions with fixed `search_path`:

- `recorrido_available_credits(uuid)`
- `recorrido_grant_purchased_credits(uuid, integer)`
- `recorrido_grant_subscription_period(uuid, timestamptz, timestamptz, integer)`
- `recorrido_reserve_generation(uuid, uuid, uuid)`
- `recorrido_consume_generation(uuid)`
- `recorrido_release_generation(uuid, text)`

Use advisory or row locks inside reservation functions. Never mutate existing
ledger rows.

- [ ] **Step 4: Verify GREEN and commit**

Run: `supabase db reset && supabase test db` Expected: all pgTAP tests pass.

Commit: `feat: add transactional Recorrido credit ledger`

### Task 4: Implement outbound approval invariants

**Files:**

- Modify: `supabase/tests/database/recorrido_core_test.sql`
- Modify: `supabase/migrations/202608040001_recorrido_core.sql`

- [ ] **Step 1: Write failing approval tests**

Tests assert:

- a pending row is not claimable for delivery
- only an approved row with a matching current version is claimable
- edit increments version and invalidates prior approvals/tokens
- rejection is terminal
- one-use tokens cannot be reused
- non-owner identifiers cannot create approval records
- a successful generation creates a pending delivery draft with the correct
  balance

- [ ] **Step 2: Verify RED**

Run: `supabase db reset && supabase test db` Expected: FAIL because approval
RPCs and triggers do not exist.

- [ ] **Step 3: Implement approval RPCs and audit triggers**

Implement:

- `recorrido_create_outbound_draft(...)`
- `recorrido_apply_owner_action(...)`
- `recorrido_apply_owner_edit(...)`
- `recorrido_claim_approved_outbound(integer)`
- `recorrido_mark_outbound_delivered(...)`
- `recorrido_mark_outbound_failed(...)`

Require the owner E.164 value as a server-supplied argument and compare it to
the inbound sender inside the transaction. Dispatcher claims use
`FOR UPDATE SKIP LOCKED` and require a current matching approval.

- [ ] **Step 4: Verify GREEN and commit**

Run: `supabase db reset && supabase test db` Expected: all pgTAP tests pass.

Commit: `feat: enforce owner-approved Recorrido outbound delivery`

### Task 5: Implement country and price resolution

**Files:**

- Create: `supabase/functions/_shared/recorrido/types.ts`
- Create: `supabase/functions/_shared/recorrido/country.test.ts`
- Create: `supabase/functions/_shared/recorrido/catalog.test.ts`
- Create: `supabase/functions/_shared/recorrido/country.ts`
- Create: `supabase/functions/_shared/recorrido/catalog.ts`

- [ ] **Step 1: Write failing Deno tests**

Tests cover verified lead country precedence, office precedence, E.164 fallback,
ambiguous +1 behavior, Ecuador-to-USD mapping, unsupported-country USD fallback,
plan eligibility, Agency overage selection, and annual Pro monthly quota
configuration.

- [ ] **Step 2: Verify RED**

Run:
`deno test supabase/functions/_shared/recorrido/country.test.ts supabase/functions/_shared/recorrido/catalog.test.ts`
Expected: FAIL because modules do not exist.

- [ ] **Step 3: Implement pure domain modules**

Country resolution returns `{countryCode, currency, source, confidence}`.
Catalog resolution uses internal price codes and never embeds live Stripe IDs.

- [ ] **Step 4: Verify GREEN and commit**

Run: `deno test supabase/functions/_shared/recorrido/*.test.ts` Expected: all
tests pass.

Commit: `feat: add Recorrido market and catalog resolution`

### Task 6: Implement Stripe Checkout and webhook processing

**Files:**

- Create: `supabase/functions/_shared/recorrido/crypto.test.ts`
- Create: `supabase/functions/_shared/recorrido/crypto.ts`
- Create: `supabase/functions/_shared/recorrido/supabase.ts`
- Create: `supabase/functions/_shared/recorrido/stripe.ts`
- Create: `supabase/functions/recorrido-create-checkout/index.ts`
- Create: `supabase/functions/recorrido-stripe-webhook/index.ts`

- [ ] **Step 1: Write failing unit tests**

Test constant-time signature helpers, metadata validation, checkout-request
idempotency, permitted purchase codes, customer/account matching, and replayed
event behavior through pure handler functions.

- [ ] **Step 2: Verify RED**

Run: `deno test supabase/functions/_shared/recorrido/*.test.ts` Expected: FAIL
for missing Stripe helpers.

- [ ] **Step 3: Implement Checkout Session creation**

Require authenticated internal service access or a signed customer action token.
Resolve the account and member, load the active Stripe price ID from
`recorrido_stripe_price_catalog`, create/reuse the Stripe customer, and create
an idempotent Checkout Session. Add internal metadata and enable Adaptive
Pricing. Return only the hosted Checkout URL and session expiry.

- [ ] **Step 4: Implement signed webhook processing**

Verify the raw payload with `STRIPE_WEBHOOK_SECRET`. Insert the event before
processing and short-circuit duplicates. Upsert subscription/payment mirrors,
store actual amount/currency, grant or revoke credits through RPCs, and create
pending customer drafts for payment and renewal events. Return 2xx only after
durable processing or recognized replay.

- [ ] **Step 5: Verify GREEN and commit**

Run: `deno test supabase/functions/_shared/recorrido/*.test.ts` Expected: all
tests pass.

Commit: `feat: add Stripe checkout and webhook processing`

### Task 7: Implement WhatsApp owner approval and fail-closed dispatch

**Files:**

- Create: `supabase/functions/_shared/recorrido/outbound.test.ts`
- Create: `supabase/functions/_shared/recorrido/whatsapp.test.ts`
- Create: `supabase/functions/_shared/recorrido/outbound.ts`
- Create: `supabase/functions/_shared/recorrido/whatsapp.ts`
- Create: `supabase/functions/recorrido-whatsapp-webhook/index.ts`
- Create: `supabase/functions/recorrido-dispatch-approved/index.ts`

- [ ] **Step 1: Write failing tests**

Tests cover Meta signature verification, webhook challenge verification, phone
normalization, owner-only action acceptance, edit-follow-up behavior, one-use
token expiry, approved-version matching, opt-out blocking, and dispatcher
refusal when any approval invariant is missing.

- [ ] **Step 2: Verify RED**

Run: `deno test supabase/functions/_shared/recorrido/*.test.ts` Expected: FAIL
because modules do not exist.

- [ ] **Step 3: Implement webhook and review actions**

Verify Meta signatures. Customer messages create internal work items only. Owner
button actions call the approval RPC. Owner edit text updates the selected
draft, invalidates prior tokens, and creates a new internal review card. No
inbound customer path calls the send API.

- [ ] **Step 4: Implement dispatcher**

Accept only a queue row ID or claim approved rows internally. Re-read approval,
draft version, opt-out, and owner identity immediately before sending. Call Meta
using `WHATSAPP_ACCESS_TOKEN` and `WHATSAPP_PHONE_NUMBER_ID`; record provider
response or failure. Reject arbitrary recipient/text input.

- [ ] **Step 5: Verify GREEN and commit**

Run: `deno test supabase/functions/_shared/recorrido/*.test.ts` Expected: all
tests pass.

Commit: `feat: add owner-gated Recorrido WhatsApp delivery`

### Task 8: Implement annual grants, health checks, and operational docs

**Files:**

- Create: `supabase/functions/recorrido-grant-annual-quotas/index.ts`
- Create: `supabase/functions/recorrido-health/index.ts`
- Create: `docs/operations/recorrido-go-live-runbook.md`
- Create: `supabase/seed.sql`

- [ ] **Step 1: Write failing annual-grant and health tests**

Test due-date selection, idempotent monthly grants, no grant after
cancellation/end, no secret values in health output, stale webhook detection,
and payment-without-entitlement detection.

- [ ] **Step 2: Verify RED**

Run Deno and pgTAP suites. Expected: FAIL for absent annual and health handlers.

- [ ] **Step 3: Implement annual grant handler and health endpoint**

The scheduled handler processes only active annual Pro subscriptions whose
`next_credit_grant_at` is due, grants one four-credit monthly period
idempotently, then advances the due time. The health endpoint returns counts and
timestamps without PII or secrets.

- [ ] **Step 4: Write launch runbook**

Document:

- exact Stripe products/prices to create
- required restricted-key permissions
- Supabase secret names
- webhook endpoints and events
- Meta webhook configuration
- project linking and migrations
- Edge Function deployment
- catalog seeding with real Stripe IDs
- owner-number configuration
- local and remote smoke tests
- rollback and migration-to-dedicated-project procedure

- [ ] **Step 5: Verify GREEN and commit**

Run full test suite and documentation checks.

Commit: `docs: add Recorrido billing operations runbook`

### Task 9: Deploy and perform go-live verification

**Files:**

- Modify only generated local linkage under ignored `supabase/.temp/`

- [ ] **Step 1: Verify required secrets by name only**

Check for `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`, `META_APP_SECRET`, `WHATSAPP_ACCESS_TOKEN`,
`WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_VERIFY_TOKEN`, and `OWNER_WHATSAPP_E164`.
Never print values.

- [ ] **Step 2: Push migration to Kofi-Sketch**

Run: `supabase db push --linked` Expected: only `recorrido_` objects are created
or altered.

- [ ] **Step 3: Deploy Edge Functions**

Deploy each `recorrido-*` function. Stripe and Meta webhook functions use their
own signature validation; configure JWT verification according to endpoint role.

- [ ] **Step 4: Configure Stripe and Meta external endpoints**

Create Stripe webhook destination, install the returned signing secret in
Supabase secrets, configure Meta verification, and seed live Stripe price IDs.

- [ ] **Step 5: Run live-mode-safe smoke tests**

Use Stripe test mode first:

- successful single purchase grants one credit once
- replayed webhook grants nothing extra
- Pro subscription grants four
- failed payment creates a pending draft and sends nothing
- one-credit concurrent reservation permits one job
- failed generation releases the credit
- non-owner approval fails
- owner edit does not send
- owner approval sends once and records the provider message ID

- [ ] **Step 6: Final verification**

Run:

```bash
python3 -m pytest tests -q
deno test supabase/functions/_shared/recorrido/*.test.ts
supabase db reset
supabase test db
git diff --check
git status --short
```

Record exact pass counts, deployed function URLs, migration version, and any
remaining external credential blocker in the task monitor.

- [ ] **Step 7: Commit verified launch state**

Commit: `feat: ship Recorrido billing and approval backend`
