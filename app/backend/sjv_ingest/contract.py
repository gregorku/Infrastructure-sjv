"""Normalized ingest input, independent of MQTT, HTTPS and UDP/DTLS.

A text ``msg_key`` or ``source_message_ref`` is kept as the source sent it.
Neither text proves identity. Content is not hashed here and is not an identifier.
"""

from dataclasses import dataclass
from datetime import datetime

TRANSPORTS = ("mqtt", "https", "udp_dtls", "platform_api", "file_import")

MESSAGE_KINDS = ("raw_wmbus", "decoded", "event", "heartbeat", "import_row")

IDENTIFIER_MISSING = "missing"
IDENTIFIER_UNPROVEN = "unproven"
IDENTIFIER_PROVEN = "proven"


def _blank(value):
    return isinstance(value, str) and value.strip() == ""


@dataclass(frozen=True)
class SourceTime:
    """Time fields the source actually sent. Missing fields stay None."""

    rx_instance_id: str | None = None
    rx_boot: int | None = None
    rx_uptime_ms: int | None = None
    device_rx_unix_ms: int | None = None
    age_ms: int | None = None
    tx_instance_id: str | None = None
    tx_boot: int | None = None
    tx_uptime_ms: int | None = None
    tx_at: datetime | None = None


@dataclass(frozen=True)
class Frame:
    """Bytes and labels of a frame, without decoding them."""

    original: bytes | None = None
    frame_format: str | None = None
    crc_included: bool | None = None
    rssi: int | None = None


@dataclass(frozen=True)
class Fragment:
    """Fragment fields supplied by the source. ``source_message_ref`` does not join sets."""

    group_key: str | None = None
    fragment_index: int | None = None
    source_message_ref: str | None = None


@dataclass(frozen=True)
class Item:
    """One item inside an envelope. ``index`` is the source order, starting at 0."""

    index: int
    original: bytes | None
    message_kind: str
    msg_key: str | None = None
    msg_key_namespace: str | None = None
    identifier_proven: bool = False
    source_time: SourceTime | None = None
    frame: Frame | None = None
    fragment: Fragment | None = None
    external_message_id: str | None = None


@dataclass(frozen=True)
class Envelope:
    """One received message. ``original`` is the unchanged envelope body."""

    ingest_source_id: int | None
    transport: str | None
    server_received_at: datetime | None
    original: bytes | None
    items: tuple[Item, ...] = ()
    endpoint_id: int | None = None
    device_id: int | None = None
    source_time: SourceTime | None = None


def identifier_status(item):
    """Classify ``msg_key`` without treating its presence as proof."""

    if item.msg_key is None:
        return IDENTIFIER_MISSING
    if item.identifier_proven and isinstance(item.msg_key, str) and not _blank(item.msg_key):
        return IDENTIFIER_PROVEN
    return IDENTIFIER_UNPROVEN
