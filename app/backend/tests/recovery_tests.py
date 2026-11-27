"""Isolated DB checks for TX1 recovery. Requires SJV_DATABASE_URL."""

from __future__ import annotations

import os
import threading
from datetime import date, datetime, timezone

import psycopg
from psycopg.errors import DeadlockDetected, SerializationFailure

from sjv_ingest.contract import Envelope, Item
from sjv_ingest.evaluator import evaluate_item
from sjv_ingest.recovery import (
    RunAbort,
    Tx1ItemRef,
    _CONNECTION_UNUSABLE_ATTR,
    fetch_unfinished,
    recover_month,
    recover_run,
)
from sjv_ingest.service import accept

URL = os.environ["SJV_DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)


def fail(message):
    raise SystemExit(message)


def month_start(stamp: datetime) -> date:
    utc = stamp.astimezone(timezone.utc)
    return date(utc.year, utc.month, 1)


def ensure_partitions(conn, month: date):
    """Create month partitions as the bootstrap/maintenance-capable role."""

    conn.execute("RESET ROLE")
    for parent in ("ingest_payloads", "ingest_payload_items", "ingest_receipts"):
        conn.execute(
            "SELECT sjv_create_month_partition(%s::regclass, %s)",
            (parent, month),
        )
    conn.execute("SET ROLE sjv_collector")


def receipt_count_for_item(conn, payload_id, payload_month, item_index):
    return conn.execute(
        """
        SELECT count(*) FROM ingest_receipts
        WHERE payload_id = %s
          AND payload_partition_month = %s
          AND item_index = %s
        """,
        (payload_id, payload_month, item_index),
    ).fetchone()[0]


def unfinished_count(conn, partition_month):
    return len(fetch_unfinished(conn, partition_month, after=None, batch_size=10000))


def bootstrap_fixture(conn, stamp: str):
    device_code = f"recv-dev-{stamp}"
    endpoint_code = f"recv-ep-{stamp}"
    source_code = f"recv-src-{stamp}"
    conn.execute(
        "INSERT INTO devices (code, kind, status) VALUES (%s, 'esp32', 'active')",
        (device_code,),
    )
    conn.execute(
        "INSERT INTO ingest_endpoints (code, transport, status) "
        "VALUES (%s, 'https', 'active')",
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
    conn.execute("SET ROLE sjv_collector")
    conn.execute(
        "INSERT INTO ingest_sources (code, kind, device_id) "
        "SELECT %s, 'device', id FROM devices WHERE code = %s",
        (source_code, device_code),
    )
    source_id = conn.execute(
        "SELECT id FROM ingest_sources WHERE code = %s",
        (source_code,),
    ).fetchone()[0]
    return source_id, endpoint_id, device_id


def accept_items(conn, source_id, endpoint_id, device_id, stamp, bodies, *, received_at=None):
    if received_at is None:
        received_at = datetime.now(timezone.utc)
    items = tuple(
        Item(
            index=index,
            original=body,
            message_kind="raw_wmbus",
            msg_key=f"recv-{stamp}-{index}",
            msg_key_namespace="https",
        )
        for index, body in enumerate(bodies)
    )
    return accept(
        Envelope(
            source_id,
            "https",
            received_at,
            b"recv-envelope-" + stamp.encode() + bodies[0],
            items,
            endpoint_id=endpoint_id,
            device_id=device_id,
        ),
        conn,
    )


def insert_explicit_payload_item(conn, source_id, endpoint_id, device_id, payload_id, month, body):
    """Insert payload/item with an explicit id (0 or negative allowed)."""

    ensure_partitions(conn, month)
    received_at = datetime(month.year, month.month, 15, 12, 0, tzinfo=timezone.utc)
    conn.execute(
        """
        INSERT INTO ingest_payloads (
            id, partition_month, ingest_source_id, endpoint_id, device_id,
            transport, received_at, content_kind, payload, origin
        ) VALUES (
            %(id)s, %(month)s, %(source_id)s, %(endpoint_id)s, %(device_id)s,
            'https', %(received_at)s, 'opaque', %(payload)s, 'received'
        )
        """,
        {
            "id": payload_id,
            "month": month,
            "source_id": source_id,
            "endpoint_id": endpoint_id,
            "device_id": device_id,
            "received_at": received_at,
            "payload": body,
        },
    )
    conn.execute(
        """
        INSERT INTO ingest_payload_items (
            partition_month, payload_id, payload_partition_month, item_index, original
        ) VALUES (%(month)s, %(id)s, %(month)s, 0, %(body)s)
        """,
        {"month": month, "id": payload_id, "body": body},
    )


def main():
    with psycopg.connect(URL, autocommit=True) as conn:
        stamp = datetime.now(timezone.utc).strftime("%H%M%S%f")
        source_id, endpoint_id, device_id = bootstrap_fixture(conn, stamp)
        try:
            _first_page_zero_and_negative(conn, source_id, endpoint_id, device_id, stamp)
            _keyset_next_pages(conn, source_id, endpoint_id, device_id, stamp)
            _multi_item_and_existing_receipt(conn, source_id, endpoint_id, device_id, stamp)
            _historical_duplicate_receipts(conn, source_id, endpoint_id, device_id, stamp)
            _item_error_continues(conn, source_id, endpoint_id, device_id, stamp)
            _injected_db_errors(conn, source_id, endpoint_id, device_id, stamp)
            _insufficient_privilege_aborts(conn, source_id, endpoint_id, device_id, stamp)
            _concurrent_recovery(conn, source_id, endpoint_id, device_id, stamp)
            _concurrent_with_evaluator(conn, source_id, endpoint_id, device_id, stamp)
            _crash_and_rerun(conn, source_id, endpoint_id, device_id, stamp)
            _partition_restriction(conn, source_id, endpoint_id, device_id, stamp)
        finally:
            conn.execute("RESET ROLE")
        print("PASS recovery integration suite")


def _first_page_zero_and_negative(conn, source_id, endpoint_id, device_id, stamp):
    month = month_start(datetime.now(timezone.utc))
    insert_explicit_payload_item(
        conn, source_id, endpoint_id, device_id, -7, month, b"\x01neg-" + stamp.encode()
    )
    insert_explicit_payload_item(
        conn, source_id, endpoint_id, device_id, 0, month, b"\x01zero-" + stamp.encode()
    )
    page = fetch_unfinished(conn, month, after=None, batch_size=10000)
    ids = {item.payload_id for item in page}
    if -7 not in ids or 0 not in ids:
        fail(f"first page missed zero/negative payload_id: {sorted(ids)[:20]}")
    print("PASS first page includes zero and negative payload_id")


def _keyset_next_pages(conn, source_id, endpoint_id, device_id, stamp):
    month = month_start(datetime.now(timezone.utc))
    stored = []
    for index in range(4):
        stored.append(
            accept_items(
                conn,
                source_id,
                endpoint_id,
                device_id,
                f"{stamp}-p{index}",
                (f"\x02page-{index}".encode(),),
            )
        )
    first = fetch_unfinished(conn, month, after=None, batch_size=2)
    if len(first) != 2:
        fail(f"expected first keyset page of 2, got {len(first)}")
    second = fetch_unfinished(conn, month, after=first[-1], batch_size=2)
    if not second:
        fail("second keyset page was empty")
    if second[0] <= first[-1]:
        fail(f"keyset did not advance: after={first[-1]} next={second[0]}")
    overlap = set(first) & set(second)
    if overlap:
        fail(f"keyset pages overlapped: {overlap}")
    print("PASS keyset next pages")


def _multi_item_and_existing_receipt(conn, source_id, endpoint_id, device_id, stamp):
    stored = accept_items(
        conn,
        source_id,
        endpoint_id,
        device_id,
        f"{stamp}-multi",
        (b"\x03a", b"\x03b", b"\x03c"),
    )
    month = stored.payload_partition_month
    evaluate_item(conn, stored.payload_id, month, 0)
    before = unfinished_count(conn, month)
    metrics = recover_month(conn, month, batch_size=50)
    if metrics.evaluated < 2:
        fail(f"multi-item recovery evaluated too few: {metrics}")
    for item_index in (0, 1, 2):
        if receipt_count_for_item(conn, stored.payload_id, month, item_index) != 1:
            fail(f"expected one receipt for item {item_index}")
    # Existing receipt must not create another
    again = evaluate_item(conn, stored.payload_id, month, 0)
    if receipt_count_for_item(conn, stored.payload_id, month, 0) != 1:
        fail("existing receipt path created another receipt")
    if again.item_index != 0:
        fail(f"short-circuit result wrong: {again}")
    after = unfinished_count(conn, month)
    if after > before:
        fail("recovery increased unfinished count")
    print("PASS multi-item recovery and existing receipt")


def _historical_duplicate_receipts(conn, source_id, endpoint_id, device_id, stamp):
    stored = accept_items(
        conn,
        source_id,
        endpoint_id,
        device_id,
        f"{stamp}-dup",
        (b"\x04dup",),
    )
    month = stored.payload_partition_month
    evaluate_item(conn, stored.payload_id, month, 0)
    # Second historical receipt for the same TX1 identity (anomaly).
    conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, endpoint_id, device_id,
            transport, status
        )
        SELECT
            partition_month, server_received_at + interval '1 second', payload_id,
            payload_partition_month, content_hash, item_index, ingest_source_id,
            endpoint_id, device_id, transport, status
        FROM ingest_receipts
        WHERE payload_id = %s AND payload_partition_month = %s AND item_index = 0
        LIMIT 1
        """,
        (stored.payload_id, month),
    )
    if receipt_count_for_item(conn, stored.payload_id, month, 0) < 2:
        fail("failed to insert historical duplicate receipt")
    page = fetch_unfinished(conn, month, after=None, batch_size=10000)
    if any(
        item.payload_id == stored.payload_id and item.item_index == 0
        for item in page
    ):
        fail("item with duplicate receipts was selected as unfinished")
    metrics = recover_month(conn, month, batch_size=50)
    if receipt_count_for_item(conn, stored.payload_id, month, 0) < 2:
        fail("recovery removed or replaced historical duplicate receipts")
    print("PASS historical duplicate receipts stay unfinished-excluded")


def _item_error_continues(conn, source_id, endpoint_id, device_id, stamp):
    first = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-e1", (b"\x05one",)
    )
    second = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-e2", (b"\x05two",)
    )
    month = first.payload_partition_month
    poison = Tx1ItemRef(first.payload_id, month, 0)
    calls = []

    def evaluate(db, payload_id, payload_month, item_index):
        calls.append((payload_id, item_index))
        if payload_id == poison.payload_id:
            raise LookupError("stored item was not found")
        return evaluate_item(db, payload_id, payload_month, item_index)

    metrics = recover_month(conn, month, batch_size=100, evaluate=evaluate)
    if poison.payload_id not in {payload_id for payload_id, _ in calls}:
        fail("poison item was not attempted")
    if second.payload_id not in {payload_id for payload_id, _ in calls}:
        fail("recovery stopped after poison item")
    if metrics.permanent < 1:
        fail("poison was not counted as permanent")
    if receipt_count_for_item(conn, second.payload_id, month, 0) != 1:
        fail("item after poison was not evaluated")
    if receipt_count_for_item(conn, first.payload_id, month, 0) != 0:
        fail("poison LookupError created a false receipt")
    print("PASS item error continues without false receipt")


def _injected_db_errors(conn, source_id, endpoint_id, device_id, stamp):
    month = month_start(datetime.now(timezone.utc))
    target = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-db", (b"\x06db",)
    )
    follower = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-db2", (b"\x06db2",)
    )

    def deadlock_then_real(db, payload_id, payload_month, item_index):
        if payload_id == target.payload_id:
            raise DeadlockDetected("deadlock detected")
        return evaluate_item(db, payload_id, payload_month, item_index)

    metrics = recover_month(conn, month, batch_size=100, evaluate=deadlock_then_real)
    if metrics.retryable < 1:
        fail("deadlock was not retryable")
    if receipt_count_for_item(conn, follower.payload_id, month, 0) != 1:
        fail("follower after deadlock was not recovered")

    ser_target = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-ser", (b"\x06ser",)
    )

    def serialization_fail(db, payload_id, payload_month, item_index):
        if payload_id == ser_target.payload_id:
            raise SerializationFailure("could not serialize access")
        return evaluate_item(db, payload_id, payload_month, item_index)

    metrics = recover_month(conn, month, batch_size=100, evaluate=serialization_fail)
    if metrics.retryable < 1:
        fail("serialization failure was not retryable")

    lost = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-lost", (b"\x06lost",)
    )

    def connection_lost(db, payload_id, payload_month, item_index):
        if payload_id == lost.payload_id:
            raise psycopg.OperationalError("server closed the connection unexpectedly")
        return evaluate_item(db, payload_id, payload_month, item_index)

    try:
        recover_month(conn, month, batch_size=100, evaluate=connection_lost)
        fail("connection loss did not abort")
    except RunAbort:
        pass
    # Injected OperationalError marks the shared test connection; clear so later
    # scenarios can still use this healthy connection.
    if getattr(conn, _CONNECTION_UNUSABLE_ATTR, False):
        delattr(conn, _CONNECTION_UNUSABLE_ATTR)
    print("PASS injected deadlock/serialization/connection handling")


def _drain_unfinished(conn, month):
    """Finish every unfinished item in ``month`` so later tests start clean."""

    while True:
        batch = fetch_unfinished(conn, month, after=None, batch_size=100)
        if not batch:
            return
        for item in batch:
            evaluate_item(
                conn,
                item.payload_id,
                item.payload_partition_month,
                item.item_index,
            )


def _insufficient_privilege_aborts(conn, source_id, endpoint_id, device_id, stamp):
    """Abort must come from R20 ``UPDATE status`` (42501) on a known TX1 item."""

    month = month_start(datetime.now(timezone.utc))
    _drain_unfinished(conn, month)
    key = f"recv-priv-{stamp}"
    first = accept(
        Envelope(
            source_id,
            "https",
            datetime.now(timezone.utc),
            b"\x07priv-first-" + stamp.encode(),
            (
                Item(
                    index=0,
                    original=b"\x07priv-first-body",
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
    evaluate_item(conn, first.payload_id, first.payload_partition_month, 0)
    second = accept(
        Envelope(
            source_id,
            "https",
            datetime.now(timezone.utc),
            b"\x07priv-second-" + stamp.encode(),
            (
                Item(
                    index=0,
                    original=b"\x07priv-second-body",
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
    leftover = fetch_unfinished(conn, month, after=None, batch_size=10000)
    target_ids = {
        (item.payload_id, item.payload_partition_month, item.item_index)
        for item in leftover
    }
    expected = (second.payload_id, second.payload_partition_month, 0)
    if target_ids != {expected}:
        fail(f"privilege fixture unclean unfinished set: {target_ids}")

    seen = []
    raised = []

    def evaluate(db, payload_id, payload_month, item_index):
        seen.append((payload_id, payload_month, item_index))
        try:
            return evaluate_item(db, payload_id, payload_month, item_index)
        except psycopg.Error as exc:
            raised.append(exc)
            raise

    conn.execute("RESET ROLE")
    conn.execute("REVOKE UPDATE (status) ON ingest_receipts FROM sjv_collector")
    try:
        conn.execute("SET ROLE sjv_collector")
        try:
            recover_month(conn, month, batch_size=50, evaluate=evaluate)
            fail("missing UPDATE(status) privilege did not abort recovery")
        except RunAbort:
            pass
    finally:
        conn.execute("RESET ROLE")
        conn.execute("GRANT UPDATE (status) ON ingest_receipts TO sjv_collector")
        conn.execute("SET ROLE sjv_collector")

    if seen != [expected]:
        fail(f"privilege abort did not target second TX1 item: seen={seen}")
    if not raised or raised[0].sqlstate != "42501":
        fail(
            "privilege abort missing SQLSTATE 42501: "
            f"{raised[0].sqlstate if raised else None}"
        )
    # Finish the item for later tests.
    evaluate_item(conn, second.payload_id, second.payload_partition_month, 0)
    print("PASS insufficient privilege aborts on R20 UPDATE status")


def _concurrent_recovery(conn, source_id, endpoint_id, device_id, stamp):
    stored = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-c2", (b"\x08c2",)
    )
    month = stored.payload_partition_month
    barrier = threading.Barrier(2)
    errors = []

    def worker():
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other.execute("SET ROLE sjv_collector")
                barrier.wait(timeout=20)
                recover_month(other, month, batch_size=50)
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover - surfaced below
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
    if errors or any(thread.is_alive() for thread in threads):
        fail(f"concurrent recovery failed: {errors}")
    if receipt_count_for_item(conn, stored.payload_id, month, 0) != 1:
        fail("concurrent recovery left wrong receipt count")
    print("PASS concurrent recovery processes")


def _concurrent_with_evaluator(conn, source_id, endpoint_id, device_id, stamp):
    stored = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-ce", (b"\x09ce",)
    )
    month = stored.payload_partition_month
    barrier = threading.Barrier(2)
    errors = []

    def recovery_worker():
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other.execute("SET ROLE sjv_collector")
                barrier.wait(timeout=20)
                recover_month(other, month, batch_size=50)
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover
            errors.append(exc)

    def evaluator_worker():
        try:
            with psycopg.connect(URL, autocommit=True) as other:
                other.execute("SET ROLE sjv_collector")
                barrier.wait(timeout=20)
                evaluate_item(other, stored.payload_id, month, 0)
                other.execute("RESET ROLE")
        except Exception as exc:  # pragma: no cover
            errors.append(exc)

    threads = [
        threading.Thread(target=recovery_worker),
        threading.Thread(target=evaluator_worker),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
    if errors or any(thread.is_alive() for thread in threads):
        fail(f"recovery/evaluator concurrency failed: {errors}")
    if receipt_count_for_item(conn, stored.payload_id, month, 0) != 1:
        fail("recovery+evaluator concurrency created multiple receipts")
    print("PASS recovery concurrent with evaluator")


def _crash_and_rerun(conn, source_id, endpoint_id, device_id, stamp):
    first = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-cr1", (b"\x0acr1",)
    )
    second = accept_items(
        conn, source_id, endpoint_id, device_id, f"{stamp}-cr2", (b"\x0acr2",)
    )
    month = first.payload_partition_month
    # Simulate crash after first success: evaluate one item, leave the other.
    evaluate_item(conn, first.payload_id, month, 0)
    metrics = recover_run(conn, months=(month,), batch_size=50)
    if metrics.evaluated < 1:
        fail("rerun after partial progress evaluated nothing")
    if receipt_count_for_item(conn, second.payload_id, month, 0) != 1:
        fail("rerun did not finish remaining item")
    if receipt_count_for_item(conn, first.payload_id, month, 0) != 1:
        fail("rerun disturbed already committed item")
    print("PASS crash simulation and repeated run")


def _partition_restriction(conn, source_id, endpoint_id, device_id, stamp):
    now = datetime.now(timezone.utc)
    current = month_start(now)
    if current.month == 1:
        other = date(current.year - 1, 12, 1)
    else:
        other = date(current.year, current.month - 1, 1)
    ensure_partitions(conn, other)
    other_payload = accept_items(
        conn,
        source_id,
        endpoint_id,
        device_id,
        f"{stamp}-other",
        (b"\x0bother",),
        received_at=datetime(other.year, other.month, 10, 8, 0, tzinfo=timezone.utc),
    )
    current_payload = accept_items(
        conn,
        source_id,
        endpoint_id,
        device_id,
        f"{stamp}-cur",
        (b"\x0bcur",),
        received_at=now,
    )
    if other_payload.payload_partition_month != other:
        fail(f"other-month payload landed in {other_payload.payload_partition_month}")
    page = fetch_unfinished(conn, current, after=None, batch_size=10000)
    if any(item.payload_id == other_payload.payload_id for item in page):
        fail("current-month fetch returned other-month item")
    if not any(item.payload_id == current_payload.payload_id for item in page):
        fail("current-month fetch missed current item")
    # SQL text must bind the same partition for receipts.
    recorder = []

    class Recording:
        autocommit = True

        def execute(self, query, params=None):
            recorder.append((query, params))
            return conn.execute(query, params)

    fetch_unfinished(Recording(), current, after=None, batch_size=5)
    query, params = recorder[0]
    if params["partition_month"] != current:
        fail("partition bind mismatch")
    if query.count("partition_month = %(partition_month)s") < 2:
        fail("SQL does not constrain items and receipts partitions explicitly")
    print("PASS partition restriction")


if __name__ == "__main__":
    main()
