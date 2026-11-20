"""Tables from docs/database-design.md for the ingest migration.

Names follow the SQLAlchemy naming convention requested in that document.
Partitions, triggers and grants are applied by the migration after these tables.
"""

from sqlalchemy import (
    ARRAY,
    BigInteger,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Identity,
    Index,
    Integer,
    Interval,
    LargeBinary,
    MetaData,
    Numeric,
    SmallInteger,
    Table,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import CHAR, ExcludeConstraint, JSONB, TSTZRANGE

NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_name)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}

metadata = MetaData(naming_convention=NAMING_CONVENTION)

TZ = DateTime(timezone=True)


def _id():
    return Column("id", BigInteger, Identity(always=False), primary_key=True)


def _enum(name, values):
    quoted = ", ".join("'" + value + "'" for value in values)
    return CheckConstraint(f"{name} IN ({quoted})", name=name)


source_streams = Table(
    "source_streams",
    metadata,
    _id(),
    Column("code", Text, nullable=False),
    Column("kind", Text, nullable=False),
    Column("description", Text),
    _enum("kind", ("radio", "vendor_decoded", "manual", "import")),
    Index("uq_source_streams_code", "code", unique=True),
)

meters = Table(
    "meters",
    metadata,
    _id(),
    Column("manufacturer_code", CHAR(3)),
    Column("wmbus_id", CHAR(8)),
    Column("wmbus_version", SmallInteger),
    Column("wmbus_type", SmallInteger),
    Column("meter_key", LargeBinary),
    Column("driver", Text),
    Column("medium", Text),
    Column("primary_register", Text),
    Column("unit", Text),
    Column("aes_key_enc", LargeBinary),
    Column("aes_key_fingerprint", Text),
    Column("dedup_window", Interval),
    Column("max_flow_per_hour", Numeric),
    Column("status", Text),
    Column("note", Text),
    _enum("medium", ("cold_water", "hot_water", "heat", "heat_cost_allocator")),
    _enum("status", ("active", "retired")),
    Index("uq_meters_meter_key", "meter_key", unique=True),
)

meter_external_ids = Table(
    "meter_external_ids",
    metadata,
    _id(),
    Column("meter_id", BigInteger, ForeignKey("meters.id"), nullable=False),
    Column("source_stream_id", BigInteger, ForeignKey("source_streams.id"), nullable=False),
    Column("external_id", Text, nullable=False),
    Index("uq_meter_external_ids_stream_external", "source_stream_id", "external_id", unique=True),
)

devices = Table(
    "devices",
    metadata,
    _id(),
    Column("code", Text, nullable=False),
    Column("kind", Text, nullable=False),
    Column("vendor", Text),
    Column("model", Text),
    Column("hardware_revision", Text),
    Column("adapter", Text),
    Column("source_stream_id", BigInteger, ForeignKey("source_streams.id")),
    Column("status", Text, nullable=False),
    Column("last_seen_at", TZ),
    Column("last_ip", Text),
    Column("clock_offset_ms", Integer),
    Column("clock_checked_at", TZ),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    _enum("kind", ("esp32", "concentrator", "import_channel")),
    _enum("status", ("active", "disabled", "revoked")),
    Index("uq_devices_code", "code", unique=True),
)

device_external_ids = Table(
    "device_external_ids",
    metadata,
    _id(),
    Column("device_id", BigInteger, ForeignKey("devices.id"), nullable=False),
    Column("kind", Text, nullable=False),
    Column("value", Text, nullable=False),
    Column("valid_from", TZ, nullable=False),
    Column("valid_to", TZ),
    Column("origin", Text, nullable=False),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    _enum("kind", ("imsi", "imei", "iccid", "serial", "platform_id", "mqtt_client_id", "mac", "esp_instance", "other")),
    _enum("origin", ("admin", "heartbeat", "api", "import")),
    ExcludeConstraint(
        ("device_id", "="),
        ("kind", "="),
        (text("tstzrange(valid_from, valid_to, '[)')"), "&&"),
        where=text("kind IN ('imsi', 'imei', 'iccid', 'esp_instance')"),
        using="gist",
        name="ex_device_external_ids_active_kind",
    ),
    Index(
        "uq_device_external_ids_active_value",
        "kind",
        "value",
        unique=True,
        postgresql_where=text("valid_to IS NULL"),
    ),
)

device_firmware_history = Table(
    "device_firmware_history",
    metadata,
    _id(),
    Column("device_id", BigInteger, ForeignKey("devices.id"), nullable=False),
    Column("firmware_version", Text, nullable=False),
    Column("valid_from", TZ, nullable=False),
    Column("valid_to", TZ),
    Column("origin", Text, nullable=False),
    _enum("origin", ("heartbeat", "api", "admin")),
    ExcludeConstraint(
        ("device_id", "="),
        (text("tstzrange(valid_from, valid_to, '[)')"), "&&"),
        using="gist",
        name="ex_device_firmware_history_span",
    ),
)

device_capabilities = Table(
    "device_capabilities",
    metadata,
    _id(),
    Column("device_id", BigInteger, ForeignKey("devices.id"), nullable=False),
    Column("capability", Text, nullable=False),
    Column("detail", JSONB),
    Column("valid_from", TZ, nullable=False),
    Column("valid_to", TZ),
    Column("origin", Text, nullable=False),
    _enum("capability", ("mqtt", "udp_dtls", "https", "platform_api", "raw_wmbus", "decoded_json", "csv", "fragmentation")),
    _enum("origin", ("admin", "observed", "vendor_doc")),
    ExcludeConstraint(
        ("device_id", "="),
        ("capability", "="),
        (text("tstzrange(valid_from, valid_to, '[)')"), "&&"),
        using="gist",
        name="ex_device_capabilities_span",
    ),
)

device_credentials = Table(
    "device_credentials",
    metadata,
    _id(),
    Column("device_id", BigInteger, ForeignKey("devices.id"), nullable=False),
    Column("kind", Text, nullable=False),
    Column("secret_hash", Text),
    Column("cert_fingerprint", Text),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    Column("revoked_at", TZ),
    _enum("kind", ("mqtt_password", "api_token", "client_cert", "dtls_psk")),
)

device_boots = Table(
    "device_boots",
    metadata,
    Column("device_id", BigInteger, ForeignKey("devices.id"), primary_key=True),
    Column("instance_id", Text, primary_key=True),
    Column("boot_counter", Integer, primary_key=True),
    Column("epoch_est", TZ),
    Column("epoch_uncertainty_ms", Integer),
    Column("first_seen_at", TZ),
    Column("last_seen_at", TZ),
)

ingest_endpoints = Table(
    "ingest_endpoints",
    metadata,
    _id(),
    Column("code", Text, nullable=False),
    Column("transport", Text, nullable=False),
    Column("adapter", Text),
    Column("status", Text, nullable=False),
    Column("max_payload_bytes", Integer),
    Column("max_batch_items", Integer),
    Column("config", JSONB),
    Column("description", Text),
    _enum("transport", ("mqtt", "https", "udp_dtls", "platform_api", "file_import")),
    _enum("status", ("planned", "active", "disabled")),
    Index("uq_ingest_endpoints_code", "code", unique=True),
)

endpoint_credentials = Table(
    "endpoint_credentials",
    metadata,
    _id(),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id"), nullable=False),
    Column("kind", Text, nullable=False),
    Column("storage", Text, nullable=False),
    Column("secret_hash", Text),
    Column("secret_enc", LargeBinary),
    Column("cert_fingerprint", Text),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    Column("revoked_at", TZ),
    _enum("kind", ("bearer", "basic", "client_cert", "dtls_psk")),
    _enum("storage", ("hash", "kek_enc")),
    CheckConstraint(
        "(kind IN ('bearer', 'basic') AND storage = 'hash' "
        "AND secret_hash IS NOT NULL AND secret_enc IS NULL AND cert_fingerprint IS NULL) "
        "OR (kind = 'client_cert' AND storage = 'hash' "
        "AND cert_fingerprint IS NOT NULL AND secret_hash IS NULL AND secret_enc IS NULL) "
        "OR (kind = 'dtls_psk' AND storage = 'kek_enc' "
        "AND secret_enc IS NOT NULL AND secret_hash IS NULL AND cert_fingerprint IS NULL)",
        name="kind_storage",
    ),
)

ingest_sources = Table(
    "ingest_sources",
    metadata,
    _id(),
    Column("code", Text, nullable=False),
    Column("kind", Text, nullable=False),
    Column("msg_key_scope", Text, nullable=False, server_default=text("'transport'")),
    Column("device_id", BigInteger, ForeignKey("devices.id")),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id")),
    _enum("kind", ("device", "platform", "import")),
    _enum("msg_key_scope", ("transport", "device")),
    CheckConstraint(
        "(kind = 'device' AND device_id IS NOT NULL AND endpoint_id IS NULL) "
        "OR (kind <> 'device' AND device_id IS NULL AND endpoint_id IS NOT NULL)",
        name="kind_target",
    ),
    Index("uq_ingest_sources_code", "code", unique=True),
    Index(
        "uq_ingest_sources_device",
        "device_id",
        unique=True,
        postgresql_where=text("kind = 'device'"),
    ),
    Index(
        "uq_ingest_sources_endpoint",
        "endpoint_id",
        unique=True,
        postgresql_where=text("kind <> 'device'"),
    ),
)

_month = "partition_month = date_trunc('month', {column} AT TIME ZONE 'UTC')::date"

ingest_payloads = Table(
    "ingest_payloads",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), nullable=False),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id")),
    Column("device_id", BigInteger, ForeignKey("devices.id")),
    Column("transport", Text, nullable=False),
    Column("received_at", TZ, nullable=False),
    Column("content_kind", Text, nullable=False),
    Column("mqtt_topic", Text),
    Column("payload", LargeBinary, nullable=False),
    Column("payload_sha256", LargeBinary),
    Column("size_bytes", Integer),
    Column("origin", Text, nullable=False),
    Column("fragment_set_id", BigInteger),
    Column("metadata", JSONB),
    CheckConstraint(_month.format(column="received_at"), name="partition_month"),
    _enum("transport", ("mqtt", "https", "udp_dtls", "platform_api", "file_import")),
    _enum("content_kind", ("wmbus_batch", "wmbus_frame", "json", "csv", "udp_datagram", "api_response", "opaque")),
    _enum("origin", ("received", "assembled")),
    postgresql_partition_by="RANGE (partition_month)",
)

ingest_receipts = Table(
    "ingest_receipts",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("server_received_at", TZ, nullable=False),
    Column("payload_id", BigInteger, nullable=False),
    Column("payload_partition_month", Date, nullable=False),
    Column("content_hash", LargeBinary, nullable=False),
    Column("item_index", Integer, nullable=False),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), nullable=False),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id")),
    Column("device_id", BigInteger, ForeignKey("devices.id")),
    Column("device_attribution", Text),
    Column("message_kind", Text),
    Column("msg_key", Text),
    Column("msg_key_namespace", Text),
    Column("external_message_id", Text),
    Column("transport", Text),
    Column("device_rx_unix_ms", BigInteger),
    Column("rx_instance_id", Text),
    Column("rx_boot", Integer),
    Column("rx_uptime_ms", BigInteger),
    Column("age_ms", BigInteger),
    Column("tx_at", TZ),
    Column("tx_uptime_ms", BigInteger),
    Column("captured_at_est", TZ),
    Column("time_source", Text),
    Column("time_uncertainty_ms", Integer),
    Column("time_flags", ARRAY(Text)),
    Column("rssi", Integer),
    Column("frame_format", Text),
    Column("original_frame", LargeBinary),
    Column("fragment_set_id", BigInteger),
    Column("raw_telegram_id", BigInteger),
    Column("raw_partition_month", Date),
    Column("decoded_observation_id", BigInteger),
    Column("decoded_partition_month", Date),
    Column("status", Text, nullable=False),
    CheckConstraint(_month.format(column="server_received_at"), name="partition_month"),
    CheckConstraint("payload_partition_month = partition_month", name="payload_month"),
    _enum("device_attribution", ("authenticated", "mapped", "unattributed")),
    _enum("message_kind", ("raw_wmbus", "decoded", "event", "heartbeat", "import_row")),
    _enum("transport", ("mqtt", "https", "udp_dtls", "platform_api", "file_import")),
    _enum("time_source", ("boot_epoch", "device_clock", "server_only")),
    _enum(
        "status",
        (
            "new_telegram",
            "duplicate",
            "probable_duplicate",
            "needs_review",
            "duplicate_delivery",
            "uncertain",
            "id_collision",
            "suspect_replay",
            "unknown_meter",
            "unknown_device",
            "crc_error",
            "invalid",
            "too_old",
            "accepted",
            "unresolved",
            "conflict",
        ),
    ),
    postgresql_partition_by="RANGE (partition_month)",
)

ingest_message_keys = Table(
    "ingest_message_keys",
    metadata,
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), primary_key=True),
    Column("msg_key_namespace", Text, primary_key=True),
    Column("msg_key", Text, primary_key=True),
    Column("item_index", Integer, primary_key=True),
    Column("message_kind", Text, nullable=False),
    Column("first_received_at", TZ),
    Column("last_received_at", TZ),
    Column("delivery_count", Integer),
    Column("outcome", Text),
    Column("receipt_id", BigInteger),
    Column("receipt_partition_month", Date),
    _enum("message_kind", ("telegram", "decoded", "event", "heartbeat", "import_row")),
    _enum(
        "outcome",
        (
            "accepted",
            "duplicate",
            "probable_duplicate",
            "needs_review",
            "duplicate_delivery",
            "uncertain",
            "id_collision",
            "suspect_replay",
            "unknown_meter",
            "invalid",
            "too_old",
            "unresolved",
            "conflict",
        ),
    ),
    ForeignKeyConstraint(
        ["receipt_id", "receipt_partition_month"],
        ["ingest_receipts.id", "ingest_receipts.partition_month"],
    ),
)

raw_telegrams = Table(
    "raw_telegrams",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("meter_key", LargeBinary),
    Column("meter_id", BigInteger, ForeignKey("meters.id")),
    Column("access_number", SmallInteger),
    Column("ci_field", SmallInteger),
    Column("encryption_mode", Text),
    Column("canonical_frame", LargeBinary),
    Column("frame_hash", LargeBinary),
    Column("normalizer_version", Text),
    Column("anchor_at", TZ, nullable=False),
    Column("time_source", Text),
    Column("first_server_received_at", TZ),
    Column("receipt_count", Integer),
    Column("capture_device_ids", ARRAY(BigInteger)),
    Column("decode_status", Text),
    Column("decode_error", Text),
    Column("decoder_version", Text),
    CheckConstraint(_month.format(column="anchor_at"), name="partition_month"),
    _enum("decode_status", ("pending", "decoded", "failed", "no_key", "suspect_replay", "needs_review", "ambiguous")),
    postgresql_partition_by="RANGE (partition_month)",
)

telegram_dedup_keys = Table(
    "telegram_dedup_keys",
    metadata,
    Column("id", BigInteger, Identity(always=True), primary_key=True),
    Column("meter_key", LargeBinary, nullable=False),
    Column("access_number", SmallInteger, nullable=False),
    Column("frame_hash", LargeBinary, nullable=False),
    Column("anchor_at", TZ, nullable=False),
    Column("dedup_window", TSTZRANGE, nullable=False),
    Column("raw_telegram_id", BigInteger, nullable=False),
    Column("raw_partition_month", Date, nullable=False),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    ExcludeConstraint(
        ("meter_key", "="),
        ("access_number", "="),
        ("frame_hash", "="),
        ("dedup_window", "&&"),
        using="gist",
        name="ex_telegram_dedup_keys_window",
    ),
    ForeignKeyConstraint(
        ["raw_telegram_id", "raw_partition_month"],
        ["raw_telegrams.id", "raw_telegrams.partition_month"],
    ),
    Index("ix_telegram_dedup_keys_content", "meter_key", "access_number", "frame_hash"),
)

ingest_dedup_candidates = Table(
    "ingest_dedup_candidates",
    metadata,
    Column("receipt_id", BigInteger, primary_key=True),
    Column("receipt_partition_month", Date, primary_key=True),
    Column("candidate_raw_telegram_id", BigInteger, primary_key=True),
    Column("candidate_partition_month", Date, primary_key=True),
    ForeignKeyConstraint(
        ["receipt_id", "receipt_partition_month"],
        ["ingest_receipts.id", "ingest_receipts.partition_month"],
    ),
    postgresql_partition_by="RANGE (receipt_partition_month)",
)

ingest_fragment_sets = Table(
    "ingest_fragment_sets",
    metadata,
    _id(),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), nullable=False),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id")),
    Column("group_key", Text),
    Column("message_ref", Text),
    Column("expected_count", Integer),
    Column("received_count", Integer),
    Column("status", Text, nullable=False),
    Column("first_received_at", TZ),
    Column("deadline_at", TZ),
    Column("assembled_payload_id", BigInteger),
    Column("assembled_payload_partition_month", Date),
    _enum("status", ("collecting", "complete", "timed_out", "conflict", "isolated")),
    CheckConstraint(
        "(status = 'isolated' AND message_ref IS NULL AND deadline_at IS NULL) "
        "OR (status IN ('collecting', 'complete', 'timed_out', 'conflict') "
        "AND message_ref IS NOT NULL AND btrim(message_ref) <> '' AND deadline_at IS NOT NULL)",
        name="status_identity",
    ),
    CheckConstraint(
        "(assembled_payload_id IS NULL) = (assembled_payload_partition_month IS NULL)",
        name="assembled_pair",
    ),
    CheckConstraint("status = 'complete' OR assembled_payload_id IS NULL", name="assembled_only_complete"),
    ForeignKeyConstraint(
        ["assembled_payload_id", "assembled_payload_partition_month"],
        ["ingest_payloads.id", "ingest_payloads.partition_month"],
    ),
)

ingest_fragments = Table(
    "ingest_fragments",
    metadata,
    _id(),
    Column("fragment_set_id", BigInteger, ForeignKey("ingest_fragment_sets.id"), nullable=False),
    Column("fragment_index", Integer, nullable=False),
    Column("payload_id", BigInteger, nullable=False),
    Column("payload_partition_month", Date, nullable=False),
    Column("content_hash", LargeBinary, nullable=False),
    Column("source_message_ref", Text),
    Column("received_at", TZ),
    Column("delivery_role", Text, nullable=False),
    _enum("delivery_role", ("first", "repeat", "conflict")),
    ForeignKeyConstraint(
        ["payload_id", "payload_partition_month"],
        ["ingest_payloads.id", "ingest_payloads.partition_month"],
    ),
    Index(
        "uq_ingest_fragments_first",
        "fragment_set_id",
        "fragment_index",
        unique=True,
        postgresql_where=text("delivery_role = 'first'"),
    ),
)

ingest_rejections = Table(
    "ingest_rejections",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("received_at", TZ, nullable=False),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id")),
    Column("endpoint_id", BigInteger, ForeignKey("ingest_endpoints.id")),
    Column("device_id", BigInteger, ForeignKey("devices.id")),
    Column("transport", Text),
    Column("reason", Text, nullable=False),
    Column("payload_id", BigInteger),
    Column("payload_partition_month", Date),
    Column("fragment_set_id", BigInteger, ForeignKey("ingest_fragment_sets.id")),
    Column("detail", JSONB),
    CheckConstraint(_month.format(column="received_at"), name="partition_month"),
    CheckConstraint(
        "(payload_id IS NULL) = (payload_partition_month IS NULL)",
        name="payload_pair",
    ),
    _enum("transport", ("mqtt", "https", "udp_dtls", "platform_api", "file_import")),
    _enum(
        "reason",
        (
            "auth_failed",
            "payload_too_large",
            "replay",
            "stale",
            "fragment_timeout",
            "fragment_conflict",
            "fragment_unidentified",
            "unparseable",
            "endpoint_disabled",
            "rate_limited",
        ),
    ),
    ForeignKeyConstraint(
        ["payload_id", "payload_partition_month"],
        ["ingest_payloads.id", "ingest_payloads.partition_month"],
    ),
    postgresql_partition_by="RANGE (partition_month)",
)

unknown_meter_sightings = Table(
    "unknown_meter_sightings",
    metadata,
    Column("meter_key", LargeBinary, primary_key=True),
    Column("first_seen_at", TZ),
    Column("last_seen_at", TZ),
    Column("sighting_count", Integer),
    Column("last_device_id", BigInteger, ForeignKey("devices.id")),
    Column("last_rssi", Integer),
)

decoded_observations = Table(
    "decoded_observations",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), nullable=False),
    Column("msg_key", Text),
    Column("msg_key_namespace", Text),
    Column("item_index", Integer, nullable=False),
    Column("content_hash", LargeBinary, nullable=False),
    Column("device_id", BigInteger, ForeignKey("devices.id")),
    Column("source_stream_id", BigInteger, ForeignKey("source_streams.id")),
    Column("external_meter_ref", Text),
    Column("meter_id", BigInteger, ForeignKey("meters.id")),
    Column("source_measured_at", TZ),
    Column("source_time_kind", Text),
    Column("server_received_at", TZ, nullable=False),
    Column("access_number", SmallInteger),
    Column("measurement_ref", Text),
    Column("values", JSONB),
    Column("vendor_payload", JSONB),
    Column("payload_id", BigInteger, nullable=False),
    Column("payload_partition_month", Date, nullable=False),
    Column("adapter", Text),
    Column("adapter_version", Text),
    Column("status", Text),
    CheckConstraint(_month.format(column="server_received_at"), name="partition_month"),
    CheckConstraint("payload_partition_month = partition_month", name="payload_month"),
    _enum("source_time_kind", ("meter_clock", "concentrator_rx", "platform_time", "unknown")),
    _enum("status", ("accepted", "unresolved", "conflict", "uncertain", "unknown_meter", "invalid")),
    ForeignKeyConstraint(
        ["payload_id", "payload_partition_month"],
        ["ingest_payloads.id", "ingest_payloads.partition_month"],
    ),
    postgresql_partition_by="RANGE (partition_month)",
)

decode_queue = Table(
    "decode_queue",
    metadata,
    Column("raw_telegram_id", BigInteger, primary_key=True),
    Column("raw_partition_month", Date, primary_key=True),
    Column("attempts", Integer),
    Column("next_attempt_at", TZ),
    Column("locked_by", Text),
    Column("locked_at", TZ),
    Column("last_error", Text),
    ForeignKeyConstraint(
        ["raw_telegram_id", "raw_partition_month"],
        ["raw_telegrams.id", "raw_telegrams.partition_month"],
    ),
)

meter_readings = Table(
    "meter_readings",
    metadata,
    _id(),
    Column("meter_id", BigInteger, ForeignKey("meters.id"), nullable=False),
    Column("source_stream_id", BigInteger, ForeignKey("source_streams.id"), nullable=False),
    Column("source_key", Text, nullable=False),
    Column("source_kind", Text, nullable=False),
    Column("reading_kind", Text, nullable=False),
    Column("quality", Text, nullable=False),
    Column("raw_telegram_id", BigInteger),
    Column("decoded_observation_id", BigInteger),
    Column("measured_at", TZ),
    Column("time_basis", Text),
    Column("time_source", Text),
    Column("primary_value", Numeric(18, 6)),
    Column("unit", Text),
    Column("quantity", Text),
    Column("values", JSONB),
    Column("status_flags", ARRAY(Text)),
    Column("decoder_version", Text),
    Column("adapter", Text),
    Column("adapter_version", Text),
    Column("normalizer_version", Text),
    Column("frame_hash", LargeBinary),
    Column("access_number", SmallInteger),
    Column("receipt_count", Integer),
    Column("capture_device_ids", ARRAY(BigInteger)),
    Column("corrects_reading_id", BigInteger, ForeignKey("meter_readings.id")),
    Column("accepted_at", TZ),
    Column("accepted_by", BigInteger),
    Column("superseded_at", TZ),
    Column("created_at", TZ, nullable=False, server_default=text("now()")),
    Column("created_by", BigInteger),
    _enum("source_kind", ("radio", "vendor_decoded", "manual", "correction", "import")),
    _enum("reading_kind", ("cumulative", "interval", "event")),
    _enum("quality", ("valid", "suspect", "invalid")),
    _enum("time_basis", ("meter_clock", "capture_estimate", "source_time", "manual")),
    CheckConstraint("reading_kind <> 'cumulative' OR primary_value IS NOT NULL", name="cumulative_value"),
    Index("uq_meter_readings_source_key", "source_key", unique=True),
    Index(
        "meter_readings_vendor_time_guard",
        "meter_id",
        "source_stream_id",
        "measured_at",
        unique=True,
        postgresql_where=text(
            "source_kind = 'vendor_decoded' AND reading_kind = 'cumulative' AND superseded_at IS NULL"
        ),
    ),
    Index("ix_meter_readings_meter_measured", "meter_id", "measured_at"),
    Index("ix_meter_readings_meter_stream_measured", "meter_id", "source_stream_id", "measured_at"),
    Index("ix_meter_readings_measured_at_brin", "measured_at", postgresql_using="brin"),
)

reading_provenance = Table(
    "reading_provenance",
    metadata,
    Column("reading_id", BigInteger, ForeignKey("meter_readings.id"), primary_key=True),
    Column("ingest_source_id", BigInteger, ForeignKey("ingest_sources.id"), nullable=False),
    Column("message_id", Text),
    Column("msg_key_namespace", Text),
    Column("item_index", Integer),
    Column("content_hash", LargeBinary, nullable=False),
    Column("transport", Text),
    Column("endpoint_code", Text),
    Column("first_server_received_at", TZ),
    Column("confirmed_source_ids", ARRAY(BigInteger)),
    _enum("transport", ("mqtt", "https", "udp_dtls", "platform_api", "file_import", "manual")),
)

device_events = Table(
    "device_events",
    metadata,
    Column("id", BigInteger, Identity(always=False), primary_key=True),
    Column("partition_month", Date, primary_key=True),
    Column("device_id", BigInteger, ForeignKey("devices.id"), nullable=False),
    Column("msg_key", Text),
    Column("kind", Text),
    Column("occurred_at", TZ),
    Column("received_at", TZ, nullable=False),
    Column("payload", JSONB),
    CheckConstraint(_month.format(column="received_at"), name="partition_month"),
    postgresql_partition_by="RANGE (partition_month)",
)
