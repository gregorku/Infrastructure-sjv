"""Structural validation of a normalized envelope.

Issues are reported beside the same envelope. The original bytes are not
rewritten, decoded, hashed, or discarded.
"""

from dataclasses import dataclass
from datetime import datetime

from sjv_ingest.contract import MESSAGE_KINDS, TRANSPORTS, Envelope

MISSING_INGEST_SOURCE = "missing_ingest_source"
INVALID_INGEST_SOURCE = "invalid_ingest_source"
INVALID_ENDPOINT = "invalid_endpoint"
INVALID_DEVICE = "invalid_device"
INVALID_TRANSPORT = "invalid_transport"
MISSING_PAYLOAD = "missing_payload"
INVALID_SERVER_TIME = "invalid_server_time"
EMPTY_ENVELOPE = "empty_envelope"
ITEM_ORDER = "item_order"
DUPLICATE_ITEM_INDEX = "duplicate_item_index"
MISSING_ITEM_CONTENT = "missing_item_content"
INVALID_ITEM_INDEX = "invalid_item_index"
INVALID_MESSAGE_KIND = "invalid_message_kind"
BLANK_MSG_KEY = "blank_msg_key"
MISSING_NAMESPACE = "missing_namespace"
BLANK_NAMESPACE = "blank_namespace"
PROVEN_WITHOUT_IDENTIFIER = "proven_without_identifier"
INVALID_TIME = "invalid_time"
INCOMPLETE_FRAGMENT = "incomplete_fragment"
BLANK_SOURCE_MESSAGE_REF = "blank_source_message_ref"
INVALID_FRAME = "invalid_frame"


@dataclass(frozen=True)
class ValidationIssue:
    code: str
    item_index: int | None = None


@dataclass(frozen=True)
class ValidationResult:
    envelope: Envelope
    issues: tuple[ValidationIssue, ...]

    @property
    def ok(self):
        return not self.issues


def _blank(value):
    return isinstance(value, str) and value.strip() == ""


def validate(envelope):
    issues = []
    _envelope(envelope, issues)
    _items(envelope, issues)
    return ValidationResult(envelope, tuple(issues))


def _envelope(envelope, issues):
    if envelope.ingest_source_id is None:
        issues.append(ValidationIssue(MISSING_INGEST_SOURCE))
    elif not _positive_int(envelope.ingest_source_id):
        issues.append(ValidationIssue(INVALID_INGEST_SOURCE))
    if envelope.endpoint_id is not None and not _positive_int(envelope.endpoint_id):
        issues.append(ValidationIssue(INVALID_ENDPOINT))
    if envelope.device_id is not None and not _positive_int(envelope.device_id):
        issues.append(ValidationIssue(INVALID_DEVICE))
    if envelope.transport not in TRANSPORTS:
        issues.append(ValidationIssue(INVALID_TRANSPORT))
    if envelope.original is None:
        issues.append(ValidationIssue(MISSING_PAYLOAD))
    elif not isinstance(envelope.original, bytes):
        issues.append(ValidationIssue(MISSING_PAYLOAD))
    if not _aware_datetime(envelope.server_received_at):
        issues.append(ValidationIssue(INVALID_SERVER_TIME))
    if not envelope.items:
        issues.append(ValidationIssue(EMPTY_ENVELOPE))
    _source_time(envelope.source_time, None, issues)


def _items(envelope, issues):
    indexes = []
    for item in envelope.items:
        if _item_index(item.index):
            indexes.append(item.index)
        else:
            issues.append(ValidationIssue(INVALID_ITEM_INDEX))
        if item.original is None:
            issues.append(ValidationIssue(MISSING_ITEM_CONTENT, _index_or_none(item)))
        elif not isinstance(item.original, bytes):
            issues.append(ValidationIssue(MISSING_ITEM_CONTENT, _index_or_none(item)))
        if item.message_kind not in MESSAGE_KINDS:
            issues.append(ValidationIssue(INVALID_MESSAGE_KIND, _index_or_none(item)))
        _identifier(item, issues)
        _source_time(item.source_time, _index_or_none(item), issues)
        _frame(item, issues)
        _fragment(item, issues)
    if indexes and len(indexes) == len(envelope.items):
        if len(indexes) != len(set(indexes)):
            issues.append(ValidationIssue(DUPLICATE_ITEM_INDEX))
        elif indexes != list(range(len(indexes))):
            issues.append(ValidationIssue(ITEM_ORDER))


def _identifier(item, issues):
    index = _index_or_none(item)
    if item.msg_key is None:
        if item.identifier_proven:
            issues.append(ValidationIssue(PROVEN_WITHOUT_IDENTIFIER, index))
        return
    if not isinstance(item.msg_key, str) or _blank(item.msg_key):
        issues.append(ValidationIssue(BLANK_MSG_KEY, index))
        return
    if item.msg_key_namespace is None:
        if item.identifier_proven:
            issues.append(ValidationIssue(MISSING_NAMESPACE, index))
        return
    if not isinstance(item.msg_key_namespace, str) or _blank(item.msg_key_namespace):
        issues.append(ValidationIssue(BLANK_NAMESPACE, index))


def _fragment(item, issues):
    fragment = item.fragment
    if fragment is None:
        return
    index = _index_or_none(item)
    group_ok = isinstance(fragment.group_key, str) and not _blank(fragment.group_key)
    if not group_ok or not _item_index(fragment.fragment_index):
        issues.append(ValidationIssue(INCOMPLETE_FRAGMENT, index))
    if fragment.source_message_ref is not None and (
        not isinstance(fragment.source_message_ref, str) or _blank(fragment.source_message_ref)
    ):
        issues.append(ValidationIssue(BLANK_SOURCE_MESSAGE_REF, index))


def _frame(item, issues):
    frame = item.frame
    if frame is None:
        return
    index = _index_or_none(item)
    if frame.original is not None and not isinstance(frame.original, bytes):
        issues.append(ValidationIssue(INVALID_FRAME, index))
    if frame.frame_format is not None and (
        not isinstance(frame.frame_format, str) or _blank(frame.frame_format)
    ):
        issues.append(ValidationIssue(INVALID_FRAME, index))
    if frame.crc_included is not None and not isinstance(frame.crc_included, bool):
        issues.append(ValidationIssue(INVALID_FRAME, index))
    if frame.rssi is not None and (isinstance(frame.rssi, bool) or not isinstance(frame.rssi, int)):
        issues.append(ValidationIssue(INVALID_FRAME, index))


def _source_time(source_time, index, issues):
    if source_time is None:
        return
    for name in (
        "rx_instance_id",
        "tx_instance_id",
    ):
        value = getattr(source_time, name)
        if value is not None and (not isinstance(value, str) or _blank(value)):
            issues.append(ValidationIssue(INVALID_TIME, index))
            return
    for name in (
        "rx_boot",
        "rx_uptime_ms",
        "device_rx_unix_ms",
        "age_ms",
        "tx_boot",
        "tx_uptime_ms",
    ):
        value = getattr(source_time, name)
        if value is not None and (isinstance(value, bool) or not isinstance(value, int)):
            issues.append(ValidationIssue(INVALID_TIME, index))
            return
    if source_time.tx_at is not None and not _aware_datetime(source_time.tx_at):
        issues.append(ValidationIssue(INVALID_TIME, index))


def _positive_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _item_index(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _index_or_none(item):
    if _item_index(item.index):
        return item.index
    return None


def _aware_datetime(value):
    return (
        isinstance(value, datetime)
        and value.tzinfo is not None
        and value.utcoffset() is not None
    )
