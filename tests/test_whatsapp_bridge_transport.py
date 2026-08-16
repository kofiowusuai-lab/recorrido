from __future__ import annotations

import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

SCRIPTS = Path(__file__).parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from outbound_delivery import DeliveryRefused
from whatsapp_bridge_transport import WhatsAppBridgeTransport

PHONE = "+1" + "555" + "000" + "1111"
ACCOUNT_HASH = "a" * 64


class FakeRequester:
    def __init__(self, account_hash=ACCOUNT_HASH):
        self.account_hash = account_hash
        self.calls = []

    def __call__(self, method, url, payload, timeout):
        self.calls.append((method, url, payload, timeout))
        if url.endswith("/health"):
            return {"status": "connected", "accountIdentityHash": self.account_hash}
        return {"success": True, "messageId": f"wamid.{len(self.calls)}"}


def transport(requester):
    return WhatsAppBridgeTransport(
        base_url="http://127.0.0.1:3000",
        expected_account_identity_hash=ACCOUNT_HASH,
        requester=requester,
    )


def test_media_uses_bound_chat_id_and_absolute_file() -> None:
    with TemporaryDirectory() as tmp:
        media = Path(tmp) / "video.mp4"
        media.write_bytes(b"video")
        requester = FakeRequester()
        result = transport(requester).send_media(
            recipient_e164=PHONE,
            media_path=str(media),
            caption="ready",
        )
        method, url, payload, _timeout = requester.calls[-1]
        assert (method, url) == ("POST", "http://127.0.0.1:3000/send-media")
        assert payload["chatId"] == "15550001111@s.whatsapp.net"
        assert payload["filePath"] == str(media.resolve())
        assert payload["mediaType"] == "video"
        assert result["provider_message_id"].startswith("wamid.")


def test_notice_uses_the_same_e164_conversion() -> None:
    requester = FakeRequester()
    transport(requester).send_text(recipient_e164=PHONE, message="3 remaining")
    assert requester.calls[-1][2] == {
        "chatId": "15550001111@s.whatsapp.net",
        "message": "3 remaining",
    }


def test_wrong_linked_whatsapp_account_fails_before_send() -> None:
    requester = FakeRequester(account_hash="b" * 64)
    with pytest.raises(DeliveryRefused, match="account identity"):
        transport(requester).send_text(recipient_e164=PHONE, message="hello")
    assert [call[1] for call in requester.calls] == ["http://127.0.0.1:3000/health"]


def test_non_loopback_bridge_is_refused() -> None:
    with pytest.raises(DeliveryRefused, match="loopback"):
        WhatsAppBridgeTransport(
            base_url="https://example.com",
            expected_account_identity_hash=ACCOUNT_HASH,
        )


def test_bridge_must_return_provider_message_id() -> None:
    def requester(method, url, payload, timeout):
        if url.endswith("/health"):
            return {"status": "connected", "accountIdentityHash": ACCOUNT_HASH}
        return {"success": True}

    with pytest.raises(DeliveryRefused, match="messageId"):
        transport(requester).send_text(recipient_e164=PHONE, message="hello")
