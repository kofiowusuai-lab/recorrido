from __future__ import annotations

import importlib.util
from pathlib import Path

MODULE = Path(__file__).parents[1] / "local/healthcheck.py"


def load_module():
    spec = importlib.util.spec_from_file_location("recorrido_cf_healthcheck", MODULE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_evaluate_is_silent_for_healthy_singleton_topology():
    m = load_module()
    issues = m.evaluate(
        health={"ok": True, "environment": "production", "database": "supabase", "storage": "r2"},
        queue={"producers": 1, "consumers": 1},
        dlq={"producers": 0, "consumers": 1},
        database={"runtime_enabled": True, "active_environment": "production", "dead": 0, "stale": 0},
        local={"loaded": True, "processes": 1},
        vercel_status=200,
    )
    assert issues == []


def test_evaluate_emits_only_privacy_safe_issue_codes():
    m = load_module()
    issues = m.evaluate(
        health={"ok": False},
        queue={"producers": 2, "consumers": 0},
        dlq={"producers": 1, "consumers": 0},
        database={"runtime_enabled": True, "active_environment": "production", "dead": 3, "stale": 2},
        local={"loaded": True, "processes": 2},
        vercel_status=503,
    )
    assert set(issues) == {
        "worker_health_failed", "queue_topology_invalid", "dlq_topology_invalid",
        "dead_dispatch_present", "stale_dispatch_present", "duplicate_local_worker",
        "vercel_unhealthy",
    }
    assert all("phone" not in issue and "token" not in issue for issue in issues)


def test_runtime_disabled_is_reported_after_cutover():
    m = load_module()
    issues = m.evaluate(
        health={"ok": True, "environment": "production", "database": "supabase", "storage": "r2"},
        queue={"producers": 1, "consumers": 1},
        dlq={"producers": 0, "consumers": 1},
        database={"runtime_enabled": False, "active_environment": "off", "dead": 0, "stale": 0},
        local={"loaded": True, "processes": 1},
        vercel_status=200,
    )
    assert issues == ["cloudflare_generation_disabled"]


def test_wrong_active_environment_is_reported():
    m = load_module()
    issues = m.evaluate(
        health={"ok": True, "environment": "production", "database": "supabase", "storage": "r2"},
        queue={"producers": 1, "consumers": 1}, dlq={"producers": 0, "consumers": 1},
        database={"runtime_enabled": True, "active_environment": "staging", "dead": 0, "stale": 0},
        local={"loaded": True, "processes": 1}, vercel_status=200,
    )
    assert issues == ["cloudflare_environment_mismatch"]
