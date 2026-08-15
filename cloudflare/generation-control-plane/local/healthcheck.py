#!/usr/bin/env python3
"""Silent Recorrido Cloudflare production watchdog; prints only privacy-safe failures."""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

WORKER_URL = "https://recorrido-generation-control-plane.fancy-sea-2dc5.workers.dev"
VERCEL_URL = "https://recorrido-website.vercel.app/"
PACKAGE = Path("/Users/AIAgenterminal/recorrido/.worktrees/recorrido-cloudflare-generation/cloudflare/generation-control-plane")
DB_HELPER = Path("/Users/AIAgenterminal/.hermes/scripts/recorrido_full_promotion_worker.py")
LOCAL_SCRIPT = "/Users/AIAgenterminal/.hermes/scripts/recorrido_cloudflare_generation_worker.py"


def evaluate(*, health: dict[str, Any], queue: dict[str, int], dlq: dict[str, int],
             database: dict[str, Any], local: dict[str, Any], vercel_status: int) -> list[str]:
    issues: list[str] = []
    if health.get("ok") is not True or health.get("environment") != "production" or health.get("database") != "supabase" or health.get("storage") != "r2":
        issues.append("worker_health_failed")
    if queue != {"producers": 1, "consumers": 1}:
        issues.append("queue_topology_invalid")
    if dlq != {"producers": 0, "consumers": 1}:
        issues.append("dlq_topology_invalid")
    if database.get("runtime_enabled") is not True:
        issues.append("cloudflare_generation_disabled")
    elif database.get("active_environment") != "production":
        issues.append("cloudflare_environment_mismatch")
    if int(database.get("dead", 0)) > 0:
        issues.append("dead_dispatch_present")
    if int(database.get("stale", 0)) > 0:
        issues.append("stale_dispatch_present")
    if local.get("loaded") is not True:
        issues.append("local_worker_unloaded")
    if int(local.get("processes", 0)) != 1:
        issues.append("duplicate_local_worker" if int(local.get("processes", 0)) > 1 else "local_worker_missing")
    if vercel_status != 200:
        issues.append("vercel_unhealthy")
    return issues


def http_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"user-agent": "recorrido-cloudflare-watchdog/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read(65536))


def http_status(url: str) -> int:
    request = urllib.request.Request(url, headers={"user-agent": "recorrido-cloudflare-watchdog/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.status


def queue_topology(name: str) -> dict[str, int]:
    result = subprocess.run(
        ["npx", "wrangler", "queues", "info", name], cwd=PACKAGE,
        check=True, capture_output=True, text=True, timeout=60,
    )
    producers = re.search(r"Number of Producers:\s*(\d+)", result.stdout)
    consumers = re.search(r"Number of Consumers:\s*(\d+)", result.stdout)
    if not producers or not consumers:
        raise RuntimeError("queue_topology_unparseable")
    return {"producers": int(producers.group(1)), "consumers": int(consumers.group(1))}


def database_state() -> dict[str, Any]:
    spec = importlib.util.spec_from_file_location("recorrido_promotion_helper", DB_HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("database_helper_unavailable")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    conn = helper.connect()
    try:
        with conn.cursor() as cur:
            cur.execute("select cloudflare_generation_enabled, active_environment from public.recorrido_cloudflare_generation_runtime where singleton")
            enabled, active_environment = cur.fetchone()
            cur.execute("select count(*) from public.recorrido_generation_dispatch_outbox where status='dead'")
            dead = cur.fetchone()[0]
            cur.execute("""
                select count(*) from public.recorrido_generation_dispatch_outbox
                where status in ('pending','dispatching','enqueued')
                  and updated_at < clock_timestamp() - interval '20 minutes'
            """)
            stale = cur.fetchone()[0]
        return {"runtime_enabled": enabled, "active_environment": active_environment, "dead": dead, "stale": stale}
    finally:
        conn.close()


def local_state() -> dict[str, Any]:
    label = f"gui/{subprocess.check_output(['id','-u'], text=True).strip()}/com.recorrido.cloudflare-generation-worker"
    loaded = subprocess.run(["launchctl", "print", label], capture_output=True).returncode == 0
    processes = subprocess.run(["pgrep", "-f", f"^{re.escape('/opt/homebrew/bin/python3.12')} {re.escape(LOCAL_SCRIPT)}"], capture_output=True, text=True)
    count = len([line for line in processes.stdout.splitlines() if line.strip()]) if processes.returncode in (0, 1) else 0
    return {"loaded": loaded, "processes": count}


def main() -> int:
    try:
        issues = evaluate(
            health=http_json(WORKER_URL + "/health"),
            queue=queue_topology("recorrido-generation-queue"),
            dlq=queue_topology("recorrido-generation-dlq"),
            database=database_state(),
            local=local_state(),
            vercel_status=http_status(VERCEL_URL),
        )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, urllib.error.URLError, json.JSONDecodeError):
        issues = ["watchdog_probe_failed"]
    if issues:
        print(json.dumps({"alert": "recorrido_cloudflare_generation", "issues": sorted(set(issues))}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
