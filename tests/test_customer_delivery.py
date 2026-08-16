from __future__ import annotations

import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

SCRIPTS = Path(__file__).parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from billing import Billing
from customer_delivery import CustomerDeliveryService, DeliveryRefused
from outbound_delivery import ListingRegistry, OutboundLedger, OwnerDirectory

PHONE_A = "+1" + "555" + "000" + "1111"
PHONE_B = "+1" + "555" + "000" + "2222"
OWNER_A = "agent-a"
OWNER_B = "agent-b"
LISTING_A = "listing-a"
LISTING_B = "listing-b"


class FakeTransport:
    def __init__(self):
        self.media = []
        self.text = []
        self.fail_media = False
        self.fail_text_once = False

    def send_media(self, *, recipient_e164, media_path, caption):
        if self.fail_media:
            raise RuntimeError("media provider down")
        self.media.append((recipient_e164, Path(media_path).name, caption))
        return {"provider_message_id": f"media.{len(self.media)}"}

    def send_text(self, *, recipient_e164, message):
        if self.fail_text_once:
            self.fail_text_once = False
            raise RuntimeError("text provider down")
        self.text.append((recipient_e164, message))
        return {"provider_message_id": f"text.{len(self.text)}"}


def setup(tmp: str):
    root = Path(tmp)
    billing = Billing(root / "billing.db")
    billing.ensure_customer(PHONE_A, agent_id=OWNER_A, lang="es")
    billing.apply_subscription_event(e164=PHONE_A, status="active")
    billing.ensure_customer(PHONE_B, agent_id=OWNER_B, lang="pt")
    billing.apply_subscription_event(e164=PHONE_B, status="active")
    owners = OwnerDirectory({OWNER_A: PHONE_A, OWNER_B: PHONE_B})
    listings = ListingRegistry({LISTING_A: OWNER_A, LISTING_B: OWNER_B})
    ledger = OutboundLedger(
        store_path=root / "outbound.json",
        listings=listings,
        owners=owners,
    )
    transport = FakeTransport()
    service = CustomerDeliveryService(
        store_path=root / "customer-delivery.json",
        billing=billing,
        outbound=ledger,
        transport=transport,
    )
    media = root / "walkthrough.mp4"
    media.write_bytes(b"video")
    return billing, ledger, transport, service, media


def approve(ledger, consignment):
    ledger.approve(
        consignment.consignment_id,
        actor_e164=consignment.recipient_e164,
        token=consignment.approval_token,
    )


def test_delivery_binds_reservation_listing_owner_media_and_notice() -> None:
    with TemporaryDirectory() as tmp:
        billing, ledger, transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="9:16", listing_key=LISTING_A)
        consignment = service.prepare(
            generation_id=generation,
            owner_id=OWNER_A,
            listing_id=LISTING_A,
            output_format="9:16",
            media_path=media,
            caption="Tu recorrido está listo.",
            lang="es",
        )
        approve(ledger, consignment)

        receipt = service.complete(consignment.consignment_id)

        assert transport.media == [(PHONE_A, "walkthrough.mp4", "Tu recorrido está listo.")]
        assert transport.text == [(PHONE_A, "Te quedan 3 generaciones disponibles este mes.")]
        assert receipt.media_delivered is True
        assert receipt.billing_settled is True
        assert receipt.notice_sent is True
        assert billing.generation(generation).state == "delivered"


def test_reservation_customer_and_listing_must_match_bound_recipient() -> None:
    with TemporaryDirectory() as tmp:
        billing, _ledger, _transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="9:16", listing_key=LISTING_A)
        with pytest.raises(DeliveryRefused, match="customer"):
            service.prepare(
                generation_id=generation,
                owner_id=OWNER_B,
                listing_id=LISTING_B,
                output_format="9:16",
                media_path=media,
            )
        with pytest.raises(DeliveryRefused, match="listing"):
            service.prepare(
                generation_id=generation,
                owner_id=OWNER_A,
                listing_id=LISTING_B,
                output_format="9:16",
                media_path=media,
            )


def test_format_must_match_reserved_generation() -> None:
    with TemporaryDirectory() as tmp:
        billing, _ledger, _transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="16:9", listing_key=LISTING_A)
        with pytest.raises(DeliveryRefused, match="format"):
            service.prepare(
                generation_id=generation,
                owner_id=OWNER_A,
                listing_id=LISTING_A,
                output_format="9:16",
                media_path=media,
            )


def test_notice_retry_never_resends_delivered_video() -> None:
    with TemporaryDirectory() as tmp:
        billing, ledger, transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="9:16", listing_key=LISTING_A)
        consignment = service.prepare(
            generation_id=generation,
            owner_id=OWNER_A,
            listing_id=LISTING_A,
            output_format="9:16",
            media_path=media,
            lang="es",
        )
        approve(ledger, consignment)
        transport.fail_text_once = True

        with pytest.raises(RuntimeError, match="text provider"):
            service.complete(consignment.consignment_id)
        assert len(transport.media) == 1
        assert billing.generation(generation).state == "delivered"

        receipt = service.complete(consignment.consignment_id)
        assert len(transport.media) == 1
        assert len(transport.text) == 1
        assert receipt.notice_sent is True


def test_media_failure_does_not_settle_or_send_balance_notice() -> None:
    with TemporaryDirectory() as tmp:
        billing, ledger, transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="9:16", listing_key=LISTING_A)
        consignment = service.prepare(
            generation_id=generation,
            owner_id=OWNER_A,
            listing_id=LISTING_A,
            output_format="9:16",
            media_path=media,
        )
        approve(ledger, consignment)
        transport.fail_media = True

        with pytest.raises(RuntimeError, match="media provider"):
            service.complete(consignment.consignment_id)
        assert billing.generation(generation).state == "reserved"
        assert transport.text == []
        assert ledger.get(consignment.consignment_id).status == "approved"


def test_both_formats_consume_two_and_notice_reports_two_remaining() -> None:
    with TemporaryDirectory() as tmp:
        billing, ledger, transport, service, media = setup(tmp)
        reservations = billing.reserve_formats(
            PHONE_A,
            output_formats=("9:16", "16:9"),
            listing_key=LISTING_A,
        )
        for output_format, generation in reservations.items():
            path = Path(tmp) / f"{output_format.replace(':', 'x')}.mp4"
            path.write_bytes(output_format.encode())
            consignment = service.prepare(
                generation_id=generation,
                owner_id=OWNER_A,
                listing_id=LISTING_A,
                output_format=output_format,
                media_path=path,
                lang="es",
            )
            approve(ledger, consignment)
            service.complete(consignment.consignment_id)

        assert len(transport.media) == 2
        assert transport.text[-1] == (PHONE_A, "Te quedan 2 generaciones disponibles este mes.")
        assert billing.account(PHONE_A).remaining == 2


def test_service_state_survives_restart_without_resending_media() -> None:
    with TemporaryDirectory() as tmp:
        billing, ledger, transport, service, media = setup(tmp)
        generation = billing.reserve(PHONE_A, output_format="9:16", listing_key=LISTING_A)
        consignment = service.prepare(
            generation_id=generation,
            owner_id=OWNER_A,
            listing_id=LISTING_A,
            output_format="9:16",
            media_path=media,
            lang="es",
        )
        approve(ledger, consignment)
        service.complete(consignment.consignment_id)

        restarted = CustomerDeliveryService(
            store_path=Path(tmp) / "customer-delivery.json",
            billing=billing,
            outbound=ledger,
            transport=transport,
        )
        receipt = restarted.complete(consignment.consignment_id)
        assert len(transport.media) == 1
        assert len(transport.text) == 1
        assert receipt.notice_sent is True
