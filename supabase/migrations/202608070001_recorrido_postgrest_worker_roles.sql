-- Repair hosted PostgREST role switching for separately signed Recorrido workers.
-- The original migration granted SET-only membership to service_role but hosted
-- PostgREST connects as authenticator before assuming the JWT role claim.
grant recorrido_billing_webhook_worker, recorrido_billing_checkout_worker,
  recorrido_billing_generation_worker, recorrido_billing_quota_worker,
  recorrido_billing_dispatcher_worker, recorrido_billing_approval_worker,
  recorrido_billing_reconciliation_worker, recorrido_billing_health_worker
  to authenticator with inherit false, set true;