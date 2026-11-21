"""Unit checks for the ingest contract. No database and no hashing."""

from datetime import datetime, timezone
import pathlib
import unittest

from sjv_ingest.contract import (
    IDENTIFIER_MISSING,
    IDENTIFIER_PROVEN,
    IDENTIFIER_UNPROVEN,
    Envelope,
    Fragment,
    Frame,
    Item,
    SourceTime,
    identifier_status,
)
from sjv_ingest.validate import (
    BLANK_MSG_KEY,
    DUPLICATE_ITEM_INDEX,
    EMPTY_ENVELOPE,
    INCOMPLETE_FRAGMENT,
    ITEM_ORDER,
    INVALID_MESSAGE_KIND,
    INVALID_TRANSPORT,
    MISSING_INGEST_SOURCE,
    MISSING_PAYLOAD,
    validate,
)

RECEIVED = datetime(2026, 11, 21, 8, 0, tzinfo=timezone.utc)
ORIGINAL = b"\x00raw-envelope\xff"
ITEM_BODY = b"\x01item-body"


def item(**overrides):
    values = {
        "index": 0,
        "original": ITEM_BODY,
        "message_kind": "raw_wmbus",
    }
    values.update(overrides)
    return Item(**values)


def envelope(**overrides):
    values = {
        "ingest_source_id": 7,
        "transport": "https",
        "server_received_at": RECEIVED,
        "original": ORIGINAL,
        "items": (item(),),
    }
    values.update(overrides)
    return Envelope(**values)


class ContractValidationTest(unittest.TestCase):
    def test_valid_envelope_with_one_item(self):
        result = validate(envelope())
        self.assertTrue(result.ok)
        self.assertEqual(result.envelope.original, ORIGINAL)
        self.assertIs(result.envelope.original, ORIGINAL)

    def test_valid_envelope_with_several_items(self):
        first = item(index=0, original=b"a")
        second = item(index=1, original=b"b", message_kind="event")
        result = validate(envelope(items=(first, second)))
        self.assertTrue(result.ok)
        self.assertEqual(result.envelope.items[0].original, b"a")
        self.assertEqual(result.envelope.items[1].original, b"b")

    def test_empty_envelope_keeps_original_bytes(self):
        result = validate(envelope(items=()))
        self.assertFalse(result.ok)
        self.assertIn(EMPTY_ENVELOPE, [issue.code for issue in result.issues])
        self.assertIs(result.envelope.original, ORIGINAL)

    def test_missing_ingest_source(self):
        result = validate(envelope(ingest_source_id=None))
        self.assertIn(MISSING_INGEST_SOURCE, [issue.code for issue in result.issues])
        self.assertIs(result.envelope.original, ORIGINAL)

    def test_invalid_transport(self):
        result = validate(envelope(transport="sms"))
        self.assertIn(INVALID_TRANSPORT, [issue.code for issue in result.issues])

    def test_missing_original_bytes(self):
        result = validate(envelope(original=None))
        self.assertIn(MISSING_PAYLOAD, [issue.code for issue in result.issues])
        self.assertIsNone(result.envelope.original)

    def test_duplicate_item_index(self):
        result = validate(envelope(items=(item(index=0), item(index=0, original=b"b"))))
        self.assertIn(DUPLICATE_ITEM_INDEX, [issue.code for issue in result.issues])
        self.assertEqual(result.envelope.items[1].original, b"b")

    def test_missing_msg_key_is_not_an_identifier(self):
        body = item()
        result = validate(envelope(items=(body,)))
        self.assertTrue(result.ok)
        self.assertIsNone(body.msg_key)
        self.assertEqual(identifier_status(body), IDENTIFIER_MISSING)

    def test_unproven_msg_key_stays_unproven(self):
        body = item(msg_key="same-text", msg_key_namespace="https", identifier_proven=False)
        result = validate(envelope(items=(body,)))
        self.assertTrue(result.ok)
        self.assertEqual(identifier_status(body), IDENTIFIER_UNPROVEN)
        self.assertEqual(body.msg_key, "same-text")

    def test_proven_msg_key_needs_an_explicit_flag(self):
        body = item(msg_key="9f3c-17-1", msg_key_namespace="mqtt", identifier_proven=True)
        result = validate(envelope(items=(body,), transport="mqtt"))
        self.assertTrue(result.ok)
        self.assertEqual(identifier_status(body), IDENTIFIER_PROVEN)

    def test_text_alone_does_not_prove_the_key(self):
        body = item(msg_key="9f3c-17-1", msg_key_namespace="mqtt")
        self.assertFalse(body.identifier_proven)
        self.assertEqual(identifier_status(body), IDENTIFIER_UNPROVEN)

    def test_blank_msg_key_is_not_proof(self):
        body = item(msg_key="  ", identifier_proven=True, msg_key_namespace="https")
        result = validate(envelope(items=(body,)))
        self.assertIn(BLANK_MSG_KEY, [issue.code for issue in result.issues])
        self.assertNotEqual(identifier_status(body), IDENTIFIER_PROVEN)

    def test_unknown_message_kind(self):
        result = validate(envelope(items=(item(message_kind="vendor_private"),)))
        self.assertIn(INVALID_MESSAGE_KIND, [issue.code for issue in result.issues])
        self.assertEqual(result.envelope.items[0].message_kind, "vendor_private")
        self.assertIs(result.envelope.original, ORIGINAL)
        self.assertEqual(result.envelope.items[0].original, ITEM_BODY)

    def test_incomplete_fragment_keeps_the_envelope(self):
        body = item(fragment=Fragment(group_key=None, fragment_index=None))
        result = validate(envelope(items=(body,)))
        self.assertIn(INCOMPLETE_FRAGMENT, [issue.code for issue in result.issues])
        self.assertIs(result.envelope.original, ORIGINAL)
        self.assertEqual(body.original, ITEM_BODY)

    def test_source_message_ref_does_not_prove_identity(self):
        body = item(
            fragment=Fragment(
                group_key="G",
                fragment_index=0,
                source_message_ref="ref-from-source",
            )
        )
        result = validate(envelope(items=(body,)))
        self.assertTrue(result.ok)
        self.assertEqual(body.fragment.source_message_ref, "ref-from-source")
        self.assertEqual(identifier_status(body), IDENTIFIER_MISSING)
        self.assertFalse(hasattr(body.fragment, "message_ref"))

    def test_original_bytes_are_not_normalized(self):
        raw = b"\xff\xfe not utf-8 \x00\x01"
        body = item(original=raw, frame=Frame(original=raw, frame_format="not-a-wmbus-format"))
        result = validate(envelope(original=raw, items=(body,)))
        self.assertTrue(result.ok)
        self.assertEqual(result.envelope.original, b"\xff\xfe not utf-8 \x00\x01")
        self.assertIs(result.envelope.items[0].original, raw)
        self.assertIs(result.envelope.items[0].frame.original, raw)

    def test_content_is_not_used_as_identity(self):
        raw = b"same-body"
        body = item(original=raw)
        self.assertIsNone(body.msg_key)
        self.assertEqual(identifier_status(body), IDENTIFIER_MISSING)
        self.assertFalse(hasattr(body, "content_hash"))
        root = pathlib.Path(__file__).resolve().parents[1] / "sjv_ingest"
        for path in (root / "contract.py", root / "validate.py"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("hashlib", text)
            self.assertNotIn("sha256", text)
        result = validate(envelope(original=raw, items=(body,)))
        self.assertTrue(result.ok)
        self.assertIsNone(result.envelope.items[0].msg_key)

    def test_supplied_time_is_kept_and_missing_time_stays_missing(self):
        stamp = datetime(2026, 11, 21, 7, 0, tzinfo=timezone.utc)
        timing = SourceTime(rx_uptime_ms=10, tx_at=stamp)
        body = item(source_time=timing)
        result = validate(envelope(items=(body,)))
        self.assertTrue(result.ok)
        self.assertEqual(body.source_time.rx_uptime_ms, 10)
        self.assertIsNone(body.source_time.age_ms)
        self.assertEqual(body.source_time.tx_at, stamp)

    def test_naive_server_time_is_rejected_without_replacing_bytes(self):
        result = validate(envelope(server_received_at=datetime(2026, 11, 21, 8, 0)))
        self.assertFalse(result.ok)
        self.assertIs(result.envelope.original, ORIGINAL)
        self.assertIsNone(result.envelope.server_received_at.tzinfo)

    def test_item_order_must_start_at_zero(self):
        result = validate(envelope(items=(item(index=1, original=b"a"),)))
        self.assertIn(ITEM_ORDER, [issue.code for issue in result.issues])
        self.assertEqual(result.envelope.items[0].original, b"a")

    def test_unknown_frame_format_is_not_a_reason_to_drop_bytes(self):
        raw = b"\x2a\x44unparsed"
        body = item(frame=Frame(original=raw, frame_format="Z", crc_included=True))
        result = validate(envelope(original=raw, items=(body,)))
        self.assertTrue(result.ok)
        self.assertEqual(body.frame.frame_format, "Z")
        self.assertIs(result.envelope.original, raw)


if __name__ == "__main__":
    unittest.main()
