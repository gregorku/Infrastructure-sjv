"""Store the original envelope and its items, then the empty-envelope receipt.

The payload and every item commit in one transaction. A later evaluation
failure cannot remove those rows. A receipt for a real item waits until
evaluation. This step evaluates only an empty envelope. It does not send ACK.
"""

from dataclasses import dataclass
from datetime import date

from sjv_ingest.contract import Envelope
from sjv_ingest.payloads import insert_empty_receipt, insert_items, insert_payload
from sjv_ingest.tx import ingest_transaction
from sjv_ingest.validate import (
    INVALID_DEVICE,
    INVALID_ENDPOINT,
    INVALID_INGEST_SOURCE,
    INVALID_SERVER_TIME,
    INVALID_TRANSPORT,
    MISSING_INGEST_SOURCE,
    MISSING_PAYLOAD,
    validate,
)

BLOCKING = frozenset(
    {
        MISSING_INGEST_SOURCE,
        INVALID_INGEST_SOURCE,
        INVALID_ENDPOINT,
        INVALID_DEVICE,
        INVALID_TRANSPORT,
        MISSING_PAYLOAD,
        INVALID_SERVER_TIME,
    }
)


class IngestRejected(Exception):
    """The envelope cannot be stored without breaking a database constraint."""

    def __init__(self, issues):
        self.issues = tuple(issues)
        super().__init__(", ".join(issue.code for issue in self.issues))


@dataclass(frozen=True)
class AcceptResult:
    """Payload stored by ``accept``.

    ``awaiting_evaluation`` means no final receipt exists yet. The empty
    envelope is the only case this step finishes: ``receipt_status`` is
    ``invalid`` and ``awaiting_evaluation`` is false. This is not an ACK.
    """

    payload_id: int
    payload_partition_month: date
    awaiting_evaluation: bool
    receipt_id: int | None = None
    receipt_partition_month: date | None = None
    receipt_status: str | None = None


def accept(envelope, conn):
    if not isinstance(envelope, Envelope):
        raise TypeError("envelope must be an Envelope")
    if not getattr(conn, "autocommit", False):
        raise RuntimeError("accept requires autocommit so the payload commit is durable")
    checked = validate(envelope)
    blocking = tuple(issue for issue in checked.issues if issue.code in BLOCKING)
    if blocking:
        raise IngestRejected(blocking)
    payload_id, payload_month = _store_payload(conn, envelope)
    if len(envelope.items) != 0:
        return AcceptResult(payload_id, payload_month, awaiting_evaluation=True)
    receipt_id, receipt_month = _store_empty_receipt(conn, envelope, payload_id, payload_month)
    return AcceptResult(
        payload_id,
        payload_month,
        awaiting_evaluation=False,
        receipt_id=receipt_id,
        receipt_partition_month=receipt_month,
        receipt_status="invalid",
    )


def _store_payload(conn, envelope):
    with ingest_transaction(conn):
        _require_collector(conn)
        payload_id, payload_month = insert_payload(conn, envelope)
        insert_items(conn, envelope, payload_id, payload_month)
        return payload_id, payload_month


def _store_empty_receipt(conn, envelope, payload_id, payload_month):
    with ingest_transaction(conn):
        _require_collector(conn)
        return insert_empty_receipt(conn, envelope, payload_id, payload_month)


def _require_collector(conn):
    role = conn.execute("SELECT current_user").fetchone()[0]
    if role != "sjv_collector":
        raise PermissionError("accept stores rows only as sjv_collector")
