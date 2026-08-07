#!/usr/bin/env python3
"""Coordinated two-session regressions for outbound claims and lease reclaim."""

import json
import os
import subprocess
import threading


DSN = os.environ.get("RECORRIDO_DATABASE_URL")
if not DSN:
    raise SystemExit("RECORRIDO_DATABASE_URL is required")
PSQL_BIN = os.environ.get("RECORRIDO_PSQL_BIN", "psql")
SUBPROCESS_TIMEOUT_SECONDS = 15
COORDINATION_TIMEOUT_SECONDS = 10
THREAD_JOIN_TIMEOUT_SECONDS = 20


def psql(sql: str) -> str:
    try:
        return subprocess.run(
            [PSQL_BIN, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", DSN],
            input=sql, text=True, check=True, capture_output=True,
            timeout=SUBPROCESS_TIMEOUT_SECONDS,
        ).stdout.strip()
    except subprocess.TimeoutExpired as error:
        raise TimeoutError("psql concurrency operation exceeded 15 seconds") from error


def must_conflict(sql: str) -> None:
    try:
        result = subprocess.run(
            [PSQL_BIN, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", DSN],
            input=sql, text=True, capture_output=True,
            timeout=SUBPROCESS_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise TimeoutError("stale-ownership conflict check exceeded 15 seconds") from error
    if result.returncode == 0 or "delivery ownership conflict" not in result.stderr:
        raise AssertionError("stale ownership operation did not conflict")


owner = "+573008880001"
psql(
    f"""
with account_row as (
  insert into public.recorrido_customer_accounts(display_name)
  values ('Outbound concurrency') returning id
), owner_row as (
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
  select id,'Concurrent Owner','{owner}','owner' from account_row returning id,account_id
)
insert into public.recorrido_pending_outbound
  (account_id,member_id,recipient_phone_e164,message_type,payload,preview_text,
   idempotency_key,status,approval_token_hash,approval_expires_at,approved_by_phone_e164,
   approved_at,approved_revision)
select account_id,id,'+57300888' || lpad(n::text,4,'0'),'text',
  jsonb_build_object('body','Concurrent ' || n),'Concurrent ' || n,
  'outbound-concurrency-' || n,'approved',encode(digest('concurrency-' || n,'sha256'),'hex'),
  clock_timestamp()+interval '1 hour','{owner}',clock_timestamp(),1
from owner_row cross join generate_series(100,124) n;
"""
)

start = threading.Event()
results: list[list[dict[str, object]]] = [[], []]
errors: list[BaseException] = []


def claim(slot: int) -> None:
    try:
        if not start.wait(COORDINATION_TIMEOUT_SECONDS):
            raise TimeoutError("claim worker timed out waiting for coordinated start")
        raw = psql(
            "set role recorrido_billing_dispatcher_worker; "
            f"select public.recorrido_claim_approved_outbound(100,'{owner}');"
        )
        results[slot] = json.loads(raw.splitlines()[-1])
    except BaseException as error:  # surfaced on the main thread
        errors.append(error)


threads = [threading.Thread(target=claim, args=(slot,)) for slot in range(2)]
for thread in threads:
    thread.start()
start.set()
for thread in threads:
    thread.join(THREAD_JOIN_TIMEOUT_SECONDS)
if any(thread.is_alive() for thread in threads):
    raise TimeoutError("concurrent outbound claim threads did not finish within 20 seconds")
if errors:
    raise errors[0]

ids = [row["id"] for result in results for row in result]
if len(ids) != 25 or len(set(ids)) != 25:
    raise AssertionError(f"concurrent claims duplicated or lost rows: {len(ids)} / {len(set(ids))}")

attempts_ok = psql(
    """
select count(*)=25 and count(distinct pending_outbound_id)=25
from public.recorrido_outbound_delivery_attempts a
join public.recorrido_pending_outbound o on o.id=a.pending_outbound_id
where o.idempotency_key like 'outbound-concurrency-%';
"""
)
if attempts_ok.splitlines()[-1] != "t":
    raise AssertionError("concurrent claims did not create exactly one attempt per outbound")

# An expired claim that never began transmission is safely reclaimable exactly once.
reclaim_owner = "+573008889999"
raw = psql(
    f"""
with account_row as (
  insert into public.recorrido_customer_accounts(display_name) values ('Outbound reclaim') returning id
), owner_row as (
  insert into public.recorrido_account_members(account_id,full_name,phone_e164,role)
  select id,'Reclaim Owner','{reclaim_owner}','owner' from account_row returning id,account_id
), outbound_row as (
  insert into public.recorrido_pending_outbound
    (account_id,member_id,recipient_phone_e164,message_type,payload,preview_text,idempotency_key,
     status,approval_token_hash,approval_expires_at,approved_by_phone_e164,approved_at,approved_revision)
  select account_id,id,'+573008887777','text','{{"body":"Reclaim"}}','Reclaim','outbound-reclaim',
    'approved',encode(digest('reclaim','sha256'),'hex'),clock_timestamp()+interval '1 hour',
    '{reclaim_owner}',clock_timestamp(),1 from owner_row returning id
)
select public.recorrido_claim_approved_outbound(1,'{reclaim_owner}') from outbound_row;
"""
)
old_claim = json.loads(raw.splitlines()[-1])[0]
psql(
    f"set session_replication_role=replica; update public.recorrido_outbound_delivery_attempts "
    f"set lease_expires_at=clock_timestamp()-interval '1 second' where id='{old_claim['attemptId']}'; "
    "set session_replication_role=origin;"
)

start = threading.Event()
reclaims: list[list[dict[str, object]]] = [[], []]
errors = []


def reclaim(slot: int) -> None:
    try:
        if not start.wait(COORDINATION_TIMEOUT_SECONDS):
            raise TimeoutError("reclaim worker timed out waiting for coordinated start")
        result = psql(
            "set role recorrido_billing_dispatcher_worker; "
            f"select public.recorrido_claim_approved_outbound(1,'{reclaim_owner}');"
        )
        reclaims[slot] = json.loads(result.splitlines()[-1])
    except BaseException as error:
        errors.append(error)


threads = [threading.Thread(target=reclaim, args=(slot,)) for slot in range(2)]
for thread in threads:
    thread.start()
start.set()
for thread in threads:
    thread.join(THREAD_JOIN_TIMEOUT_SECONDS)
if any(thread.is_alive() for thread in threads):
    raise TimeoutError("concurrent reclaim threads did not finish within 20 seconds")
if errors:
    raise errors[0]

new_claims = [claim for batch in reclaims for claim in batch]
if len(new_claims) != 1:
    raise AssertionError(f"expired lease was not reclaimed exactly once: {len(new_claims)}")
new_claim = new_claims[0]
if new_claim["attemptId"] == old_claim["attemptId"] or new_claim["claimToken"] == old_claim["claimToken"]:
    raise AssertionError("reclaim did not issue fresh ownership")

for role, operation in [
    ("recorrido_billing_dispatcher_worker", f"select public.recorrido_mark_outbound_delivered('{old_claim['id']}','{old_claim['attemptId']}','{old_claim['claimToken']}','wamid.stale')"),
    ("recorrido_billing_dispatcher_worker", f"select public.recorrido_mark_outbound_failed('{old_claim['id']}','{old_claim['attemptId']}','{old_claim['claimToken']}','stale',true)"),
    ("recorrido_billing_dispatcher_worker", f"select public.recorrido_mark_outbound_ambiguous('{old_claim['id']}','{old_claim['attemptId']}','{old_claim['claimToken']}','stale',null)"),
    ("recorrido_billing_reconciliation_worker", f"select public.recorrido_reconcile_outbound_accepted('{old_claim['id']}','{old_claim['attemptId']}','{old_claim['claimToken']}','wamid.stale',false)"),
    ("recorrido_billing_reconciliation_worker", f"select public.recorrido_reconcile_outbound_not_accepted('{old_claim['id']}','{old_claim['attemptId']}','{old_claim['claimToken']}','stale')"),
]:
    must_conflict(f"set role {role}; " + operation + ";")

fence_ok = psql(
    f"select o.status='sending' and a.status='claimed' and a.attempt_number=2 "
    f"from public.recorrido_pending_outbound o join public.recorrido_outbound_delivery_attempts a "
    f"on a.pending_outbound_id=o.id where a.id='{new_claim['attemptId']}';"
)
if fence_ok.splitlines()[-1] != "t":
    raise AssertionError("stale operations mutated the fresh claim")

# Once transmission begins, lease expiry is ambiguous and concurrent claimers
# must never create another delivery attempt.
ambiguous_raw = psql(
    f"""
with outbound_row as (
  insert into public.recorrido_pending_outbound
    (account_id,member_id,recipient_phone_e164,message_type,payload,preview_text,idempotency_key,
     status,approval_token_hash,approval_expires_at,approved_by_phone_e164,approved_at,approved_revision)
  select account_id,member_id,'+573008887778','text','{{"body":"Ambiguous"}}','Ambiguous',
    'outbound-ambiguous','approved',encode(digest('ambiguous','sha256'),'hex'),
    clock_timestamp()+interval '1 hour','{reclaim_owner}',clock_timestamp(),1
  from public.recorrido_pending_outbound where id='{old_claim['id']}' returning id
)
select public.recorrido_claim_approved_outbound(1,'{reclaim_owner}') from outbound_row;
"""
)
ambiguous_claim = json.loads(ambiguous_raw.splitlines()[-1])[0]
psql(
    "set role recorrido_billing_dispatcher_worker; "
    f"select public.recorrido_begin_outbound_send('{ambiguous_claim['id']}','{ambiguous_claim['attemptId']}','{ambiguous_claim['claimToken']}');"
)
psql(
    f"set session_replication_role=replica; update public.recorrido_outbound_delivery_attempts "
    f"set lease_expires_at=clock_timestamp()-interval '1 second' where id='{ambiguous_claim['attemptId']}'; "
    "set session_replication_role=origin;"
)
start = threading.Event()
ambiguous_reclaims: list[list[dict[str, object]]] = [[], []]
errors = []

def claim_ambiguous(slot: int) -> None:
    try:
        if not start.wait(COORDINATION_TIMEOUT_SECONDS):
            raise TimeoutError("ambiguous-claim worker timed out waiting for coordinated start")
        result = psql(
            "set role recorrido_billing_dispatcher_worker; "
            f"select public.recorrido_claim_approved_outbound(1,'{reclaim_owner}');"
        )
        ambiguous_reclaims[slot] = json.loads(result.splitlines()[-1])
    except BaseException as error:
        errors.append(error)

threads = [threading.Thread(target=claim_ambiguous, args=(slot,)) for slot in range(2)]
for thread in threads:
    thread.start()
start.set()
for thread in threads:
    thread.join(THREAD_JOIN_TIMEOUT_SECONDS)
if any(thread.is_alive() for thread in threads):
    raise TimeoutError("ambiguous-claim threads did not finish within 20 seconds")
if errors:
    raise errors[0]
if any(ambiguous_reclaims):
    raise AssertionError("expired sending attempt was automatically reclaimed")
ambiguous_ok = psql(
    f"select o.status='ambiguous' and a.status='ambiguous' and a.attempt_number=1 "
    f"from public.recorrido_pending_outbound o join public.recorrido_outbound_delivery_attempts a "
    f"on a.pending_outbound_id=o.id where a.id='{ambiguous_claim['attemptId']}';"
)
if ambiguous_ok.splitlines()[-1] != "t":
    raise AssertionError("expired sending attempt was not fenced as ambiguous")

print("outbound concurrency assertions: 12 passed")
