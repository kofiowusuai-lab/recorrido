# Recorrido Cloudflare generation control plane

This Worker moves only the previously agreed cloud-suitable control-plane pieces:

- Private R2 generation inputs, outputs, and temporary objects
- Authenticated job ingress
- Cloudflare Queue delivery with bounded retries and DLQ
- Cron recovery of the Supabase transactional dispatch outbox
- Privacy-safe structured logs and health checks

Supabase remains the source of truth for billing, reservations, job status, leases, completion, and failure release. Vercel, Stripe, authentication, webhooks, Route 53 DNS, local media generation, local files, Keychain credentials, authenticated desktop profiles, BlueStacks/Baileys, and WhatsApp stay unchanged.

## Runtime secrets

Inventory names only:

- `INGRESS_API_TOKEN`
- `LOCAL_WORKER_TOKEN`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `ALERT_WEBHOOK_URL` (optional)

Never commit secret values. Set secrets with `wrangler secret put`, piping values from the protected local source. Before authority secrets are installed, a deployment must fail closed for billable job creation. Runtime activation is controlled independently in Supabase and defaults to `off`.

## Environments

- Staging: `recorrido-generation-control-plane-staging`
- Production: `recorrido-generation-control-plane`

Both use explicit, separate producer Queue and DLQ bindings. Staging uses separate R2 buckets. Production binds the three private buckets created during the storage-first phase. `tests/contracts.test.ts` rejects inherited staging producer bindings.

## Commands

```sh
npm ci
npm test
npm run typecheck
python3 -m pytest -q
npx wrangler deploy --env staging
npx wrangler deployments list --env staging
npx wrangler deploy
npx wrangler deployments list
```

## Local Mac boundary

The local renderer polls the authenticated lease endpoint, downloads the private manifest/assets, runs the existing local render command, uploads the result, and settles through the Worker. Supabase issues an opaque lease token plus a monotonic lease version; every heartbeat, output upload, completion, and failure call must present environment, `worker_id`, `lease_token`, and `lease_version`. Outputs are fenced under `accounts/<account>/jobs/<job>/leases/<lease_token>/output.mp4`, so a stale renderer cannot overwrite the active renderer's artifact. No WhatsApp sender or outreach table is read or modified.

Switch runtime environments only through `python3 local/runtime_control.py off|staging|production`. It locks the singleton runtime row and refuses the switch while queued/running jobs or pending/dispatching/enqueued outbox rows exist.

Input objects are create-only. Manifest uploads compute SHA-256 in the Worker, store it as private R2 custom metadata, and pass the digest to the authoritative job-prepare RPC. Replays cannot replace a manifest after its idempotency namespace has been established.

The main Queue consumer marks delivery in Supabase. The separate DLQ consumer terminalizes exhausted dispatches before acknowledging them, and cron recovery terminalizes rows returned in explicit `dead` dispatch state rather than re-enqueueing them.

## Logging

Logs allow only event name, job/account/reservation IDs, attempt number, environment, release, and stable error code. Request bodies, property details, phone numbers, media, auth headers, and secret values are never logged.

## Alerts

Deployment and runtime failures are visible in Cloudflare Workers observability. When `ALERT_WEBHOOK_URL` is configured, terminal dispatch/cron failures emit a privacy-safe alert containing only environment, release, event, and error code.
