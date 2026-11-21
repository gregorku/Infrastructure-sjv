"""Read a stored envelope back into the in-memory contract.

This does not evaluate the envelope, insert a receipt, or decide identity.
``identifier_proven`` is returned as stored. It is not a proof and this module
does not write ``proof_basis`` or ``ingest_message_keys``.
"""

from sjv_ingest.contract import Envelope, Fragment, Frame, Item, SourceTime

_PAYLOAD = (
    "ingest_source_id",
    "endpoint_id",
    "device_id",
    "transport",
    "received_at",
    "payload",
)
_ITEM = (
    "item_index",
    "original",
    "message_kind",
    "msg_key",
    "msg_key_namespace",
    "identifier_proven",
    "rx_instance_id",
    "rx_boot",
    "rx_uptime_ms",
    "device_rx_unix_ms",
    "age_ms",
    "tx_instance_id",
    "tx_boot",
    "tx_uptime_ms",
    "tx_at",
    "frame_original",
    "frame_format",
    "crc_included",
    "rssi",
    "group_key",
    "fragment_index",
    "source_message_ref",
    "external_message_id",
)


def _record(names, row):
    return dict(zip(names, row))


def _bytes(value):
    if value is None or isinstance(value, bytes):
        return value
    return bytes(value)


def _optional(row, names):
    fields = {name: row[name] for name in names}
    if all(value is None for value in fields.values()):
        return None
    return fields


def _source_time(row):
    fields = _optional(
        row,
        (
            "rx_instance_id",
            "rx_boot",
            "rx_uptime_ms",
            "device_rx_unix_ms",
            "age_ms",
            "tx_instance_id",
            "tx_boot",
            "tx_uptime_ms",
            "tx_at",
        ),
    )
    if fields is None:
        return None
    return SourceTime(**fields)


def _frame(row):
    fields = _optional(row, ("frame_format", "crc_included", "rssi"))
    original = _bytes(row["frame_original"])
    if fields is None and original is None:
        return None
    return Frame(
        original=original,
        frame_format=None if fields is None else fields["frame_format"],
        crc_included=None if fields is None else fields["crc_included"],
        rssi=None if fields is None else fields["rssi"],
    )


def _fragment(row):
    fields = _optional(row, ("group_key", "fragment_index", "source_message_ref"))
    if fields is None:
        return None
    return Fragment(**fields)


def _item(row):
    return Item(
        index=row["item_index"],
        original=_bytes(row["original"]),
        message_kind=row["message_kind"],
        msg_key=row["msg_key"],
        msg_key_namespace=row["msg_key_namespace"],
        identifier_proven=bool(row["identifier_proven"]),
        source_time=_source_time(row),
        frame=_frame(row),
        fragment=_fragment(row),
        external_message_id=row["external_message_id"],
    )


def load_envelope(conn, payload_id, payload_partition_month):
    """Return the envelope stored for one payload. Reads only."""

    payload = conn.execute(
        """
        SELECT ingest_source_id, endpoint_id, device_id, transport, received_at, payload
        FROM ingest_payloads
        WHERE id = %(payload_id)s AND partition_month = %(partition_month)s
        """,
        {"payload_id": payload_id, "partition_month": payload_partition_month},
    ).fetchone()
    if payload is None:
        raise LookupError("stored payload was not found")
    payload = _record(_PAYLOAD, payload)
    rows = conn.execute(
        """
        SELECT item_index, original, message_kind, msg_key, msg_key_namespace,
               identifier_proven,
               rx_instance_id, rx_boot, rx_uptime_ms, device_rx_unix_ms, age_ms,
               tx_instance_id, tx_boot, tx_uptime_ms, tx_at,
               frame_original, frame_format, crc_included, rssi,
               group_key, fragment_index, source_message_ref, external_message_id
        FROM ingest_payload_items
        WHERE payload_id = %(payload_id)s AND payload_partition_month = %(partition_month)s
        ORDER BY item_index
        """,
        {"payload_id": payload_id, "partition_month": payload_partition_month},
    ).fetchall()
    return Envelope(
        ingest_source_id=payload["ingest_source_id"],
        endpoint_id=payload["endpoint_id"],
        device_id=payload["device_id"],
        transport=payload["transport"],
        server_received_at=payload["received_at"],
        original=_bytes(payload["payload"]),
        items=tuple(_item(_record(_ITEM, row)) for row in rows),
    )
