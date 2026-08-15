# Rollback

1. Drain or settle queued/running jobs and pending/dispatching/enqueued outbox rows. Confirm with `python3 local/runtime_control.py status`.
2. Stop new Cloudflare prepare/dispatch/claims atomically:
   ```sh
   python3 local/runtime_control.py off
   ```
   The command atomically sets `cloudflare_generation_enabled=false` and `active_environment=off`, takes the runtime-row lock, and refuses to switch while work remains, preventing an unclaimed delivered job from stranding a reservation.
3. Confirm `/health` still responds and new `POST /v1/jobs` calls fail closed.
4. Unload the Cloudflare generation LaunchAgent. Do not stop unrelated renderer, sender, or WhatsApp processes.
5. Roll back Worker code:
   ```sh
   npx wrangler deployments list
   npx wrangler rollback <KNOWN_GOOD_VERSION_ID>
   ```
6. Leave R2 buckets, Queue, DLQ, outbox rows, job metadata, and Supabase ledger data intact. Do not drop tables, columns, objects, or queued evidence during rollback.
7. Re-enable the previous local-only intake path only if its independent authorization and billing checks pass.
8. Inspect pending outbox and expired leases before re-enabling Cloudflare dispatch.

The migration does not disable local rendering. It changes job ingress/storage/dispatch only, so rollback does not require restoring media tooling, desktop sessions, Keychain items, Vercel, Stripe, Route 53, Supabase, or WhatsApp.
