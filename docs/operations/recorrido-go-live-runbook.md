# Recorrido billing go-live runbook

Do not deploy from an unverified worktree. Run every repository gate, then apply
the migration once to the intended Supabase project and record migration
`202608040001`.

For local database verification, install PostgreSQL 16 or newer and run
`sh supabase/tests/database/run_recorrido_database_tests.sh`. The harness
defaults to Homebrew PostgreSQL 16 at `/opt/homebrew/opt/postgresql@16/bin`; set
`RECORRIDO_PG_BIN` to another 16+ `bin` directory when needed. Before running
against a remote database, preflight with
`psql "$RECORRIDO_DATABASE_URL" -XAtqc "show server_version_num"` and require a
numeric result of at least `160000`; use an empty disposable database because
the migration is intentionally one-shot. The local harness creates a uniquely
named temporary cluster, uses a bounded test port, and removes the cluster on
success, failure, or interruption. Container or agent sandboxes must permit
PostgreSQL shared memory primitives during `initdb` and server startup.

Create the six catalog prices described in the migration: Single Listing USD 22,
Pro monthly USD 32, Pro annual USD 320, Agency monthly USD 79, Pro extra USD 18,
and Agency extra USD 15. Replace only the catalog `stripe_price_id` values with
live `price_…` identifiers. Keep Adaptive Pricing enabled; webhook records must
retain Stripe’s actual charged minor amount and lowercase currency.

Configure Stripe webhook events: `checkout.session.completed`,
`payment_intent.succeeded`, all three `customer.subscription.*` lifecycle
events, `invoice.paid`, `invoice.payment_succeeded`, `invoice.payment_failed`,
`payment_intent.payment_failed`, `charge.refunded`, and
`charge.dispute.created`. Use a restricted Stripe key that can create/read
Checkout Sessions and read Customers, Prices, PaymentIntents, Invoices, and
Subscriptions; it must not manage unrelated Stripe resources.

Set the exact variables listed in `.env.example`, including
`RECORRIDO_INTERNAL_API_SECRET`, `RECORRIDO_CHECKOUT_SUCCESS_URL`,
`RECORRIDO_CHECKOUT_CANCEL_URL`, `RECORRIDO_OWNER_E164`,
`RECORRIDO_META_VERIFY_TOKEN`, `RECORRIDO_META_APP_SECRET`,
`RECORRIDO_STRIPE_LIVEMODE`, and `STRIPE_API_VERSION`; `WHATSAPP_GRAPH_VERSION`
is optional and defaults to the deployed function's supported Graph version.
Each `RECORRIDO_*_WORKER_JWT` must be a separately signed Supabase JWT whose
`role` claim is exactly its matching NOLOGIN database role. Use
`SUPABASE_ANON_KEY` as the PostgREST API key; never configure or give an Edge
Function a service-role JWT. Rotate worker JWTs and scheduler/health secrets
independently.

Deploy `recorrido-create-checkout`, `recorrido-checkout-result`,
`recorrido-stripe-webhook`, `recorrido-whatsapp-webhook`,
`recorrido-dispatch-approved`, `recorrido-grant-annual-quotas`, and
`recorrido-health`. Configure Meta verification and signatures with the exact
webhook URL and owner E.164 number. Schedule an authenticated POST to
`recorrido-grant-annual-quotas` hourly using `RECORRIDO_SCHEDULER_SECRET`.
Monitor an authenticated GET to `recorrido-health`; HTTP 503 is degraded and
contains counters only.

Smoke test in Stripe test mode: successful localized purchase evidence, replay
idempotency, subscription ordering, both failed-payment drafts, annual quota
idempotency, refund/dispute summaries, owner edit then new-token approval,
ambiguous WhatsApp delivery fencing, and explicit reconciliation. Confirm no
customer message sends before owner approval.

Rollback by disabling scheduler and dispatcher invocation, disabling Stripe/Meta
webhook destinations, and reverting traffic. Do not delete immutable events,
reversals, ledgers, approvals, or delivery attempts. For migration to a
dedicated project, restore all `recorrido_` tables and role grants together,
rotate every JWT/secret, repoint external webhooks, run smoke tests, then retire
the shared-project endpoints.
