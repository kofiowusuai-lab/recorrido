# Recorrido Billing, Entitlements, and Outbound Approval Design

**Status:** Approved default for implementation
**Date:** 2026-08-04
**Scope:** Go-live billing, customer identity, credit accounting, and owner-gated WhatsApp delivery

## 1. Goals

1. Accept international cards through Stripe Checkout for one-time purchases and subscriptions.
2. Present supported customers with a checkout amount in their local currency.
3. Link each payer and team member to a name, normalized WhatsApp number, office, lead record, and Stripe identity.
4. Track included and purchased generation credits without race conditions or mutable-balance drift.
5. Tell customers their remaining balance after each completed generation.
6. Offer WhatsApp actions for buying another generation, upgrading, and checking balance.
7. Prevent every customer-facing outbound message from sending until Kofi approves it.
8. Preserve a complete audit trail for billing, usage, approvals, and deliveries.

## 2. Non-goals

- A customer web dashboard
- Automated sales or support replies
- Automatic customer delivery without owner approval
- Separate Supabase projects per customer
- Colombia-only payment rails
- Usage-based Stripe metering

## 3. Architecture decision

Use one shared Supabase project as the system of record.

- Supabase Postgres stores customer identity, billing mirrors, entitlements, usage, generation reservations, and outbound approvals.
- Supabase Edge Functions receive WhatsApp and Stripe webhooks and create Stripe Checkout Sessions.
- Existing Recorrido workers reserve credits and process generation jobs through database RPCs.
- Stripe remains authoritative for money and subscription state.
- Supabase remains authoritative for access, available credits, generation usage, and message approval state.
- The customer-facing WhatsApp sender only accepts approved queue rows. Production agents never receive a direct send primitive.

A Vercel API layer is deferred until a customer or operator dashboard exists. A local tunneled webhook is forbidden for production.

## 4. Launch catalog

### 4.1 Single Listing

- Canonical price: USD 22 one time
- Grants: one non-expiring generation credit
- Includes one cinematic AI video tour, branding/contact/MLS, amenities map and drive times, 24-hour turnaround, and one social caption

### 4.2 Pro Agent Pass

- USD 32 monthly or USD 320 annually
- Grants four generation credits each monthly entitlement period
- Annual billing does not grant 48 credits up front
- Included monthly credits expire at the end of their entitlement period and do not roll over
- Extra generation working price: USD 18 one time
- “Unlimited revisions” means corrections to map locations and amenities before final approval. It does not include unlimited full video regenerations.

### 4.3 Agency / Team Pass

- USD 79 monthly
- Grants 12 generation credits each billing period
- Shared across one payer and up to two additional members
- Extra generation working price: USD 15 one time
- Voiceover is included

The overage prices remain configuration values so they can be changed without schema changes.

## 5. Local currency behavior

USD is the canonical catalog currency. Stripe Adaptive Pricing is enabled for eligible Checkout Sessions.

Country resolution order:

1. Verified country stored on the imported lead
2. Verified office or listing country
3. Country inferred from the normalized E.164 WhatsApp number
4. Customer confirmation
5. Unknown, with USD as the fallback

The stored country controls localized WhatsApp copy and expected currency. Stripe determines the final eligible presentment currency using checkout context. The system stores both canonical USD catalog data and Stripe’s actual presentment currency and amount from webhook payloads.

Supported launch-market currencies include COP, ARS, BRL, CLP, PEN, PYG, DOP, and USD. Ecuador maps to USD. Phone inference never overwrites a verified lead, office, or customer-confirmed country. Ambiguous +1 numbers require lead data or confirmation.

## 6. Identity model

### 6.1 Account

`customer_accounts` represents the billing and entitlement boundary.

Important fields:

- account type: individual or team
- display name
- office name
- payer member
- country and country source
- expected currency
- Stripe customer ID
- status

### 6.2 Member

`account_members` represents a person allowed to submit jobs against an account.

- normalized WhatsApp E.164 number is unique globally among active members
- name, email, lead source ID, role, and account association are retained
- roles are payer, member, or office_admin
- an Agency account has at most three active members, enforced in a transaction

Inbound WhatsApp identity resolves by normalized number to one active member and account. Unknown numbers do not consume credits and generate an internal review item.

## 7. Stripe model

### 7.1 Products and prices

Stripe products:

- Recorrido Single Listing
- Recorrido Pro Agent Pass
- Recorrido Agency / Team Pass
- Recorrido Extra Generation

Prices:

- single_listing_once_usd_22
- pro_monthly_usd_32
- pro_annual_usd_320
- agency_monthly_usd_79
- pro_extra_once_usd_18
- agency_extra_once_usd_15

Stripe IDs are stored in `stripe_price_catalog`; source code uses internal price codes rather than hard-coded Stripe IDs.

### 7.2 Checkout Sessions

Every Checkout Session is created server-side for a resolved account and member. Metadata includes:

- account_id
- member_id
- purchase_type
- internal_price_code
- normalized WhatsApp number
- country
- checkout_request_id

Subscription sessions use `mode=subscription`. One-time credit purchases use `mode=payment`. Adaptive Pricing is enabled where the account supports it. Success URLs are informational only and never grant credits.

### 7.3 Webhooks

At minimum, process:

- `checkout.session.completed`
- `payment_intent.succeeded`
- `payment_intent.payment_failed`
- `invoice.paid`
- `invoice.payment_failed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `charge.refunded`
- `charge.dispute.created`

`stripe_events.event_id` is unique. The raw payload, API version, processing result, and timestamps are retained. Replayed events return success without duplicating effects.

Money state changes only after a signed Stripe webhook. A Checkout success redirect never activates access.

### 7.4 Payment and subscription behavior

- Successful one-time payments create a payment record and a non-expiring purchased-credit bucket.
- `invoice.paid` activates or continues a subscription and grants the applicable monthly entitlement bucket.
- Monthly subscriptions use Stripe invoice period boundaries.
- Annual Pro subscriptions use an internal monthly grant schedule anchored to the subscription start date.
- `invoice.payment_failed` marks the subscription past due and creates a pending owner-approved customer message.
- New generation reservations are blocked after a configurable three-day grace period.
- Cancellation keeps already-paid access through `current_period_end`.
- Refunds and disputes revoke unused credits from the associated purchase. If credits were consumed, the account receives a negative adjustment and is blocked until resolved.

## 8. Credit accounting

Never store or edit a standalone “credits remaining” field.

### 8.1 Credit buckets

`credit_buckets` identifies where credits came from:

- subscription entitlement period
- single listing purchase
- extra generation purchase
- operator adjustment

Each bucket stores granted quantity, start time, optional expiry, source identifiers, and revocation state.

### 8.2 Append-only ledger

`credit_ledger` is append-only and stores signed deltas tied to one bucket:

- grant: positive
- reserve: negative
- release: positive
- revoke: negative
- adjustment: positive or negative

A database trigger rejects update and delete operations. Available credit equals the sum of active ledger entries for unexpired, non-revoked buckets.

### 8.3 Generation reservation lifecycle

1. Worker calls `reserve_generation(account_id, member_id, generation_id)`.
2. The function locks the account’s eligible buckets and spends the earliest-expiring included credit before non-expiring purchased credits.
3. It inserts a unique reservation and a `reserve = -1` ledger entry atomically.
4. Successful generation calls `consume_generation(reservation_id)` and marks the reservation consumed. No new balance delta is needed because reservation already reduced availability.
5. Failed or cancelled generation calls `release_generation(reservation_id)`, marks it released, and appends `release = +1` to the same bucket.
6. Repeated reserve, consume, and release calls are idempotent.

This prevents two team members from spending the final credit concurrently.

## 9. Remaining-balance messaging

After a generation passes QA, the system creates one customer delivery draft containing:

- output file or secure media reference
- localized completion text
- remaining included and purchased credits
- next quota reset date, if subscribed
- actions for buying one generation, upgrading, and checking balance

Example Spanish copy:

> Tu recorrido está listo. Te quedan 3 recorridos en este período. Tu cupo se renueva el 14 de septiembre.

The customer does not receive this draft until owner approval.

WhatsApp quick replies are used for stable actions:

- Comprar 1 recorrido
- Mejorar plan
- Ver mi saldo

A selected purchase action creates a customer-specific Stripe Checkout Session and then creates a new pending outbound draft containing the URL. No generic shared payment link is used.

## 10. Fail-closed outbound approval

### 10.1 Queue

Every customer-facing outbound payload enters `pending_outbound` with `status=pending`.

The row stores:

- account and recipient
- message type
- rendered text
- media references
- interactive actions
- reason and source event
- immutable version number
- status and timestamps

No customer-facing code path calls the WhatsApp send API directly.

### 10.2 Owner review

Internal review notifications are sent only to the configured owner number and contain:

- recipient name and number
- account and plan
- reason for the message
- exact draft text
- media summary
- Approve, Edit, and Reject actions

Action tokens are random, single-use, hashed at rest, scoped to one draft version, and expire. The webhook verifies the sender’s normalized number against `OWNER_WHATSAPP_E164` before accepting an action.

### 10.3 Approve

Approval inserts an immutable `outbound_approvals` record. The dispatcher rechecks:

- queue status is approved
- approval version matches current draft version
- approver is the configured owner
- token was used once and is not expired
- recipient is not opted out or blocked

Only then does it call WhatsApp. Successful delivery records the provider message ID and final payload.

### 10.4 Edit

Edit moves the row to `awaiting_edit` and records which owner session is editing it. The owner’s next text updates the draft, increments its version, invalidates old action tokens, and creates a new review card. Editing never sends.

### 10.5 Reject

Reject records the reason and terminal status. A rejected draft cannot be revived; a new version must be created deliberately.

### 10.6 Defense in depth

- The Edge Function holding the customer-send credential accepts only an internal approved row ID, never arbitrary recipient/text input.
- Database row-level security prevents customer-facing roles from setting approval fields.
- Production agent tools can create drafts but cannot approve or send them.
- A database audit trigger records all outbound state transitions.
- Missing owner configuration disables customer sends.

## 11. Supabase schema

Tables:

- `customer_accounts`
- `account_members`
- `stripe_price_catalog`
- `stripe_events`
- `stripe_subscriptions`
- `stripe_payments`
- `entitlement_periods`
- `credit_buckets`
- `credit_ledger`
- `generation_reservations`
- `generation_jobs`
- `pending_outbound`
- `outbound_action_tokens`
- `outbound_approvals`
- `outbound_deliveries`
- `outbound_audit_log`

RPC functions:

- `resolve_member_by_whatsapp(e164)`
- `available_credits(account_id)`
- `reserve_generation(account_id, member_id, generation_id)`
- `consume_generation(reservation_id)`
- `release_generation(reservation_id, reason)`
- `grant_subscription_period(subscription_id, starts_at, ends_at, quantity)`
- `grant_purchased_credits(payment_id, quantity)`
- `claim_approved_outbound(limit)`

## 12. Security

- Store Stripe secret keys, Stripe webhook secret, Supabase service-role key, Meta access token, app secret, and owner E.164 number in Supabase project secrets, never Git.
- `.env` and `.env.local` remain ignored for local development.
- Verify Stripe webhook signatures against the raw request body.
- Verify Meta webhook signatures when provided.
- Use service-role access only inside Edge Functions.
- Enable RLS on every public table and deny access by default.
- Minimize stored Stripe payloads where full payload retention is not required.
- Normalize and validate all phone numbers before lookup or send.
- Store monetary values as integer minor units and three-letter lowercase currency codes.

## 13. Operational monitoring

The operator view must answer:

- who paid, amount, currency, and when
- current subscription state and next renewal
- current available included and purchased credits
- every generation reservation and result
- every Stripe webhook and processing outcome
- every pending, approved, edited, rejected, sent, or failed outbound item

Alerts:

- unprocessed Stripe webhook after five minutes
- payment succeeded but no entitlement granted
- negative available balance
- approval token misuse
- customer delivery failure
- subscription past due beyond grace period

## 14. Acceptance criteria

1. Replaying any Stripe webhook does not duplicate payments, subscriptions, or credits.
2. Two concurrent requests against one remaining team credit produce one reservation and one insufficient-credit result.
3. Failed production releases the same reserved credit once.
4. Successful production decrements the available balance once and creates a delivery draft with the correct remaining count.
5. A customer-facing message cannot reach the WhatsApp API without a current owner approval record.
6. A non-owner number cannot approve, edit, reject, or dispatch a draft.
7. Editing invalidates prior approvals and tokens.
8. Single Listing and extra-credit payments grant one non-expiring credit only after signed payment confirmation.
9. Monthly plans reset to four or 12 credits on the proper billing boundary without rollover.
10. Annual Pro grants four credits monthly while charging once annually.
11. Actual presentment amount and currency are stored from Stripe events.
12. Missing secrets, malformed signatures, unknown customers, and uncertain entitlement state fail closed.
