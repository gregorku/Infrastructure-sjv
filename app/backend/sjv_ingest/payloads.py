"""Insert the original envelope and, for an empty envelope, one receipt.

``sha256`` of a real item is the hash of that item's canonical body. An
empty envelope has no item body, so its receipt hash is ``sha256`` of the
original envelope bytes. Neither hash is a message identity, and neither
replaces the stored payload.
"""


def insert_payload(conn, envelope):
    row = conn.execute(
        """
        INSERT INTO ingest_payloads (
            partition_month, ingest_source_id, endpoint_id, device_id,
            transport, received_at, content_kind, payload, payload_sha256,
            size_bytes, origin
        ) VALUES (
            date_trunc('month', %(received_at)s AT TIME ZONE 'UTC')::date,
            %(ingest_source_id)s, %(endpoint_id)s, %(device_id)s,
            %(transport)s, %(received_at)s, 'opaque', %(payload)s,
            sha256(%(payload)s), %(size_bytes)s, 'received'
        )
        RETURNING id, partition_month
        """,
        {
            "received_at": envelope.server_received_at,
            "ingest_source_id": envelope.ingest_source_id,
            "endpoint_id": envelope.endpoint_id,
            "device_id": envelope.device_id,
            "transport": envelope.transport,
            "payload": envelope.original,
            "size_bytes": len(envelope.original),
        },
    ).fetchone()
    return row[0], row[1]


def insert_items(conn, envelope, payload_id, payload_partition_month):
    """Store every item of this delivery. ``proof_basis`` stays empty.

    ``identifier_proven`` is stored as the input flag and is not copied into
    ``proof_basis``. Item bytes are stored even when the kind or frame format
    is unknown. Index -1 is rejected by the table and is only legal on an
    empty-envelope receipt.
    """

    for item in envelope.items:
        source_time = item.source_time
        frame = item.frame
        fragment = item.fragment
        conn.execute(
            """
            INSERT INTO ingest_payload_items (
                partition_month, payload_id, payload_partition_month, item_index,
                original, message_kind, msg_key, msg_key_namespace, proof_basis,
                identifier_proven,
                rx_instance_id, rx_boot, rx_uptime_ms, device_rx_unix_ms, age_ms,
                tx_instance_id, tx_boot, tx_uptime_ms, tx_at,
                frame_original, frame_format, crc_included, rssi,
                group_key, fragment_index, source_message_ref, external_message_id
            ) VALUES (
                %(partition_month)s, %(payload_id)s, %(payload_partition_month)s, %(item_index)s,
                %(original)s, %(message_kind)s, %(msg_key)s, %(msg_key_namespace)s, NULL,
                %(identifier_proven)s,
                %(rx_instance_id)s, %(rx_boot)s, %(rx_uptime_ms)s, %(device_rx_unix_ms)s, %(age_ms)s,
                %(tx_instance_id)s, %(tx_boot)s, %(tx_uptime_ms)s, %(tx_at)s,
                %(frame_original)s, %(frame_format)s, %(crc_included)s, %(rssi)s,
                %(group_key)s, %(fragment_index)s, %(source_message_ref)s, %(external_message_id)s
            )
            """,
            {
                "partition_month": payload_partition_month,
                "payload_id": payload_id,
                "payload_partition_month": payload_partition_month,
                "item_index": item.index,
                "original": item.original,
                "message_kind": item.message_kind,
                "msg_key": item.msg_key,
                "msg_key_namespace": item.msg_key_namespace,
                "identifier_proven": bool(item.identifier_proven),
                "rx_instance_id": None if source_time is None else source_time.rx_instance_id,
                "rx_boot": None if source_time is None else source_time.rx_boot,
                "rx_uptime_ms": None if source_time is None else source_time.rx_uptime_ms,
                "device_rx_unix_ms": None if source_time is None else source_time.device_rx_unix_ms,
                "age_ms": None if source_time is None else source_time.age_ms,
                "tx_instance_id": None if source_time is None else source_time.tx_instance_id,
                "tx_boot": None if source_time is None else source_time.tx_boot,
                "tx_uptime_ms": None if source_time is None else source_time.tx_uptime_ms,
                "tx_at": None if source_time is None else source_time.tx_at,
                "frame_original": None if frame is None else frame.original,
                "frame_format": None if frame is None else frame.frame_format,
                "crc_included": None if frame is None else frame.crc_included,
                "rssi": None if frame is None else frame.rssi,
                "group_key": None if fragment is None else fragment.group_key,
                "fragment_index": None if fragment is None else fragment.fragment_index,
                "source_message_ref": None if fragment is None else fragment.source_message_ref,
                "external_message_id": item.external_message_id,
            },
        )


def insert_empty_receipt(conn, envelope, payload_id, payload_partition_month):
    """One invalid receipt for an envelope that contains no item.

    ``item_index`` -1 is reserved for this receipt. It is not an item, so
    this insert does not write ``msg_key`` or ``ingest_message_keys``.
    ``content_hash`` is the hash of the original envelope bytes.
    """

    if len(envelope.items) != 0:
        raise ValueError("item_index -1 is only for an envelope with no items")
    row = conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, endpoint_id, device_id,
            transport, status
        ) VALUES (
            date_trunc('month', %(server_received_at)s AT TIME ZONE 'UTC')::date,
            %(server_received_at)s, %(payload_id)s, %(payload_partition_month)s,
            sha256(%(body)s), -1, %(ingest_source_id)s, %(endpoint_id)s, %(device_id)s,
            %(transport)s, 'invalid'
        )
        RETURNING id, partition_month
        """,
        {
            "server_received_at": envelope.server_received_at,
            "payload_id": payload_id,
            "payload_partition_month": payload_partition_month,
            "body": envelope.original,
            "ingest_source_id": envelope.ingest_source_id,
            "endpoint_id": envelope.endpoint_id,
            "device_id": envelope.device_id,
            "transport": envelope.transport,
        },
    ).fetchone()
    return row[0], row[1]
