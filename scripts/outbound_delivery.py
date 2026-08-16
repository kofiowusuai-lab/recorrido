#!/usr/bin/env python3
"""Fail-closed outbound delivery for Recorrido.

Implements section 10 of the billing-and-approval design: no customer-facing
code path calls the WhatsApp send API directly. Every outbound payload is a
row in this ledger, and the row — not the caller, not the chat session, not
ambient thread state — is the only place a recipient number comes from.

The invariant this module exists to hold:

    a rendered recorrido reaches the agent who requested it, and no one else.

That is enforced structurally rather than by convention:

* ``draft`` resolves the recipient from the owner directory. Callers pass an
  ``owner_id``; they cannot name a phone number, so they cannot name the wrong
  one. The listing is checked against the same owner, so an agent can never be
  sent a video of a property another agent holds.
* ``deliver`` takes no recipient parameter at all. It reads the number off the
  claimed row and re-verifies it against the directory immediately before the
  send, so a mutated in-memory object cannot redirect a payload.
* The media digest is recorded at draft time and re-checked at send time. A
  file swapped between approval and delivery — the shape a cross-tenant leak
  would actually take on a shared worker — is refused.

Every refusal raises :class:`DeliveryRefused`. There is no path that silently
downgrades to "send anyway": unknown state fails closed.

The store is a JSON file so the ledger survives the killed-window problem that
already bites long renders. The interface mirrors the Postgres RPCs in the
plan (``recorrido_create_outbound_draft``, ``recorrido_apply_owner_action``,
``recorrido_claim_approved_outbound``, …) so moving to
``SELECT … FOR UPDATE SKIP LOCKED`` later is a store swap, not a rewrite.
"""

from __future__ import annotations

import hashlib
import json
import re
import os
import secrets
import tempfile
import threading
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable, Iterable


PENDING = "pending"
APPROVED = "approved"
CLAIMED = "claimed"
DELIVERED = "delivered"
REJECTED = "rejected"

TERMINAL = frozenset({DELIVERED, REJECTED})


class DeliveryRefused(Exception):
    """Raised whenever an outbound payload cannot be proven safe to send."""


# ---------------------------------------------------------------------------
# Identity sources
# ---------------------------------------------------------------------------


_E164 = re.compile(r"^\+[1-9]\d{7,14}$")


def validate_e164(number: str, *, owner_id: str = "?") -> str:
    """Reject a number before it can become a confidently-wrong delivery.

    The ledger binds a recipient and then refuses to let anything change it.
    That is the right shape, but it means a bad number in the directory is
    delivered to a stranger with total confidence — the guard cannot tell a
    typo from an intention. So the directory is where numbers get checked.

    The Argentina rule is not a nicety. Argentine mobiles carry a ``9`` after
    the country code and 87% of the harvested values omit it, so ``+54 11…``
    is a landline that either fails to resolve or resolves to someone else
    entirely. Shipping those means messaging strangers about a stranger's
    property.
    """
    n = (number or "").strip().replace(" ", "").replace("-", "")
    if not _E164.match(n):
        raise DeliveryRefused(f"owner {owner_id!r}: {number!r} is not valid E.164")
    if n.startswith("+54") and not n.startswith("+549"):
        raise DeliveryRefused(
            f"owner {owner_id!r}: {n} is an Argentine number missing the mobile '9' "
            f"(expected +549…). It will not resolve on WhatsApp — normalise before sending."
        )
    if n.startswith("+52") and not n.startswith("+521") and len(n) > 12:
        raise DeliveryRefused(f"owner {owner_id!r}: {n} looks like a Mexican mobile missing the '1'")
    return n


class OwnerDirectory:
    """Maps an owner id to the one number we are allowed to message.

    Deliberately the *only* source of recipient numbers. Nothing else in the
    delivery path accepts a phone number as an argument.
    """

    def __init__(self, mapping: dict[str, str], *, validate: bool = True):
        self._by_owner = {
            owner: (validate_e164(num, owner_id=owner) if validate else num)
            for owner, num in mapping.items()
        }

    def recipient_for(self, owner_id: str) -> str:
        try:
            return self._by_owner[owner_id]
        except KeyError:
            raise DeliveryRefused(f"unknown owner {owner_id!r}: refusing to guess a recipient") from None

    def owns_number(self, owner_id: str, e164: str) -> bool:
        return self._by_owner.get(owner_id) == e164


class ListingRegistry:
    """Maps a listing id to the owner who holds it."""

    def __init__(self, mapping: dict[str, str]):
        self._owner_of = dict(mapping)

    def assert_held_by(self, listing_id: str, owner_id: str) -> None:
        holder = self._owner_of.get(listing_id)
        if holder is None:
            raise DeliveryRefused(f"unknown listing {listing_id!r}")
        if holder != owner_id:
            raise DeliveryRefused(
                f"owner {owner_id!r} does not hold listing {listing_id!r} (held by {holder!r})"
            )


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------


@dataclass
class Consignment:
    consignment_id: str
    job_id: str
    owner_id: str
    recipient_e164: str
    listing_id: str
    media_path: str
    media_sha256: str
    caption: str
    version: int
    status: str
    approval_token: str | None
    created_at: float
    updated_at: float
    provider_message_id: str | None = None
    last_error: str | None = None

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, raw: dict) -> "Consignment":
        return cls(**raw)


@dataclass
class Claim:
    """A short-lived right to send exactly one consignment, once."""

    consignment: Consignment
    claim_token: str
    claimed_at: float


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------


class OutboundLedger:
    def __init__(
        self,
        *,
        store_path: Path | str,
        listings: ListingRegistry,
        owners: OwnerDirectory,
        clock: Callable[[], float] = time.time,
    ):
        self._path = Path(store_path)
        self._listings = listings
        self._owners = owners
        self._clock = clock
        self._lock = threading.RLock()
        self._rows: dict[str, Consignment] = {}
        self._claims: dict[str, str] = {}
        self._load()

    # -- persistence -------------------------------------------------------

    def _load(self) -> None:
        if not self._path.exists():
            return
        raw = json.loads(self._path.read_text())
        self._rows = {k: Consignment.from_json(v) for k, v in raw.get("consignments", {}).items()}
        # Claims are process-local by design: a crashed worker's claim must not
        # outlive it, or a payload could be stranded unsendable forever.
        for row in self._rows.values():
            if row.status == CLAIMED:
                row.status = APPROVED

    def _flush(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"consignments": {k: v.to_json() for k, v in self._rows.items()}}
        fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(payload, fh, indent=2, sort_keys=True)
            os.replace(tmp, self._path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise

    # -- helpers -----------------------------------------------------------

    @staticmethod
    def _digest(path: Path) -> str:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    def _require(self, consignment_id: str) -> Consignment:
        row = self._rows.get(consignment_id)
        if row is None:
            raise DeliveryRefused(f"unknown consignment {consignment_id!r}")
        return row

    # -- public API --------------------------------------------------------

    def get(self, consignment_id: str) -> Consignment:
        with self._lock:
            return self._require(consignment_id)

    def draft(
        self,
        *,
        job_id: str,
        owner_id: str,
        listing_id: str,
        media_path: Path | str,
        caption: str = "",
    ) -> Consignment:
        """Create a pending outbound row with the recipient bound server-side."""
        media = Path(media_path)
        if not media.is_file():
            raise DeliveryRefused(f"media {media}: not a file")

        # Ownership is proven before a recipient is ever resolved.
        self._listings.assert_held_by(listing_id, owner_id)
        recipient = self._owners.recipient_for(owner_id)

        now = self._clock()
        with self._lock:
            row = Consignment(
                consignment_id=f"csg_{secrets.token_hex(8)}",
                job_id=job_id,
                owner_id=owner_id,
                recipient_e164=recipient,
                listing_id=listing_id,
                media_path=str(media),
                media_sha256=self._digest(media),
                caption=caption,
                version=1,
                status=PENDING,
                approval_token=secrets.token_urlsafe(24),
                created_at=now,
                updated_at=now,
            )
            self._rows[row.consignment_id] = row
            self._flush()
            return row

    def approve(self, consignment_id: str, *, actor_e164: str, token: str) -> Consignment:
        with self._lock:
            row = self._require(consignment_id)
            if row.status in TERMINAL:
                raise DeliveryRefused(f"{consignment_id}: {row.status} is terminal")
            if row.status != PENDING:
                raise DeliveryRefused(f"{consignment_id}: not pending (status={row.status})")
            if not self._owners.owns_number(row.owner_id, actor_e164):
                raise DeliveryRefused(
                    f"{consignment_id}: {actor_e164} is not the bound owner — refusing approval"
                )
            if row.approval_token is None or not secrets.compare_digest(row.approval_token, token):
                raise DeliveryRefused(f"{consignment_id}: approval token invalid or already spent")
            row.status = APPROVED
            row.approval_token = None  # single use
            row.updated_at = self._clock()
            self._flush()
            return row

    def reject(self, consignment_id: str, *, actor_e164: str, token: str) -> Consignment:
        with self._lock:
            row = self._require(consignment_id)
            if row.status in TERMINAL:
                raise DeliveryRefused(f"{consignment_id}: {row.status} is terminal")
            if not self._owners.owns_number(row.owner_id, actor_e164):
                raise DeliveryRefused(f"{consignment_id}: {actor_e164} is not the bound owner")
            if row.approval_token is None or not secrets.compare_digest(row.approval_token, token):
                raise DeliveryRefused(f"{consignment_id}: token invalid or already spent")
            row.status = REJECTED
            row.approval_token = None
            row.updated_at = self._clock()
            self._flush()
            return row

    def edit(
        self,
        consignment_id: str,
        *,
        media_path: Path | str | None = None,
        caption: str | None = None,
    ) -> Consignment:
        """Revise a consignment. Bumps version and invalidates any approval."""
        with self._lock:
            row = self._require(consignment_id)
            if row.status in TERMINAL:
                raise DeliveryRefused(f"{consignment_id}: {row.status} is terminal")
            if media_path is not None:
                media = Path(media_path)
                if not media.is_file():
                    raise DeliveryRefused(f"media {media}: not a file")
                row.media_path = str(media)
                row.media_sha256 = self._digest(media)
            if caption is not None:
                row.caption = caption
            row.version += 1
            row.status = PENDING
            row.approval_token = secrets.token_urlsafe(24)
            row.updated_at = self._clock()
            self._flush()
            return row

    def claim(self, consignment_id: str) -> Claim:
        """Take the exclusive right to send this row. The analog of
        ``SELECT … FOR UPDATE SKIP LOCKED`` in the Postgres design."""
        with self._lock:
            row = self._require(consignment_id)
            if row.status != APPROVED:
                raise DeliveryRefused(
                    f"{consignment_id}: only an approved row is claimable (status={row.status})"
                )
            token = secrets.token_urlsafe(16)
            row.status = CLAIMED
            row.updated_at = self._clock()
            self._claims[row.consignment_id] = token
            self._flush()
            # Hand out a copy: a mutated claim must not corrupt ledger state.
            return Claim(
                consignment=Consignment.from_json(row.to_json()),
                claim_token=token,
                claimed_at=self._clock(),
            )

    def _validate_claim(self, claim: Claim) -> Consignment:
        row = self._require(claim.consignment.consignment_id)
        held = self._claims.get(row.consignment_id)
        if held is None or not secrets.compare_digest(held, claim.claim_token):
            raise DeliveryRefused(f"{row.consignment_id}: claim is not current")
        if row.status != CLAIMED:
            raise DeliveryRefused(f"{row.consignment_id}: not in claimed state (status={row.status})")
        if claim.consignment.version != row.version:
            raise DeliveryRefused(f"{row.consignment_id}: claim is for version {claim.consignment.version}, ledger is at {row.version}")
        return row

    def mark_delivered(self, claim: Claim, *, provider_message_id: str) -> Consignment:
        with self._lock:
            row = self._validate_claim(claim)
            row.status = DELIVERED
            row.provider_message_id = provider_message_id
            row.updated_at = self._clock()
            self._claims.pop(row.consignment_id, None)
            self._flush()
            return row

    def mark_failed(self, claim: Claim, *, error: str) -> Consignment:
        """Release a claim so the payload can be retried. Never terminal."""
        with self._lock:
            row = self._validate_claim(claim)
            row.status = APPROVED
            row.last_error = error
            row.updated_at = self._clock()
            self._claims.pop(row.consignment_id, None)
            self._flush()
            return row

    def pending_review(self) -> list[Consignment]:
        with self._lock:
            return [r for r in self._rows.values() if r.status == PENDING]

    def ready_to_send(self) -> list[Consignment]:
        with self._lock:
            return [r for r in self._rows.values() if r.status == APPROVED]


# ---------------------------------------------------------------------------
# The one send path
# ---------------------------------------------------------------------------


def deliver(claim: Claim, *, transport: Callable[..., dict], ledger: OutboundLedger) -> Consignment:
    """Send one claimed consignment.

    Note the signature: there is no recipient parameter. The number is read off
    the ledger row under lock and re-verified against the owner directory here,
    at the last possible moment, so neither a caller nor a mutated in-memory
    object can redirect the payload.
    """
    with ledger._lock:  # noqa: SLF001 — deliberate: validation and send must not interleave
        row = ledger._validate_claim(claim)  # noqa: SLF001

        # Re-derive the recipient from the directory rather than trusting the row.
        expected = ledger._owners.recipient_for(row.owner_id)  # noqa: SLF001
        if row.recipient_e164 != expected:
            raise DeliveryRefused(
                f"{row.consignment_id}: stored recipient does not match the owner directory — refusing"
            )
        if claim.consignment.recipient_e164 != expected:
            raise DeliveryRefused(
                f"{row.consignment_id}: claim recipient was altered after claiming — refusing"
            )

        # Ownership of the listing must still hold.
        ledger._listings.assert_held_by(row.listing_id, row.owner_id)  # noqa: SLF001

        # The bytes must be the bytes that were approved.
        media = Path(row.media_path)
        if not media.is_file():
            raise DeliveryRefused(f"{row.consignment_id}: media {media} is missing")
        actual = ledger._digest(media)  # noqa: SLF001
        if actual != row.media_sha256:
            raise DeliveryRefused(
                f"{row.consignment_id}: media digest changed since approval "
                f"(approved {row.media_sha256[:12]}…, found {actual[:12]}…) — refusing"
            )

        try:
            result = transport(
                recipient_e164=expected,
                media_path=row.media_path,
                caption=row.caption,
            )
        except Exception as exc:
            ledger.mark_failed(claim, error=f"{type(exc).__name__}: {exc}")
            raise

        return ledger.mark_delivered(
            claim, provider_message_id=str(result.get("provider_message_id", ""))
        )


def owner_directory_from_rows(rows: Iterable[dict], *, id_key: str = "agent_id", phone_key: str = "whatsapp_e164") -> OwnerDirectory:
    """Build a directory from lead-table rows, rejecting duplicate numbers.

    Two owners sharing a number is the precise data condition that would let one
    agent receive another's recorrido, so it is refused at construction.
    """
    mapping: dict[str, str] = {}
    seen: dict[str, str] = {}
    for row in rows:
        owner, phone = row.get(id_key), row.get(phone_key)
        if not owner or not phone:
            continue
        phone = validate_e164(phone, owner_id=owner)
        if phone in seen and seen[phone] != owner:
            raise DeliveryRefused(
                f"number {phone} is claimed by both {seen[phone]!r} and {owner!r} — refusing to build a directory"
            )
        seen[phone] = owner
        mapping[owner] = phone
    return OwnerDirectory(mapping)
