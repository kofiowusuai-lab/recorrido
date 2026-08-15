#!/usr/bin/env python3
"""Seed/status/close the isolated Recorrido Cloudflare generation canary account."""
from __future__ import annotations

import argparse
import importlib.util
import json
import uuid
from pathlib import Path
from typing import Any

NAMESPACE = uuid.UUID("4ab09f7d-8870-4d1b-a449-6f2bfa9f5adc")
ACCOUNT_ID = uuid.uuid5(NAMESPACE, "recorrido-cloudflare-generation-canary-account")
MEMBER_ID = uuid.uuid5(NAMESPACE, "recorrido-cloudflare-generation-canary-member")
BUCKET_ID = uuid.uuid5(NAMESPACE, "recorrido-cloudflare-generation-canary-bucket")
LEDGER_ID = uuid.uuid5(NAMESPACE, "recorrido-cloudflare-generation-canary-grant")
SOURCE_ID = "cloudflare-generation-migration-canary-20260815"
HELPER = Path("/Users/AIAgenterminal/.hermes/scripts/recorrido_full_promotion_worker.py")


def connect() -> Any:
    spec = importlib.util.spec_from_file_location("recorrido_db_helper", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("database helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.connect()


def seed(connection: Any) -> dict[str, Any]:
    with connection.cursor() as cursor:
        cursor.execute(
            """insert into public.recorrido_customer_accounts(id, display_name, home_country, status)
               values (%s, 'Cloudflare Generation Canary', 'CO', 'active')
               on conflict (id) do update set status='active', display_name=excluded.display_name""",
            (str(ACCOUNT_ID),),
        )
        cursor.execute(
            """insert into public.recorrido_account_members(id, account_id, full_name, phone_e164, role, status)
               values (%s, %s, 'Infrastructure Canary', '+573000000000', 'owner', 'active')
               on conflict (id) do update set status='active', role='owner'""",
            (str(MEMBER_ID), str(ACCOUNT_ID)),
        )
        cursor.execute(
            """insert into public.recorrido_credit_buckets
                 (id, account_id, source_kind, source_id, credits_granted, metadata)
               values (%s, %s, 'manual_adjustment', %s, 2,
                 '{"purpose":"cloudflare generation migration canary","non_customer":true}'::jsonb)
               on conflict (id) do nothing""",
            (str(BUCKET_ID), str(ACCOUNT_ID), SOURCE_ID),
        )
        cursor.execute(
            """insert into public.recorrido_credit_ledger
                 (id, account_id, bucket_id, delta, entry_kind, source_type, source_id, metadata)
               values (%s, %s, %s, 2, 'grant', 'cloudflare_canary', %s,
                 '{"purpose":"cloudflare generation migration canary","non_customer":true}'::jsonb)
               on conflict (id) do nothing""",
            (str(LEDGER_ID), str(ACCOUNT_ID), str(BUCKET_ID), SOURCE_ID),
        )
    connection.commit()
    return status(connection)


def status(connection: Any) -> dict[str, Any]:
    with connection.cursor() as cursor:
        cursor.execute(
            """select a.status, m.status,
                      public.recorrido_available_credits(a.id),
                      count(j.id) filter (where j.cloudflare_managed is true),
                      count(j.id) filter (where j.status in ('queued','running'))
               from public.recorrido_customer_accounts a
               join public.recorrido_account_members m on m.account_id=a.id and m.id=%s
               left join public.recorrido_generation_jobs j on j.account_id=a.id
               where a.id=%s
               group by a.status,m.status,a.id""",
            (str(MEMBER_ID), str(ACCOUNT_ID)),
        )
        row = cursor.fetchone()
    if row is None:
        return {"exists": False, "account_id": str(ACCOUNT_ID), "member_id": str(MEMBER_ID)}
    return {
        "exists": True, "account_id": str(ACCOUNT_ID), "member_id": str(MEMBER_ID),
        "account_status": row[0], "member_status": row[1], "available_credits": row[2],
        "cloudflare_jobs": row[3], "active_jobs": row[4],
    }


def close(connection: Any) -> dict[str, Any]:
    with connection.cursor() as cursor:
        cursor.execute("update public.recorrido_account_members set status='revoked' where id=%s and account_id=%s", (str(MEMBER_ID), str(ACCOUNT_ID)))
        cursor.execute("update public.recorrido_customer_accounts set status='closed' where id=%s", (str(ACCOUNT_ID),))
    connection.commit()
    return status(connection)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seed", "status", "close"))
    args = parser.parse_args()
    connection = connect()
    try:
        result = {"seed": seed, "status": status, "close": close}[args.action](connection)
    finally:
        connection.close()
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
