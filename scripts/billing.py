#!/usr/bin/env python3
"""Subscriptions and generation quota for Recorrido.

Two things here are worth more care than the rest of the codebase, because both
failure modes are expensive in ways a bug report will not capture.

**Quota is spent on delivery, never on request.** If a generation fails, or a
worker dies mid-render, or a clip is rejected by QA, the customer must not have
paid for it. Decrementing when the job is accepted is the easy way to write it
and the reason a customer's second month starts with an argument.

**The decrement is atomic.** An agent who sends four listing links at once
produces four concurrent jobs. Read-then-write would let all four see "4
remaining" and deliver five videos on a four-video plan. Everything goes
through a single conditional UPDATE that cannot oversell.

Stripe is injected rather than imported at module scope, so the whole billing
path is testable offline and the live key stays in one process instead of being
copied onto every phone that sends messages.
"""

from __future__ import annotations

import os
import sqlite3
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator

MONTH = 30 * 86_400

PLANS = {
    "starter": {"price_usd": 32, "videos": 4, "label": "4 videos al mes"},
}
DEFAULT_PLAN = "starter"

ACTIVE_STATES = frozenset({"active", "trialing"})
OUTPUT_FORMATS = frozenset({"9:16", "16:9"})

SCHEMA = """
create table if not exists customers (
  e164            text primary key,
  agent_id        text,
  lang            text,
  plan            text not null default 'starter',
  status          text not null default 'none',
  stripe_customer text,
  stripe_sub      text,
  videos_total    integer not null default 0,
  videos_used     integer not null default 0,
  period_start    real,
  period_end      real,
  created_at      real not null,
  updated_at      real not null
);

create table if not exists generations (
  id            text primary key,
  e164          text not null,
  listing_key   text,
  output_format text not null,
  state         text not null default 'reserved',
  created_at    real not null,
  settled_at    real,
  detail        text
);
create index if not exists gen_by_customer on generations(e164, state);

create table if not exists billing_events (
  id         integer primary key autoincrement,
  e164       text,
  kind       text not null,
  detail     text,
  created_at real not null
);
"""


class BillingError(Exception):
    """Refusal to spend or grant something that would be wrong."""


class QuotaExhausted(BillingError):
    pass


class NotSubscribed(BillingError):
    pass


@dataclass
class Account:
    e164: str
    plan: str
    status: str
    videos_total: int
    videos_used: int
    period_end: float | None

    @property
    def remaining(self) -> int:
        return max(self.videos_total - self.videos_used, 0)

    @property
    def active(self) -> bool:
        return self.status in ACTIVE_STATES


@dataclass(frozen=True)
class Generation:
    id: str
    e164: str
    listing_key: str
    output_format: str
    state: str
    created_at: float
    settled_at: float | None
    detail: str


class Billing:
    def __init__(self, db_path: Path | str, *, clock: Callable[[], float] = time.time,
                 stripe=None):
        self.path = Path(db_path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock
        self._stripe = stripe
        self._db = sqlite3.connect(str(self.path), isolation_level=None, timeout=30)
        self._db.row_factory = sqlite3.Row
        self._db.execute("pragma journal_mode=WAL")
        self._db.execute("pragma busy_timeout=30000")
        self._db.executescript(SCHEMA)
        self._migrate_schema()

    def _migrate_schema(self) -> None:
        """Add the aspect-ratio identity to databases created before this rule."""
        columns = {
            row["name"] for row in self._db.execute("pragma table_info(generations)").fetchall()
        }
        if "output_format" not in columns:
            self._db.execute(
                "alter table generations add column output_format text not null "
                "default 'legacy_unspecified'"
            )

    def close(self) -> None:
        self._db.close()

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        self._db.execute("begin immediate")
        try:
            yield self._db
        except BaseException:
            self._db.execute("rollback")
            raise
        else:
            self._db.execute("commit")

    def _log(self, db, e164: str | None, kind: str, detail: str = "") -> None:
        db.execute("insert into billing_events(e164,kind,detail,created_at) values(?,?,?,?)",
                   (e164, kind, detail[:300], self._clock()))

    # -- accounts ----------------------------------------------------------

    def ensure_customer(self, e164: str, *, agent_id: str = "", lang: str = "es") -> Account:
        now = self._clock()
        with self._tx() as db:
            db.execute(
                "insert or ignore into customers(e164,agent_id,lang,created_at,updated_at) "
                "values(?,?,?,?,?)", (e164, agent_id, lang, now, now))
        return self.account(e164)

    def account(self, e164: str) -> Account:
        r = self._db.execute("select * from customers where e164=?", (e164,)).fetchone()
        if r is None:
            raise BillingError(f"no customer for {e164}")
        self._roll_period(e164)
        r = self._db.execute("select * from customers where e164=?", (e164,)).fetchone()
        return Account(r["e164"], r["plan"], r["status"], r["videos_total"],
                       r["videos_used"], r["period_end"])

    def _roll_period(self, e164: str) -> None:
        """Reset usage when a billing period has elapsed."""
        now = self._clock()
        with self._tx() as db:
            r = db.execute("select * from customers where e164=?", (e164,)).fetchone()
            if r is None or r["period_end"] is None:
                return
            if now < r["period_end"]:
                return
            if r["status"] not in ACTIVE_STATES:
                return
            periods = int((now - r["period_end"]) // MONTH) + 1
            db.execute(
                "update customers set videos_used=0, period_start=?, period_end=?, updated_at=? "
                "where e164=?",
                (r["period_end"], r["period_end"] + periods * MONTH, now, e164))
            self._log(db, e164, "period_rollover")

    # -- stripe ------------------------------------------------------------

    def checkout_link(self, e164: str, *, plan: str = DEFAULT_PLAN,
                      success_url: str = "https://recorrido.app/ok") -> str:
        """A payment link for one agent.

        Stripe is called through the injected client so the secret key lives in
        exactly one process. The phones never hold it and never need to.
        """
        if plan not in PLANS:
            raise BillingError(f"unknown plan {plan!r}")
        if self._stripe is None:
            raise BillingError("no Stripe client configured")
        self.ensure_customer(e164)
        session = self._stripe.create_checkout_session(
            e164=e164, plan=plan, price_usd=PLANS[plan]["price_usd"],
            success_url=success_url)
        url = session.get("url") if isinstance(session, dict) else getattr(session, "url", None)
        if not url:
            raise BillingError("Stripe returned no checkout url")
        with self._tx() as db:
            self._log(db, e164, "checkout_created", url)
        return url

    def apply_subscription_event(self, *, e164: str, status: str, plan: str = DEFAULT_PLAN,
                                 stripe_customer: str = "", stripe_sub: str = "") -> Account:
        """Apply a Stripe webhook.

        Activating grants the period's allowance. Cancelling stops future
        generations but never claws back videos already delivered.
        """
        if plan not in PLANS:
            raise BillingError(f"unknown plan {plan!r}")
        now = self._clock()
        self.ensure_customer(e164)
        with self._tx() as db:
            prior = db.execute("select status from customers where e164=?", (e164,)).fetchone()
            becoming_active = status in ACTIVE_STATES and prior["status"] not in ACTIVE_STATES
            if becoming_active:
                db.execute(
                    "update customers set status=?, plan=?, stripe_customer=?, stripe_sub=?,"
                    " videos_total=?, videos_used=0, period_start=?, period_end=?, updated_at=?"
                    " where e164=?",
                    (status, plan, stripe_customer, stripe_sub, PLANS[plan]["videos"],
                     now, now + MONTH, now, e164))
            else:
                db.execute(
                    "update customers set status=?, plan=?, stripe_customer=coalesce(nullif(?,''),"
                    " stripe_customer), stripe_sub=coalesce(nullif(?,''), stripe_sub),"
                    " updated_at=? where e164=?",
                    (status, plan, stripe_customer, stripe_sub, now, e164))
            self._log(db, e164, f"subscription_{status}", plan)
        return self.account(e164)

    # -- quota -------------------------------------------------------------

    def generation(self, generation_id: str) -> Generation:
        """Return the immutable delivery identity attached to a reservation."""
        row = self._db.execute(
            "select * from generations where id=?", (generation_id,)
        ).fetchone()
        if row is None:
            raise BillingError(f"unknown generation {generation_id}")
        return Generation(
            id=row["id"],
            e164=row["e164"],
            listing_key=row["listing_key"] or "",
            output_format=row["output_format"],
            state=row["state"],
            created_at=row["created_at"],
            settled_at=row["settled_at"],
            detail=row["detail"] or "",
        )

    @staticmethod
    def _validated_formats(output_formats: tuple[str, ...]) -> tuple[str, ...]:
        if not output_formats:
            raise BillingError("at least one output format is required")
        if len(set(output_formats)) != len(output_formats):
            raise BillingError("duplicate output formats would double-charge one deliverable")
        invalid = [value for value in output_formats if value not in OUTPUT_FORMATS]
        if invalid:
            raise BillingError(f"unsupported output format: {invalid[0]!r}")
        return output_formats

    def reserve(self, e164: str, *, output_format: str, listing_key: str = "") -> str:
        """Claim one explicitly identified aspect-ratio generation slot."""
        return self.reserve_formats(
            e164,
            output_formats=(output_format,),
            listing_key=listing_key,
        )[output_format]

    def reserve_formats(
        self,
        e164: str,
        *,
        output_formats: tuple[str, ...],
        listing_key: str = "",
    ) -> dict[str, str]:
        """Atomically reserve one credit for each requested output format.

        Reserving rather than spending is what makes a failed render free. The
        conditional UPDATE reserves the whole format set or none of it. A 9:16
        plus a 16:9 request therefore consumes two credits, never one bundle.
        """
        formats = self._validated_formats(tuple(output_formats))
        now = self._clock()
        acct = self.account(e164)
        if not acct.active:
            raise NotSubscribed(f"{e164} is {acct.status}, not an active subscriber")
        reservations = {
            output_format: f"gen_{uuid.uuid4().hex[:12]}" for output_format in formats
        }
        required = len(formats)
        with self._tx() as db:
            cur = db.execute(
                "update customers set videos_used = videos_used + ?, updated_at=? "
                "where e164=? and videos_used + ? <= videos_total",
                (required, now, e164, required),
            )
            if cur.rowcount == 0:
                raise QuotaExhausted(
                    f"{e164} lacks {required} generation credit{'s' if required != 1 else ''}; "
                    f"{acct.remaining} remaining"
                )
            for output_format, gen_id in reservations.items():
                db.execute(
                    "insert into generations(id,e164,listing_key,output_format,state,created_at) "
                    "values(?,?,?,?,'reserved',?)",
                    (gen_id, e164, listing_key, output_format, now),
                )
                self._log(db, e164, "reserved", f"{listing_key}|{output_format}")
        return reservations

    def settle(self, gen_id: str, *, delivered: bool, detail: str = "") -> None:
        """Close a reservation. A failure returns the slot to the customer."""
        now = self._clock()
        with self._tx() as db:
            r = db.execute("select * from generations where id=?", (gen_id,)).fetchone()
            if r is None:
                raise BillingError(f"unknown generation {gen_id}")
            if r["state"] != "reserved":
                return                      # idempotent: settling twice is a no-op
            state = "delivered" if delivered else "refunded"
            db.execute("update generations set state=?, settled_at=?, detail=? where id=?",
                       (state, now, detail[:300], gen_id))
            if not delivered:
                db.execute("update customers set videos_used = max(videos_used - 1, 0),"
                           " updated_at=? where e164=?", (now, r["e164"]))
            self._log(db, r["e164"], state, detail)

    def release_stale_reservations(self, older_than: float = 6 * 3600) -> int:
        """Return slots held by renders that never finished."""
        now = self._clock()
        cutoff = now - older_than
        with self._tx() as db:
            rows = db.execute("select id, e164 from generations where state='reserved' "
                              "and created_at < ?", (cutoff,)).fetchall()
            for r in rows:
                db.execute("update generations set state='refunded', settled_at=?, "
                           "detail='stale reservation' where id=?", (now, r["id"]))
                db.execute("update customers set videos_used = max(videos_used - 1, 0),"
                           " updated_at=? where e164=?", (now, r["e164"]))
                self._log(db, r["e164"], "refunded", "stale reservation")
            return len(rows)

    # -- messaging helpers -------------------------------------------------

    def quota_sentence(self, e164: str, lang: str = "es") -> str:
        a = self.account(e164)
        if not a.active:
            return ("Sua assinatura não está ativa." if lang == "pt"
                    else "Tu suscripción no está activa.")
        n = a.remaining
        if lang == "pt":
            if n == 0:
                return "Você já usou os 4 vídeos deste mês. Renova no próximo ciclo."
            return f"Você tem {n} vídeo{'s' if n != 1 else ''} disponíve{'is' if n != 1 else 'l'} este mês."
        if n == 0:
            return "Ya usaste los 4 videos de este mes. Se renueva el próximo ciclo."
        return f"Te queda{'n' if n != 1 else ''} {n} video{'s' if n != 1 else ''} este mes."


class StripeClient:
    """Thin wrapper so the secret key is read in one place and nowhere else."""

    def __init__(self, api_key: str | None = None):
        self.api_key = api_key or os.environ.get("STRIPE_SECRET_KEY", "")
        if not self.api_key:
            raise BillingError("STRIPE_SECRET_KEY is not set")

    def create_checkout_session(self, *, e164: str, plan: str, price_usd: int,
                                success_url: str) -> dict:
        import stripe  # imported lazily so the module loads without the SDK

        stripe.api_key = self.api_key
        session = stripe.checkout.Session.create(
            mode="subscription",
            success_url=success_url,
            client_reference_id=e164,
            line_items=[{
                "price_data": {
                    "currency": "usd",
                    "unit_amount": price_usd * 100,
                    "recurring": {"interval": "month"},
                    "product_data": {"name": f"Recorrido — {PLANS[plan]['label']}"},
                },
                "quantity": 1,
            }],
            metadata={"e164": e164, "plan": plan},
        )
        return {"url": session.url, "id": session.id}
