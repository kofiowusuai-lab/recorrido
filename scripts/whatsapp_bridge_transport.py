#!/usr/bin/env python3
"""Loopback-only, account-bound adapter for the Hermes WhatsApp bridge."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

from outbound_delivery import DeliveryRefused, validate_e164


JsonRequester = Callable[[str, str, dict | None, float], dict]


def _request_json(method: str, url: str, payload: dict | None, timeout: float) -> dict:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"Content-Type": "application/json"} if body is not None else {},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            decoded = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise DeliveryRefused(f"WhatsApp bridge request failed: {exc}") from exc
    if not isinstance(decoded, dict):
        raise DeliveryRefused("WhatsApp bridge returned a non-object response")
    return decoded


class WhatsAppBridgeTransport:
    """Send through one verified local bridge account, never an arbitrary URL."""

    def __init__(
        self,
        *,
        base_url: str,
        expected_account_identity_hash: str,
        timeout: float = 900,
        requester: JsonRequester = _request_json,
    ):
        parsed = urlparse(base_url)
        if parsed.scheme != "http" or parsed.hostname not in {
            "127.0.0.1",
            "localhost",
            "::1",
        }:
            raise DeliveryRefused("WhatsApp bridge URL must be loopback HTTP")
        if not expected_account_identity_hash:
            raise DeliveryRefused("expected WhatsApp account identity hash is required")
        self._base = base_url.rstrip("/")
        self._expected_hash = expected_account_identity_hash
        self._timeout = timeout
        self._requester = requester

    @staticmethod
    def _chat_id(e164: str) -> str:
        return f"{validate_e164(e164).removeprefix('+')}@s.whatsapp.net"

    def health(self) -> dict:
        health = self._requester("GET", f"{self._base}/health", None, 10)
        if health.get("status") != "connected":
            raise DeliveryRefused(
                f"WhatsApp bridge is not connected (status={health.get('status')!r})"
            )
        actual_hash = health.get("accountIdentityHash")
        if actual_hash != self._expected_hash:
            raise DeliveryRefused(
                "WhatsApp bridge account identity does not match the configured Recorrido sender"
            )
        return health

    def _send(self, endpoint: str, payload: dict) -> dict:
        self.health()
        result = self._requester(
            "POST", f"{self._base}{endpoint}", payload, self._timeout
        )
        if result.get("success") is not True or not result.get("messageId"):
            raise DeliveryRefused(
                f"WhatsApp bridge did not confirm delivery: {result.get('error', 'missing messageId')}"
            )
        return {"provider_message_id": str(result["messageId"])}

    def send_media(self, *, recipient_e164: str, media_path: str, caption: str) -> dict:
        media = Path(media_path)
        if not media.is_file():
            raise DeliveryRefused(f"delivery media is missing: {media}")
        return self._send(
            "/send-media",
            {
                "chatId": self._chat_id(recipient_e164),
                "filePath": str(media.resolve()),
                "mediaType": "video",
                "caption": caption,
            },
        )

    def send_text(self, *, recipient_e164: str, message: str) -> dict:
        if not message.strip():
            raise DeliveryRefused("refusing to send an empty customer notice")
        return self._send(
            "/send",
            {"chatId": self._chat_id(recipient_e164), "message": message},
        )
