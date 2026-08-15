# Recorrido Cloudflare Generation Migration Scope

## Recovered decision sources

The scope was reconstructed before implementation from both primary records:

1. Exported WhatsApp discussion: `/Users/AIAgenterminal/.hermes/profiles/commandcentre/cache/documents/doc_612210cd6d5c_WhatsApp_Chat_Helper_extracted/_chat.txt`
2. Hermes session `20260811_024641_775d56dd`, including the Cloudflare architecture discussion.

The agreed order is durable storage first and compute last. Cloudflare transports private objects and dispatch events. Supabase remains authoritative. Rendering remains on the Mac.

## Verified source and destination matrix

| Workload | Existing source | Destination | Authority after migration |
|---|---|---|---|
| Generation input manifests/assets | Mac-local generation files and current generation upload flow | Private Cloudflare R2 input bucket | Supabase authorizes the account/job; R2 stores immutable private objects |
| Generated video outputs | Mac-local renderer output directories | Private Cloudflare R2 output bucket | Supabase records the authoritative job result and object key |
| Temporary generation objects | Mac-local temporary generation files | Private Cloudflare R2 temporary bucket with seven-day expiry | R2 lifecycle manages expiry |
| Stateless generation API/orchestration | Local batch entry and direct job coordination | Cloudflare Worker | Supabase remains authorization, billing, idempotency, lease, and job-state authority |
| Asynchronous generation dispatch | Local/direct polling coordination | Cloudflare Queue plus separate DLQ | Supabase outbox remains the authoritative dispatch ledger |
| Outbox dispatch/recovery schedule | Local control-plane polling | Cloudflare Cron Trigger | Supabase runtime flag and outbox govern whether work exists |
| Actual V16 generation and rendering | Mac scripts, FFmpeg, local assets, authenticated desktop context | Stays on Mac behind an authenticated lease bridge | Supabase owns leases and settlement; Mac performs compute only |

## Explicit non-migrations

- No Cloudflare Pages. The website remains on Vercel.
- No Cloudflare DNS zone. Route 53 remains authoritative.
- No D1 or Durable Objects. Supabase remains the sole database and job source of truth.
- No Stripe, Supabase Auth, webhook, or billing authority migration.
- No WhatsApp/Baileys session, sender, campaign, outreach worker, or prospect-control change.
- No authenticated browser profile, Keychain credential, local GUI automation, FFmpeg, or local-file workload migration.

## Secret inventory by name only

Cloudflare encrypted Worker secrets:

- `INGRESS_API_TOKEN`
- `LOCAL_WORKER_TOKEN`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `ALERT_WEBHOOK_URL` (optional external alert integration)

Protected Mac worker configuration:

- `WORKER_URL`
- `LOCAL_WORKER_TOKEN`
- `WORKER_ID`

No secret value belongs in Git, Worker variables, logs, deployment output, or this document.
