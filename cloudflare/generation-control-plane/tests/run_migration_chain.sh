#!/bin/bash
set -euo pipefail
export LC_ALL=C LANG=C
PG=/opt/homebrew/Cellar/postgresql@16/16.12/bin
ROOT=/tmp/rcdel-pg
SOCK=/tmp/rcdel-sock
REMOTE=/Users/AIAgenterminal/recorrido/runtime/builds/customer-delivery-production-20260816/supabase-deploy-copy/supabase/migrations
LOCAL=/Users/AIAgenterminal/recorrido/.worktrees/customer-delivery-production/supabase/migrations
HERE="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$ROOT" "$SOCK"
mkdir -p "$ROOT" "$SOCK"
"$PG/initdb" -D "$ROOT" -A trust --no-locale >/dev/null
"$PG/pg_ctl" -D "$ROOT" -l "$ROOT/postgres.log" -o "-p 55439 -k $SOCK" start >/dev/null
cleanup() { "$PG/pg_ctl" -D "$ROOT" stop -m fast >/dev/null 2>&1 || true; }
trap cleanup EXIT
PSQL=("$PG/psql" -h "$SOCK" -p 55439 -U AIAgenterminal -d postgres -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -f "$HERE/postgres_bootstrap.sql"
"${PSQL[@]}" -f "$REMOTE/202608040001_recorrido_billing_core.sql"
"${PSQL[@]}" -f "$LOCAL/202608150001_recorrido_cloudflare_generation_control_plane.sql"
"${PSQL[@]}" -f "$LOCAL/202608150002_recorrido_cloudflare_generation_security_fences.sql"
"${PSQL[@]}" -f "$LOCAL/202608150003_recorrido_output_upload_hash_fence.sql"
"${PSQL[@]}" -f "$LOCAL/202608160001_recorrido_customer_delivery.sql"
"${PSQL[@]}" -f "$HERE/customer_delivery_behavior.sql"
"${PSQL[@]}" -At -c "select count(*) from information_schema.tables where table_schema='public' and table_name like 'recorrido_customer_delivery_%';"
"${PSQL[@]}" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname like 'recorrido_%customer_delivery%';"
