from __future__ import annotations

import importlib.util
import sys
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "outbound_delivery.py"


def _load():
    spec = importlib.util.spec_from_file_location("outbound_delivery", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolve __module__ through sys.modules; register before exec.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


od = _load()


AGENT_A = "agent-adriana"
AGENT_B = "agent-carmina"
PHONE_A = "+573001112222"
PHONE_B = "+573004445555"


class RecordingTransport:
    """Stands in for the WhatsApp send API and records exactly what it was handed."""

    def __init__(self):
        self.sent = []

    def __call__(self, *, recipient_e164, media_path, caption):
        self.sent.append({"recipient_e164": recipient_e164, "media_path": media_path, "caption": caption})
        return {"provider_message_id": f"wamid.{len(self.sent)}"}


def _ledger(tmp):
    root = Path(tmp)
    registry = od.ListingRegistry({
        "listing-a1": AGENT_A,
        "listing-a2": AGENT_A,
        "listing-b1": AGENT_B,
    })
    owners = od.OwnerDirectory({AGENT_A: PHONE_A, AGENT_B: PHONE_B})
    return od.OutboundLedger(store_path=root / "outbound.json", listings=registry, owners=owners)


def _media(tmp, name="recorrido.mp4", body=b"video-bytes"):
    p = Path(tmp) / name
    p.write_bytes(body)
    return p


class DraftBinding(unittest.TestCase):
    def test_draft_binds_recipient_from_the_owner_directory_not_the_caller(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            self.assertEqual(c.recipient_e164, PHONE_A)
            self.assertEqual(c.status, "pending")
            self.assertEqual(c.version, 1)

    def test_draft_refuses_a_listing_the_owner_does_not_hold(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            with self.assertRaises(od.DeliveryRefused) as ctx:
                led.draft(job_id="job-x", owner_id=AGENT_A, listing_id="listing-b1", media_path=_media(tmp))
            self.assertIn("does not hold", str(ctx.exception))

    def test_draft_refuses_an_unknown_owner(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            with self.assertRaises(od.DeliveryRefused):
                led.draft(job_id="job-x", owner_id="agent-ghost", listing_id="listing-a1", media_path=_media(tmp))

    def test_draft_records_the_media_digest(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            self.assertEqual(len(c.media_sha256), 64)


class ApprovalInvariants(unittest.TestCase):
    def test_pending_is_not_claimable(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            with self.assertRaises(od.DeliveryRefused):
                led.claim(c.consignment_id)

    def test_only_the_bound_owner_can_approve(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            with self.assertRaises(od.DeliveryRefused):
                led.approve(c.consignment_id, actor_e164=PHONE_B, token=c.approval_token)
            approved = led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            self.assertEqual(approved.status, "approved")

    def test_approval_token_is_single_use(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            with self.assertRaises(od.DeliveryRefused):
                led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)

    def test_edit_bumps_version_and_invalidates_the_prior_approval(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            edited = led.edit(c.consignment_id, media_path=_media(tmp, "v2.mp4", b"new-bytes"), caption="v2")
            self.assertEqual(edited.version, 2)
            self.assertEqual(edited.status, "pending")
            with self.assertRaises(od.DeliveryRefused):
                led.claim(c.consignment_id)

    def test_rejection_is_terminal(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.reject(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            with self.assertRaises(od.DeliveryRefused):
                led.approve(c.consignment_id, actor_e164=PHONE_A, token=led.get(c.consignment_id).approval_token)
            with self.assertRaises(od.DeliveryRefused):
                led.claim(c.consignment_id)


class CrossClientIsolation(unittest.TestCase):
    """The invariant the whole module exists for."""

    def test_two_live_jobs_deliver_to_their_own_recipients(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            transport = RecordingTransport()

            a = led.draft(job_id="job-a", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp, "a.mp4", b"aaa"))
            b = led.draft(job_id="job-b", owner_id=AGENT_B, listing_id="listing-b1", media_path=_media(tmp, "b.mp4", b"bbb"))
            led.approve(a.consignment_id, actor_e164=PHONE_A, token=a.approval_token)
            led.approve(b.consignment_id, actor_e164=PHONE_B, token=b.approval_token)

            od.deliver(led.claim(b.consignment_id), transport=transport, ledger=led)
            od.deliver(led.claim(a.consignment_id), transport=transport, ledger=led)

            self.assertEqual([s["recipient_e164"] for s in transport.sent], [PHONE_B, PHONE_A])
            self.assertEqual([Path(s["media_path"]).name for s in transport.sent], ["b.mp4", "a.mp4"])

    def test_deliver_takes_no_recipient_argument(self):
        """A caller must not be able to name the recipient — it comes off the claim."""
        import inspect

        params = set(inspect.signature(od.deliver).parameters)
        self.assertNotIn("recipient", params)
        self.assertNotIn("recipient_e164", params)
        self.assertNotIn("to", params)

    def test_tampered_recipient_on_the_claim_is_refused_at_send(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            transport = RecordingTransport()
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            claim = led.claim(c.consignment_id)
            object.__setattr__(claim.consignment, "recipient_e164", PHONE_B)
            with self.assertRaises(od.DeliveryRefused):
                od.deliver(claim, transport=transport, ledger=led)
            self.assertEqual(transport.sent, [])

    def test_media_swapped_after_approval_is_refused(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            transport = RecordingTransport()
            media = _media(tmp, "a.mp4", b"original")
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=media)
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            claim = led.claim(c.consignment_id)
            media.write_bytes(b"someone-elses-listing")
            with self.assertRaises(od.DeliveryRefused) as ctx:
                od.deliver(claim, transport=transport, ledger=led)
            self.assertIn("digest", str(ctx.exception).lower())
            self.assertEqual(transport.sent, [])


class ClaimSemantics(unittest.TestCase):
    def test_a_consignment_is_claimable_once(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            led.claim(c.consignment_id)
            with self.assertRaises(od.DeliveryRefused):
                led.claim(c.consignment_id)

    def test_concurrent_claims_yield_exactly_one_winner(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)

            wins, start = [], threading.Barrier(8)

            def race():
                start.wait(timeout=5)
                try:
                    wins.append(led.claim(c.consignment_id))
                except od.DeliveryRefused:
                    pass

            threads = [threading.Thread(target=race) for _ in range(8)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=5)
            self.assertEqual(len(wins), 1)

    def test_delivery_is_recorded_and_the_row_becomes_terminal(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            transport = RecordingTransport()
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            od.deliver(led.claim(c.consignment_id), transport=transport, ledger=led)
            row = led.get(c.consignment_id)
            self.assertEqual(row.status, "delivered")
            self.assertEqual(row.provider_message_id, "wamid.1")

    def test_transport_failure_releases_the_claim_for_retry(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)

            def boom(**kwargs):
                raise RuntimeError("network down")

            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)
            with self.assertRaises(RuntimeError):
                od.deliver(led.claim(c.consignment_id), transport=boom, ledger=led)
            self.assertEqual(led.get(c.consignment_id).status, "approved")
            transport = RecordingTransport()
            od.deliver(led.claim(c.consignment_id), transport=transport, ledger=led)
            self.assertEqual(transport.sent[0]["recipient_e164"], PHONE_A)


class Durability(unittest.TestCase):
    def test_state_survives_a_process_restart(self):
        with TemporaryDirectory() as tmp:
            led = _ledger(tmp)
            c = led.draft(job_id="job-1", owner_id=AGENT_A, listing_id="listing-a1", media_path=_media(tmp))
            led.approve(c.consignment_id, actor_e164=PHONE_A, token=c.approval_token)

            reloaded = _ledger(tmp)
            row = reloaded.get(c.consignment_id)
            self.assertEqual(row.status, "approved")
            self.assertEqual(row.recipient_e164, PHONE_A)


if __name__ == "__main__":
    unittest.main()


class RecipientValidation(unittest.TestCase):
    """A bound-but-wrong number is delivered to a stranger with full confidence."""

    def test_argentine_mobile_missing_the_nine_is_refused(self):
        with self.assertRaises(od.DeliveryRefused) as ctx:
            od.validate_e164("+541155551234", owner_id="agent-x")
        self.assertIn("missing the mobile", str(ctx.exception))
        self.assertEqual(od.validate_e164("+5491155551234"), "+5491155551234")

    def test_malformed_numbers_are_refused(self):
        for bad in ("", "1155551234", "+54", "not-a-number", "+0123456789"):
            with self.assertRaises(od.DeliveryRefused):
                od.validate_e164(bad)

    def test_directory_refuses_to_build_on_bad_numbers(self):
        with self.assertRaises(od.DeliveryRefused):
            od.OwnerDirectory({"agent-x": "+541155551234"})

    def test_directory_refuses_two_owners_sharing_a_number(self):
        rows = [
            {"agent_id": "a", "whatsapp_e164": "+573001112222"},
            {"agent_id": "b", "whatsapp_e164": "+573001112222"},
        ]
        with self.assertRaises(od.DeliveryRefused):
            od.owner_directory_from_rows(rows)

    def test_whitespace_and_dashes_are_normalised(self):
        self.assertEqual(od.validate_e164("+57 300 111-2222"), "+573001112222")
