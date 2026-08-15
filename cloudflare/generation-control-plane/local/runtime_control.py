#!/usr/bin/env python3
"""Atomically inspect or switch the Recorrido Cloudflare generation environment."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
from typing import Any

HELPER = Path('/Users/AIAgenterminal/.hermes/scripts/recorrido_full_promotion_worker.py')
TARGETS = ('off', 'staging', 'production')


def connect() -> Any:
    spec = importlib.util.spec_from_file_location('recorrido_db_helper', HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError('database helper unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.connect()


def status(connection: Any, lock: bool = False) -> dict[str, Any]:
    suffix = ' for update' if lock else ''
    with connection.cursor() as cursor:
        cursor.execute(
            'select cloudflare_generation_enabled,active_environment '
            'from public.recorrido_cloudflare_generation_runtime where singleton' + suffix
        )
        row = cursor.fetchone()
        if row is None:
            raise RuntimeError('runtime row unavailable')
        cursor.execute("select count(*) from public.recorrido_generation_jobs where status in ('queued','running')")
        active_jobs = cursor.fetchone()[0]
        cursor.execute(
            "select count(*) from public.recorrido_generation_dispatch_outbox "
            "where status in ('pending','dispatching','enqueued') and terminalized_at is null"
        )
        unsettled_dispatches = cursor.fetchone()[0]
    return {
        'runtime_enabled': bool(row[0]), 'active_environment': row[1],
        'active_jobs': active_jobs, 'unsettled_dispatches': unsettled_dispatches,
    }


def switch(connection: Any, target: str) -> dict[str, Any]:
    current = status(connection, lock=True)
    if target != 'off' and (current['active_jobs'] or current['unsettled_dispatches']):
        raise RuntimeError(
            f"runtime_switch_blocked active_jobs={current['active_jobs']} "
            f"unsettled_dispatches={current['unsettled_dispatches']}"
        )
    with connection.cursor() as cursor:
        cursor.execute(
            'update public.recorrido_cloudflare_generation_runtime '
            'set cloudflare_generation_enabled=%s, active_environment=%s where singleton',
            (target != 'off', target),
        )
    connection.commit()
    return status(connection)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=('status',) + TARGETS)
    args = parser.parse_args()
    connection = connect()
    try:
        result = status(connection) if args.target == 'status' else switch(connection, args.target)
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
