#!/usr/bin/env python3
"""Lease Supabase-authorized Recorrido jobs and run the existing local V16 renderer."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
SAFE_WORKER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._~-]{1,256}$")
REPO = Path("/Users/AIAgenterminal/recorrido")
GENERATE = REPO / "scripts/generate_recorrido_v16_batch.py"
ASSEMBLE = REPO / "scripts/assemble_recorrido_v16.py"
MAX_MANIFEST_BYTES = 1_000_000
MAX_FILE_BYTES = 90_000_000
MAX_AGGREGATE_BYTES = 500_000_000
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
OUTPUT_PART_BYTES = 512 * 1024
HEARTBEAT_INTERVAL = 30.0


class ContractError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class LeaseLost(RuntimeError):
    """Raised when the authority no longer recognizes this worker's lease."""


class SingletonLock:
    """An advisory process lock which remains safe across crashes and stale files."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.handle: Any | None = None

    def acquire(self) -> bool:
        _mkdir_private(self.path.parent)
        descriptor = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(descriptor, 0o600)
        handle = os.fdopen(descriptor, "r+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            return False
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
        self.handle = handle
        return True

    def release(self) -> None:
        if self.handle is None:
            return
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.handle.close()
            self.handle = None


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


class WorkerClient:
    def __init__(self, base_url: str, token: str, timeout: int = 120):
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise RuntimeError("invalid_worker_url")
        self.base_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))
        self.origin = (parsed.scheme.lower(), parsed.hostname.lower(), parsed.port or 443)
        self.token = token
        self.timeout = timeout
        self.opener = urllib.request.build_opener(NoRedirectHandler())

    def _request(self, method: str, path: str, body: bytes | None = None,
                 content_type: str = "application/json", max_bytes: int | None = None,
                 extra_headers: dict[str, str] | None = None) -> Any:
        if not path.startswith("/"):
            raise RuntimeError("invalid_worker_path")
        headers = {
            "authorization": f"Bearer {self.token}",
            "user-agent": "RecorridoMacGenerationWorker/1.0",
        }
        if extra_headers:
            headers.update(extra_headers)
        if body is not None:
            headers["content-type"] = content_type
            headers["content-length"] = str(len(body))
        request = urllib.request.Request(self.base_url + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                final = urllib.parse.urlsplit(response.geturl())
                final_origin = (final.scheme.lower(), (final.hostname or "").lower(), final.port or 443)
                if final_origin != self.origin:
                    raise RuntimeError("cross_origin_response")
                limit = max_bytes if max_bytes is not None else MAX_MANIFEST_BYTES
                payload = response.read(limit + 1)
                if len(payload) > limit:
                    raise RuntimeError("object_too_large")
                response_type = response.headers.get_content_type()
        except urllib.error.HTTPError as exc:
            exc.read(4096)
            raise RuntimeError(f"worker_http_{exc.code}") from None
        except urllib.error.URLError as exc:
            raise RuntimeError("worker_unavailable") from exc
        if not payload:
            return None
        if content_type == "application/json":
            try:
                return json.loads(payload)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise RuntimeError("invalid_worker_response") from exc
        return payload

    def claim(self, worker_id: str) -> dict[str, Any] | None:
        body = json.dumps({"worker_id": worker_id}, separators=(",", ":")).encode()
        value = self._request("POST", "/v1/leases/next", body)
        return value if isinstance(value, dict) else None

    def download(self, key: str, max_bytes: int = MAX_FILE_BYTES) -> bytes:
        path = "/v1/objects/input?" + urllib.parse.urlencode({"key": key})
        value = self._request("GET", path, content_type="application/octet-stream", max_bytes=max_bytes)
        if not isinstance(value, bytes):
            raise RuntimeError("invalid_object_response")
        return value

    def heartbeat(self, job_id: str, environment: str, worker_id: str,
                  lease_token: str, lease_version: int) -> bool:
        body = json.dumps({
            "environment": environment, "worker_id": worker_id,
            "lease_token": lease_token, "lease_version": lease_version,
        }, separators=(",", ":")).encode()
        value = self._request("POST", f"/v1/jobs/{job_id}/heartbeat", body)
        return isinstance(value, dict) and value.get("leased", value.get("ok", True)) is True

    def upload_output(self, job_id: str, account_id: str, path: Path,
                      environment: str, worker_id: str, lease_token: str,
                      lease_version: int, output_sha256: str) -> str:
        size = path.stat().st_size
        if size <= 0 or size > MAX_OUTPUT_BYTES:
            raise ContractError("output_too_large")
        query_values = {
            "account_id": account_id, "environment": environment,
            "worker_id": worker_id, "lease_token": lease_token,
            "lease_version": lease_version,
        }
        if size > OUTPUT_PART_BYTES:
            part_count = 0
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(OUTPUT_PART_BYTES)
                    if not chunk:
                        break
                    part_count += 1
                    query = urllib.parse.urlencode({**query_values, "output_sha256": output_sha256})
                    self._request(
                        "PUT", f"/v1/jobs/{job_id}/output-parts/{part_count}?{query}",
                        chunk, "video/mp4", OUTPUT_PART_BYTES,
                        {"x-content-sha256": hashlib.sha256(chunk).hexdigest()},
                    )
            body = json.dumps({
                **query_values, "output_sha256": output_sha256,
                "part_count": part_count, "total_size": size,
            }, separators=(",", ":")).encode()
            value = self._request("POST", f"/v1/jobs/{job_id}/output-finalize", body)
        else:
            body = path.read_bytes()
            query = urllib.parse.urlencode(query_values)
            value = self._request(
                "PUT", f"/v1/jobs/{job_id}/output?{query}", body, "video/mp4", MAX_OUTPUT_BYTES,
                {"x-content-sha256": output_sha256},
            )
        if not isinstance(value, dict) or not isinstance(value.get("key"), str):
            raise RuntimeError("invalid_upload_response")
        return value["key"]

    def complete(self, job_id: str, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode()
        self._request("POST", f"/v1/jobs/{job_id}/complete", body)

    def fail(self, job_id: str, reservation_id: str, error_code: str,
             environment: str, worker_id: str, lease_token: str,
             lease_version: int) -> None:
        body = json.dumps({
            "reservation_id": reservation_id, "error_code": error_code,
            "environment": environment, "worker_id": worker_id,
            "lease_token": lease_token, "lease_version": lease_version,
        }, separators=(",", ":")).encode()
        self._request("POST", f"/v1/jobs/{job_id}/fail", body)


def _object(value: bytes) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError("invalid_manifest_json") from exc
    if not isinstance(parsed, dict):
        raise ContractError("invalid_manifest_json")
    return parsed


def _relative(value: object) -> Path:
    if not isinstance(value, str) or not value or len(value) > 240:
        raise ContractError("invalid_relative_path")
    path = Path(value)
    if path.is_absolute() or "\\" in value or ".." in path.parts or any(
        part in ("", ".") or part.startswith(".") for part in path.parts
    ):
        raise ContractError("invalid_relative_path")
    return path


def _mkdir_private(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise RuntimeError("unsafe_work_directory")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def _atomic_write(path: Path, payload: bytes) -> None:
    _mkdir_private(path.parent)
    temporary = path.parent / f".{path.name}.{os.getpid()}.{time.monotonic_ns()}.tmp"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _lease_fields(lease: dict[str, Any]) -> tuple[str, str, str, str, str, str, str, str, int]:
    job_id = lease.get("job_id")
    reservation_id = lease.get("reservation_id")
    account_id = lease.get("account_id")
    idempotency_key = lease.get("idempotency_key")
    input_key = lease.get("input_manifest_key")
    manifest_sha = lease.get("manifest_sha256")
    environment = lease.get("environment")
    lease_token = lease.get("lease_token")
    lease_version = lease.get("lease_version")
    if not all(isinstance(value, str) and UUID.fullmatch(value) for value in (job_id, reservation_id, account_id)):
        raise ContractError("invalid_lease")
    if not isinstance(idempotency_key, str) or not SAFE_NAME.fullmatch(idempotency_key):
        raise ContractError("invalid_lease")
    expected = f"accounts/{account_id}/jobs/{idempotency_key}/manifest.json"
    if input_key != expected:
        raise ContractError("invalid_lease")
    if not isinstance(manifest_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", manifest_sha):
        raise ContractError("invalid_lease")
    if environment not in ("staging", "production"):
        raise ContractError("invalid_lease")
    if not isinstance(lease_token, str) or not UUID.fullmatch(lease_token):
        raise ContractError("invalid_lease")
    if not isinstance(lease_version, int) or isinstance(lease_version, bool) or lease_version < 1:
        raise ContractError("invalid_lease")
    assert isinstance(job_id, str) and isinstance(reservation_id, str) and isinstance(account_id, str)
    assert isinstance(input_key, str) and isinstance(environment, str)
    return job_id, reservation_id, account_id, idempotency_key, input_key, manifest_sha, environment, lease_token, lease_version


def materialize(root: Path, lease: dict[str, Any], manifest: dict[str, Any], client: Any) -> Path:
    job_id, _, account_id, idempotency_key, input_key, _, _, _, _ = _lease_fields(lease)
    if manifest.get("version") != 1 or manifest.get("pipeline") != "recorrido_v16":
        raise ContractError("unsupported_pipeline")
    job_name = manifest.get("job_name")
    if not isinstance(job_name, str) or not SAFE_NAME.fullmatch(job_name) or job_name.startswith("."):
        raise ContractError("invalid_job_name")
    files = manifest.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= 200:
        raise ContractError("invalid_file_list")
    prefix = f"accounts/{account_id}/jobs/{idempotency_key}/assets/"
    root = Path(root)
    job_dir = root / job_id / job_name
    for directory in (root, root / job_id, job_dir):
        _mkdir_private(directory)
    total = 0
    seen_keys: set[str] = set()
    seen_paths: set[str] = set()
    for row in files:
        if not isinstance(row, dict):
            raise ContractError("invalid_file_entry")
        key = row.get("key")
        digest = row.get("sha256")
        relative = _relative(row.get("relative_path"))
        relative_name = relative.as_posix()
        if not isinstance(key, str) or not key.startswith(prefix):
            raise ContractError("invalid_asset_key")
        if key in seen_keys or relative_name in seen_paths:
            raise ContractError("duplicate_manifest_entry")
        seen_keys.add(key)
        seen_paths.add(relative_name)
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ContractError("invalid_asset_hash")
        payload = client.download(key, max_bytes=MAX_FILE_BYTES)
        total += len(payload)
        if total > MAX_AGGREGATE_BYTES:
            raise ContractError("aggregate_input_too_large")
        if hashlib.sha256(payload).hexdigest() != digest:
            raise ContractError("asset_hash_mismatch")
        destination = (job_dir / relative).resolve()
        if job_dir.resolve() not in destination.parents:
            raise ContractError("invalid_relative_path")
        private_parent = job_dir
        for part in relative.parts[:-1]:
            private_parent = private_parent / part
            _mkdir_private(private_parent)
        _atomic_write(destination, payload)
    _atomic_write(job_dir / "cloudflare_manifest.json", (json.dumps(manifest, sort_keys=True) + "\n").encode())
    return job_dir


def _terminate_process_group(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    except ProcessLookupError:
        pass


def _run_process(command: list[str], timeout: float, heartbeat: Callable[[], bool],
                 heartbeat_interval: float = HEARTBEAT_INTERVAL, **kwargs: Any) -> subprocess.Popen[Any]:
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    started = time.monotonic()
    last_heartbeat = started - heartbeat_interval
    try:
        while process.poll() is None:
            now = time.monotonic()
            if now - started > timeout:
                raise subprocess.TimeoutExpired(command, timeout)
            if now - last_heartbeat >= heartbeat_interval:
                if not heartbeat():
                    raise LeaseLost("lease_lost")
                last_heartbeat = now
            time.sleep(0.25)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command)
        return process
    except BaseException:
        _terminate_process_group(process)
        raise


def render_v16(job_dir: Path, heartbeat: Callable[[], bool]) -> tuple[Path, int]:
    if not (job_dir / "v16/generation_manifest.json").is_file():
        raise ContractError("generation_manifest_missing")
    _run_process([
        sys.executable, str(GENERATE), "--jobs-root", str(job_dir.parent), "--jobs", job_dir.name,
        "--max-workers", "3", "--resume",
    ], timeout=7200, heartbeat=heartbeat)
    _run_process([sys.executable, str(ASSEMBLE), str(job_dir), "--resume"], timeout=7200, heartbeat=heartbeat)
    result_path = job_dir / "v16/assembly_results.json"
    result = _object(result_path.read_bytes()) if result_path.is_file() else {}
    relative = _relative(result.get("output"))
    output = (job_dir / "v16" / relative).resolve()
    if job_dir.resolve() not in output.parents or output.is_symlink() or not output.is_file() or output.stat().st_size <= 0:
        raise ContractError("verified_output_missing")
    if output.stat().st_size > MAX_OUTPUT_BYTES:
        raise ContractError("output_too_large")
    probe = _run_process([
        "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(output),
    ], timeout=60, heartbeat=heartbeat, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    probe_output = probe.stdout.read() if probe.stdout is not None else ""
    if not isinstance(probe_output, str):
        raise ContractError("invalid_output_duration")
    duration = round(float(probe_output.strip()))
    if duration <= 0:
        raise ContractError("invalid_output_duration")
    return output, duration


def _settle_failure(client: Any, job_id: str, reservation_id: str, code: str,
                    environment: str, worker_id: str, lease_token: str,
                    lease_version: int) -> str:
    try:
        client.fail(job_id, reservation_id, code, environment, worker_id, lease_token, lease_version)
    except (OSError, RuntimeError, urllib.error.URLError):
        return "settlement_pending"
    return "failed"


def _write_settlement_journal(job_dir: Path, job_id: str, output: Path,
                              payload: dict[str, Any]) -> Path:
    relative = output.resolve().relative_to(job_dir.resolve()).as_posix()
    journal = job_dir / ".settlement.json"
    _atomic_write(journal, (json.dumps({
        "version": 1,
        "job_id": job_id,
        "output_relative": relative,
        "completion": payload,
    }, sort_keys=True) + "\n").encode())
    return journal


def _resume_settlement_journal(client: Any, journal: Path) -> str:
    if journal.is_symlink() or not journal.is_file() or journal.stat().st_mode & 0o077:
        raise RuntimeError("unsafe_settlement_journal")
    try:
        saved = json.loads(journal.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("invalid_settlement_journal") from exc
    if not isinstance(saved, dict) or saved.get("version") != 1:
        raise RuntimeError("invalid_settlement_journal")
    job_id = saved.get("job_id")
    relative_value = saved.get("output_relative")
    payload = saved.get("completion")
    if not isinstance(job_id, str) or not UUID.fullmatch(job_id) or journal.parent.parent.name != job_id:
        raise RuntimeError("invalid_settlement_journal")
    if not isinstance(payload, dict):
        raise RuntimeError("invalid_settlement_journal")
    reservation_id = payload.get("reservation_id")
    account_id = payload.get("account_id")
    environment = payload.get("environment")
    worker_id = payload.get("worker_id")
    lease_token = payload.get("lease_token")
    lease_version = payload.get("lease_version")
    output_key = payload.get("output_object_key")
    output_sha256 = payload.get("output_sha256")
    duration = payload.get("duration_seconds")
    expected_key = f"accounts/{account_id}/jobs/{job_id}/leases/{lease_token}/output.mp4"
    if not all(isinstance(value, str) and UUID.fullmatch(value) for value in (reservation_id, account_id, lease_token)):
        raise RuntimeError("invalid_settlement_journal")
    if environment not in ("staging", "production") or not isinstance(worker_id, str) or not SAFE_WORKER.fullmatch(worker_id):
        raise RuntimeError("invalid_settlement_journal")
    if not isinstance(lease_version, int) or isinstance(lease_version, bool) or lease_version < 1:
        raise RuntimeError("invalid_settlement_journal")
    if output_key != expected_key or not isinstance(output_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", output_sha256):
        raise RuntimeError("invalid_settlement_journal")
    if not isinstance(duration, int) or isinstance(duration, bool) or duration <= 0:
        raise RuntimeError("invalid_settlement_journal")
    relative = _relative(relative_value)
    output = (journal.parent / relative).resolve()
    if journal.parent.resolve() not in output.parents or output.is_symlink() or not output.is_file():
        raise RuntimeError("settlement_output_missing")
    if output.stat().st_size <= 0 or output.stat().st_size > MAX_OUTPUT_BYTES:
        raise RuntimeError("settlement_output_invalid")
    if hashlib.sha256(output.read_bytes()).hexdigest() != output_sha256:
        raise RuntimeError("settlement_output_digest_mismatch")
    if not client.heartbeat(job_id, environment, worker_id, lease_token, lease_version):
        journal.unlink()
        return "lease_lost"
    stored_key = client.upload_output(
        job_id, account_id, output, environment, worker_id, lease_token,
        lease_version, output_sha256,
    )
    if stored_key != output_key:
        raise RuntimeError("unexpected_output_key")
    client.complete(job_id, payload)
    journal.unlink()
    return "completed"


def _resume_pending_settlement(client: Any, work_root: Path) -> str | None:
    for journal in sorted(Path(work_root).glob("*/*/.settlement.json")):
        return _resume_settlement_journal(client, journal)
    return None


def run_once(client: Any, worker_id: str, work_root: Path,
             renderer: Callable[[Path, Callable[[], bool]], tuple[Path, int]] = render_v16) -> str:
    try:
        resumed = _resume_pending_settlement(client, work_root)
    except (OSError, RuntimeError, urllib.error.URLError) as exc:
        code = str(exc) if re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", str(exc)) else "settlement_unavailable"
        print(json.dumps({"event": "recorrido_cloudflare_settlement_pending", "error_code": code, "exception_type": type(exc).__name__}), file=sys.stderr, flush=True)
        return "settlement_pending"
    if resumed is not None:
        return resumed
    try:
        lease = client.claim(worker_id)
    except (OSError, RuntimeError, urllib.error.URLError):
        return "transient_error"
    if lease is None:
        return "idle"
    try:
        job_id, reservation_id, account_id, _, input_key, manifest_sha, environment, lease_token, lease_version = _lease_fields(lease)
    except ContractError:
        return "invalid_lease"

    def heartbeat() -> bool:
        try:
            return bool(client.heartbeat(job_id, environment, worker_id, lease_token, lease_version))
        except (OSError, RuntimeError, urllib.error.URLError):
            return False

    try:
        manifest_bytes = client.download(input_key, max_bytes=MAX_MANIFEST_BYTES)
        if hashlib.sha256(manifest_bytes).hexdigest() != manifest_sha:
            raise ContractError("manifest_hash_mismatch")
        manifest = _object(manifest_bytes)
        job_dir = materialize(Path(work_root), lease, manifest, client)
        output, duration = renderer(job_dir, heartbeat)
        output = Path(output).resolve()
        if job_dir.resolve() not in output.parents or output.is_symlink() or not output.is_file() or output.stat().st_size <= 0:
            raise ContractError("verified_output_missing")
        if output.stat().st_size > MAX_OUTPUT_BYTES:
            raise ContractError("output_too_large")
        os.chmod(output, 0o600)
        if not isinstance(duration, int) or duration <= 0:
            raise ContractError("invalid_output_duration")
    except LeaseLost:
        return "lease_lost"
    except ContractError as exc:
        return _settle_failure(
            client, job_id, reservation_id, exc.code, environment,
            worker_id, lease_token, lease_version,
        )
    except subprocess.TimeoutExpired as exc:
        print(json.dumps({"event": "recorrido_cloudflare_worker_failure", "error_code": "renderer_timeout", "exception_type": type(exc).__name__}), file=sys.stderr, flush=True)
        return _settle_failure(
            client, job_id, reservation_id, "renderer_timeout", environment,
            worker_id, lease_token, lease_version,
        )
    except subprocess.CalledProcessError as exc:
        print(json.dumps({"event": "recorrido_cloudflare_worker_failure", "error_code": "renderer_failed", "exception_type": type(exc).__name__, "return_code": exc.returncode}), file=sys.stderr, flush=True)
        return _settle_failure(
            client, job_id, reservation_id, "renderer_failed", environment,
            worker_id, lease_token, lease_version,
        )
    except OSError as exc:
        print(json.dumps({"event": "recorrido_cloudflare_worker_failure", "error_code": "local_io_error", "exception_type": type(exc).__name__, "errno": exc.errno}), file=sys.stderr, flush=True)
        return _settle_failure(
            client, job_id, reservation_id, "local_io_error", environment,
            worker_id, lease_token, lease_version,
        )
    except (RuntimeError, ValueError) as exc:
        print(json.dumps({"event": "recorrido_cloudflare_worker_failure", "error_code": "renderer_failed", "exception_type": type(exc).__name__}), file=sys.stderr, flush=True)
        return _settle_failure(
            client, job_id, reservation_id, "renderer_failed", environment,
            worker_id, lease_token, lease_version,
        )

    try:
        output_sha256 = hashlib.sha256(output.read_bytes()).hexdigest()
        output_key = f"accounts/{account_id}/jobs/{job_id}/leases/{lease_token}/output.mp4"
        payload = {
            "reservation_id": reservation_id,
            "account_id": account_id,
            "output_object_key": output_key,
            "output_sha256": output_sha256,
            "duration_seconds": duration,
            "environment": environment,
            "worker_id": worker_id,
            "lease_token": lease_token,
            "lease_version": lease_version,
        }
        journal = _write_settlement_journal(job_dir, job_id, output, payload)
        return _resume_settlement_journal(client, journal)
    except (OSError, RuntimeError, urllib.error.URLError):
        return "settlement_pending"


def load_protected_env(path: Path) -> dict[str, str]:
    path = Path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_mode & 0o077:
        raise RuntimeError("protected env file must exist with mode 600")
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def _require_trusted_renderer(path: Path) -> None:
    try:
        resolved = path.resolve(strict=True)
        repo = REPO.resolve(strict=True)
        metadata = path.lstat()
    except OSError as exc:
        raise RuntimeError("trusted renderer path missing") from exc
    if path.is_symlink() or not path.is_file() or repo not in resolved.parents:
        raise RuntimeError("trusted renderer path required")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
        raise RuntimeError("trusted renderer permissions required")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--env-file", type=Path, default=Path.home() / ".config/recorrido/cloudflare-generation.env")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        raise RuntimeError("local generation worker requires Darwin")
    _require_trusted_renderer(GENERATE)
    _require_trusted_renderer(ASSEMBLE)
    values = load_protected_env(args.env_file)
    base = values.get("WORKER_URL", "")
    token = values.get("LOCAL_WORKER_TOKEN", "")
    worker_id = values.get("WORKER_ID", "mac-render-01")
    if not base.startswith("https://") or not token or not SAFE_WORKER.fullmatch(worker_id):
        raise RuntimeError("invalid local worker configuration")
    state = Path.home() / ".hermes/runtime/recorrido-cloudflare-generation"
    _mkdir_private(state)
    lock = SingletonLock(state / "worker.lock")
    if not lock.acquire():
        print(json.dumps({"event": "recorrido_cloudflare_worker", "status": "already_running"}))
        return 0
    client = WorkerClient(base, token)
    try:
        while True:
            status = run_once(client, worker_id, state / "jobs")
            print(json.dumps({"event": "recorrido_cloudflare_worker", "status": status}), flush=True)
            if args.once:
                return 0 if status in ("idle", "completed") else 1
            time.sleep(max(5, args.interval))
    finally:
        lock.release()


if __name__ == "__main__":
    raise SystemExit(main())
