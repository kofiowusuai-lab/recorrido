#!/usr/bin/env python3
"""Recipient-bound Recorrido customer delivery worker.

Only claims server-bound recipients, verifies the local WhatsApp sender, and uses
private journals to prevent duplicate sends across crashes and authority outages.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)
SAFE_WORKER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._~-]{1,512}$")
SAFE_PROVIDER_ID = re.compile(r"^[A-Za-z0-9._:@/-]{1,255}$")
E164 = re.compile(r"^\+[1-9][0-9]{7,14}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_MEDIA_BYTES = 64 * 1024 * 1024


class ContractError(ValueError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


class SingletonLock:
    def __init__(self, path: Path):
        self.path = path
        self.handle: Any | None = None

    def acquire(self) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        handle = os.fdopen(fd, "r+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            return False
        handle.seek(0); handle.truncate(); handle.write(str(os.getpid())); handle.flush()
        self.handle = handle
        return True

    def release(self) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close(); self.handle = None


def _private_dir(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise RuntimeError("unsafe_runtime_directory")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    _private_dir(path.parent)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{time.monotonic_ns()}.tmp")
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path); os.chmod(path, 0o600)
    finally:
        try: temporary.unlink()
        except FileNotFoundError: pass


def _json_file(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise RuntimeError("unsafe_delivery_journal")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict): raise RuntimeError("invalid_delivery_journal")
    return value


class ControlPlaneClient:
    def __init__(self, base_url: str, token: str, timeout: int = 120):
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ContractError("invalid_control_plane_url")
        if not SAFE_TOKEN.fullmatch(token): raise ContractError("invalid_control_plane_token")
        self.base = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", ""))
        self.origin = (parsed.scheme, parsed.hostname.lower(), parsed.port or 443)
        self.token = token; self.timeout = timeout
        self.opener = urllib.request.build_opener(NoRedirect())

    def _request(self, method: str, path: str, payload: dict[str, Any] | None = None, *, binary: bool = False, maximum: int = 1_000_000) -> Any:
        body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
        headers = {"authorization": f"Bearer {self.token}", "user-agent": "RecorridoCustomerDeliveryWorker/1.0"}
        if body is not None: headers.update({"content-type": "application/json", "content-length": str(len(body))})
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                final = urllib.parse.urlsplit(response.geturl())
                if (final.scheme, (final.hostname or "").lower(), final.port or 443) != self.origin:
                    raise RuntimeError("cross_origin_response")
                data = response.read(maximum + 1)
                if len(data) > maximum: raise RuntimeError("response_too_large")
                response_headers = dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            exc.read(4096); raise RuntimeError(f"control_plane_http_{exc.code}") from None
        except urllib.error.URLError as exc:
            raise RuntimeError("control_plane_unavailable") from exc
        if binary: return data, response_headers
        if not data: return None
        try: value = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc: raise RuntimeError("invalid_control_plane_response") from exc
        return value

    def claim(self, worker_id: str) -> dict[str, Any] | None:
        value = self._request("POST", "/v1/deliveries/next", {"worker_id": worker_id})
        return value if isinstance(value, dict) else None

    @staticmethod
    def fence(claim: dict[str, Any], worker_id: str) -> dict[str, Any]:
        return {"environment": claim["environment"], "worker_id": worker_id,
                "claim_token": claim["claim_token"], "attempt": claim["attempt"]}

    def heartbeat(self, claim: dict[str, Any], worker_id: str) -> None:
        self._request("POST", f"/v1/deliveries/{claim['delivery_id']}/heartbeat", self.fence(claim, worker_id))

    def checkpoint(self, claim: dict[str, Any], worker_id: str) -> None:
        self._request("POST", f"/v1/deliveries/{claim['delivery_id']}/checkpoint", {**self.fence(claim, worker_id), "phase": claim["phase"]})

    def accept(self, claim: dict[str, Any], worker_id: str, provider_id: str) -> None:
        endpoint = "media-accepted" if claim["phase"] == "media" else "notice-accepted"
        self._request("POST", f"/v1/deliveries/{claim['delivery_id']}/{endpoint}", {**self.fence(claim, worker_id), "provider_message_id": provider_id})

    def abandon(self, claim: dict[str, Any], worker_id: str, error_code: str) -> None:
        self._request("POST", f"/v1/deliveries/{claim['delivery_id']}/abandon", {**self.fence(claim, worker_id), "error_code": error_code})

    def download_media(self, claim: dict[str, Any], worker_id: str, destination: Path) -> None:
        query = urllib.parse.urlencode(self.fence(claim, worker_id))
        data, headers = self._request("GET", f"/v1/deliveries/{claim['delivery_id']}/media?{query}", binary=True, maximum=MAX_MEDIA_BYTES)
        digest = hashlib.sha256(data).hexdigest()
        expected = claim["output_sha256"]
        header_digest = headers.get("x-content-sha256") or headers.get("X-Content-Sha256")
        if digest != expected or header_digest != expected: raise ContractError("delivery_media_digest_mismatch")
        _private_dir(destination.parent)
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data); handle.flush(); os.fsync(handle.fileno())


class WhatsAppBridge:
    def __init__(self, base_url: str = "http://127.0.0.1:3000", timeout: int = 900):
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"} or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ContractError("bridge_must_be_loopback")
        self.base = base_url.rstrip("/"); self.timeout = timeout
        self.opener = urllib.request.build_opener(NoRedirect())

    def _json(self, method: str, path: str, payload: dict[str, Any] | None = None, timeout: int | None = None) -> dict[str, Any]:
        body = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.base + path, data=body, method=method,
            headers={"content-type": "application/json"} if body is not None else {})
        try:
            with self.opener.open(request, timeout=timeout or self.timeout) as response:
                value = json.loads(response.read(1_000_001))
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
            raise RuntimeError("bridge_unavailable") from exc
        if not isinstance(value, dict): raise RuntimeError("invalid_bridge_response")
        return value

    def health(self, expected_hash: str) -> None:
        value = self._json("GET", "/health", timeout=10)
        if value.get("status") != "connected": raise RuntimeError("bridge_not_connected")
        if value.get("accountIdentityHash") != expected_hash: raise RuntimeError("sender_identity_mismatch")

    @staticmethod
    def chat_id(e164: str) -> str:
        if not E164.fullmatch(e164): raise ContractError("invalid_recipient")
        return e164[1:] + "@s.whatsapp.net"

    def _send(self, path: str, payload: dict[str, Any]) -> str:
        value = self._json("POST", path, payload)
        provider_id = value.get("messageId")
        if value.get("success") is not True or not isinstance(provider_id, str) or not SAFE_PROVIDER_ID.fullmatch(provider_id):
            raise RuntimeError("bridge_send_unconfirmed")
        return provider_id

    def send_media(self, e164: str, path: Path) -> str:
        return self._send("/send-media", {"chatId": self.chat_id(e164), "filePath": str(path.resolve()), "mediaType": "video", "caption": "Tu recorrido está listo."})

    def send_notice(self, e164: str, notice: str) -> str:
        if not notice or len(notice) > 500: raise ContractError("invalid_notice")
        return self._send("/send", {"chatId": self.chat_id(e164), "message": notice})


def _validate_claim(claim: dict[str, Any], worker_id: str) -> None:
    if claim.get("phase") not in {"media", "notice"} or not UUID.fullmatch(str(claim.get("delivery_id", ""))): raise ContractError("invalid_claim")
    if not UUID.fullmatch(str(claim.get("claim_token", ""))) or not isinstance(claim.get("attempt"), int) or claim["attempt"] < 1: raise ContractError("invalid_claim")
    if claim.get("environment") not in {"staging", "production"} or not E164.fullmatch(str(claim.get("recipient_phone_e164", ""))): raise ContractError("invalid_claim")
    if not SHA256.fullmatch(str(claim.get("expected_sender_identity_hash", ""))): raise ContractError("invalid_claim")
    if claim["phase"] == "media" and not SHA256.fullmatch(str(claim.get("output_sha256", ""))): raise ContractError("invalid_claim")
    if claim["phase"] == "notice" and not isinstance(claim.get("notice_text"), str): raise ContractError("invalid_claim")
    if not SAFE_WORKER.fullmatch(worker_id): raise ContractError("invalid_worker_id")


def _journal_path(root: Path, claim: dict[str, Any]) -> Path:
    return root / "journals" / f"{claim['delivery_id']}-{claim['phase']}-{claim['attempt']}.json"


def _resume_ack(client: ControlPlaneClient, journal: Path, worker_id: str) -> str:
    saved = _json_file(journal)
    if saved.get("version") != 1 or saved.get("state") not in {"sending", "provider_accepted"}: raise RuntimeError("invalid_delivery_journal")
    claim = saved.get("claim")
    if not isinstance(claim, dict): raise RuntimeError("invalid_delivery_journal")
    _validate_claim(claim, worker_id)
    provider_id = saved.get("provider_message_id")
    if saved["state"] == "sending" or not isinstance(provider_id, str): return "ambiguous"
    client.accept(claim, worker_id, provider_id)
    journal.unlink()
    media = saved.get("media_path")
    if isinstance(media, str):
        try: Path(media).unlink()
        except FileNotFoundError: pass
    return "accepted"


def run_once(client: ControlPlaneClient, bridge: WhatsAppBridge, worker_id: str, root: Path) -> str:
    _private_dir(root); _private_dir(root / "journals"); _private_dir(root / "media")
    journals = sorted((root / "journals").glob("*.json"))
    if journals: return _resume_ack(client, journals[0], worker_id)
    claim = client.claim(worker_id)
    if not claim: return "idle"
    _validate_claim(claim, worker_id)
    journal = _journal_path(root, claim)
    media_path: Path | None = None
    try:
        bridge.health(claim["expected_sender_identity_hash"])
        client.heartbeat(claim, worker_id)
        if claim["phase"] == "media":
            media_path = root / "media" / f"{claim['delivery_id']}-{claim['attempt']}.mp4"
            client.download_media(claim, worker_id, media_path)
        _atomic_json(journal, {"version": 1, "state": "ready", "claim": claim, "media_path": str(media_path) if media_path else None})
        client.checkpoint(claim, worker_id)
        _atomic_json(journal, {"version": 1, "state": "sending", "claim": claim, "media_path": str(media_path) if media_path else None})
        if claim["phase"] == "media":
            assert media_path is not None
            provider_id = bridge.send_media(claim["recipient_phone_e164"], media_path)
        else:
            provider_id = bridge.send_notice(claim["recipient_phone_e164"], claim["notice_text"])
        _atomic_json(journal, {"version": 1, "state": "provider_accepted", "claim": claim, "media_path": str(media_path) if media_path else None, "provider_message_id": provider_id})
        client.accept(claim, worker_id, provider_id)
        journal.unlink()
        if media_path: media_path.unlink(missing_ok=True)
        return "delivered"
    except (ContractError, RuntimeError, OSError):
        if journal.exists():
            state = _json_file(journal).get("state")
            if state in {"sending", "provider_accepted"}: return "settlement_pending" if state == "provider_accepted" else "ambiguous"
            journal.unlink(missing_ok=True)
        if media_path: media_path.unlink(missing_ok=True)
        try: client.abandon(claim, worker_id, "pre_send_unavailable")
        except RuntimeError: return "abandon_pending"
        return "retryable"


def load_env_file(path: Path) -> dict[str, str]:
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise RuntimeError("unsafe_env_file")
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"): continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key): raise RuntimeError("invalid_env_file")
        values[key] = value
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, default=Path.home()/".config/recorrido/cloudflare-generation.env")
    parser.add_argument("--root", type=Path, default=Path.home()/".hermes/runtime/recorrido-customer-delivery")
    parser.add_argument("--once", action="store_true"); args = parser.parse_args()
    values = load_env_file(args.env_file)
    base_url = values.get("WORKER_URL") or values.get("CLOUDFLARE_GENERATION_CONTROL_URL", "")
    token = values.get("LOCAL_WORKER_TOKEN") or values.get("CLOUDFLARE_GENERATION_LOCAL_TOKEN", "")
    worker_id = values.get("RECORRIDO_DELIVERY_WORKER_ID") or values.get("WORKER_ID", "mac-delivery-01")
    bridge_url = values.get("RECORRIDO_WHATSAPP_BRIDGE_URL", "http://127.0.0.1:3000")
    lock = SingletonLock(args.root/"worker.lock")
    if not lock.acquire(): return 0
    client = ControlPlaneClient(base_url, token); bridge = WhatsAppBridge(bridge_url)
    try:
        while True:
            result = run_once(client, bridge, worker_id, args.root)
            print(json.dumps({"event": "customer_delivery_tick", "result": result}), flush=True)
            if args.once: return 0
            time.sleep(5 if result != "idle" else 15)
    finally: lock.release()


if __name__ == "__main__": raise SystemExit(main())
