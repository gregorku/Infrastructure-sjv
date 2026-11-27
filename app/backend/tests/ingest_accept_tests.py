"""Isolated checks for storing one envelope. The connection starts as the
bootstrap superuser only to create a device and an endpoint. ``accept``
itself runs as ``sjv_collector``.
"""

import os
import threading
from datetime import datetime, timezone

import psycopg

from sjv_ingest.contract import Envelope, Fragment, Frame, Item, SourceTime
from sjv_ingest.restore import load_envelope
from sjv_ingest.evaluator import _ADVISORY_LOCK_SQL, evaluate_item
from sjv_ingest.service import IngestRejected, accept

URL = os.environ["SJV_DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)
UNTOUCHED = (
    "telegram_dedup_keys",
    "raw_telegrams",
    "decode_queue",
    "ingest_fragment_sets",
    "ingest_fragments",
    "meter_readings",
)


def fail(message):
    raise SystemExit(message)


class Recording:
    def __init__(self, conn, fail_on_receipt=False, fail_on_second_item=False):
        self._conn = conn
        self._fail_on_receipt = fail_on_receipt
        self._fail_on_second_item = fail_on_second_item
        self.statements = []
        self.transactions = 0
        self.item_inserts = 0

    @property
    def autocommit(self):
        return self._conn.autocommit

    def execute(self, query, params=None):
        self.statements.append(query)
        if self._fail_on_receipt and "INTO ingest_receipts" in query:
            raise RuntimeError("forced receipt failure")
        if self._fail_on_second_item and "INTO ingest_payload_items" in query:
            self.item_inserts += 1
            if self.item_inserts == 2:
                raise RuntimeError("forced item failure")
        if params is None:
            return self._conn.execute(query)
        return self._conn.execute(query, params)

    def transaction(self):
        self.transactions += 1
        return self._conn.transaction()


def envelope(source_id, endpoint_id, device_id, original, items):
    return Envelope(
        ingest_source_id=source_id,
        endpoint_id=endpoint_id,
        device_id=device_id,
        transport="https",
        server_received_at=datetime.now(timezone.utc),
        original=original,
        items=items,
    )


def one_item(original, **overrides):
    values = {"index": 0, "original": original, "message_kind": "raw_wmbus"}
    values.update(overrides)
    return (Item(**values),)


def payload_count(conn, original):
    return conn.execute(
        "SELECT count(*) FROM ingest_payloads WHERE payload = %s",
        (original,),
    ).fetchone()[0]


def receipt_count(conn, payload_id, payload_month):
    return conn.execute(
        """
        SELECT count(*) FROM ingest_receipts
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (payload_id, payload_month),
    ).fetchone()[0]


def counts(conn):
    found = {}
    for table in UNTOUCHED:
        found[table] = conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
    return found


def main():
    with psycopg.connect(URL, autocommit=True) as conn:
        stamp = datetime.now(timezone.utc).strftime("%H%M%S%f")
        device_code = f"stepb-{stamp}"
        endpoint_code = f"stepb-ep-{stamp}"
        source_code = f"stepb-src-{stamp}"
        conn.execute(
            "INSERT INTO devices (code, kind, status) VALUES (%s, 'esp32', 'active')",
            (device_code,),
        )
        conn.execute(
            "INSERT INTO ingest_endpoints (code, transport, status) VALUES (%s, 'https', 'active')",
            (endpoint_code,),
        )
        device_id = conn.execute(
            "SELECT id FROM devices WHERE code = %s",
            (device_code,),
        ).fetchone()[0]
        endpoint_id = conn.execute(
            "SELECT id FROM ingest_endpoints WHERE code = %s",
            (endpoint_code,),
        ).fetchone()[0]
        before = counts(conn)
        bootstrap_user = conn.execute("SELECT current_user").fetchone()[0]
        if bootstrap_user == "sjv_collector":
            print("SKIP non-collector role test: test URL is sjv_collector")

        conn.execute("SET ROLE sjv_collector")
        if conn.execute("SELECT current_user").fetchone()[0] != "sjv_collector":
            fail("main test connection did not assume sjv_collector")
        try:
            conn.execute(
                "INSERT INTO ingest_sources (code, kind, device_id) "
                "SELECT %s, 'device', id FROM devices WHERE code = %s",
                (source_code, device_code),
            )
            source_id = conn.execute(
                "SELECT id FROM ingest_sources WHERE code = %s",
                (source_code,),
            ).fetchone()[0]
            _valid(conn, source_id, endpoint_id, device_id)
            _round_trip(conn, source_id, endpoint_id, device_id)
            _evaluate(conn, source_id, endpoint_id, device_id)
            _boolean_is_not_proof(conn, source_id, endpoint_id, device_id)
            _item_failure(conn, source_id, endpoint_id, device_id)
            _empty(conn, source_id, endpoint_id, device_id)
            _unknown_format(conn, source_id, endpoint_id, device_id)
            _unknown_kind(conn, source_id, endpoint_id, device_id)
            _rejected(conn, endpoint_id, device_id)
            _rollback(conn, source_id, endpoint_id, device_id)
            _repeat(conn, source_id, endpoint_id, device_id)
        finally:
            conn.execute("RESET ROLE")
        if conn.execute("SELECT current_user").fetchone()[0] != "sjv_bootstrap":
            fail("role was not reset")
        after = counts(conn)
        if after != before:
            fail(f"untouched tables changed: {before} -> {after}")
        print("PASS collector role reset and untouched tables")


def _valid(conn, source_id, endpoint_id, device_id):
    original = b"\x00step-b-valid\xff"
    body = b"\x01item\xfe"
    recorder = Recording(conn)
    result = accept(
        envelope(source_id, endpoint_id, device_id, original, one_item(body)),
        recorder,
    )
    if any("INTO ingest_receipts" in sql for sql in recorder.statements):
        fail("valid envelope inserted a receipt")
    if recorder.transactions != 1:
        fail(f"valid envelope used {recorder.transactions} transactions")
    if not result.awaiting_evaluation or result.receipt_id is not None or result.receipt_status is not None:
        fail(f"valid result is not waiting for evaluation: {result}")
    row = conn.execute(
        """
        SELECT payload, ingest_source_id, endpoint_id, device_id, origin, content_kind,
               payload_sha256 = sha256(payload), size_bytes
        FROM ingest_payloads
        WHERE id = %s AND partition_month = %s
        """,
        (result.payload_id, result.payload_partition_month),
    ).fetchone()
    expected = (original, source_id, endpoint_id, device_id, "received", "opaque", True, len(original))
    if row != expected:
        fail(f"stored valid envelope differs: {row}")
    if receipt_count(conn, result.payload_id, result.payload_partition_month) != 0:
        fail("valid envelope created a receipt")
    if payload_count(conn, original) != 1:
        fail("valid payload was not stored once")
    item = conn.execute(
        """
        SELECT item_index, original, message_kind, msg_key, proof_basis
        FROM ingest_payload_items
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (result.payload_id, result.payload_partition_month),
    ).fetchone()
    if item != (0, body, "raw_wmbus", None, None):
        fail(f"stored item differs from the envelope bytes: {item}")
    if body == original:
        fail("item bytes were not stored separately from the envelope")
    print("PASS valid envelope stores the payload and waits for evaluation")


def _round_trip(conn, source_id, endpoint_id, device_id):
    received_at = datetime(2026, 11, 21, 8, 30, tzinfo=timezone.utc)
    sent_at = datetime(2026, 11, 21, 8, 29, tzinfo=timezone.utc)
    original = b"\x00envelope\xff"
    first = b"\x00item-a\xff"
    second = b"\xffitem-b\x00"
    stored = Envelope(
        ingest_source_id=source_id,
        endpoint_id=endpoint_id,
        device_id=device_id,
        transport="https",
        server_received_at=received_at,
        original=original,
        items=(
            Item(
                index=0,
                original=first,
                message_kind="vendor_private",
                msg_key="plain-text",
                msg_key_namespace="https",
                identifier_proven=True,
                source_time=SourceTime(tx_instance_id="9f3c51a07be2d410", tx_boot=17, tx_at=sent_at),
                frame=Frame(original=b"\x2a\x44\xff", frame_format="Z", crc_included=False, rssi=-80),
            ),
            Item(
                index=1,
                original=second,
                message_kind="raw_wmbus",
                fragment=Fragment(group_key="group", fragment_index=1, source_message_ref="ref"),
                external_message_id="ext-1",
            ),
        ),
    )
    before = conn.execute(
        """
        SELECT
            (SELECT count(*) FROM ingest_receipts),
            (SELECT count(*) FROM raw_telegrams),
            (SELECT count(*) FROM ingest_message_keys)
        """
    ).fetchone()
    result = accept(stored, conn)
    if not result.awaiting_evaluation or result.receipt_status is not None:
        fail(f"multi-item result is not waiting: {result}")
    loaded = load_envelope(conn, result.payload_id, result.payload_partition_month)
    expected = Envelope(
        ingest_source_id=source_id,
        endpoint_id=endpoint_id,
        device_id=device_id,
        transport="https",
        server_received_at=received_at,
        original=original,
        items=(
            Item(
                index=0,
                original=first,
                message_kind="vendor_private",
                msg_key="plain-text",
                msg_key_namespace="https",
                identifier_proven=True,
                source_time=SourceTime(tx_instance_id="9f3c51a07be2d410", tx_boot=17, tx_at=sent_at),
                frame=Frame(original=b"\x2a\x44\xff", frame_format="Z", crc_included=False, rssi=-80),
            ),
            Item(
                index=1,
                original=second,
                message_kind="raw_wmbus",
                fragment=Fragment(group_key="group", fragment_index=1, source_message_ref="ref"),
                external_message_id="ext-1",
            ),
        ),
    )
    if loaded != expected:
        fail(f"reloaded envelope differs: {loaded}")
    after = conn.execute(
        """
        SELECT
            (SELECT count(*) FROM ingest_receipts),
            (SELECT count(*) FROM raw_telegrams),
            (SELECT count(*) FROM ingest_message_keys)
        """
    ).fetchone()
    if after != before:
        fail(f"reload created rows: {before} -> {after}")
    try:
        accept(
            envelope(source_id, endpoint_id, device_id, b"\x05later", ()),
            Recording(conn, fail_on_receipt=True),
        )
    except RuntimeError:
        pass
    else:
        fail("later receipt failure returned a result")
    again = load_envelope(conn, result.payload_id, result.payload_partition_month)
    if again != expected:
        fail("later evaluation failure changed the stored envelope")
    print("PASS stored items reload in order and survive a later failure")


def _evaluate(conn, source_id, endpoint_id, device_id):
    received_at = datetime(2026, 11, 21, 9, 0, tzinfo=timezone.utc)
    body = b"\x0a-evaluator"
    stored = accept(
        Envelope(
            source_id,
            "https",
            received_at,
            body,
            (
                Item(
                    index=0,
                    original=body,
                    message_kind="raw_wmbus",
                    msg_key="evaluator-key",
                    msg_key_namespace="https",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    _evaluate_invalid_item_indexes(conn, stored)
    first = evaluate_item(conn, stored.payload_id, stored.payload_partition_month, 0)
    if (
        first.receipt_status != "accepted"
        or not first.first_delivery
        or first.outcome != "accepted"
        or first.original_receipt_id != first.receipt_id
    ):
        fail(f"first evaluation result is wrong: {first}")
    with psycopg.connect(URL, autocommit=True) as bootstrap:
        current_user = bootstrap.execute("SELECT current_user").fetchone()[0]
        if current_user == "sjv_collector":
            print("SKIP evaluator rejects a non-collector role: test URL is sjv_collector")
        else:
            try:
                evaluate_item(bootstrap, stored.payload_id, stored.payload_partition_month, 0)
            except PermissionError:
                pass
            else:
                fail("evaluator accepted a non-collector role")
    _evaluate_selected_item(conn, source_id, endpoint_id, device_id)
    row = conn.execute(
        """
        SELECT first_received_at, last_received_at, delivery_count, outcome,
               receipt_id, receipt_partition_month, message_kind
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'evaluator-key' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()
    expected = (
        received_at,
        received_at,
        1,
        "accepted",
        first.receipt_id,
        first.receipt_partition_month,
        "telegram",
    )
    if row != expected:
        fail(f"first dedup row is wrong: {row}")

    older = accept(
        Envelope(
            source_id,
            "https",
            datetime(2026, 11, 20, 9, 0, tzinfo=timezone.utc),
            b"\x0b-evaluator-older",
            (
                Item(
                    index=0,
                    original=b"\x0b-evaluator-older",
                    message_kind="raw_wmbus",
                    msg_key="evaluator-key",
                    msg_key_namespace="https",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    duplicate = evaluate_item(conn, older.payload_id, older.payload_partition_month, 0)
    if (
        duplicate.receipt_status != "duplicate_delivery"
        or duplicate.first_delivery
        or duplicate.outcome != "accepted"
        or duplicate.original_receipt_id != first.receipt_id
    ):
        fail(f"duplicate evaluation result is wrong: {duplicate}")
    if _ack_projection(first) != _ack_projection(duplicate):
        fail(
            "repeated delivery cannot reconstruct the original ACK result: "
            f"{_ack_projection(first)} != {_ack_projection(duplicate)}"
        )
    row = conn.execute(
        """
        SELECT first_received_at, last_received_at, delivery_count, outcome,
               receipt_id, receipt_partition_month
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'evaluator-key' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()
    if row != (
        received_at,
        received_at,
        2,
        "accepted",
        first.receipt_id,
        first.receipt_partition_month,
    ):
        fail(f"duplicate changed original key state: {row}")
    statuses = conn.execute(
        """
        SELECT status FROM ingest_receipts
        WHERE id IN (%s, %s)
        ORDER BY id
        """,
        (first.receipt_id, duplicate.receipt_id),
    ).fetchall()
    if [status[0] for status in statuses] != ["accepted", "duplicate_delivery"]:
        fail(f"receipt statuses are wrong: {statuses}")
    print("PASS evaluator stores first and duplicate delivery state")

    _evaluate_rollbacks(conn, source_id, endpoint_id, device_id)
    _evaluate_null_history(conn, source_id, endpoint_id, device_id)
    _evaluate_tx1_idempotence(conn, source_id, endpoint_id, device_id)
    _evaluate_repeat_after_duplicate(conn, source_id, endpoint_id, device_id)
    _evaluate_concurrent(conn, source_id, endpoint_id, device_id)
    _evaluate_concurrent_same_tx1(conn, source_id, endpoint_id, device_id)
    _evaluate_advisory_lock_sql(conn)


def _evaluate_invalid_item_indexes(conn, stored):
    before = conn.execute(
        """
        SELECT
            (SELECT count(*) FROM ingest_receipts),
            (SELECT count(*) FROM ingest_message_keys)
        """
    ).fetchone()
    for invalid in (True, False, 1.0, -1, "1", None):
        try:
            evaluate_item(
                conn,
                stored.payload_id,
                stored.payload_partition_month,
                invalid,
            )
        except ValueError:
            pass
        else:
            fail(f"invalid item_index was accepted: {invalid!r}")
    after = conn.execute(
        """
        SELECT
            (SELECT count(*) FROM ingest_receipts),
            (SELECT count(*) FROM ingest_message_keys)
        """
    ).fetchone()
    if after != before:
        fail(f"invalid item_index changed database state: {before} -> {after}")
    print("PASS evaluator rejects invalid item_index before database work")


def _ack_projection(result):
    """The current ACK-relevant result; transport serialization is separate."""

    return (
        result.outcome,
        result.original_receipt_id,
        result.original_receipt_partition_month,
    )


class _FailingConnection:
    def __init__(self, conn, needle):
        self._conn = conn
        self._needle = needle

    @property
    def autocommit(self):
        return self._conn.autocommit

    def execute(self, query, params=None):
        if self._needle in query:
            raise RuntimeError(f"forced failure: {self._needle}")
        if params is None:
            return self._conn.execute(query)
        return self._conn.execute(query, params)

    def transaction(self):
        return self._conn.transaction()


def _new_evaluation_payload(conn, source_id, endpoint_id, device_id, key, stamp, body):
    return accept(
        Envelope(
            source_id,
            "https",
            stamp,
            body,
            (
                Item(
                    index=0,
                    original=body,
                    message_kind="raw_wmbus",
                    msg_key=key,
                    msg_key_namespace="https",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )


def _evaluate_rollbacks(conn, source_id, endpoint_id, device_id):
    receipt_payload = _new_evaluation_payload(
        conn, source_id, endpoint_id, device_id, "rollback-receipt",
        datetime(2026, 11, 21, 11, 0, tzinfo=timezone.utc), b"\x0e-receipt",
    )
    try:
        evaluate_item(
            _FailingConnection(conn, "INSERT INTO ingest_receipts"),
            receipt_payload.payload_id,
            receipt_payload.payload_partition_month,
            0,
        )
    except RuntimeError:
        pass
    else:
        fail("receipt failure was not raised")
    if conn.execute(
        """
        SELECT count(*) FROM ingest_receipts
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (receipt_payload.payload_id, receipt_payload.payload_partition_month),
    ).fetchone()[0] != 0:
        fail("receipt rollback left a receipt")
    if conn.execute(
        """
        SELECT count(*) FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key = 'rollback-receipt'
        """,
        (source_id,),
    ).fetchone()[0] != 0:
        fail("receipt rollback left a dedup key")

    upsert_payload = _new_evaluation_payload(
        conn, source_id, endpoint_id, device_id, "rollback-upsert",
        datetime(2026, 11, 21, 11, 1, tzinfo=timezone.utc), b"\x0f-upsert",
    )
    try:
        evaluate_item(
            _FailingConnection(conn, "INSERT INTO ingest_message_keys"),
            upsert_payload.payload_id,
            upsert_payload.payload_partition_month,
            0,
        )
    except RuntimeError:
        pass
    else:
        fail("upsert failure was not raised")
    if conn.execute(
        """
        SELECT count(*) FROM ingest_receipts
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (upsert_payload.payload_id, upsert_payload.payload_partition_month),
    ).fetchone()[0] != 0:
        fail("upsert rollback did not remove its receipt")
    print("PASS evaluator rolls back receipt and dedup changes together")


def _evaluate_null_history(conn, source_id, endpoint_id, device_id):
    first_payload = _new_evaluation_payload(
        conn, source_id, endpoint_id, device_id, "null-history",
        datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc), b"\x10-null-first",
    )
    first = evaluate_item(conn, first_payload.payload_id, first_payload.payload_partition_month, 0)
    conn.execute(
        """
        UPDATE ingest_message_keys
        SET last_received_at = NULL, delivery_count = NULL
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'null-history' AND item_index = 0
        """,
        (source_id,),
    )
    second_payload = _new_evaluation_payload(
        conn, source_id, endpoint_id, device_id, "null-history",
        datetime(2026, 11, 21, 12, 1, tzinfo=timezone.utc), b"\x11-null-second",
    )
    second = evaluate_item(conn, second_payload.payload_id, second_payload.payload_partition_month, 0)
    row = conn.execute(
        """
        SELECT first_received_at, last_received_at, delivery_count, receipt_id
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'null-history' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()
    if row != (
        datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc),
        datetime(2026, 11, 21, 12, 1, tzinfo=timezone.utc),
        2,
        first.receipt_id,
    ):
        fail(f"NULL historical fields were not handled safely: {row}")
    if second.receipt_status != "duplicate_delivery":
        fail(f"NULL historical key did not produce a duplicate receipt: {second}")
    print("PASS evaluator handles NULL historical dedup fields conservatively")


def _receipt_count_for_item(conn, payload_id, payload_partition_month, item_index):
    return conn.execute(
        """
        SELECT count(*) FROM ingest_receipts
        WHERE payload_id = %s
          AND payload_partition_month = %s
          AND item_index = %s
        """,
        (payload_id, payload_partition_month, item_index),
    ).fetchone()[0]


def _evaluate_tx1_idempotence(conn, source_id, endpoint_id, device_id):
    keyed = _new_evaluation_payload(
        conn,
        source_id,
        endpoint_id,
        device_id,
        "tx1-idempotent",
        datetime(2026, 11, 22, 8, 0, tzinfo=timezone.utc),
        b"\x20-tx1-keyed",
    )
    first = evaluate_item(conn, keyed.payload_id, keyed.payload_partition_month, 0)
    second = evaluate_item(conn, keyed.payload_id, keyed.payload_partition_month, 0)
    if second != first:
        fail(f"repeated keyed TX1 evaluate changed result: {first} -> {second}")
    if _receipt_count_for_item(
        conn, keyed.payload_id, keyed.payload_partition_month, 0
    ) != 1:
        fail("repeated keyed TX1 evaluate created another receipt")
    keyed_count = conn.execute(
        """
        SELECT delivery_count FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'tx1-idempotent' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()[0]
    if keyed_count != 1:
        fail(f"repeated keyed TX1 evaluate changed delivery_count: {keyed_count}")

    unkeyed = accept(
        Envelope(
            source_id,
            "https",
            datetime(2026, 11, 22, 8, 5, tzinfo=timezone.utc),
            b"\x21-tx1-unkeyed",
            (Item(index=0, original=b"\x21-tx1-unkeyed", message_kind="raw_wmbus"),),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    first_unkeyed = evaluate_item(
        conn, unkeyed.payload_id, unkeyed.payload_partition_month, 0
    )
    second_unkeyed = evaluate_item(
        conn, unkeyed.payload_id, unkeyed.payload_partition_month, 0
    )
    if second_unkeyed != first_unkeyed:
        fail(
            "repeated unkeyed TX1 evaluate changed result: "
            f"{first_unkeyed} -> {second_unkeyed}"
        )
    if _receipt_count_for_item(
        conn, unkeyed.payload_id, unkeyed.payload_partition_month, 0
    ) != 1:
        fail("repeated unkeyed TX1 evaluate created another receipt")
    print("PASS evaluator is idempotent for the same TX1 item")


def _evaluate_repeat_after_duplicate(conn, source_id, endpoint_id, device_id):
    key = "tx1-after-duplicate"
    payload_a = _new_evaluation_payload(
        conn,
        source_id,
        endpoint_id,
        device_id,
        key,
        datetime(2026, 11, 22, 9, 0, tzinfo=timezone.utc),
        b"\x22-payload-a",
    )
    result_a = evaluate_item(conn, payload_a.payload_id, payload_a.payload_partition_month, 0)
    payload_b = _new_evaluation_payload(
        conn,
        source_id,
        endpoint_id,
        device_id,
        key,
        datetime(2026, 11, 22, 9, 1, tzinfo=timezone.utc),
        b"\x23-payload-b",
    )
    result_b = evaluate_item(conn, payload_b.payload_id, payload_b.payload_partition_month, 0)
    if (
        result_b.receipt_status != "duplicate_delivery"
        or result_b.first_delivery
        or result_b.outcome != result_a.outcome
        or result_b.original_receipt_id != result_a.receipt_id
        or result_b.receipt_id == result_a.receipt_id
    ):
        fail(f"payload B duplicate result is wrong: {result_b}")
    before = conn.execute(
        """
        SELECT delivery_count FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = %s AND item_index = 0
        """,
        (source_id, key),
    ).fetchone()[0]
    repeated_b = evaluate_item(
        conn, payload_b.payload_id, payload_b.payload_partition_month, 0
    )
    if repeated_b != result_b:
        fail(f"repeated evaluate of payload B changed result: {result_b} -> {repeated_b}")
    if _receipt_count_for_item(
        conn, payload_b.payload_id, payload_b.payload_partition_month, 0
    ) != 1:
        fail("repeated evaluate of payload B created another receipt")
    after = conn.execute(
        """
        SELECT delivery_count FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = %s AND item_index = 0
        """,
        (source_id, key),
    ).fetchone()[0]
    if after != before or after != 2:
        fail(f"repeated evaluate of payload B changed delivery_count: {before} -> {after}")
    print("PASS repeated evaluate of duplicate_delivery TX1 item returns the same result")


def _evaluate_selected_item(conn, source_id, endpoint_id, device_id):
    first_body = b"\x14-invalid-other-item"
    selected_body = b"\x15-selected-item"
    stored = accept(
        Envelope(
            source_id,
            "https",
            datetime(2026, 11, 21, 12, 30, tzinfo=timezone.utc),
            b"\x16-selected-envelope",
            (
                Item(index=0, original=first_body, message_kind="not-a-kind"),
                Item(
                    index=1,
                    original=selected_body,
                    message_kind="raw_wmbus",
                    msg_key="selected-index",
                    msg_key_namespace="https",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    result = evaluate_item(conn, stored.payload_id, stored.payload_partition_month, 1)
    if result.receipt_status != "accepted" or not result.first_delivery:
        fail(f"selected valid item was affected by another item: {result}")
    receipt = conn.execute(
        """
        SELECT item_index, status FROM ingest_receipts
        WHERE id = %s AND partition_month = %s
        """,
        (result.receipt_id, result.receipt_partition_month),
    ).fetchone()
    if receipt != (1, "accepted"):
        fail(f"original item index was not preserved in receipt: {receipt}")
    key = conn.execute(
        """
        SELECT item_index FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'selected-index'
        """,
        (source_id,),
    ).fetchone()
    if key != (1,):
        fail(f"original item index was not preserved in dedup key: {key}")
    print("PASS evaluator validates only the selected item and preserves its index")


class _BarrierConnection:
    def __init__(self, conn, barrier, wait_needle="INSERT INTO ingest_message_keys"):
        self._conn = conn
        self._barrier = barrier
        self._wait_needle = wait_needle

    @property
    def autocommit(self):
        return self._conn.autocommit

    def execute(self, query, params=None):
        if self._wait_needle in query:
            self._barrier.wait(timeout=10)
        if params is None:
            return self._conn.execute(query)
        return self._conn.execute(query, params)

    def transaction(self):
        return self._conn.transaction()


def _evaluate_concurrent(conn, source_id, endpoint_id, device_id):
    body_a = b"\x0c-concurrent-a"
    body_b = b"\x0d-concurrent-b"
    payloads = []
    for body in (body_a, body_b):
        result = accept(
            Envelope(
                source_id,
                "https",
                datetime(2026, 11, 21, 10, 0, tzinfo=timezone.utc),
                body,
                (
                    Item(
                        index=0,
                        original=body,
                        message_kind="raw_wmbus",
                        msg_key="concurrent-key",
                        msg_key_namespace="https",
                    ),
                ),
                endpoint_id=endpoint_id,
                device_id=device_id,
            ),
            conn,
        )
        payloads.append((result.payload_id, result.payload_partition_month))

    barrier = threading.Barrier(2)
    results = []
    errors = []

    def run(payload):
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other_user = other.execute("SELECT current_user").fetchone()[0]
                other.execute("SET ROLE sjv_collector")
                if other.execute("SELECT current_user").fetchone()[0] != "sjv_collector":
                    raise AssertionError(f"concurrent connection role is {other_user}")
                results.append(evaluate_item(_BarrierConnection(other, barrier), *payload, 0))
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover - reported by the test
            errors.append(exc)

    threads = [threading.Thread(target=run, args=(payload,)) for payload in payloads]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=20)
    if errors or len(results) != 2 or any(thread.is_alive() for thread in threads):
        fail(f"concurrent evaluation failed: {errors}, results={results}")
    row = conn.execute(
        """
        SELECT delivery_count, first_received_at, last_received_at
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'concurrent-key' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()
    if row != (2, datetime(2026, 11, 21, 10, 0, tzinfo=timezone.utc),
               datetime(2026, 11, 21, 10, 0, tzinfo=timezone.utc)):
        fail(f"concurrent upsert lost an update: {row}")
    if sum(result.first_delivery for result in results) != 1:
        fail(f"concurrent first-delivery count is wrong: {results}")
    if sum(not result.first_delivery for result in results) != 1:
        fail(f"concurrent duplicate-delivery count is wrong: {results}")
    first = next(result for result in results if result.first_delivery)
    duplicate = next(result for result in results if not result.first_delivery)
    if first.receipt_status != "accepted" or duplicate.receipt_status != "duplicate_delivery":
        fail(f"concurrent receipt statuses are wrong: {results}")
    if {result.outcome for result in results} != {"accepted"}:
        fail(f"concurrent outcomes differ: {results}")
    if (
        first.original_receipt_id != first.receipt_id
        or first.original_receipt_partition_month != first.receipt_partition_month
    ):
        fail(f"first concurrent result does not reference itself: {first}")
    if (
        duplicate.original_receipt_id != first.receipt_id
        or duplicate.original_receipt_partition_month != first.receipt_partition_month
    ):
        fail(f"duplicate concurrent result does not reference the first receipt: {duplicate}")
    if len({result.receipt_id for result in results}) != 2:
        fail(f"concurrent deliveries did not get separate receipts: {results}")
    key = conn.execute(
        """
        SELECT receipt_id, receipt_partition_month
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'concurrent-key' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()
    if key != (first.original_receipt_id, first.original_receipt_partition_month):
        fail(f"dedup key does not point to the first concurrent receipt: {key}")
    if key != (first.receipt_id, first.receipt_partition_month):
        fail(f"first concurrent receipt reference is wrong: {key}")
    print("PASS concurrent evaluator upserts serialize without lost delivery")
    _evaluate_concurrent_duplicates(conn, source_id, endpoint_id, device_id)


def _evaluate_concurrent_duplicates(conn, source_id, endpoint_id, device_id):
    key = "concurrent-duplicate"
    seed = _new_evaluation_payload(
        conn, source_id, endpoint_id, device_id, key,
        datetime(2026, 11, 21, 10, 30, tzinfo=timezone.utc), b"\x12-seed",
    )
    original = evaluate_item(conn, seed.payload_id, seed.payload_partition_month, 0)
    deliveries = []
    timestamps = (
        datetime(2026, 11, 21, 10, 29, tzinfo=timezone.utc),
        datetime(2026, 11, 21, 10, 31, tzinfo=timezone.utc),
        datetime(2026, 11, 21, 10, 30, 30, tzinfo=timezone.utc),
    )
    for index, stamp in enumerate(timestamps):
        payload = _new_evaluation_payload(
            conn, source_id, endpoint_id, device_id, key, stamp,
            f"\x13-duplicate-{index}".encode(),
        )
        deliveries.append((payload.payload_id, payload.payload_partition_month))

    barrier = threading.Barrier(len(deliveries))
    results = []
    errors = []

    def run(payload):
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other_user = other.execute("SELECT current_user").fetchone()[0]
                other.execute("SET ROLE sjv_collector")
                if other.execute("SELECT current_user").fetchone()[0] != "sjv_collector":
                    raise AssertionError(f"duplicate connection role is {other_user}")
                results.append(evaluate_item(_BarrierConnection(other, barrier), *payload, 0))
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover - reported by the test
            errors.append(exc)

    threads = [threading.Thread(target=run, args=(payload,)) for payload in deliveries]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=20)
    if errors or len(results) != len(deliveries) or any(thread.is_alive() for thread in threads):
        fail(f"concurrent duplicate evaluation failed: {errors}, results={results}")
    if any(result.first_delivery for result in results):
        fail(f"concurrent duplicate was reported as first delivery: {results}")
    if any(result.receipt_status != "duplicate_delivery" for result in results):
        fail(f"concurrent duplicate receipt status is wrong: {results}")
    if any(result.outcome != original.outcome for result in results):
        fail(f"concurrent duplicate outcome changed: {results}")
    if any(result.original_receipt_id != original.receipt_id for result in results):
        fail(f"concurrent duplicate receipt reference changed: {results}")
    row = conn.execute(
        """
        SELECT delivery_count, last_received_at, receipt_id, receipt_partition_month,
               outcome
        FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = %s AND item_index = 0
        """,
        (source_id, key),
    ).fetchone()
    if row != (
        4,
        max(timestamps),
        original.receipt_id,
        original.receipt_partition_month,
        original.outcome,
    ):
        fail(f"concurrent duplicate update is wrong: {row}")
    receipt_ids = {result.receipt_id for result in results}
    if len(receipt_ids) != len(deliveries):
        fail(f"concurrent duplicate receipts were merged: {results}")
    print("PASS concurrent duplicate deliveries preserve outcome and count")


def _run_concurrent_evaluate(payloads, wait_needle, item_indexes=None):
    if item_indexes is None:
        item_indexes = (0,) * len(payloads)
    barrier = threading.Barrier(len(payloads))
    results = []
    errors = []

    def run(payload, item_index):
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other.execute("SET ROLE sjv_collector")
                if other.execute("SELECT current_user").fetchone()[0] != "sjv_collector":
                    raise AssertionError("concurrent connection is not sjv_collector")
                wrapped = _BarrierConnection(other, barrier, wait_needle=wait_needle)
                results.append(evaluate_item(wrapped, *payload, item_index))
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover - reported by the test
            errors.append(exc)

    threads = [
        threading.Thread(target=run, args=(payload, item_index))
        for payload, item_index in zip(payloads, item_indexes)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=20)
    if errors or len(results) != len(payloads) or any(thread.is_alive() for thread in threads):
        fail(f"concurrent TX1 evaluation failed: {errors}, results={results}")
    return results


def _evaluate_concurrent_same_tx1(conn, source_id, endpoint_id, device_id):
    keyed = _new_evaluation_payload(
        conn,
        source_id,
        endpoint_id,
        device_id,
        "tx1-concurrent-key",
        datetime(2026, 11, 22, 10, 0, tzinfo=timezone.utc),
        b"\x24-tx1-concurrent-keyed",
    )
    keyed_payload = (keyed.payload_id, keyed.payload_partition_month)
    keyed_results = _run_concurrent_evaluate(
        (keyed_payload, keyed_payload),
        wait_needle="pg_advisory_xact_lock",
    )
    if len({result.receipt_id for result in keyed_results}) != 1:
        fail(f"concurrent keyed TX1 created multiple receipts: {keyed_results}")
    if _receipt_count_for_item(conn, *keyed_payload, 0) != 1:
        fail("concurrent keyed TX1 left more than one receipt")
    if keyed_results[0] != keyed_results[1]:
        fail(f"concurrent keyed TX1 results differ: {keyed_results}")
    keyed_count = conn.execute(
        """
        SELECT delivery_count FROM ingest_message_keys
        WHERE ingest_source_id = %s AND msg_key_namespace = 'https'
          AND msg_key = 'tx1-concurrent-key' AND item_index = 0
        """,
        (source_id,),
    ).fetchone()[0]
    if keyed_count != 1:
        fail(f"concurrent keyed TX1 changed delivery_count: {keyed_count}")

    unkeyed = accept(
        Envelope(
            source_id,
            "https",
            datetime(2026, 11, 22, 10, 5, tzinfo=timezone.utc),
            b"\x25-tx1-concurrent-unkeyed",
            (
                Item(
                    index=0,
                    original=b"\x25-tx1-concurrent-unkeyed",
                    message_kind="raw_wmbus",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    unkeyed_payload = (unkeyed.payload_id, unkeyed.payload_partition_month)
    unkeyed_results = _run_concurrent_evaluate(
        (unkeyed_payload, unkeyed_payload),
        wait_needle="pg_advisory_xact_lock",
    )
    if len({result.receipt_id for result in unkeyed_results}) != 1:
        fail(f"concurrent unkeyed TX1 created multiple receipts: {unkeyed_results}")
    if _receipt_count_for_item(conn, *unkeyed_payload, 0) != 1:
        fail("concurrent unkeyed TX1 left more than one receipt")

    multi = accept(
        Envelope(
            source_id,
            "https",
            datetime(2026, 11, 22, 10, 10, tzinfo=timezone.utc),
            b"\x26-tx1-parallel-items",
            (
                Item(
                    index=0,
                    original=b"\x26-item-0",
                    message_kind="raw_wmbus",
                    msg_key="tx1-parallel-0",
                    msg_key_namespace="https",
                ),
                Item(
                    index=1,
                    original=b"\x26-item-1",
                    message_kind="raw_wmbus",
                    msg_key="tx1-parallel-1",
                    msg_key_namespace="https",
                ),
            ),
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )
    multi_payload = (multi.payload_id, multi.payload_partition_month)
    parallel = _run_concurrent_evaluate(
        (multi_payload, multi_payload),
        wait_needle="pg_advisory_xact_lock",
        item_indexes=(0, 1),
    )
    if {result.item_index for result in parallel} != {0, 1}:
        fail(f"parallel item indexes were not both evaluated: {parallel}")
    if len({result.receipt_id for result in parallel}) != 2:
        fail(f"parallel item indexes did not get separate receipts: {parallel}")
    print("PASS concurrent evaluators serialize the same TX1 item and keep indexes parallel")


def _evaluate_advisory_lock_sql(conn):
    params = {
        "payload_id": 1,
        "payload_partition_month": datetime(2026, 11, 1, tzinfo=timezone.utc).date(),
        "item_index": 0,
    }
    key = conn.execute(
        """
        SELECT decode(
          substr(
            md5(
              'sjv.evaluate_item.v1|'
              || %(payload_id)s::text || '|'
              || to_char(%(payload_partition_month)s::date, 'YYYY-MM-DD') || '|'
              || %(item_index)s::text
            ),
            1,
            16
          ),
          'hex'
        )::bigint
        """,
        params,
    ).fetchone()[0]
    if not isinstance(key, int):
        fail(f"advisory lock key is not bigint-compatible: {key!r}")
    with conn.transaction():
        conn.execute(_ADVISORY_LOCK_SQL, params)
        again = conn.execute(
            """
            SELECT decode(
              substr(
                md5(
                  'sjv.evaluate_item.v1|'
                  || %(payload_id)s::text || '|'
                  || to_char(%(payload_partition_month)s::date, 'YYYY-MM-DD') || '|'
                  || %(item_index)s::text
                ),
                1,
                16
              ),
              'hex'
            )::bigint
            """,
            params,
        ).fetchone()[0]
        if again != key:
            fail(f"advisory lock key is not stable: {key} -> {again}")
    print("PASS evaluate_item advisory lock SQL converts md5 to bigint on PostgreSQL")


def _boolean_is_not_proof(conn, source_id, endpoint_id, device_id):
    original = b"\x09boolean-flag"
    body = b"\x09item"
    keys_before = conn.execute("SELECT count(*) FROM ingest_message_keys").fetchone()[0]
    result = accept(
        envelope(
            source_id,
            endpoint_id,
            device_id,
            original,
            one_item(
                body,
                msg_key="9f3c51a07be2d410-17-104233",
                msg_key_namespace="https",
                identifier_proven=True,
            ),
        ),
        conn,
    )
    row = conn.execute(
        """
        SELECT identifier_proven, msg_key, msg_key_namespace, proof_basis
        FROM ingest_payload_items
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (result.payload_id, result.payload_partition_month),
    ).fetchone()
    keys_after = conn.execute("SELECT count(*) FROM ingest_message_keys").fetchone()[0]
    if row != (True, "9f3c51a07be2d410-17-104233", "https", None) or keys_after != keys_before:
        fail(f"boolean flag was stored as a proof: {row}, keys {keys_before} -> {keys_after}")
    print("PASS identifier_proven does not set proof_basis")


def _item_failure(conn, source_id, endpoint_id, device_id):
    original = b"\x08two-items"
    first = b"\x08item-a"
    second = b"\x08item-b"
    items = (
        Item(index=0, original=first, message_kind="raw_wmbus"),
        Item(index=1, original=second, message_kind="raw_wmbus"),
    )
    try:
        accept(
            envelope(source_id, endpoint_id, device_id, original, items),
            Recording(conn, fail_on_second_item=True),
        )
    except RuntimeError as exc:
        if str(exc) != "forced item failure":
            fail(f"unexpected item failure: {exc}")
    else:
        fail("item failure returned a result")
    if payload_count(conn, original) != 0:
        fail("failed item insert left the payload stored")
    left = conn.execute(
        "SELECT count(*) FROM ingest_payload_items WHERE original = %s",
        (first,),
    ).fetchone()[0]
    if left != 0:
        fail("failed item insert left an item without its payload")
    print("PASS item insert failure rolls back the payload")


def _empty(conn, source_id, endpoint_id, device_id):
    original = b"\x02empty-envelope\x00"
    recorder = Recording(conn)
    result = accept(envelope(source_id, endpoint_id, device_id, original, ()), recorder)
    payload_at = next(i for i, sql in enumerate(recorder.statements) if "INTO ingest_payloads" in sql)
    receipt_at = next(i for i, sql in enumerate(recorder.statements) if "INTO ingest_receipts" in sql)
    if any("INTO ingest_payload_items" in sql for sql in recorder.statements):
        fail("empty envelope stored an item")
    if payload_at >= receipt_at or recorder.transactions != 2:
        fail("empty envelope did not commit the payload before its receipt")
    if result.awaiting_evaluation or result.receipt_status != "invalid":
        fail(f"empty result is {result}")
    row = conn.execute(
        """
        SELECT payloads.payload, receipts.status, receipts.item_index, receipts.msg_key,
               receipts.message_kind, receipts.payload_id, receipts.payload_partition_month,
               receipts.content_hash = sha256(payloads.payload)
        FROM ingest_payloads AS payloads
        JOIN ingest_receipts AS receipts
          ON receipts.payload_id = payloads.id
         AND receipts.payload_partition_month = payloads.partition_month
        WHERE payloads.id = %s AND payloads.partition_month = %s
        """,
        (result.payload_id, result.payload_partition_month),
    ).fetchone()
    expected = (
        original,
        "invalid",
        -1,
        None,
        None,
        result.payload_id,
        result.payload_partition_month,
        True,
    )
    if row != expected:
        fail(f"empty envelope storage differs: {row}")
    if receipt_count(conn, result.payload_id, result.payload_partition_month) != 1:
        fail("empty envelope did not store exactly one receipt")
    print("PASS empty envelope commits an invalid receipt with item_index -1")


def _unknown_format(conn, source_id, endpoint_id, device_id):
    original = b"\xff\xfe unknown-format \x00"
    frame = b"\x2a\x44\xff"
    result = accept(
        envelope(
            source_id,
            endpoint_id,
            device_id,
            original,
            one_item(original, frame=Frame(original=frame, frame_format="Z")),
        ),
        conn,
    )
    stored = conn.execute(
        "SELECT payload FROM ingest_payloads WHERE id = %s AND partition_month = %s",
        (result.payload_id, result.payload_partition_month),
    ).fetchone()[0]
    if stored != original or not result.awaiting_evaluation:
        fail("unknown format did not keep the original bytes")
    if receipt_count(conn, result.payload_id, result.payload_partition_month) != 0:
        fail("unknown format wrote a receipt before evaluation")
    print("PASS unknown frame format keeps the original bytes")


def _unknown_kind(conn, source_id, endpoint_id, device_id):
    original = b"\x03unknown-kind\xff"
    result = accept(
        envelope(
            source_id,
            endpoint_id,
            device_id,
            original,
            one_item(original, message_kind="vendor_private"),
        ),
        conn,
    )
    stored = conn.execute(
        "SELECT payload FROM ingest_payloads WHERE id = %s AND partition_month = %s",
        (result.payload_id, result.payload_partition_month),
    ).fetchone()[0]
    if stored != original or not result.awaiting_evaluation:
        fail("unknown message_kind lost the payload")
    if receipt_count(conn, result.payload_id, result.payload_partition_month) != 0:
        fail("unknown message_kind was written into a receipt")
    kind = conn.execute(
        """
        SELECT original, message_kind
        FROM ingest_payload_items
        WHERE payload_id = %s AND payload_partition_month = %s
        """,
        (result.payload_id, result.payload_partition_month),
    ).fetchone()
    if kind != (original, "vendor_private"):
        fail(f"unknown message_kind was not kept on the item: {kind}")
    print("PASS unknown message_kind keeps the payload")


def _rejected(conn, endpoint_id, device_id):
    original = b"\x04missing-source"
    try:
        accept(envelope(None, endpoint_id, device_id, original, one_item(original)), conn)
    except IngestRejected as exc:
        if "missing_ingest_source" not in str(exc):
            fail(f"rejection did not name the missing source: {exc}")
    else:
        fail("missing source was stored")
    if payload_count(conn, original) != 0:
        fail("rejected envelope was stored")
    print("PASS blocking validation stores nothing")


def _rollback(conn, source_id, endpoint_id, device_id):
    original = b"\x05rollback-payload"
    try:
        accept(
            envelope(source_id, endpoint_id, device_id, original, ()),
            Recording(conn, fail_on_receipt=True),
        )
    except RuntimeError as exc:
        if str(exc) != "forced receipt failure":
            fail(f"unexpected rollback error: {exc}")
    else:
        fail("receipt failure returned a result")
    if payload_count(conn, original) != 1:
        fail("evaluation rollback removed the payload")
    receipt_rows = conn.execute(
        "SELECT count(*) FROM ingest_receipts WHERE content_hash = sha256(%s)",
        (original,),
    ).fetchone()[0]
    if receipt_rows != 0:
        fail("rolled back receipt stayed stored")
    print("PASS evaluation failure keeps the payload and returns no result")


def _repeat(conn, source_id, endpoint_id, device_id):
    first = b"\x06repeat-same"
    second = b"\x07repeat-other"
    accept(envelope(source_id, endpoint_id, device_id, first, one_item(first)), conn)
    accept(envelope(source_id, endpoint_id, device_id, first, one_item(first)), conn)
    accept(envelope(source_id, endpoint_id, device_id, second, one_item(second)), conn)
    if payload_count(conn, first) != 2 or payload_count(conn, second) != 1:
        fail("repeated delivery merged payloads by hash")
    stored = conn.execute(
        "SELECT count(*) FROM ingest_payloads WHERE payload = %s",
        (first,),
    ).fetchone()[0]
    if stored != 2:
        fail("repeated accept rewrote the first payload")
    print("PASS repeated delivery stores a new payload and does not merge by hash")


if __name__ == "__main__":
    main()
