from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import time
import urllib.error
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

MODULE = Path(__file__).parents[1] / "local/worker.py"


def load_module():
    spec = importlib.util.spec_from_file_location("recorrido_cf_local_worker", MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeClient:
    def __init__(self, lease, objects):
        self.lease = lease
        self.objects = objects
        self.downloads = []
        self.uploads = []
        self.completed = []
        self.failed = []
        self.heartbeats = []
        self.claim_error: Exception | None = None
        self.upload_error: Exception | None = None
        self.complete_error: Exception | None = None
        self.fail_error: Exception | None = None
        self.heartbeat_result = True

    def claim(self, worker_id):
        if self.claim_error:
            raise self.claim_error
        return self.lease

    def download(self, key, max_bytes=None):
        self.downloads.append((key, max_bytes))
        value = self.objects[key]
        if max_bytes is not None and len(value) > max_bytes:
            raise RuntimeError("object_too_large")
        return value

    def upload_output(self, job_id, account_id, path, environment, worker_id, lease_token, lease_version, output_sha256):
        if self.upload_error:
            raise self.upload_error
        self.uploads.append((job_id, account_id, path.read_bytes(), environment, worker_id, lease_token, lease_version, output_sha256))
        return f"accounts/{account_id}/jobs/{job_id}/leases/{lease_token}/output.mp4"

    def complete(self, job_id, payload):
        if self.complete_error:
            raise self.complete_error
        self.completed.append((job_id, payload))

    def fail(self, job_id, reservation_id, error_code, environment, worker_id, lease_token, lease_version):
        if self.fail_error:
            raise self.fail_error
        self.failed.append((job_id, reservation_id, error_code, environment, worker_id, lease_token, lease_version))

    def heartbeat(self, job_id, environment, worker_id, lease_token, lease_version):
        self.heartbeats.append((job_id, environment, worker_id, lease_token, lease_version))
        return self.heartbeat_result


def fixture():
    account = "11111111-1111-4111-8111-111111111111"
    job = "33333333-3333-4333-8333-333333333333"
    reservation = "44444444-4444-4444-8444-444444444444"
    idempotency = "canary"
    prefix = f"accounts/{account}/jobs/{idempotency}"
    asset = b"approved-anchor"
    manifest = {
        "version": 1,
        "pipeline": "recorrido_v16",
        "job_name": "canary-job",
        "files": [{
            "key": f"{prefix}/assets/v16/stills/001.jpg",
            "relative_path": "v16/stills/001.jpg",
            "sha256": hashlib.sha256(asset).hexdigest(),
        }],
    }
    manifest_bytes = json.dumps(manifest).encode()
    manifest_key = f"{prefix}/manifest.json"
    lease = {
        "job_id": job,
        "account_id": account,
        "reservation_id": reservation,
        "idempotency_key": idempotency,
        "input_manifest_key": manifest_key,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "environment": "staging",
        "lease_token": "55555555-5555-4555-8555-555555555555",
        "lease_version": 7,
    }
    return lease, {manifest_key: manifest_bytes, manifest["files"][0]["key"]: asset}


def test_download_preserves_manifest_bytes_even_when_r2_content_type_is_json() -> None:
    from email.message import Message

    m = load_module()
    payload = b'{"version":1}'
    headers = Message()
    headers['content-type'] = 'application/json'

    class Response:
        def __init__(self):
            self.headers = headers

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

        def geturl(self):
            return 'https://worker.example/v1/objects/input'

        def read(self, _):
            return payload

    response = Response()

    class Opener:
        def open(self, *_args, **_kwargs):
            return response

    client = m.WorkerClient('https://worker.example', 'token')
    client.opener = Opener()
    assert client.download('accounts/a/jobs/b/manifest.json', 100) == payload


def test_render_v16_reads_completed_ffprobe_stream_and_uses_jobs_flag(monkeypatch, tmp_path: Path) -> None:
    import io
    from types import SimpleNamespace

    m = load_module()
    job_dir = tmp_path / "job"
    output = job_dir / "v16" / "final" / "canary.mp4"
    output.parent.mkdir(parents=True)
    output.write_bytes(b"synthetic-video")
    (job_dir / "v16" / "generation_manifest.json").write_text("{}")
    (job_dir / "v16" / "assembly_results.json").write_text(json.dumps({
        "output": "final/canary.mp4",
    }))
    commands = []

    def fake_run(command, **_kwargs):
        commands.append(command)
        if command[0] == "ffprobe":
            return SimpleNamespace(stdout=io.StringIO("47.061\n"))
        return SimpleNamespace(stdout=None)

    monkeypatch.setattr(m, "_run_process", fake_run)
    rendered, duration = m.render_v16(job_dir, lambda: True)

    assert rendered == output.resolve()
    assert duration == 47
    assert "--jobs" in commands[0]
    assert commands[0][commands[0].index("--jobs") + 1] == job_dir.name
    assert commands[0][commands[0].index("--jobs-root") + 1] == str(job_dir.parent)


def test_manifest_namespace_and_digest_are_verified_before_asset_download():
    m = load_module()
    lease, objects = fixture()
    wrong = dict(lease, input_manifest_key=f"accounts/{lease['account_id']}/jobs/other/manifest.json")
    client = FakeClient(wrong, objects)
    with TemporaryDirectory() as temp:
        assert m.run_once(client, "mac-render-01", Path(temp), lambda *_: None) == "invalid_lease"
    assert client.downloads == []

    client = FakeClient(dict(lease, manifest_sha256="0" * 64), objects)
    with TemporaryDirectory() as temp:
        assert m.run_once(client, "mac-render-01", Path(temp), lambda *_: None) == "failed"
    assert [item[0] for item in client.downloads] == [lease["input_manifest_key"]]
    assert client.failed[0][2] == "manifest_hash_mismatch"


@pytest.mark.parametrize("name", [".hidden", "..", ".", "ok/.hidden"])
def test_materialize_rejects_hidden_or_dot_job_names(name):
    m = load_module()
    lease, objects = fixture()
    manifest = json.loads(objects[lease["input_manifest_key"]])
    manifest["job_name"] = name
    with TemporaryDirectory() as temp, pytest.raises(m.ContractError) as caught:
        m.materialize(Path(temp), lease, manifest, FakeClient(lease, objects))
    assert caught.value.code == "invalid_job_name"


def test_materialize_rejects_path_traversal_hash_mismatch_and_size_limits(monkeypatch):
    m = load_module()
    lease, objects = fixture()
    manifest = json.loads(objects[lease["input_manifest_key"]])
    client = FakeClient(lease, objects)
    with TemporaryDirectory() as temp:
        manifest["files"][0]["relative_path"] = "../escape.jpg"
        with pytest.raises(m.ContractError, match="invalid_relative_path"):
            m.materialize(Path(temp), lease, manifest, client)

        manifest["files"][0]["relative_path"] = "v16/stills/001.jpg"
        manifest["files"][0]["sha256"] = "0" * 64
        with pytest.raises(m.ContractError, match="asset_hash_mismatch"):
            m.materialize(Path(temp), lease, manifest, client)

        manifest["files"][0]["sha256"] = hashlib.sha256(b"approved-anchor").hexdigest()
        monkeypatch.setattr(m, "MAX_FILE_BYTES", 4)
        with pytest.raises(RuntimeError, match="object_too_large"):
            m.materialize(Path(temp), lease, manifest, client)

        monkeypatch.setattr(m, "MAX_FILE_BYTES", 100)
        monkeypatch.setattr(m, "MAX_AGGREGATE_BYTES", 4)
        with pytest.raises(m.ContractError, match="aggregate_input_too_large"):
            m.materialize(Path(temp), lease, manifest, client)


def test_materialize_rejects_hidden_path_components_and_duplicate_entries():
    m = load_module()
    lease, objects = fixture()
    manifest = json.loads(objects[lease["input_manifest_key"]])
    client = FakeClient(lease, objects)
    with TemporaryDirectory() as temp:
        manifest["files"][0]["relative_path"] = "v16/.private/001.jpg"
        with pytest.raises(m.ContractError, match="invalid_relative_path"):
            m.materialize(Path(temp), lease, manifest, client)

    manifest = json.loads(objects[lease["input_manifest_key"]])
    manifest["files"].append(dict(manifest["files"][0]))
    with TemporaryDirectory() as temp:
        with pytest.raises(m.ContractError, match="duplicate_manifest_entry"):
            m.materialize(Path(temp), lease, manifest, client)


def test_materialize_uses_private_directories_and_atomic_private_files():
    m = load_module()
    lease, objects = fixture()
    manifest = json.loads(objects[lease["input_manifest_key"]])
    with TemporaryDirectory() as temp:
        job_dir = m.materialize(Path(temp), lease, manifest, FakeClient(lease, objects))
        assert stat.S_IMODE(job_dir.stat().st_mode) == 0o700
        assert stat.S_IMODE((job_dir / "v16").stat().st_mode) == 0o700
        assert stat.S_IMODE((job_dir / "v16/stills").stat().st_mode) == 0o700
        assert stat.S_IMODE((job_dir / "v16/stills/001.jpg").stat().st_mode) == 0o600
        assert stat.S_IMODE((job_dir / "cloudflare_manifest.json").stat().st_mode) == 0o600
        assert list(job_dir.rglob("*.tmp")) == []


def test_run_once_heartbeats_and_includes_lease_credentials_in_settlement():
    m = load_module()
    lease, objects = fixture()
    client = FakeClient(lease, objects)

    def render(job_dir: Path, heartbeat):
        assert heartbeat() is True
        output = job_dir / "v16/final/output.mp4"
        output.parent.mkdir(parents=True)
        output.write_bytes(b"verified-mp4")
        return output, 30

    with TemporaryDirectory() as temp:
        result = m.run_once(client, "mac-render-01", Path(temp), render)
    assert result == "completed"
    expected_heartbeat = (lease["job_id"], "staging", "mac-render-01", lease["lease_token"], 7)
    assert client.heartbeats == [expected_heartbeat, expected_heartbeat]
    assert client.uploads[0][3:7] == ("staging", "mac-render-01", lease["lease_token"], 7)
    assert client.uploads[0][7] == hashlib.sha256(b"verified-mp4").hexdigest()
    assert client.completed[0][1]["worker_id"] == "mac-render-01"
    assert client.completed[0][1]["lease_token"] == lease["lease_token"]
    assert client.completed[0][1]["lease_version"] == 7
    assert client.completed[0][1]["environment"] == "staging"
    assert client.completed[0][1]["output_sha256"] == hashlib.sha256(b"verified-mp4").hexdigest()
    assert client.failed == []


def test_run_once_rejects_oversized_output_without_upload(monkeypatch):
    m = load_module()
    lease, objects = fixture()
    client = FakeClient(lease, objects)
    monkeypatch.setattr(m, "MAX_OUTPUT_BYTES", 3)

    def render(job_dir, heartbeat):
        output = job_dir / "out.mp4"
        output.write_bytes(b"large")
        return output, 1

    with TemporaryDirectory() as temp:
        assert m.run_once(client, "mac-render-01", Path(temp), render) == "failed"
    assert client.uploads == []
    assert client.failed[0][2] == "output_too_large"


def test_completion_failure_resumes_same_lease_without_rerendering():
    m = load_module()
    lease, objects = fixture()
    client = FakeClient(lease, objects)
    client.complete_error = RuntimeError("worker_http_503")
    render_calls = []

    def render(job_dir, heartbeat):
        render_calls.append(job_dir)
        output = job_dir / "output.mp4"
        output.write_bytes(b"durable-output")
        return output, 47

    with TemporaryDirectory() as temp:
        root = Path(temp)
        assert m.run_once(client, "mac-render-01", root, render) == "settlement_pending"
        journals = list(root.glob("*/*/.settlement.json"))
        assert len(journals) == 1
        assert journals[0].stat().st_mode & 0o077 == 0
        client.complete_error = None
        assert m.run_once(client, "mac-render-01", root, lambda *_: pytest.fail("renderer reran")) == "completed"
        assert list(root.glob("*/*/.settlement.json")) == []

    assert len(render_calls) == 1
    assert len(client.uploads) == 2
    assert len(client.completed) == 1
    assert client.heartbeats[-1][0] == lease["job_id"]


def test_transient_claim_upload_completion_and_failure_errors_do_not_incorrectly_release():
    m = load_module()
    lease, objects = fixture()

    claim_client = FakeClient(lease, objects)
    claim_client.claim_error = RuntimeError("worker_http_503")
    assert m.run_once(claim_client, "worker", Path("/unused"), lambda *_: None) == "transient_error"
    assert claim_client.failed == []

    def render(job_dir, heartbeat):
        output = job_dir / "output.mp4"
        output.write_bytes(b"ok")
        return output, 1

    for field in ("upload_error", "complete_error"):
        client = FakeClient(lease, objects)
        setattr(client, field, RuntimeError("worker_http_503"))
        with TemporaryDirectory() as temp:
            assert m.run_once(client, "worker", Path(temp), render) == "settlement_pending"
        assert client.failed == []

    bad_objects = dict(objects)
    manifest = json.loads(bad_objects[lease["input_manifest_key"]])
    manifest["pipeline"] = "bad"
    bad_objects[lease["input_manifest_key"]] = json.dumps(manifest).encode()
    bad_lease = dict(lease, manifest_sha256=hashlib.sha256(bad_objects[lease["input_manifest_key"]]).hexdigest())
    client = FakeClient(bad_lease, bad_objects)
    client.fail_error = RuntimeError("worker_http_503")
    with TemporaryDirectory() as temp:
        assert m.run_once(client, "worker", Path(temp), render) == "settlement_pending"
    assert client.failed == []


def test_client_disables_redirects_and_rejects_cross_origin(monkeypatch):
    m = load_module()
    client = m.WorkerClient("https://worker.example", "token")
    assert any(isinstance(handler, m.NoRedirectHandler) for handler in client.opener.handlers)

    class Response:
        headers = type("Headers", (), {"get_content_type": lambda self: "application/json"})()
        def __enter__(self): return self
        def __exit__(self, *args): return None
        def geturl(self): return "https://evil.example/v1/leases/next"
        def read(self, amount=-1): return b"{}"

    monkeypatch.setattr(client.opener, "open", lambda *args, **kwargs: Response())
    with pytest.raises(RuntimeError, match="cross_origin_response"):
        client.claim("worker")


def test_client_enforces_bounded_download_and_sends_lease_credentials(monkeypatch, tmp_path):
    m = load_module()
    client = m.WorkerClient("https://worker.example", "token")
    calls = []
    monkeypatch.setattr(
        client,
        "_request",
        lambda method, path, body=None, content_type="application/json", max_bytes=None, extra_headers=None:
            calls.append((method, path, body, content_type, max_bytes, extra_headers))
            or ({"key": "stored"} if method == "PUT" else b"download"),
    )
    path = tmp_path / "out.mp4"
    path.write_bytes(b"mp4")
    client.download("key", max_bytes=17)
    digest = hashlib.sha256(b"mp4").hexdigest()
    client.upload_output("job", "account", path, "staging", "worker", "lease", 7, digest)
    client.fail("job", "reservation", "bad", "staging", "worker", "lease", 7)
    assert calls[0][4] == 17
    assert all(piece in calls[1][1] for piece in ("environment=staging", "worker_id=worker", "lease_token=lease", "lease_version=7"))
    assert calls[1][5] == {"x-content-sha256": digest}
    assert json.loads(calls[2][2]) == {"reservation_id": "reservation", "error_code": "bad", "environment": "staging", "worker_id": "worker", "lease_token": "lease", "lease_version": 7}


def test_run_process_terminates_process_group_on_lease_loss_and_timeout(monkeypatch):
    m = load_module()
    killed = []
    monkeypatch.setattr(m.os, "killpg", lambda pgid, signal: killed.append((pgid, signal)))

    class Process:
        pid = 321
        returncode = None
        def poll(self): return None
        def wait(self, timeout=None): self.returncode = -15; return -15

    monkeypatch.setattr(m.subprocess, "Popen", lambda *args, **kwargs: Process())
    with pytest.raises(m.LeaseLost):
        m._run_process(["renderer"], timeout=10, heartbeat=lambda: False, heartbeat_interval=0)
    assert killed and killed[0][0] == 321

    killed.clear()
    clock = iter([0.0, 11.0, 12.0])
    monkeypatch.setattr(m.time, "monotonic", lambda: next(clock))
    with pytest.raises(subprocess.TimeoutExpired):
        m._run_process(["renderer"], timeout=10, heartbeat=lambda: True)
    assert killed and killed[0][0] == 321


def test_singleton_lock_uses_flock_and_rejects_second_worker():
    m = load_module()
    with TemporaryDirectory() as temp:
        path = Path(temp) / "worker.lock"
        first = m.SingletonLock(path)
        second = m.SingletonLock(path)
        assert first.acquire() is True
        assert second.acquire() is False
        first.release()
        assert second.acquire() is True
        second.release()


def test_main_requires_darwin_and_trusted_renderer_paths(monkeypatch, tmp_path):
    m = load_module()
    env = tmp_path / "worker.env"
    env.write_text("WORKER_URL=https://worker.example\nLOCAL_WORKER_TOKEN=t\n")
    env.chmod(0o600)
    monkeypatch.setattr(m.sys, "platform", "linux")
    with pytest.raises(RuntimeError, match="Darwin"):
        m.main(["--once", "--env-file", str(env)])

    monkeypatch.setattr(m.sys, "platform", "darwin")
    bad = tmp_path / "renderer.py"
    bad.write_text("pass\n")
    bad.chmod(0o666)
    monkeypatch.setattr(m, "GENERATE", bad)
    monkeypatch.setattr(m, "ASSEMBLE", bad)
    with pytest.raises(RuntimeError, match="trusted renderer"):
        m.main(["--once", "--env-file", str(env)])
