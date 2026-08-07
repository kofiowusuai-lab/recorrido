#!/bin/sh
set -eu
export LC_ALL=C

PG_BIN=${RECORRIDO_PG_BIN:-/opt/homebrew/opt/postgresql@16/bin}
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)

for executable in postgres initdb pg_ctl createdb psql; do
  test -x "$PG_BIN/$executable" || {
    echo "PostgreSQL executable missing: $PG_BIN/$executable" >&2
    echo 'Set RECORRIDO_PG_BIN to a PostgreSQL 16+ bin directory.' >&2
    exit 1
  }
done
PG_MAJOR=$($PG_BIN/postgres --version | sed -E 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/')
case $PG_MAJOR in
  ''|*[!0-9]*) echo 'Could not determine PostgreSQL major version.' >&2; exit 1 ;;
esac
test "$PG_MAJOR" -ge 16 || {
  echo "PostgreSQL 16+ is required; found major version $PG_MAJOR." >&2
  exit 1
}

CLUSTER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/recorrido-db.XXXXXX")
if [ "${RECORRIDO_TEST_PORT:-}" ]; then
  PORT=$RECORRIDO_TEST_PORT
else
  PORT=$((55000 + ($$ % 9000)))
fi

cleanup() {
  "$PG_BIN/pg_ctl" -D "$CLUSTER_DIR/data" -m immediate stop >/dev/null 2>&1 || true
  case $CLUSTER_DIR in
    "${TMPDIR:-/tmp}"/recorrido-db.*) rm -rf -- "$CLUSTER_DIR" ;;
    *) echo "Refusing to clean unexpected test path: $CLUSTER_DIR" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

wait_fifo_lines() {
  python3 - "$1" "$2" <<'PY'
import os, select, sys, time
path, expected = sys.argv[1], int(sys.argv[2])
fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
deadline = time.monotonic() + 10
buffer = b""
try:
    while buffer.count(b"\n") < expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit(f"timed out after 10s waiting for {expected} workers at {path}")
        readable, _, _ = select.select([fd], [], [], remaining)
        if readable:
            buffer += os.read(fd, 4096)
finally:
    os.close(fd)
PY
}

wait_pid_bounded() {
  pid=$1
  log=$2
  elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge 20 ]; then
      kill "$pid" 2>/dev/null || true
      sed -n '1,120p' "$log" >&2
      echo "worker $pid exceeded 20 seconds" >&2
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" || { sed -n '1,120p' "$log" >&2; return 1; }
}

PGOPTIONS='-c shared_memory_type=mmap -c dynamic_shared_memory_type=mmap' \
  "$PG_BIN/initdb" -D "$CLUSTER_DIR/data" -A trust --no-locale \
  --set=shared_memory_type=mmap --set=dynamic_shared_memory_type=mmap >/dev/null
test -f "$CLUSTER_DIR/data/PG_VERSION" || {
  echo 'initdb did not produce a usable PostgreSQL 16 cluster' >&2
  exit 1
}
"$PG_BIN/pg_ctl" -D "$CLUSTER_DIR/data" \
  -o "-k $CLUSTER_DIR -p $PORT -c shared_memory_type=mmap -c dynamic_shared_memory_type=mmap" \
  -w start >/dev/null
"$PG_BIN/createdb" -h "$CLUSTER_DIR" -p "$PORT" recorrido_test
PSQL="$PG_BIN/psql -X -v ON_ERROR_STOP=1 -h $CLUSTER_DIR -p $PORT -d recorrido_test"

$PSQL <<'SQL'
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create role authenticator nologin;
create table public.non_recorrido_privilege_sentinel(id integer);
grant select on public.non_recorrido_privilege_sentinel to anon, authenticated;
grant create on schema public to anon, authenticated, service_role;
SQL
$PSQL -f "$ROOT_DIR/supabase/migrations/202608040001_recorrido_billing_core.sql"
$PSQL -f "$ROOT_DIR/supabase/tests/database/recorrido_core_test.sql"
$PSQL -f "$ROOT_DIR/supabase/tests/database/recorrido_review_findings_test.sql"
$PSQL -f "$ROOT_DIR/supabase/tests/database/recorrido_hardening_test.sql"

RECORRIDO_DATABASE_URL="postgresql:///recorrido_test?host=$CLUSTER_DIR&port=$PORT" \
  RECORRIDO_PSQL_BIN="$PG_BIN/psql" \
  python3 "$ROOT_DIR/supabase/tests/database/recorrido_concurrency_test.py"

# True two-session barriers: both workers start before either transaction is released.
IDS=$($PSQL -At <<'SQL'
create table public.recorrido_test_barrier(name text primary key, arrivals integer not null default 0);
with account_row as (
  insert into public.recorrido_customer_accounts(display_name)
  values ('Concurrent') returning id
), member_row as (
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
  select id,'Owner','+573004442233','owner' from account_row
  returning id,account_id
), bucket_row as (
  select public.recorrido_grant_credit_bucket(account_id,'manual_adjustment','concurrency',1) as id
  from member_row
)
select account_id || ',' || member_row.id || ',' || bucket_row.id
from member_row cross join bucket_row;
SQL
)
IDS=$(printf '%s\n' "$IDS" | sed -n '$p')
IFS=, read -r ACCOUNT_ID MEMBER_ID BUCKET_ID <<EOF
$IDS
EOF
export ACCOUNT_ID MEMBER_ID BUCKET_ID

mkfifo "$CLUSTER_DIR/reserve-start" "$CLUSTER_DIR/reserve-go"
reserve_worker() {
  key=$1
  printf '%s\n' "$key" >"$CLUSTER_DIR/reserve-start"
  IFS= read -r _ <"$CLUSTER_DIR/reserve-go"
  $PSQL <<SQL
set statement_timeout='8s'; set lock_timeout='6s'; begin;
select public.recorrido_reserve_generation('$ACCOUNT_ID','$MEMBER_ID','$key');
commit;
SQL
}
reserve_worker concurrent-a >"$CLUSTER_DIR/reserve-a.log" 2>&1 & A=$!
reserve_worker concurrent-b >"$CLUSTER_DIR/reserve-b.log" 2>&1 & B=$!
wait_fifo_lines "$CLUSTER_DIR/reserve-start" 2
printf 'go\ngo\n' >"$CLUSTER_DIR/reserve-go"
wait_pid_bounded "$A" "$CLUSTER_DIR/reserve-a.log"
wait_pid_bounded "$B" "$CLUSTER_DIR/reserve-b.log"
$PSQL -Atqc "select count(*)=1 and count(*) filter (where status='reserved')=1 from public.recorrido_generation_reservations where account_id='$ACCOUNT_ID'" | grep -qx t
$PSQL -Atqc "select count(*)=1 and coalesce(sum(delta),0)=-1 from public.recorrido_credit_ledger where account_id='$ACCOUNT_ID' and entry_kind='reserve'" | grep -qx t

mkfifo "$CLUSTER_DIR/claim-start" "$CLUSTER_DIR/claim-go"
claim_worker() {
  worker=$1
  printf '%s\n' "$worker" >"$CLUSTER_DIR/claim-start"
  IFS= read -r _ <"$CLUSTER_DIR/claim-go"
  $PSQL -Atqc "set statement_timeout='8s'; select public.recorrido_claim_stripe_event('evt_concurrent','test',null,false,'2025-06-30.basil','{}',interval '2 minutes','{}')"
}
claim_worker a >"$CLUSTER_DIR/claim-a.log" 2>&1 & A=$!
claim_worker b >"$CLUSTER_DIR/claim-b.log" 2>&1 & B=$!
wait_fifo_lines "$CLUSTER_DIR/claim-start" 2
printf 'go\ngo\n' >"$CLUSTER_DIR/claim-go"
wait_pid_bounded "$A" "$CLUSTER_DIR/claim-a.log"
wait_pid_bounded "$B" "$CLUSTER_DIR/claim-b.log"
$PSQL -Atqc "select processing_attempts=1 and processing_status='processing' and claim_token is not null and lease_expires_at>clock_timestamp() from public.recorrido_stripe_events where stripe_event_id='evt_concurrent'" | grep -qx t
CLAIM_RESULTS=$(grep -h -o '"claimed": [a-z]*' "$CLUSTER_DIR/claim-a.log" "$CLUSTER_DIR/claim-b.log")
test "$(printf '%s\n' "$CLAIM_RESULTS" | grep -xc '"claimed": true')" -eq 1
test "$(printf '%s\n' "$CLAIM_RESULTS" | grep -xc '"claimed": false')" -eq 1
test "$(printf '%s\n' "$CLAIM_RESULTS" | grep -c .)" -eq 2

# Reserve/revoke races on the same account lock; either ordering is valid but
# revocation can never mint and reservation can never overspend.
REVERSAL_ID=$($PSQL -Atq <<SQL
update public.recorrido_price_catalog set active=true where product_code='single_listing_once_usd_22';
insert into public.recorrido_payment_records(account_id,product_code,payment_kind,amount_minor,currency,status)
values('$ACCOUNT_ID','single_listing_once_usd_22','extra_purchase',2200,'usd','paid') returning id \gset
select public.recorrido_grant_paid_purchase(:'id') as bucket_id \gset
select public.recorrido_record_stripe_reversal(:'id','re_concurrency','refund',2200,'usd',now());
SQL
)
$PSQL -c "set statement_timeout='8s'; begin; select public.recorrido_reserve_generation('$ACCOUNT_ID','$MEMBER_ID','reserve-revoke'); select pg_sleep(0.5); commit" >"$CLUSTER_DIR/reserve-revoke-reserve.log" 2>&1 & A=$!
$PSQL -c "set statement_timeout='8s'; begin; select public.recorrido_revoke_stripe_reversal('$REVERSAL_ID'); commit" >"$CLUSTER_DIR/reserve-revoke-revoke.log" 2>&1 & B=$!
wait_pid_bounded "$A" "$CLUSTER_DIR/reserve-revoke-reserve.log"
wait_pid_bounded "$B" "$CLUSTER_DIR/reserve-revoke-revoke.log"
$PSQL -Atqc "select public.recorrido_available_credits('$ACCOUNT_ID') <= 0" | grep -qx t
$PSQL -Atqc "select count(*)=1 and min(delta)=-1 from public.recorrido_credit_ledger where source_type='stripe_reversal' and source_id='$REVERSAL_ID'" | grep -qx t
$PSQL -Atqc "select count(*)=1 from public.recorrido_payment_credit_buckets pcb join public.recorrido_payment_records p on p.id=pcb.payment_id where p.account_id='$ACCOUNT_ID' and pcb.account_id=p.account_id" | grep -qx t
$PSQL -Atqc "select not exists(select 1 from public.recorrido_generation_reservations r left join public.recorrido_generation_jobs j on j.id=r.job_id left join public.recorrido_credit_ledger l on l.id=r.reserve_ledger_id where j.id is null or l.id is null)" | grep -qx t
echo 'concurrency assertions: 10 passed'
