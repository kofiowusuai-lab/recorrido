from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

MODULE = Path(__file__).parents[1] / "local/delivery_worker.py"


def load_module():
    spec = importlib.util.spec_from_file_location("recorrido_delivery_worker", MODULE)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def claim(phase="media"):
    value = {
        "delivery_id": "66666666-6666-4666-8666-666666666666",
        "phase": phase,
        "attempt": 1,
        "claim_token": "55555555-5555-4555-8555-555555555555",
        "environment": "staging",
        "recipient_phone_e164": "+12025550123",
        "expected_sender_identity_hash": "a" * 64,
        "output_sha256": hashlib.sha256(b"video").hexdigest(),
        "notice_text": "Te quedan 3 generaciones disponibles este mes.",
    }
    return value


class FakeClient:
    def __init__(self, value):
        self.value = value
        self.events = []
        self.accept_error = False
        self.claims = 0

    def claim(self, worker_id):
        self.claims += 1; self.events.append(("claim", worker_id)); return self.value

    def heartbeat(self, value, worker_id): self.events.append(("heartbeat", worker_id))

    def download_media(self, value, worker_id, destination):
        self.events.append(("download", value["recipient_phone_e164"]))
        destination.write_bytes(b"video")

    def checkpoint(self, value, worker_id): self.events.append(("checkpoint", value["phase"]))

    def accept(self, value, worker_id, provider_id):
        self.events.append(("accept", value["phase"], provider_id))
        if self.accept_error: raise RuntimeError("authority_unavailable")

    def abandon(self, value, worker_id, error_code): self.events.append(("abandon", error_code))


class FakeBridge:
    def __init__(self):
        self.events = []
        self.health_error = False
        self.send_error = False

    def health(self, expected_hash):
        self.events.append(("health", expected_hash))
        if self.health_error: raise RuntimeError("sender_identity_mismatch")

    def send_media(self, recipient, path):
        self.events.append(("media", recipient, path.read_bytes()))
        if self.send_error: raise RuntimeError("bridge_send_unconfirmed")
        return "media.123"

    def send_notice(self, recipient, notice):
        self.events.append(("notice", recipient, notice))
        if self.send_error: raise RuntimeError("bridge_send_unconfirmed")
        return "notice.123"


def test_bridge_rejects_every_non_loopback_destination():
    m = load_module()
    for url in ["https://127.0.0.1:3000", "http://example.com:3000", "http://user@localhost:3000"]:
        with pytest.raises(m.ContractError): m.WhatsAppBridge(url)


def test_media_delivery_uses_only_claimed_recipient_and_checkpoints_before_send():
    m = load_module(); client = FakeClient(claim()); bridge = FakeBridge()
    with TemporaryDirectory() as temp:
        assert m.run_once(client, bridge, "mac-delivery-01", Path(temp)) == "delivered"
        assert list(Path(temp).rglob("*.json")) == []
    assert client.events == [
        ("claim", "mac-delivery-01"), ("heartbeat", "mac-delivery-01"),
        ("download", "+12025550123"), ("checkpoint", "media"),
        ("accept", "media", "media.123"),
    ]
    assert bridge.events[1] == ("media", "+12025550123", b"video")


def test_sender_mismatch_abandons_before_checkpoint_or_provider_call():
    m = load_module(); client = FakeClient(claim()); bridge = FakeBridge(); bridge.health_error = True
    with TemporaryDirectory() as temp:
        assert m.run_once(client, bridge, "mac-delivery-01", Path(temp)) == "retryable"
    assert ("abandon", "pre_send_unavailable") in client.events
    assert not any(row[0] == "checkpoint" for row in client.events)
    assert not any(row[0] == "media" for row in bridge.events)


def test_provider_acceptance_is_journaled_and_ack_retries_without_resend():
    m = load_module(); client = FakeClient(claim()); bridge = FakeBridge(); client.accept_error = True
    with TemporaryDirectory() as temp:
        root = Path(temp)
        assert m.run_once(client, bridge, "mac-delivery-01", root) == "settlement_pending"
        journal = next(root.rglob("*.json"))
        saved = json.loads(journal.read_text())
        assert saved["state"] == "provider_accepted" and saved["provider_message_id"] == "media.123"
        client.accept_error = False
        assert m.run_once(client, bridge, "mac-delivery-01", root) == "accepted"
        assert list(root.rglob("*.json")) == []
    assert sum(row[0] == "media" for row in bridge.events) == 1
    assert client.claims == 1


def test_unknown_send_outcome_becomes_ambiguous_and_never_auto_resends():
    m = load_module(); client = FakeClient(claim()); bridge = FakeBridge(); bridge.send_error = True
    with TemporaryDirectory() as temp:
        root = Path(temp)
        assert m.run_once(client, bridge, "mac-delivery-01", root) == "ambiguous"
        assert m.run_once(client, bridge, "mac-delivery-01", root) == "ambiguous"
    assert sum(row[0] == "media" for row in bridge.events) == 1
    assert client.claims == 1
    assert not any(row[0] == "abandon" for row in client.events)


def test_notice_phase_never_downloads_or_resends_media():
    m = load_module(); client = FakeClient(claim("notice")); bridge = FakeBridge()
    with TemporaryDirectory() as temp:
        assert m.run_once(client, bridge, "mac-delivery-01", Path(temp)) == "delivered"
    assert not any(row[0] == "download" for row in client.events)
    assert not any(row[0] == "media" for row in bridge.events)
    assert bridge.events[1] == ("notice", "+12025550123", "Te quedan 3 generaciones disponibles este mes.")
    assert ("accept", "notice", "notice.123") in client.events
