#!/usr/bin/env python3
"""Recipient-bound customer delivery with post-delivery quota notices.

This module joins Recorrido's two fail-closed ledgers:

* ``Billing`` owns the customer, listing key, selected native format and credit.
* ``OutboundLedger`` owns the approved media digest and server-bound recipient.

A video is sent only when those identities agree. Provider acceptance is recorded
before billing settlement. The remaining-generation notice is then sent to the
same server-derived recipient and is retried independently, so a notice outage
never causes the delivered video to be sent twice.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Protocol

from billing import Billing, BillingError
from outbound_delivery import (
    APPROVED,
    DELIVERED,
    Consignment,
    DeliveryRefused,
    OutboundLedger,
    deliver,
)


class CustomerTransport(Protocol):
    def send_media(self, *, recipient_e164: str, media_path: str, caption: str) -> dict: ...

    def send_text(self, *, recipient_e164: str, message: str) -> dict: ...


@dataclass
class DeliveryReceipt:
    consignment_id: str
    generation_id: str
    owner_id: str
    listing_id: str
    output_format: str
    recipient_e164: str
    lang: str
    media_delivered: bool = False
    media_provider_message_id: str | None = None
    billing_settled: bool = False
    notice_sent: bool = False
    notice_provider_message_id: str | None = None
    notice_text: str | None = None
    last_error: str | None = None

    @classmethod
    def from_json(cls, raw: dict) -> "DeliveryReceipt":
        return cls(**raw)


class CustomerDeliveryService:
    """Coordinate one safe customer delivery through durable, retryable phases."""

    def __init__(
        self,
        *,
        store_path: Path | str,
        billing: Billing,
        outbound: OutboundLedger,
        transport: CustomerTransport,
    ):
        self._path = Path(store_path)
        self._billing = billing
        self._outbound = outbound
        self._transport = transport
        self._lock = threading.RLock()
        self._receipts: dict[str, DeliveryReceipt] = {}
        self._load()

    def _load(self) -> None:
        if not self._path.exists():
            return
        raw = json.loads(self._path.read_text())
        self._receipts = {
            key: DeliveryReceipt.from_json(value)
            for key, value in raw.get("receipts", {}).items()
        }

    def _flush(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "receipts": {
                key: asdict(value) for key, value in sorted(self._receipts.items())
            }
        }
        fd, temporary = tempfile.mkstemp(dir=str(self._path.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
            os.replace(temporary, self._path)
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise

    def get(self, consignment_id: str) -> DeliveryReceipt:
        try:
            return self._receipts[consignment_id]
        except KeyError:
            raise DeliveryRefused(
                f"unknown customer delivery {consignment_id!r}"
            ) from None

    def prepare(
        self,
        *,
        generation_id: str,
        owner_id: str,
        listing_id: str,
        output_format: str,
        media_path: Path | str,
        caption: str = "",
        lang: str = "es",
    ) -> Consignment:
        """Draft a delivery only after all customer identities agree."""
        if lang not in {"es", "pt"}:
            raise DeliveryRefused(f"unsupported customer language {lang!r}")
        try:
            generation = self._billing.generation(generation_id)
        except BillingError as exc:
            raise DeliveryRefused(str(exc)) from exc
        if generation.state != "reserved":
            raise DeliveryRefused(
                f"generation {generation_id} is {generation.state}, not reserved"
            )
        expected_recipient = self._outbound._owners.recipient_for(owner_id)  # noqa: SLF001
        if expected_recipient != generation.e164:
            raise DeliveryRefused(
                "reservation customer does not match the owner-bound recipient"
            )
        if generation.listing_key != listing_id:
            raise DeliveryRefused(
                f"generation listing {generation.listing_key!r} does not match {listing_id!r}"
            )
        if generation.output_format != output_format:
            raise DeliveryRefused(
                f"generation format {generation.output_format!r} does not match {output_format!r}"
            )

        with self._lock:
            if any(
                receipt.generation_id == generation_id
                for receipt in self._receipts.values()
            ):
                raise DeliveryRefused(
                    f"generation {generation_id} already has a customer delivery"
                )
            consignment = self._outbound.draft(
                job_id=generation_id,
                owner_id=owner_id,
                listing_id=listing_id,
                media_path=media_path,
                caption=caption,
            )
            if consignment.recipient_e164 != generation.e164:
                # The draft has not been approved or sent. Leave an evidence row
                # rather than deleting history, but reject the unsafe join.
                raise DeliveryRefused(
                    "reservation customer does not match the owner-bound recipient"
                )
            self._receipts[consignment.consignment_id] = DeliveryReceipt(
                consignment_id=consignment.consignment_id,
                generation_id=generation_id,
                owner_id=owner_id,
                listing_id=listing_id,
                output_format=output_format,
                recipient_e164=generation.e164,
                lang=lang,
            )
            self._flush()
            return consignment

    @staticmethod
    def remaining_notice(remaining: int, lang: str) -> str:
        if lang == "pt":
            if remaining == 0:
                return "Você não tem gerações disponíveis neste mês."
            noun = "geração disponível" if remaining == 1 else "gerações disponíveis"
            return f"Você tem {remaining} {noun} neste mês."
        if remaining == 0:
            return "No te quedan generaciones disponibles este mes."
        noun = "generación disponible" if remaining == 1 else "generaciones disponibles"
        return f"Te queda{'n' if remaining != 1 else ''} {remaining} {noun} este mes."

    def _assert_identity(self, receipt: DeliveryReceipt, row: Consignment) -> None:
        generation = self._billing.generation(receipt.generation_id)
        expected = self._outbound._owners.recipient_for(receipt.owner_id)  # noqa: SLF001
        if expected != receipt.recipient_e164 or row.recipient_e164 != expected:
            raise DeliveryRefused("customer recipient identity changed; refusing delivery")
        if generation.e164 != expected:
            raise DeliveryRefused("billing customer no longer matches delivery recipient")
        if generation.listing_key != receipt.listing_id:
            raise DeliveryRefused("billing listing no longer matches delivery listing")
        if generation.output_format != receipt.output_format:
            raise DeliveryRefused("billing format no longer matches delivery format")

    def complete(self, consignment_id: str) -> DeliveryReceipt:
        """Send media, settle one credit, then send a retryable balance notice."""
        with self._lock:
            receipt = self.get(consignment_id)
            row = self._outbound.get(consignment_id)
            self._assert_identity(receipt, row)

            if row.status == APPROVED:
                try:
                    row = deliver(
                        self._outbound.claim(consignment_id),
                        transport=lambda **payload: self._transport.send_media(**payload),
                        ledger=self._outbound,
                    )
                except Exception as exc:
                    receipt.last_error = f"media: {type(exc).__name__}: {exc}"
                    self._flush()
                    raise
            elif row.status != DELIVERED:
                raise DeliveryRefused(
                    f"{consignment_id}: delivery is not approved (status={row.status})"
                )

            receipt.media_delivered = True
            receipt.media_provider_message_id = row.provider_message_id
            receipt.last_error = None
            self._flush()

            generation = self._billing.generation(receipt.generation_id)
            if generation.state == "reserved":
                self._billing.settle(
                    receipt.generation_id,
                    delivered=True,
                    detail=f"consignment={consignment_id}|provider={row.provider_message_id or ''}",
                )
            elif generation.state != "delivered":
                raise DeliveryRefused(
                    f"generation {receipt.generation_id} is {generation.state}; refusing notice"
                )
            receipt.billing_settled = True
            self._flush()

            if not receipt.notice_sent:
                remaining = self._billing.account(receipt.recipient_e164).remaining
                notice = self.remaining_notice(remaining, receipt.lang)
                try:
                    result = self._transport.send_text(
                        recipient_e164=receipt.recipient_e164,
                        message=notice,
                    )
                except Exception as exc:
                    receipt.notice_text = notice
                    receipt.last_error = f"notice: {type(exc).__name__}: {exc}"
                    self._flush()
                    raise
                receipt.notice_sent = True
                receipt.notice_text = notice
                receipt.notice_provider_message_id = str(
                    result.get("provider_message_id", "")
                )
                receipt.last_error = None
                self._flush()

            return receipt
