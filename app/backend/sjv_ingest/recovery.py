"""TX1 recovery: find stored items without a receipt and call ``evaluate_item``.

Hot-path only (default: current and previous UTC month). No schema changes,
no attempts table, no historical backfill orchestration.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timezone

import psycopg
from psycopg import errors as pg_errors

from sjv_ingest.evaluator import evaluate_item

logger = logging.getLogger("sjv_ingest.recovery")

# Set on a connection after a classified connection loss; further DB use is unsafe.
_CONNECTION_UNUSABLE_ATTR = "_sjv_recovery_connection_unusable"

_ABORT_SQLSTATES = frozenset({"42501"})
_RETRYABLE_SQLSTATES = frozenset({"40001", "40P01"})
_CONNECTION_SQLSTATES = frozenset(
    {
        "08000",
        "08001",
        "08003",
        "08004",
        "08006",
        "08007",
        "08P01",
        "57P01",
        "57P02",
        "57P03",
    }
)

_UNFINISHED_FIRST_PAGE_SQL = """
SELECT
  items.payload_id,
  items.payload_partition_month,
  items.item_index
FROM ingest_payload_items AS items
WHERE items.partition_month = %(partition_month)s
  AND NOT EXISTS (
    SELECT 1
    FROM ingest_receipts AS receipts
    WHERE receipts.payload_id = items.payload_id
      AND receipts.payload_partition_month = items.payload_partition_month
      AND receipts.item_index = items.item_index
      AND receipts.partition_month = %(partition_month)s
  )
ORDER BY
  items.payload_id,
  items.payload_partition_month,
  items.item_index
LIMIT %(batch_size)s
"""

_UNFINISHED_NEXT_PAGE_SQL = """
SELECT
  items.payload_id,
  items.payload_partition_month,
  items.item_index
FROM ingest_payload_items AS items
WHERE items.partition_month = %(partition_month)s
  AND NOT EXISTS (
    SELECT 1
    FROM ingest_receipts AS receipts
    WHERE receipts.payload_id = items.payload_id
      AND receipts.payload_partition_month = items.payload_partition_month
      AND receipts.item_index = items.item_index
      AND receipts.partition_month = %(partition_month)s
  )
  AND (
        items.payload_id,
        items.payload_partition_month,
        items.item_index
      ) > (
        %(after_payload_id)s::bigint,
        %(after_payload_partition_month)s::date,
        %(after_item_index)s::integer
      )
ORDER BY
  items.payload_id,
  items.payload_partition_month,
  items.item_index
LIMIT %(batch_size)s
"""

_OLDEST_UNFINISHED_SQL = """
SELECT min(payloads.received_at)
FROM ingest_payload_items AS items
JOIN ingest_payloads AS payloads
  ON payloads.id = items.payload_id
 AND payloads.partition_month = items.payload_partition_month
WHERE items.partition_month = ANY(%(months)s)
  AND NOT EXISTS (
    SELECT 1
    FROM ingest_receipts AS receipts
    WHERE receipts.payload_id = items.payload_id
      AND receipts.payload_partition_month = items.payload_partition_month
      AND receipts.item_index = items.item_index
      AND receipts.partition_month = items.partition_month
  )
"""


class RunAbort(Exception):
    """Stop the current recovery run; remaining items stay unfinished."""


@dataclass(frozen=True, order=True)
class Tx1ItemRef:
    payload_id: int
    payload_partition_month: date
    item_index: int


@dataclass
class RecoveryMetrics:
    found: int = 0
    evaluated: int = 0
    skipped: int = 0
    permanent: int = 0
    retryable: int = 0
    unexpected: int = 0
    duration_seconds: float = 0.0
    oldest_unfinished_age_seconds: float | None = None
    months: tuple[date, ...] = field(default_factory=tuple)
    aborted: bool = False
    abort_reason: str | None = None


def default_hot_path_months(now: datetime | None = None) -> tuple[date, date]:
    """Current and previous UTC calendar months (newest first)."""

    stamp = now if now is not None else datetime.now(timezone.utc)
    if stamp.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    stamp = stamp.astimezone(timezone.utc)
    current = date(stamp.year, stamp.month, 1)
    if stamp.month == 1:
        previous = date(stamp.year - 1, 12, 1)
    else:
        previous = date(stamp.year, stamp.month - 1, 1)
    return (current, previous)


def fetch_unfinished(conn, partition_month, *, after=None, batch_size=100):
    """Return unfinished TX1 items for one partition month.

    First page (``after is None``) has no keyset predicate so zero and
    negative ``payload_id`` values are visible. Later pages use keyset
    pagination matching ``ORDER BY``.
    """

    if batch_size < 1:
        raise ValueError("batch_size must be >= 1")
    if after is None:
        rows = conn.execute(
            _UNFINISHED_FIRST_PAGE_SQL,
            {
                "partition_month": partition_month,
                "batch_size": batch_size,
            },
        ).fetchall()
    else:
        rows = conn.execute(
            _UNFINISHED_NEXT_PAGE_SQL,
            {
                "partition_month": partition_month,
                "batch_size": batch_size,
                "after_payload_id": after.payload_id,
                "after_payload_partition_month": after.payload_partition_month,
                "after_item_index": after.item_index,
            },
        ).fetchall()
    return tuple(Tx1ItemRef(row[0], row[1], row[2]) for row in rows)


def _sqlstate(exc: BaseException) -> str | None:
    return getattr(exc, "sqlstate", None)


def _is_connection_loss(exc: psycopg.Error) -> bool:
    # DeadlockDetected / SerializationFailure subclass OperationalError in psycopg.
    if isinstance(exc, (pg_errors.DeadlockDetected, pg_errors.SerializationFailure)):
        return False
    state = _sqlstate(exc)
    if state in _RETRYABLE_SQLSTATES:
        return False
    if state in _CONNECTION_SQLSTATES:
        return True
    return isinstance(exc, psycopg.OperationalError)


def classify_psycopg_error(exc: psycopg.Error) -> str:
    """Return ``abort`` or ``retryable`` for a database error."""

    state = _sqlstate(exc)
    if state in _RETRYABLE_SQLSTATES:
        return "retryable"
    if isinstance(exc, (pg_errors.DeadlockDetected, pg_errors.SerializationFailure)):
        return "retryable"
    if state in _ABORT_SQLSTATES:
        return "abort"
    if isinstance(exc, pg_errors.InsufficientPrivilege):
        return "abort"
    if _is_connection_loss(exc):
        return "abort"
    return "abort"


def mark_connection_unusable(conn) -> None:
    """Mark ``conn`` so recovery must not issue further statements on it."""

    try:
        setattr(conn, _CONNECTION_UNUSABLE_ATTR, True)
    except Exception:
        pass


def connection_is_unusable(conn) -> bool:
    if getattr(conn, _CONNECTION_UNUSABLE_ATTR, False):
        return True
    closed = getattr(conn, "closed", False)
    return bool(closed)


def oldest_unfinished_age_seconds(conn, months, *, now=None) -> float | None:
    if not months:
        return None
    row = conn.execute(
        _OLDEST_UNFINISHED_SQL,
        {"months": list(months)},
    ).fetchone()
    if row is None or row[0] is None:
        return None
    stamp = now if now is not None else datetime.now(timezone.utc)
    if stamp.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    oldest = row[0]
    if oldest.tzinfo is None:
        oldest = oldest.replace(tzinfo=timezone.utc)
    return max(0.0, (stamp.astimezone(timezone.utc) - oldest.astimezone(timezone.utc)).total_seconds())


def recover_month(
    conn,
    partition_month,
    *,
    batch_size=100,
    evaluate=evaluate_item,
    metrics=None,
):
    """Recover unfinished items in one month. Raises ``RunAbort`` to stop the run."""

    if batch_size < 1:
        raise ValueError("batch_size must be >= 1")
    if metrics is None:
        metrics = RecoveryMetrics()
    after = None
    while True:
        try:
            batch = fetch_unfinished(
                conn,
                partition_month,
                after=after,
                batch_size=batch_size,
            )
        except psycopg.Error as exc:
            state = _sqlstate(exc)
            action = classify_psycopg_error(exc)
            if action == "retryable":
                # Deadlock/serialization on the page query: leave the connection
                # usable and abort this run so the next invocation can retry.
                metrics.retryable += 1
                metrics.aborted = True
                metrics.abort_reason = f"psycopg sqlstate={state}: {exc}"
                logger.warning(
                    "event=run_abort stage=fetch_unfinished retryable=true "
                    "partition_month=%s sqlstate=%s error=%s",
                    partition_month.isoformat(),
                    state,
                    exc,
                )
                raise RunAbort(metrics.abort_reason) from exc
            if _is_connection_loss(exc):
                mark_connection_unusable(conn)
            metrics.aborted = True
            metrics.abort_reason = f"psycopg sqlstate={state}: {exc}"
            logger.error(
                "event=run_abort stage=fetch_unfinished partition_month=%s "
                "sqlstate=%s error=%s",
                partition_month.isoformat(),
                state,
                exc,
            )
            raise RunAbort(metrics.abort_reason) from exc
        metrics.found += len(batch)
        if not batch:
            break
        for item in batch:
            try:
                evaluate(
                    conn,
                    item.payload_id,
                    item.payload_partition_month,
                    item.item_index,
                )
                metrics.evaluated += 1
                logger.info(
                    "event=item_evaluated payload_id=%s payload_partition_month=%s "
                    "item_index=%s",
                    item.payload_id,
                    item.payload_partition_month.isoformat(),
                    item.item_index,
                )
            except LookupError as exc:
                # evaluate_item raises bare LookupError; subclasses (e.g. KeyError)
                # are unexpected program errors, not missing TX1 rows.
                if type(exc) is not LookupError:
                    metrics.unexpected += 1
                    metrics.skipped += 1
                    logger.exception(
                        "event=unexpected_error payload_id=%s "
                        "payload_partition_month=%s item_index=%s error=%s",
                        item.payload_id,
                        item.payload_partition_month.isoformat(),
                        item.item_index,
                        exc,
                    )
                else:
                    metrics.permanent += 1
                    metrics.skipped += 1
                    logger.error(
                        "event=permanent_anomaly payload_id=%s "
                        "payload_partition_month=%s item_index=%s error=%s",
                        item.payload_id,
                        item.payload_partition_month.isoformat(),
                        item.item_index,
                        exc,
                    )
            except (ValueError, RuntimeError, PermissionError) as exc:
                metrics.aborted = True
                metrics.abort_reason = f"{type(exc).__name__}: {exc}"
                logger.error(
                    "event=run_abort payload_id=%s payload_partition_month=%s "
                    "item_index=%s error=%s",
                    item.payload_id,
                    item.payload_partition_month.isoformat(),
                    item.item_index,
                    exc,
                )
                after = item
                raise RunAbort(metrics.abort_reason) from exc
            except psycopg.Error as exc:
                action = classify_psycopg_error(exc)
                state = _sqlstate(exc)
                if action == "retryable":
                    metrics.retryable += 1
                    metrics.skipped += 1
                    logger.warning(
                        "event=retryable_db_error payload_id=%s "
                        "payload_partition_month=%s item_index=%s sqlstate=%s error=%s",
                        item.payload_id,
                        item.payload_partition_month.isoformat(),
                        item.item_index,
                        state,
                        exc,
                    )
                else:
                    if _is_connection_loss(exc):
                        mark_connection_unusable(conn)
                    metrics.aborted = True
                    metrics.abort_reason = f"psycopg sqlstate={state}: {exc}"
                    logger.error(
                        "event=run_abort payload_id=%s payload_partition_month=%s "
                        "item_index=%s sqlstate=%s error=%s",
                        item.payload_id,
                        item.payload_partition_month.isoformat(),
                        item.item_index,
                        state,
                        exc,
                    )
                    after = item
                    raise RunAbort(metrics.abort_reason) from exc
            except Exception as exc:
                metrics.unexpected += 1
                metrics.skipped += 1
                logger.exception(
                    "event=unexpected_error payload_id=%s payload_partition_month=%s "
                    "item_index=%s error=%s",
                    item.payload_id,
                    item.payload_partition_month.isoformat(),
                    item.item_index,
                    exc,
                )
            after = item
        if len(batch) < batch_size:
            break
    return metrics


def recover_run(
    conn,
    months=None,
    *,
    batch_size=100,
    evaluate=evaluate_item,
    now=None,
):
    """Run hot-path recovery. ``months`` defaults to current and previous UTC month."""

    started = time.monotonic()
    resolved = tuple(months) if months is not None else default_hot_path_months(now)
    metrics = RecoveryMetrics(months=resolved)
    try:
        for month in resolved:
            logger.info("event=month_start partition_month=%s", month.isoformat())
            recover_month(
                conn,
                month,
                batch_size=batch_size,
                evaluate=evaluate,
                metrics=metrics,
            )
    except RunAbort:
        metrics.aborted = True
        raise
    finally:
        metrics.duration_seconds = time.monotonic() - started
        if connection_is_unusable(conn):
            logger.warning(
                "event=oldest_age_skipped reason=connection_unusable"
            )
        else:
            try:
                metrics.oldest_unfinished_age_seconds = oldest_unfinished_age_seconds(
                    conn,
                    resolved,
                    now=now if now is not None else datetime.now(timezone.utc),
                )
            except Exception as exc:
                logger.warning("event=oldest_age_failed error=%s", exc)
        logger.info(
            "event=run_finished found=%s evaluated=%s skipped=%s permanent=%s "
            "retryable=%s unexpected=%s aborted=%s duration_seconds=%.3f "
            "oldest_unfinished_age_seconds=%s months=%s",
            metrics.found,
            metrics.evaluated,
            metrics.skipped,
            metrics.permanent,
            metrics.retryable,
            metrics.unexpected,
            metrics.aborted,
            metrics.duration_seconds,
            metrics.oldest_unfinished_age_seconds,
            ",".join(month.isoformat() for month in resolved),
        )
    return metrics


def _parse_month(value: str) -> date:
    parsed = date.fromisoformat(value)
    if parsed.day != 1:
        raise argparse.ArgumentTypeError(
            f"month must be the first day of a month (YYYY-MM-01), got {value}"
        )
    return parsed


def _parse_batch_size(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("batch-size must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("batch-size must be >= 1")
    return parsed


def _database_url() -> str:
    raw = os.environ.get("SJV_DATABASE_URL", "")
    if not raw:
        raise SystemExit("SJV_DATABASE_URL is required")
    return raw.replace("postgresql+psycopg://", "postgresql://", 1)


def _ensure_collector(conn) -> None:
    role = conn.execute("SELECT current_user").fetchone()[0]
    if role == "sjv_collector":
        return
    conn.execute("SET ROLE sjv_collector")
    if conn.execute("SELECT current_user").fetchone()[0] != "sjv_collector":
        raise SystemExit(f"could not assume sjv_collector (was {role})")


def _close_connection(conn) -> None:
    """Close ``conn`` without masking an earlier recovery failure."""

    if conn is None:
        return
    try:
        if getattr(conn, "closed", False):
            return
        conn.close()
    except Exception as exc:
        logger.warning("event=connection_close_failed error=%s", exc)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="One-shot TX1 recovery for unfinished ingest_payload_items.",
    )
    parser.add_argument(
        "--batch-size",
        type=_parse_batch_size,
        default=100,
        help="Keyset page size (default: 100).",
    )
    parser.add_argument(
        "--month",
        action="append",
        type=_parse_month,
        dest="months",
        help=(
            "Partition month as YYYY-MM-01. Repeatable. "
            "Default: current and previous UTC month."
        ),
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
    )
    return parser


def main(argv=None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    url = _database_url()
    exit_code = 0
    metrics = None
    conn = None
    try:
        conn = psycopg.connect(url, autocommit=True)
    except psycopg.Error as exc:
        logger.error("event=main_db_error sqlstate=%s error=%s", _sqlstate(exc), exc)
        return 2
    try:
        _ensure_collector(conn)
        try:
            metrics = recover_run(
                conn,
                months=args.months,
                batch_size=args.batch_size,
            )
        except RunAbort as exc:
            logger.error("event=main_aborted error=%s", exc)
            exit_code = 2
    except psycopg.Error as exc:
        logger.error("event=main_db_error sqlstate=%s error=%s", _sqlstate(exc), exc)
        exit_code = 2
    finally:
        _close_connection(conn)
    if exit_code:
        return exit_code
    if metrics is None:
        return 2
    if metrics.permanent or metrics.unexpected or metrics.retryable:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
