from __future__ import annotations

import importlib.util
import sqlite3
import sys
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "billing.py"


def _load():
    spec = importlib.util.spec_from_file_location("billing", MODULE_PATH)
    m = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = m
    spec.loader.exec_module(m)
    return m


bl = _load()
PHONE = "+5511900000001"


class Clock:
    def __init__(self, t=1_786_000_000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, s):
        self.t += s


class FakeStripe:
    def __init__(self):
        self.calls = []

    def create_checkout_session(self, **kw):
        self.calls.append(kw)
        return {"url": "https://buy.stripe.com/test_123", "id": "cs_test_123"}


def _billing(tmp, clock=None, stripe=None):
    return bl.Billing(Path(tmp) / "billing.db", clock=clock or Clock(), stripe=stripe)


def _subscribed(b, phone=PHONE):
    b.ensure_customer(phone, lang="pt")
    return b.apply_subscription_event(e164=phone, status="active",
                                      stripe_customer="cus_1", stripe_sub="sub_1")


class Subscribing(unittest.TestCase):
    def test_a_new_agent_starts_with_nothing(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            a = b.ensure_customer(PHONE)
            self.assertFalse(a.active)
            self.assertEqual(a.remaining, 0)

    def test_activating_grants_the_plan_allowance(self):
        with TemporaryDirectory() as tmp:
            a = _subscribed(_billing(tmp))
            self.assertTrue(a.active)
            self.assertEqual(a.remaining, 4)

    def test_reactivating_does_not_grant_a_second_allowance(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            b.reserve(PHONE, output_format="9:16")
            again = b.apply_subscription_event(e164=PHONE, status="active")
            self.assertEqual(again.remaining, 3, "a duplicate webhook refilled the quota")

    def test_cancelling_stops_new_work_without_clawing_back(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            gen = b.reserve(PHONE, output_format="9:16")
            b.settle(gen, delivered=True)
            b.apply_subscription_event(e164=PHONE, status="canceled")
            with self.assertRaises(bl.NotSubscribed):
                b.reserve(PHONE, output_format="9:16")
            self.assertEqual(
                b._db.execute("select count(*) c from generations where state='delivered'"
                              ).fetchone()["c"], 1)


class Quota(unittest.TestCase):
    def test_the_plan_ceiling_is_enforced(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            for _ in range(4):
                b.reserve(PHONE, output_format="9:16")
            with self.assertRaises(bl.QuotaExhausted):
                b.reserve(PHONE, output_format="9:16")

    def test_an_unsubscribed_agent_cannot_generate(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            b.ensure_customer(PHONE)
            with self.assertRaises(bl.NotSubscribed):
                b.reserve(PHONE, output_format="9:16")

    def test_concurrent_requests_cannot_oversell(self):
        """Four listing links pasted at once must not deliver five videos."""
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "billing.db"
            seed = bl.Billing(path, clock=Clock(), stripe=None)
            _subscribed(seed)
            seed.close()

            granted, errors, lock, start = [], [], threading.Lock(), threading.Barrier(10)

            def worker():
                b = bl.Billing(path, clock=Clock())
                start.wait(timeout=10)
                try:
                    g = b.reserve(PHONE, output_format="9:16")
                    with lock:
                        granted.append(g)
                except bl.QuotaExhausted:
                    with lock:
                        errors.append(1)
                finally:
                    b.close()

            ts = [threading.Thread(target=worker) for _ in range(10)]
            for t in ts:
                t.start()
            for t in ts:
                t.join(timeout=20)
            self.assertEqual(len(granted), 4, f"oversold: {len(granted)} slots for a 4-video plan")
            self.assertEqual(len(errors), 6)


class FormatCredits(unittest.TestCase):
    def test_format_is_required_and_invalid_values_fail_closed(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            with self.assertRaises(TypeError):
                b.reserve(PHONE)
            with self.assertRaises(bl.BillingError):
                b.reserve(PHONE, output_format="square")
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_both_formats_are_two_atomic_generations(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            reservations = b.reserve_formats(
                PHONE,
                output_formats=("9:16", "16:9"),
                listing_key="valley-brook",
            )
            self.assertEqual(set(reservations), {"9:16", "16:9"})
            self.assertEqual(b.account(PHONE).remaining, 2)
            rows = b._db.execute(
                "select output_format, listing_key from generations order by output_format"
            ).fetchall()
            self.assertEqual(
                [(row["output_format"], row["listing_key"]) for row in rows],
                [("16:9", "valley-brook"), ("9:16", "valley-brook")],
            )

    def test_duplicate_formats_are_refused_without_spending(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            with self.assertRaises(bl.BillingError):
                b.reserve_formats(PHONE, output_formats=("9:16", "9:16"))
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_two_format_request_is_all_or_nothing_when_only_one_credit_remains(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            for _ in range(3):
                b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            with self.assertRaises(bl.QuotaExhausted):
                b.reserve_formats(PHONE, output_formats=("9:16", "16:9"))
            self.assertEqual(b.account(PHONE).remaining, 1)

    def test_each_failed_format_refunds_only_its_own_credit(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            reservations = b.reserve_formats(PHONE, output_formats=("9:16", "16:9"))
            b.settle(reservations["9:16"], delivered=True)
            b.settle(reservations["16:9"], delivered=False, detail="horizontal QA failed")
            self.assertEqual(b.account(PHONE).remaining, 3)

    def test_old_database_migrates_without_losing_generations(self):
        with TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "billing.db"
            conn = sqlite3.connect(db_path)
            conn.executescript(
                """
                create table generations (
                  id text primary key,
                  e164 text not null,
                  listing_key text,
                  state text not null default 'reserved',
                  created_at real not null,
                  settled_at real,
                  detail text
                );
                create index gen_by_customer on generations(e164, state);
                insert into generations(id, e164, listing_key, state, created_at)
                values ('old-generation', '+15550000000', 'old-listing', 'delivered', 1.0);
                """
            )
            conn.close()

            billing = bl.Billing(db_path, clock=Clock())
            row = billing._db.execute(
                "select output_format, state from generations where id='old-generation'"
            ).fetchone()
            self.assertEqual(
                (row["output_format"], row["state"]),
                ("legacy_unspecified", "delivered"),
            )


class SpendOnDeliveryNotOnRequest(unittest.TestCase):
    def test_a_failed_render_returns_the_slot(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            gen = b.reserve(PHONE, output_format="9:16")
            self.assertEqual(b.account(PHONE).remaining, 3)
            b.settle(gen, delivered=False, detail="grok refused")
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_a_delivered_video_is_paid_for(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            self.assertEqual(b.account(PHONE).remaining, 3)

    def test_settling_twice_is_a_no_op(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            gen = b.reserve(PHONE, output_format="9:16")
            b.settle(gen, delivered=False)
            b.settle(gen, delivered=False)
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_a_render_that_never_finishes_is_refunded(self):
        with TemporaryDirectory() as tmp:
            clock = Clock()
            b = _billing(tmp, clock)
            _subscribed(b)
            b.reserve(PHONE, output_format="9:16")
            self.assertEqual(b.account(PHONE).remaining, 3)
            clock.advance(7 * 3600)
            self.assertEqual(b.release_stale_reservations(), 1)
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_quota_never_goes_negative(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            gen = b.reserve(PHONE, output_format="9:16")
            b.settle(gen, delivered=False)
            b.settle(gen, delivered=False)
            self.assertGreaterEqual(b.account(PHONE).videos_used, 0)


class BillingPeriod(unittest.TestCase):
    def test_usage_resets_next_month(self):
        with TemporaryDirectory() as tmp:
            clock = Clock()
            b = _billing(tmp, clock)
            _subscribed(b)
            for _ in range(4):
                b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            self.assertEqual(b.account(PHONE).remaining, 0)
            clock.advance(bl.MONTH + 60)
            self.assertEqual(b.account(PHONE).remaining, 4)

    def test_a_cancelled_account_does_not_get_a_fresh_month(self):
        with TemporaryDirectory() as tmp:
            clock = Clock()
            b = _billing(tmp, clock)
            _subscribed(b)
            b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            b.apply_subscription_event(e164=PHONE, status="canceled")
            clock.advance(bl.MONTH + 60)
            self.assertFalse(b.account(PHONE).active)
            with self.assertRaises(bl.NotSubscribed):
                b.reserve(PHONE, output_format="9:16")


class Checkout(unittest.TestCase):
    def test_a_link_is_created_through_the_injected_client(self):
        with TemporaryDirectory() as tmp:
            fake = FakeStripe()
            b = _billing(tmp, stripe=fake)
            url = b.checkout_link(PHONE)
            self.assertTrue(url.startswith("https://buy.stripe.com/"))
            self.assertEqual(fake.calls[0]["e164"], PHONE)
            self.assertEqual(fake.calls[0]["price_usd"], 32)

    def test_without_a_client_it_refuses_rather_than_guesses(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(bl.BillingError):
                _billing(tmp).checkout_link(PHONE)

    def test_an_unknown_plan_is_refused(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(bl.BillingError):
                _billing(tmp, stripe=FakeStripe()).checkout_link(PHONE, plan="enterprise")


class QuotaSentence(unittest.TestCase):
    def test_portuguese_and_spanish_read_naturally(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            self.assertIn("4 vídeos", b.quota_sentence(PHONE, "pt"))
            self.assertIn("4 videos", b.quota_sentence(PHONE, "es"))
            for _ in range(3):
                b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            self.assertIn("1 vídeo ", b.quota_sentence(PHONE, "pt") + " ")
            self.assertIn("Te queda 1 video", b.quota_sentence(PHONE, "es"))

    def test_an_exhausted_month_says_so(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            _subscribed(b)
            for _ in range(4):
                b.settle(b.reserve(PHONE, output_format="9:16"), delivered=True)
            self.assertIn("Ya usaste", b.quota_sentence(PHONE, "es"))

    def test_an_inactive_account_is_told_plainly(self):
        with TemporaryDirectory() as tmp:
            b = _billing(tmp)
            b.ensure_customer(PHONE)
            self.assertIn("no está activa", b.quota_sentence(PHONE, "es"))


if __name__ == "__main__":
    unittest.main()
