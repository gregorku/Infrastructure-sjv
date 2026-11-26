"""Evaluate one item that was already durably stored by ``accept``.

The evaluator owns the receipt and message-key transaction.  It deliberately
does not send a transport response and it does not enqueue decoder work.
"""

from dataclasses import dataclass, replace
from datetime import date

from sjv_ingest.restore import load_envelope
from sjv_ingest.tx import ingest_transaction
from sjv_ingest.validate import INVALID_ITEM_INDEX, ValidationIssue, validate


_KEY_MESSAGE_KIND = {
    "raw_wmbus": "telegram",
    "decoded": "decoded",
    "event": "event",
    "heartbeat": "heartbeat",
    "import_row": "import_row",
}
_RECEIPT_MESSAGE_KINDS = frozenset(_KEY_MESSAGE_KIND)
_RECEIPT_TRANSPORTS = frozenset(
    ("mqtt", "https", "udp_dtls", "platform_api", "file_import")
)


@dataclass(frozen=True)
class EvaluationResult:
    """Committed result for one stored item.

    ``outcome`` is the outcome of the first evaluation.  On a duplicate
    delivery it remains the original outcome so a transport adapter can
    construct the same application result after the transaction commits.
    """

    payload_id: int
    payload_partition_month: date
    item_index: int
    receipt_id: int
    receipt_partition_month: date
    receipt_status: str
    first_delivery: bool
    outcome: str
    original_receipt_id: int | None
    original_receipt_partition_month: date | None


def evaluate_item(conn, payload_id, payload_partition_month, item_index):
    """Evaluate one stored item and commit receipt/dedup state atomically.

    The connection is expected to follow the same autocommit convention as
    ``accept``.  The timestamp is read from the stored payload; this function
    never substitutes ``now()`` or a client timestamp.
    """

    if not isinstance(item_index, int) or isinstance(item_index, bool) or item_index < 0:
        raise ValueError("item_index must be a non-negative int, not bool")
    if not getattr(conn, "autocommit", False):
        raise RuntimeError("evaluate_item requires autocommit")
    with ingest_transaction(conn):
        _require_collector(conn)
        envelope = load_envelope(conn, payload_id, payload_partition_month)
        item = next(
            (candidate for candidate in envelope.items if candidate.index == item_index),
            None,
        )
        if item is None:
            raise LookupError("stored item was not found")

        # Validate only the selected item while retaining the stored envelope
        # metadata and authoritative server_received_at.
        selected = replace(envelope, items=(replace(item, index=0),))
        checked = validate(selected)
        item_issues = tuple(checked.issues)
        if not isinstance(item.index, int) or isinstance(item.index, bool) or item.index < 0:
            item_issues += (ValidationIssue(INVALID_ITEM_INDEX, None),)
        first_status = "accepted" if not item_issues else "invalid"
        outcome = first_status

        identity = _identity(item)
        key_kind = None if identity is None else _KEY_MESSAGE_KIND.get(item.message_kind)
        if identity is not None and key_kind is None:
            first_status = "invalid"
            outcome = first_status

        receipt_id, receipt_month = _insert_receipt(
            conn,
            envelope,
            item,
            payload_id,
            payload_partition_month,
            first_status,
        )

        if identity is None or key_kind is None:
            return _result_without_key(
                payload_id,
                payload_partition_month,
                item.index,
                receipt_id,
                receipt_month,
                first_status,
                outcome,
            )

        row = conn.execute(
            """
            INSERT INTO ingest_message_keys (
                ingest_source_id, msg_key_namespace, msg_key, item_index,
                message_kind, first_received_at, last_received_at,
                delivery_count, outcome, receipt_id, receipt_partition_month
            ) VALUES (
                %(ingest_source_id)s, %(msg_key_namespace)s, %(msg_key)s, %(item_index)s,
                %(message_kind)s, %(received_at)s, %(received_at)s,
                1, %(outcome)s, %(receipt_id)s, %(receipt_partition_month)s
            )
            ON CONFLICT (
                ingest_source_id, msg_key_namespace, msg_key, item_index
            )
            DO UPDATE SET
                last_received_at = GREATEST(
                    COALESCE(
                        ingest_message_keys.last_received_at,
                        EXCLUDED.last_received_at
                    ),
                    EXCLUDED.last_received_at
                ),
                delivery_count = COALESCE(
                    ingest_message_keys.delivery_count,
                    1
                ) + 1
            RETURNING
                receipt_id,
                receipt_partition_month,
                delivery_count,
                outcome,
                (
                    receipt_id IS NOT DISTINCT FROM %(receipt_id)s
                    AND receipt_partition_month IS NOT DISTINCT FROM
                        %(receipt_partition_month)s
                ) AS first_delivery
            """,
            {
                "ingest_source_id": envelope.ingest_source_id,
                "msg_key_namespace": item.msg_key_namespace,
                "msg_key": item.msg_key,
                "item_index": item.index,
                "message_kind": key_kind,
                "received_at": envelope.server_received_at,
                "outcome": outcome,
                "receipt_id": receipt_id,
                "receipt_partition_month": receipt_month,
            },
        ).fetchone()

        original_receipt_id, original_receipt_month, _, original_outcome, first_delivery = row
        receipt_status = first_status if first_delivery else "duplicate_delivery"
        conn.execute(
            """
            UPDATE ingest_receipts
            SET status = %(status)s
            WHERE id = %(receipt_id)s
              AND partition_month = %(receipt_partition_month)s
            """,
            {
                "status": receipt_status,
                "receipt_id": receipt_id,
                "receipt_partition_month": receipt_month,
            },
        )
        return EvaluationResult(
            payload_id,
            payload_partition_month,
            item.index,
            receipt_id,
            receipt_month,
            receipt_status,
            bool(first_delivery),
            original_outcome,
            original_receipt_id,
            original_receipt_month,
        )


def _identity(item):
    if not isinstance(item.msg_key, str) or not item.msg_key.strip():
        return None
    if not isinstance(item.msg_key_namespace, str) or not item.msg_key_namespace.strip():
        return None
    return item.msg_key_namespace, item.msg_key


def _require_collector(conn):
    role = conn.execute("SELECT current_user").fetchone()[0]
    if role != "sjv_collector":
        raise PermissionError("evaluate_item runs only as sjv_collector")


def _insert_receipt(
    conn,
    envelope,
    item,
    payload_id,
    payload_partition_month,
    status,
):
    source_time = item.source_time
    frame = item.frame
    row = conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, endpoint_id, device_id,
            message_kind, msg_key, msg_key_namespace, external_message_id,
            transport, device_rx_unix_ms, rx_instance_id, rx_boot, rx_uptime_ms,
            age_ms, tx_at, tx_uptime_ms, rssi, frame_format, original_frame, status
        ) VALUES (
            date_trunc('month', %(received_at)s AT TIME ZONE 'UTC')::date,
            %(received_at)s, %(payload_id)s, %(payload_partition_month)s,
            sha256(%(original)s), %(item_index)s, %(ingest_source_id)s,
            %(endpoint_id)s, %(device_id)s, %(message_kind)s, %(msg_key)s,
            %(msg_key_namespace)s, %(external_message_id)s, %(transport)s,
            %(device_rx_unix_ms)s, %(rx_instance_id)s, %(rx_boot)s,
            %(rx_uptime_ms)s, %(age_ms)s, %(tx_at)s, %(tx_uptime_ms)s,
            %(rssi)s, %(frame_format)s, %(original_frame)s, %(status)s
        )
        RETURNING id, partition_month
        """,
        {
            "received_at": envelope.server_received_at,
            "payload_id": payload_id,
            "payload_partition_month": payload_partition_month,
            "original": item.original,
            "item_index": item.index,
            "ingest_source_id": envelope.ingest_source_id,
            "endpoint_id": envelope.endpoint_id,
            "device_id": envelope.device_id,
            "message_kind": (
                item.message_kind
                if item.message_kind in _RECEIPT_MESSAGE_KINDS
                else None
            ),
            "msg_key": item.msg_key,
            "msg_key_namespace": item.msg_key_namespace,
            "external_message_id": item.external_message_id,
            "transport": (
                envelope.transport
                if envelope.transport in _RECEIPT_TRANSPORTS
                else None
            ),
            "device_rx_unix_ms": None if source_time is None else source_time.device_rx_unix_ms,
            "rx_instance_id": None if source_time is None else source_time.rx_instance_id,
            "rx_boot": None if source_time is None else source_time.rx_boot,
            "rx_uptime_ms": None if source_time is None else source_time.rx_uptime_ms,
            "age_ms": None if source_time is None else source_time.age_ms,
            "tx_at": None if source_time is None else source_time.tx_at,
            "tx_uptime_ms": None if source_time is None else source_time.tx_uptime_ms,
            "rssi": None if frame is None else frame.rssi,
            "frame_format": None if frame is None else frame.frame_format,
            "original_frame": None if frame is None else frame.original,
            "status": status,
        },
    ).fetchone()
    return row[0], row[1]


def _result_without_key(
    payload_id,
    payload_partition_month,
    item_index,
    receipt_id,
    receipt_month,
    status,
    outcome,
):
    return EvaluationResult(
        payload_id,
        payload_partition_month,
        item_index,
        receipt_id,
        receipt_month,
        status,
        True,
        outcome,
        receipt_id,
        receipt_month,
    )
