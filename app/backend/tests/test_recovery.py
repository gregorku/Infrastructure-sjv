"""Unit checks for TX1 recovery. No database required."""

from __future__ import annotations

import unittest
from datetime import date, datetime, timezone
from unittest.mock import Mock

import psycopg
from psycopg.errors import (
    DeadlockDetected,
    InsufficientPrivilege,
    SerializationFailure,
)

from sjv_ingest.recovery import (
    RunAbort,
    Tx1ItemRef,
    build_arg_parser,
    classify_psycopg_error,
    connection_is_unusable,
    default_hot_path_months,
    fetch_unfinished,
    mark_connection_unusable,
    recover_month,
    recover_run,
    _UNFINISHED_FIRST_PAGE_SQL,
    _UNFINISHED_NEXT_PAGE_SQL,
)


MONTH = date(2026, 11, 1)


class FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def fetchall(self):
        return list(self._rows)

    def fetchone(self):
        return self._rows[0] if self._rows else None


class FakeConn:
    def __init__(self, pages):
        self.pages = list(pages)
        self.calls = []
        self.autocommit = True

    def execute(self, query, params=None):
        self.calls.append((query, params))
        if "min(payloads.received_at)" in query:
            return FakeResult([(None,)])
        if not self.pages:
            return FakeResult([])
        return FakeResult(self.pages.pop(0))


class HotPathMonthsTest(unittest.TestCase):
    def test_default_months_newest_first(self):
        now = datetime(2026, 11, 27, 12, 0, tzinfo=timezone.utc)
        self.assertEqual(
            default_hot_path_months(now),
            (date(2026, 11, 1), date(2026, 10, 1)),
        )

    def test_january_wraps_to_december(self):
        now = datetime(2026, 1, 3, tzinfo=timezone.utc)
        self.assertEqual(
            default_hot_path_months(now),
            (date(2026, 1, 1), date(2025, 12, 1)),
        )

    def test_naive_datetime_rejected(self):
        with self.assertRaises(ValueError):
            default_hot_path_months(datetime(2026, 11, 27, 12, 0))


class FetchSqlTest(unittest.TestCase):
    def test_first_page_has_no_keyset_and_binds_partition(self):
        conn = FakeConn([[(-5, MONTH, 0), (0, MONTH, 0), (3, MONTH, 1)]])
        rows = fetch_unfinished(conn, MONTH, after=None, batch_size=10)
        query, params = conn.calls[0]
        self.assertIn("NOT EXISTS", query)
        self.assertNotIn("after_payload_id", query)
        self.assertEqual(_UNFINISHED_FIRST_PAGE_SQL.strip(), query.strip())
        self.assertEqual(params["partition_month"], MONTH)
        self.assertEqual(params["batch_size"], 10)
        self.assertIn("receipts.partition_month = %(partition_month)s", query)
        self.assertIn("items.partition_month = %(partition_month)s", query)
        self.assertEqual(
            rows,
            (
                Tx1ItemRef(-5, MONTH, 0),
                Tx1ItemRef(0, MONTH, 0),
                Tx1ItemRef(3, MONTH, 1),
            ),
        )

    def test_next_page_uses_keyset_matching_order_by(self):
        conn = FakeConn([[(4, MONTH, 0)]])
        after = Tx1ItemRef(0, MONTH, 0)
        rows = fetch_unfinished(conn, MONTH, after=after, batch_size=2)
        query, params = conn.calls[0]
        self.assertEqual(_UNFINISHED_NEXT_PAGE_SQL.strip(), query.strip())
        self.assertEqual(params["after_payload_id"], 0)
        self.assertEqual(params["after_payload_partition_month"], MONTH)
        self.assertEqual(params["after_item_index"], 0)
        self.assertEqual(params["partition_month"], MONTH)
        order_idx = query.index("ORDER BY")
        keyset_idx = query.index(") > (")
        self.assertLess(keyset_idx, order_idx)
        self.assertEqual(rows, (Tx1ItemRef(4, MONTH, 0),))


class ClassifyErrorTest(unittest.TestCase):
    def test_deadlock_and_serialization_are_retryable(self):
        self.assertEqual(classify_psycopg_error(DeadlockDetected("x")), "retryable")
        self.assertEqual(classify_psycopg_error(SerializationFailure("x")), "retryable")

    def test_insufficient_privilege_aborts(self):
        self.assertEqual(classify_psycopg_error(InsufficientPrivilege("x")), "abort")

    def test_operational_error_aborts(self):
        self.assertEqual(classify_psycopg_error(psycopg.OperationalError("gone")), "abort")

    def test_unknown_db_error_aborts(self):
        self.assertEqual(classify_psycopg_error(psycopg.Error("mystery")), "abort")


class BatchSizeValidationTest(unittest.TestCase):
    def test_recover_month_rejects_zero_and_negative(self):
        conn = FakeConn([])
        with self.assertRaises(ValueError):
            recover_month(conn, MONTH, batch_size=0)
        with self.assertRaises(ValueError):
            recover_month(conn, MONTH, batch_size=-3)

    def test_cli_rejects_zero_and_negative_batch_size(self):
        parser = build_arg_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["--batch-size", "0"])
        with self.assertRaises(SystemExit):
            parser.parse_args(["--batch-size", "-1"])


class ConnectionUnusableTest(unittest.TestCase):
    def test_connection_loss_marks_connection_and_skips_oldest_query(self):
        conn = FakeConn([[(1, MONTH, 0)]])

        def evaluate(*_args):
            raise psycopg.OperationalError("connection lost")

        with self.assertRaises(RunAbort):
            recover_run(
                conn,
                months=(MONTH,),
                batch_size=10,
                evaluate=evaluate,
                now=datetime(2026, 11, 27, tzinfo=timezone.utc),
            )
        self.assertTrue(connection_is_unusable(conn))
        oldest_calls = [
            query
            for query, _params in conn.calls
            if "min(payloads.received_at)" in query
        ]
        self.assertEqual(oldest_calls, [])

    def test_fetch_connection_loss_marks_unusable_and_skips_oldest(self):
        class FailingFetchConn(FakeConn):
            def execute(self, query, params=None):
                self.calls.append((query, params))
                if "FROM ingest_payload_items" in query:
                    raise psycopg.OperationalError("server closed the connection")
                if "min(payloads.received_at)" in query:
                    return FakeResult([(None,)])
                return FakeResult([])

        conn = FailingFetchConn([])

        with self.assertRaises(RunAbort):
            recover_run(
                conn,
                months=(MONTH,),
                batch_size=10,
                now=datetime(2026, 11, 27, tzinfo=timezone.utc),
            )
        self.assertTrue(connection_is_unusable(conn))
        oldest_calls = [
            query
            for query, _params in conn.calls
            if "min(payloads.received_at)" in query
        ]
        self.assertEqual(oldest_calls, [])

    def test_fetch_deadlock_is_retryable_and_not_connection_loss(self):
        from sjv_ingest.recovery import RecoveryMetrics

        class DeadlockFetchConn(FakeConn):
            def execute(self, query, params=None):
                self.calls.append((query, params))
                if "FROM ingest_payload_items" in query:
                    raise DeadlockDetected("deadlock detected")
                if "min(payloads.received_at)" in query:
                    return FakeResult([(None,)])
                return FakeResult([])

        conn = DeadlockFetchConn([])
        metrics = RecoveryMetrics()
        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, metrics=metrics)
        self.assertFalse(connection_is_unusable(conn))
        self.assertEqual(metrics.retryable, 1)
        self.assertTrue(metrics.aborted)

    def test_mark_connection_unusable_helper(self):
        conn = FakeConn([])
        self.assertFalse(connection_is_unusable(conn))
        mark_connection_unusable(conn)
        self.assertTrue(connection_is_unusable(conn))


class RecoverMonthTest(unittest.TestCase):
    def test_lookup_error_continues_and_advances_cursor(self):
        pages = [
            [(-5, MONTH, 0), (0, MONTH, 0), (2, MONTH, 1)],
            [],
        ]
        conn = FakeConn(pages)
        calls = []

        def evaluate(_conn, payload_id, payload_month, item_index):
            calls.append((payload_id, payload_month, item_index))
            if payload_id == 0:
                raise LookupError("stored item was not found")

        metrics = recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(calls, [(-5, MONTH, 0), (0, MONTH, 0), (2, MONTH, 1)])
        self.assertEqual(metrics.evaluated, 2)
        self.assertEqual(metrics.permanent, 1)
        self.assertEqual(metrics.skipped, 1)
        self.assertFalse(metrics.aborted)

    def test_multi_item_same_payload_processed_in_order(self):
        conn = FakeConn([[(9, MONTH, 0), (9, MONTH, 1), (9, MONTH, 2)], []])
        calls = []

        def evaluate(_conn, payload_id, payload_month, item_index):
            calls.append((payload_id, item_index))

        recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(calls, [(9, 0), (9, 1), (9, 2)])

    def test_deadlock_is_retryable_and_continues(self):
        conn = FakeConn([[(1, MONTH, 0), (2, MONTH, 0)], []])
        calls = []

        def evaluate(_conn, payload_id, payload_month, item_index):
            calls.append(payload_id)
            if payload_id == 1:
                raise DeadlockDetected("deadlock detected")

        metrics = recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(calls, [1, 2])
        self.assertEqual(metrics.retryable, 1)
        self.assertEqual(metrics.evaluated, 1)

    def test_serialization_failure_is_retryable(self):
        conn = FakeConn([[(1, MONTH, 0)], []])

        def evaluate(*_args):
            raise SerializationFailure("could not serialize")

        metrics = recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(metrics.retryable, 1)
        self.assertEqual(metrics.evaluated, 0)

    def test_insufficient_privilege_aborts_after_cursor_update(self):
        conn = FakeConn([[(1, MONTH, 0), (2, MONTH, 0)]])
        calls = []

        def evaluate(_conn, payload_id, *_rest):
            calls.append(payload_id)
            raise InsufficientPrivilege("permission denied")

        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(calls, [1])

    def test_connection_loss_aborts(self):
        conn = FakeConn([[(1, MONTH, 0)]])

        def evaluate(*_args):
            raise psycopg.OperationalError("connection lost")

        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)

    def test_permission_error_aborts(self):
        conn = FakeConn([[(1, MONTH, 0)]])

        def evaluate(*_args):
            raise PermissionError("evaluate_item runs only as sjv_collector")

        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)

    def test_runtime_error_aborts(self):
        conn = FakeConn([[(1, MONTH, 0)]])

        def evaluate(*_args):
            raise RuntimeError("evaluate_item requires autocommit")

        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)

    def test_value_error_aborts(self):
        conn = FakeConn([[(1, MONTH, 0)]])

        def evaluate(*_args):
            raise ValueError("item_index must be a non-negative int, not bool")

        with self.assertRaises(RunAbort):
            recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)

    def test_unexpected_python_error_skips_without_false_receipt(self):
        conn = FakeConn([[(1, MONTH, 0), (2, MONTH, 0)], []])
        calls = []

        def evaluate(_conn, payload_id, *_rest):
            calls.append(payload_id)
            if payload_id == 1:
                # Not a LookupError subclass (KeyError would be misclassified).
                raise AttributeError("unexpected")

        metrics = recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        self.assertEqual(calls, [1, 2])
        self.assertEqual(metrics.unexpected, 1)
        self.assertEqual(metrics.evaluated, 1)
        self.assertEqual(metrics.skipped, 1)

    def test_keyset_second_page_uses_last_item_including_failed(self):
        # page1 returns three ids; middle fails; page2 requested with after=last of page1
        conn = FakeConn(
            [
                [(1, MONTH, 0), (2, MONTH, 0), (3, MONTH, 0)],
                [(4, MONTH, 0)],
                [],
            ]
        )
        evaluated = []

        def evaluate(_conn, payload_id, *_rest):
            evaluated.append(payload_id)
            if payload_id == 2:
                raise LookupError("gone")

        metrics = recover_month(conn, MONTH, batch_size=3, evaluate=evaluate)
        self.assertEqual(evaluated, [1, 2, 3, 4])
        self.assertEqual(metrics.permanent, 1)
        # Second fetch must be next-page with after=(3, MONTH, 0)
        next_calls = [
            params
            for query, params in conn.calls
            if params and "after_payload_id" in params
        ]
        self.assertEqual(next_calls[0]["after_payload_id"], 3)
        self.assertEqual(next_calls[0]["after_item_index"], 0)

    def test_poison_item_not_reloaded_in_same_run(self):
        # Single-item pages would loop forever if cursor did not advance on error.
        conn = FakeConn(
            [
                [(7, MONTH, 0)],
                [(8, MONTH, 0)],
                [],
            ]
        )
        hits = {7: 0, 8: 0}

        def evaluate(_conn, payload_id, *_rest):
            hits[payload_id] += 1
            if payload_id == 7:
                raise LookupError("poison")

        metrics = recover_month(conn, MONTH, batch_size=1, evaluate=evaluate)
        self.assertEqual(hits[7], 1)
        self.assertEqual(hits[8], 1)
        self.assertEqual(metrics.permanent, 1)
        self.assertEqual(metrics.evaluated, 1)


class RecoverRunTest(unittest.TestCase):
    def test_run_visits_months_in_order(self):
        months = (date(2026, 11, 1), date(2026, 10, 1))
        conn = FakeConn([[], []])
        seen = []

        def evaluate(*_args):
            seen.append("evaluate")

        # recover_run will call fetch per month; empty batches only
        metrics = recover_run(
            conn,
            months=months,
            batch_size=5,
            evaluate=evaluate,
            now=datetime(2026, 11, 27, tzinfo=timezone.utc),
        )
        partition_calls = [
            params["partition_month"]
            for query, params in conn.calls
            if params and "partition_month" in params and "batch_size" in params
        ]
        self.assertEqual(partition_calls, [months[0], months[1]])
        self.assertEqual(metrics.months, months)
        self.assertEqual(seen, [])


class ExistingReceiptShortCircuitContractTest(unittest.TestCase):
    def test_recovery_invokes_evaluate_only(self):
        conn = FakeConn([[(1, MONTH, 0)], []])
        evaluate = Mock(return_value=object())
        recover_month(conn, MONTH, batch_size=10, evaluate=evaluate)
        evaluate.assert_called_once_with(conn, 1, MONTH, 0)


if __name__ == "__main__":
    unittest.main()
