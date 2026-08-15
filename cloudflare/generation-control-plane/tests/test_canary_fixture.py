from __future__ import annotations

import importlib.util
import json
from pathlib import Path

MODULE = Path(__file__).parents[1] / "local/build_canary_fixture.py"
ACCOUNT = "11111111-1111-4111-8111-111111111111"


def load_module():
    spec = importlib.util.spec_from_file_location("canary_fixture", MODULE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_builds_non_customer_resume_fixture_with_bound_keys(tmp_path: Path) -> None:
    module = load_module()
    job, manifest_path = module.build(tmp_path, ACCOUNT, "staging-canary-v1")
    manifest = json.loads(manifest_path.read_text())
    generation = json.loads((job / "v16/generation_manifest.json").read_text())
    results = json.loads((job / "v16/generation_results.json").read_text())
    plan = json.loads((job / "v16/production_plan.json").read_text())

    assert manifest["pipeline"] == "recorrido_v16"
    assert len(manifest["files"]) == 10
    assert all(row["key"].startswith(f"accounts/{ACCOUNT}/jobs/staging-canary-v1/assets/") for row in manifest["files"])
    assert generation["generator_contract"] == "video_studio.grok_animation.AnimationRequest"
    assert len(results["shots"]) == 5 and all(row["status"] == "ready" for row in results["shots"])
    assert plan["listing"]["mls"] == "CANARY-000"
    assert "No customer property data" in plan["verified_facts"]
    assert all((job / row["relative_path"]).is_file() for row in manifest["files"])


def test_cloudflare_clients_set_explicit_service_user_agents() -> None:
    root = Path(__file__).parents[1] / "local"
    assert "RecorridoCanaryUploader/1.0" in (root / "canary_upload.py").read_text()
    assert "RecorridoMacGenerationWorker/1.0" in (root / "worker.py").read_text()


def test_rejects_unsafe_identity(tmp_path: Path) -> None:
    module = load_module()
    try:
        module.build(tmp_path, ACCOUNT, "../bad")
    except ValueError as exc:
        assert str(exc) == "invalid canary identity"
    else:
        raise AssertionError("unsafe idempotency key accepted")
