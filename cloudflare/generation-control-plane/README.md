# Recorrido Cloudflare generation control plane

This Worker moves only the previously agreed cloud-suitable control-plane pieces:

- Private R2 generation inputs, outputs, and temporary objects
- Authenticated job ingress
- Cloudflare Queue delivery with bounded retries and DLQ
- Cron recovery of the Supabase transactional dispatch outbox
- Privacy-safe structured logs and health checks

Supabase remains the source of truth for billing, reservations, job status, generation leases, customer-delivery leases, settlement, and failure release. Vercel, Stripe, authentication, webhooks, Route 53 DNS, local media generation, local files, Keychain credentials, and authenticated desktop profiles stay unchanged. The local Baileys bridge is used only through the account-bound delivery worker.

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

## Customer delivery transaction

Migration `202608160001_recorrido_customer_delivery.sql` binds `account_id`, `member_id`, reservation, source listing, native output format, recipient E.164, output object/hash, and expected sender identity. The caller never supplies a delivery recipient. Render completion creates one outbox row while the generation reservation remains `reserved`.

`local/delivery_worker.py` claims the server-bound row and verifies the loopback WhatsApp bridge's `accountIdentityHash` before checkpointing. Provider-confirmed media acceptance persists the provider message ID, consumes the reservation once, rereads the committed balance, and stages the Spanish or Portuguese remaining-generation notice. Notice acceptance has a separate lease and provider ID.

Crash behavior fails closed:

- A pre-checkpoint bridge or sender failure abandons the claim for retry without settlement.
- A crash or timeout after the sending checkpoint without a provider ID stays ambiguous and never auto-resends.
- A journaled provider ID retries only the Supabase acknowledgement, never the WhatsApp send.
- Notice failure never resends media or refunds a delivered generation.
- Expired `media_claimed` and `notice_claimed` leases are reclaimable. `media_sending` and `notice_sending` are not.

Install the LaunchAgent without starting it via `./local/install-delivery.command`. Use `--enable` only after production Worker, Supabase sender hash, and bridge health pass. The protected environment file is `~/.config/recorrido/cloudflare-generation.env`; secrets never appear in process arguments. Runtime delivery remains independently fail-closed in `recorrido_customer_delivery_runtime`.

The real PostgreSQL behavior harness is `tests/run_migration_chain.sh`. It applies the authoritative billing/control-plane predecessor chain to a disposable PostgreSQL 16 cluster, then verifies recipient drift rejection, settlement timing, balance notice content, and idempotent provider acknowledgements.

## Logging

Logs allow only event name, job/account/reservation IDs, attempt number, environment, release, and stable error code. Request bodies, property details, phone numbers, media, auth headers, and secret values are never logged.

## Alerts

Deployment and runtime failures are visible in Cloudflare Workers observability. When `ALERT_WEBHOOK_URL` is configured, terminal dispatch/cron failures emit a privacy-safe alert containing only environment, release, event, and error code.
