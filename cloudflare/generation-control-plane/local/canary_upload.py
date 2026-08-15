#!/usr/bin/env python3
"""Upload a canary fixture to private R2 and prepare its authoritative generation job."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import mimetypes
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def request(opener: Any, base: str, method: str, path: str, token: str, payload: bytes | None = None,
            content_type: str = "application/json", max_bytes: int = 2_000_000) -> tuple[int, bytes]:
    headers = {
        "authorization": f"Bearer {token}",
        "accept": "application/json",
        "user-agent": "RecorridoCanaryUploader/1.0",
    }
    if payload is not None:
        headers.update({"content-type": content_type, "content-length": str(len(payload))})
    req = urllib.request.Request(base.rstrip("/") + path, data=payload, headers=headers, method=method)
    try:
        with opener.open(req, timeout=120) as response:
            body = response.read(max_bytes + 1)
            if len(body) > max_bytes:
                raise RuntimeError("response_too_large")
            return response.status, body
    except urllib.error.HTTPError as exc:
        body = exc.read(max_bytes + 1)
        return exc.code, body


def content_type(path: Path) -> str:
    if path.suffix.lower() == ".mp4":
        return "video/mp4"
    if path.suffix.lower() == ".json":
        return "application/json"
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def upload_fixture(root: Path, account_id: str, member_id: str, idempotency_key: str,
                   base: str, ingress_token: str, local_token: str) -> dict[str, Any]:
    builder = load_module("canary_builder", HERE / "build_canary_fixture.py")
    job, manifest_path = builder.build(root, account_id, idempotency_key)
    manifest = json.loads(manifest_path.read_text())
    opener = urllib.request.build_opener(NoRedirect())
    uploaded = 0
    replayed = 0
    for row in manifest["files"]:
        path = job / row["relative_path"]
        payload = path.read_bytes()
        query = urllib.parse.urlencode({"key": row["key"]})
        status, _ = request(opener, base, "PUT", f"/v1/objects/input?{query}", ingress_token, payload, content_type(path))
        if status == 201:
            uploaded += 1
        elif status == 409:
            read_status, existing = request(opener, base, "GET", f"/v1/objects/input?{query}", local_token, max_bytes=25_000_000)
            if read_status != 200 or sha256_bytes(existing) != row["sha256"]:
                raise RuntimeError("immutable_asset_conflict")
            replayed += 1
        else:
            raise RuntimeError(f"asset_upload_{status}")

    manifest_payload = manifest_path.read_bytes()
    manifest_key = f"accounts/{account_id}/jobs/{idempotency_key}/manifest.json"
    manifest_query = urllib.parse.urlencode({"key": manifest_key})
    status, _ = request(opener, base, "PUT", f"/v1/objects/input?{manifest_query}", ingress_token, manifest_payload, "application/json")
    if status == 201:
        uploaded += 1
    elif status == 409:
        read_status, existing = request(opener, base, "GET", f"/v1/objects/input?{manifest_query}", local_token)
        if read_status != 200 or sha256_bytes(existing) != sha256_bytes(manifest_payload):
            raise RuntimeError("immutable_manifest_conflict")
        replayed += 1
    else:
        raise RuntimeError(f"manifest_upload_{status}")

    body = json.dumps({
        "account_id": account_id, "member_id": member_id, "idempotency_key": idempotency_key,
        "input_manifest_key": manifest_key,
    }, separators=(",", ":")).encode()
    status, response = request(opener, base, "POST", "/v1/jobs", ingress_token, body)
    if status not in (200, 202):
        raise RuntimeError(f"job_prepare_{status}")
    result = json.loads(response)
    return {
        "account_id": account_id, "member_id": member_id, "idempotency_key": idempotency_key,
        "uploaded": uploaded, "replayed": replayed, "job_id": result.get("job_id"),
        "status": result.get("status"), "dispatch_status": result.get("dispatch_status"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--member-id", required=True)
    parser.add_argument("--idempotency-key", required=True)
    args = parser.parse_args()
    worker = load_module("local_worker", HERE / "worker.py")
    values = worker.load_protected_env(args.env_file)
    result = upload_fixture(
        args.output, args.account_id, args.member_id, args.idempotency_key,
        values["WORKER_URL"], values["INGRESS_API_TOKEN"], values["LOCAL_WORKER_TOKEN"],
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
