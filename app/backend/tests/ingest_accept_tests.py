"""Isolated checks for storing one envelope. The connection starts as the
bootstrap superuser only to create a device and an endpoint. ``accept``
itself runs as ``sjv_collector``.
"""

import os
from datetime import datetime, timezone

import psycopg

from sjv_ingest.contract import Envelope, Fragment, Frame, Item, SourceTime
from sjv_ingest.restore import load_envelope
from sjv_ingest.service import IngestRejected, accept

URL = os.environ["SJV_DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)
UNTOUCHED = (
    "telegram_dedup_keys",
    "raw_telegrams",
    "decode_queue",
    "ingest_message_keys",
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

        conn.execute("SET ROLE sjv_collector")
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
