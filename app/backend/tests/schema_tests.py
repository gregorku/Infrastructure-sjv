"""Live checks for the ingest migration. Prints no passwords."""

import os

import psycopg

URL = os.environ["SJV_DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)

TABLES = (
    "source_streams",
    "meters",
    "meter_external_ids",
    "devices",
    "device_external_ids",
    "device_firmware_history",
    "device_capabilities",
    "device_credentials",
    "device_boots",
    "ingest_endpoints",
    "endpoint_credentials",
    "ingest_sources",
    "ingest_payloads",
    "ingest_payload_items",
    "ingest_receipts",
    "ingest_message_keys",
    "raw_telegrams",
    "telegram_dedup_keys",
    "ingest_dedup_candidates",
    "ingest_fragment_sets",
    "ingest_fragments",
    "ingest_rejections",
    "unknown_meter_sightings",
    "decoded_observations",
    "decode_queue",
    "meter_readings",
    "reading_provenance",
    "device_events",
    "retention_log",
)


def fail(message):
    raise SystemExit(message)


def expect_sqlstate(conn, role, statement, sqlstate):
    try:
        with conn.transaction():
            conn.execute(f"SET LOCAL ROLE {role}")
            conn.execute(statement)
    except psycopg.Error as exc:
        if exc.sqlstate != sqlstate:
            fail(f"statement as {role} raised {exc.sqlstate}, expected {sqlstate}")
        return
    fail(f"statement as {role} was allowed")


def main():
    with psycopg.connect(URL, autocommit=True) as conn:
        missing = conn.execute(
            "SELECT name FROM unnest(%s::text[]) AS name "
            "WHERE NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = name AND relkind IN ('r', 'p'))",
            (list(TABLES),),
        ).fetchall()
        if missing:
            fail("missing tables: " + ", ".join(row[0] for row in missing))
        print("PASS tables")

        role = conn.execute(
            "SELECT rolsuper, rolinherit, rolcreatedb, rolcreaterole, rolcanlogin, rolbypassrls "
            "FROM pg_roles WHERE rolname = 'sjv_collector'"
        ).fetchone()
        if role != (False, False, False, False, True, False):
            fail(f"sjv_collector attributes changed: {role}")
        print("PASS collector attributes")

        unique_message_ref = conn.execute(
            """
            SELECT c.relname
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_class t ON t.oid = i.indrelid
            WHERE i.indisunique
              AND t.relname = 'ingest_fragment_sets'
              AND pg_get_indexdef(i.indexrelid) ILIKE '%%message_ref%%'
            """
        ).fetchall()
        if unique_message_ref:
            fail("message_ref has a unique index")
        print("PASS no message_ref unique constraint")

        trigger = conn.execute(
            "SELECT 1 FROM pg_trigger WHERE tgname = 'trg_ingest_fragment_sets_status' AND NOT tgisinternal"
        ).fetchone()
        if trigger is None:
            fail("fragment status trigger is missing")
        delivery = conn.execute(
            """
            SELECT pg_get_triggerdef(oid)
            FROM pg_trigger
            WHERE tgname = 'trg_ingest_fragments_delivery_role' AND NOT tgisinternal
            """
        ).fetchone()
        if delivery is None or "UPDATE OF delivery_role" not in delivery[0]:
            fail(f"fragment delivery role trigger is missing or wrong: {delivery}")
        print("PASS trigger")

        version = conn.execute("SELECT version_num FROM alembic_version").fetchone()
        if version != ("0003_retention",):
            fail(f"alembic version is {version}")
        print("PASS alembic version")

        missing_pk = conn.execute(
            """
            SELECT relname
            FROM pg_class
            WHERE relname = ANY(%s)
              AND relkind IN ('r', 'p')
              AND NOT EXISTS (
                  SELECT 1 FROM pg_constraint
                  WHERE conrelid = pg_class.oid AND contype = 'p'
              )
            """,
            (list(TABLES),),
        ).fetchall()
        if missing_pk:
            fail("missing primary keys: " + ", ".join(row[0] for row in missing_pk))
        print("PASS primary keys")

        parents = (
            "ingest_payloads",
            "ingest_payload_items",
            "ingest_receipts",
            "ingest_dedup_candidates",
            "ingest_rejections",
            "raw_telegrams",
            "decoded_observations",
            "device_events",
        )
        partitioned = conn.execute(
            """
            SELECT c.relname
            FROM pg_class AS c
            JOIN pg_partitioned_table AS p ON p.partrelid = c.oid
            WHERE c.relname = ANY(%s)
            """,
            (list(parents),),
        ).fetchall()
        if sorted(row[0] for row in partitioned) != sorted(parents):
            fail(f"partition parents are {partitioned}")
        children = conn.execute(
            "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relname ~ '_p[0-9]{6}$'"
        ).fetchone()[0]
        if children < len(parents) * 4:
            fail(f"expected at least {len(parents) * 4} month partitions, found {children}")
        print("PASS partitions")

        conn.execute("INSERT INTO source_streams (code, kind) VALUES ('radio', 'radio')")
        conn.execute(
            "INSERT INTO meters (meter_key, medium, status) "
            "VALUES (decode('0102030405060708', 'hex'), 'cold_water', 'active')"
        )
        conn.execute("INSERT INTO devices (code, kind, status) VALUES ('ESP-SJV-001', 'esp32', 'active')")
        conn.execute(
            "INSERT INTO ingest_endpoints (code, transport, status, max_payload_bytes) "
            "VALUES ('esp-https', 'https', 'active', 1048576)"
        )
        conn.execute(
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_enc) "
            "SELECT id, 'dtls_psk', 'kek_enc', decode('0011', 'hex') "
            "FROM ingest_endpoints WHERE code = 'esp-https'"
        )

        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_collector")
            conn.execute(
                "INSERT INTO ingest_sources (code, kind, device_id) "
                "SELECT 'esp-sjv-001', 'device', id FROM devices WHERE code = 'ESP-SJV-001'"
            )
            conn.execute(
                """
                INSERT INTO ingest_payloads (
                    partition_month, ingest_source_id, transport, received_at,
                    content_kind, payload, origin
                )
                SELECT date_trunc('month', now() AT TIME ZONE 'UTC')::date,
                       id, 'https', now(), 'json', convert_to('{}', 'UTF8'), 'received'
                FROM ingest_sources WHERE code = 'esp-sjv-001'
                """
            )
            conn.execute(
                """
                INSERT INTO ingest_receipts (
                    partition_month, server_received_at, payload_id, payload_partition_month,
                    content_hash, item_index, ingest_source_id, status
                )
                SELECT date_trunc('month', payloads.received_at AT TIME ZONE 'UTC')::date,
                       payloads.received_at, payloads.id, payloads.partition_month,
                       sha256('item'), 0, payloads.ingest_source_id, 'accepted'
                FROM ingest_payloads AS payloads
                JOIN ingest_sources AS sources ON sources.id = payloads.ingest_source_id
                WHERE sources.code = 'esp-sjv-001'
                """
            )
            conn.execute(
                "INSERT INTO ingest_rejections (partition_month, received_at, reason) "
                "VALUES (date_trunc('month', now() AT TIME ZONE 'UTC')::date, now(), 'unparseable')"
            )
            conn.execute(
                """
                INSERT INTO ingest_message_keys (
                    ingest_source_id, msg_key_namespace, msg_key, item_index, message_kind
                )
                SELECT id, namespace, 'same-key', item_index, 'decoded'
                FROM ingest_sources
                CROSS JOIN (VALUES ('https', 0), ('https', 1), ('mqtt', 0)) AS items(namespace, item_index)
                WHERE code = 'esp-sjv-001'
                """
            )
            conn.execute(
                """
                INSERT INTO ingest_fragment_sets (ingest_source_id, group_key, status, first_received_at)
                SELECT id, 'group-a', 'isolated', now()
                FROM ingest_sources WHERE code = 'esp-sjv-001'
                """
            )
            conn.execute(
                """
                INSERT INTO ingest_fragments (
                    fragment_set_id, fragment_index, payload_id, payload_partition_month,
                    content_hash, received_at, delivery_role
                )
                SELECT sets.id, 0, payloads.id, payloads.partition_month, sha256('fragment'), now(), 'first'
                FROM ingest_fragment_sets AS sets
                JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
                WHERE sets.group_key = 'group-a'
                """
            )
            conn.execute(
                "UPDATE devices SET last_seen_at = now() "
                "WHERE code = 'ESP-SJV-001'"
            )
        print("PASS collector writes")

        expect_sqlstate(
            conn,
            "sjv_collector",
            "INSERT INTO devices (code, kind, status) VALUES ('ESP-SJV-002', 'esp32', 'active')",
            "42501",
        )
        expect_sqlstate(conn, "sjv_collector", "CREATE TABLE collector_forbidden (id integer)", "42501")
        expect_sqlstate(conn, "sjv_collector", "SELECT secret_enc FROM endpoint_credentials", "42501")
        expect_sqlstate(conn, "sjv_collector", "SELECT aes_key_enc FROM meters", "42501")
        expect_sqlstate(conn, "sjv_collector", "DELETE FROM ingest_payloads", "42501")
        expect_sqlstate(conn, "sjv_collector", "DELETE FROM ingest_payload_items", "42501")
        expect_sqlstate(
            conn,
            "sjv_collector",
            "UPDATE ingest_payload_items SET message_kind = 'event'",
            "42501",
        )
        expect_sqlstate(conn, "sjv_api", "SELECT original FROM ingest_payload_items", "42501")
        expect_sqlstate(
            conn,
            "sjv_api",
            "INSERT INTO ingest_payload_items "
            "(partition_month, payload_id, payload_partition_month, item_index, original) "
            "VALUES (DATE '2026-11-01', 1, DATE '2026-11-01', 0, '\\x00')",
            "42501",
        )
        expect_sqlstate(
            conn,
            "sjv_collector",
            """
            INSERT INTO ingest_payload_items (
                partition_month, payload_id, payload_partition_month, item_index, original
            )
            SELECT partition_month, id, partition_month, -1, '\\x00'::bytea
            FROM ingest_payloads
            LIMIT 1
            """,
            "23514",
        )
        expect_sqlstate(
            conn,
            "sjv_collector",
            """
            INSERT INTO ingest_payload_items (
                partition_month, payload_id, payload_partition_month, item_index, original
            )
            SELECT partition_month, id, DATE '1999-01-01', 0, '\\x00'::bytea
            FROM ingest_payloads
            LIMIT 1
            """,
            "23514",
        )
        privileges = conn.execute(
            """
            SELECT
                has_table_privilege('sjv_readonly', 'ingest_payload_items', 'SELECT'),
                has_table_privilege('sjv_readonly', 'ingest_payload_items', 'INSERT'),
                has_table_privilege('sjv_collector', 'ingest_payload_items', 'SELECT'),
                has_table_privilege('sjv_collector', 'ingest_payload_items', 'INSERT'),
                has_table_privilege('sjv_collector', 'ingest_payload_items', 'UPDATE'),
                has_table_privilege('sjv_collector', 'ingest_payload_items', 'DELETE'),
                has_table_privilege('sjv_api', 'ingest_payload_items', 'SELECT'),
                has_table_privilege('sjv_api', 'ingest_payload_items', 'INSERT'),
                has_table_privilege('sjv_worker', 'ingest_payload_items', 'SELECT'),
                has_table_privilege('sjv_worker', 'ingest_payload_items', 'INSERT'),
                has_table_privilege('sjv_maintenance', 'ingest_payload_items', 'SELECT'),
                has_table_privilege('sjv_maintenance', 'ingest_payload_items', 'INSERT'),
                has_table_privilege('sjv_maintenance', 'ingest_payload_items', 'UPDATE'),
                has_table_privilege('sjv_maintenance', 'ingest_payload_items', 'DELETE'),
                has_function_privilege(
                    'sjv_maintenance',
                    'sjv_create_month_partition(regclass, date)',
                    'EXECUTE'
                )
            """
        ).fetchone()
        if privileges != (
            True, False,
            True, True, False, False,
            False, False,
            False, False,
            False, False, False, False,
            True,
        ):
            fail(f"payload item privileges are {privileges}")
        expect_sqlstate(
            conn,
            "sjv_collector",
            "UPDATE devices SET last_ip = '203.0.113.5' WHERE code = 'ESP-SJV-001'",
            "42501",
        )
        expect_sqlstate(conn, "sjv_api", "SELECT secret_enc FROM endpoint_credentials", "42501")
        expect_sqlstate(conn, "sjv_worker", "SELECT secret_enc FROM endpoint_credentials", "42501")
        expect_sqlstate(
            conn,
            "sjv_collector",
            "INSERT INTO meter_readings (meter_id, source_stream_id, source_key, source_kind, reading_kind, quality) "
            "VALUES (1, 1, 'raw:denied', 'radio', 'event', 'valid')",
            "42501",
        )
        expect_sqlstate(
            conn,
            "sjv_worker",
            "INSERT INTO meter_readings (meter_id, source_stream_id, source_key, source_kind, reading_kind, quality) "
            "VALUES (1, 1, 'raw:denied', 'radio', 'event', 'valid')",
            "42501",
        )
        print("PASS collector denials")

        conn.execute("INSERT INTO devices (code, kind, status) VALUES ('ESP-SJV-002', 'esp32', 'active')")
        conn.execute(
            "INSERT INTO ingest_sources (code, kind, device_id) "
            "SELECT 'esp-sjv-002', 'device', id FROM devices WHERE code = 'ESP-SJV-002'"
        )
        conn.execute(
            """
            INSERT INTO ingest_message_keys (
                ingest_source_id, msg_key_namespace, msg_key, item_index, message_kind
            )
            SELECT id, 'https', 'same-key', 0, 'decoded'
            FROM ingest_sources WHERE code = 'esp-sjv-002'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragment_sets (ingest_source_id, group_key, status, first_received_at)
            SELECT id, 'group-a', 'isolated', now()
            FROM ingest_sources WHERE code = 'esp-sjv-001'
            """
        )
        print("PASS separate source, item and namespace keys")
        print("PASS same group_key does not merge sets")

        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            UPDATE ingest_fragment_sets
            SET status = 'collecting', message_ref = 'proven', deadline_at = now()
            WHERE group_key = 'group-a'
            """,
            "23514",
        )
        print("PASS isolated status cannot change")

        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            INSERT INTO ingest_fragment_sets (ingest_source_id, status, first_received_at)
            SELECT id, 'collecting', now() FROM ingest_sources WHERE code = 'esp-sjv-001'
            """,
            "23514",
        )
        print("PASS collecting requires message_ref and deadline")

        conn.execute(
            """
            INSERT INTO ingest_fragment_sets (
                ingest_source_id, group_key, message_ref, status, first_received_at, deadline_at
            )
            SELECT id, 'group-timeout', 'ref-timeout', 'collecting', now(), now()
            FROM ingest_sources WHERE code = 'esp-sjv-001'
            """
        )
        conn.execute(
            "UPDATE ingest_fragment_sets SET status = 'timed_out' WHERE message_ref = 'ref-timeout'"
        )
        print("PASS timed_out set can be stored")
        reasons = conn.execute(
            """
            SELECT pg_get_constraintdef(oid)
            FROM pg_constraint
            WHERE conrelid = 'ingest_rejections'::regclass
              AND pg_get_constraintdef(oid) ILIKE '%%unassigned%%'
            """
        ).fetchall()
        if reasons:
            fail("a rejection reason for the unassigned timed_out delivery was invented")
        print("PASS timed_out follow-up is not modeled")

        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 1, payloads.id, payloads.partition_month, sha256('repeat-isolated'),
                   now(), 'repeat'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
            WHERE sets.group_key = 'group-a' AND sets.status = 'isolated'
            LIMIT 1
            """,
            "23514",
        )
        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 2, payloads.id, payloads.partition_month, sha256('conflict-isolated'),
                   now(), 'conflict'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
            WHERE sets.group_key = 'group-a' AND sets.status = 'isolated'
            LIMIT 1
            """,
            "23514",
        )
        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            UPDATE ingest_fragments
            SET delivery_role = 'repeat'
            WHERE id = (
                SELECT fragments.id
                FROM ingest_fragments AS fragments
                JOIN ingest_fragment_sets AS sets ON sets.id = fragments.fragment_set_id
                WHERE sets.group_key = 'group-a' AND fragments.delivery_role = 'first'
                LIMIT 1
            )
            """,
            "23514",
        )
        conn.execute(
            """
            UPDATE ingest_fragments
            SET delivery_role = 'first'
            WHERE id = (
                SELECT fragments.id
                FROM ingest_fragments AS fragments
                JOIN ingest_fragment_sets AS sets ON sets.id = fragments.fragment_set_id
                WHERE sets.group_key = 'group-a' AND fragments.delivery_role = 'first'
                LIMIT 1
            )
            """
        )
        expect_sqlstate(
            conn,
            "sjv_owner",
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 1, payloads.id, payloads.partition_month, sha256('repeat-timeout'),
                   now(), 'repeat'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_sources AS sources ON sources.id = sets.ingest_source_id
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sources.id
            WHERE sets.message_ref = 'ref-timeout'
            LIMIT 1
            """,
            "23514",
        )
        conn.execute(
            """
            INSERT INTO ingest_fragment_sets (
                ingest_source_id, group_key, message_ref, status, first_received_at, deadline_at
            )
            SELECT id, 'group-collect', 'ref-collect', 'collecting', now(), now()
            FROM ingest_sources WHERE code = 'esp-sjv-001'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 0, payloads.id, payloads.partition_month, sha256('first-collect'),
                   now(), 'first'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
            WHERE sets.message_ref = 'ref-collect'
            LIMIT 1
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 0, payloads.id, payloads.partition_month, sha256('repeat-collect'),
                   now(), 'repeat'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
            WHERE sets.message_ref = 'ref-collect' AND sets.status = 'collecting'
            LIMIT 1
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 0, payloads.id, payloads.partition_month, sha256('conflict-collect'),
                   now(), 'conflict'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.ingest_source_id = sets.ingest_source_id
            WHERE sets.message_ref = 'ref-collect' AND sets.status = 'collecting'
            LIMIT 1
            """
        )
        conn.execute(
            "UPDATE ingest_fragment_sets SET status = 'conflict' WHERE message_ref = 'ref-collect'"
        )
        conn.execute(
            """
            UPDATE ingest_fragments
            SET received_at = received_at
            WHERE delivery_role = 'conflict'
              AND fragment_set_id = (
                  SELECT id FROM ingest_fragment_sets WHERE message_ref = 'ref-collect'
              )
            """
        )
        conn.execute(
            """
            UPDATE ingest_fragments
            SET delivery_role = 'conflict'
            WHERE delivery_role = 'conflict'
              AND fragment_set_id = (
                  SELECT id FROM ingest_fragment_sets WHERE message_ref = 'ref-collect'
              )
            """
        )
        print("PASS fragment delivery role")

        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_collector")
            conn.execute(
                """
                INSERT INTO raw_telegrams (partition_month, anchor_at, decode_status)
                VALUES (
                    date_trunc('month', now() AT TIME ZONE 'UTC')::date,
                    now(),
                    'pending'
                )
                """
            )
            conn.execute(
                """
                INSERT INTO decode_queue (raw_telegram_id, raw_partition_month, attempts)
                SELECT id, partition_month, 0
                FROM raw_telegrams
                WHERE decode_status = 'pending'
                ORDER BY id
                LIMIT 1
                """
            )
        expect_sqlstate(conn, "sjv_collector", "SELECT raw_telegram_id FROM decode_queue", "42501")
        expect_sqlstate(
            conn,
            "sjv_collector",
            "UPDATE decode_queue SET attempts = 1",
            "42501",
        )
        expect_sqlstate(conn, "sjv_collector", "DELETE FROM decode_queue", "42501")
        api_telegram = conn.execute(
            """
            INSERT INTO raw_telegrams (partition_month, anchor_at, decode_status)
            VALUES (date_trunc('month', now() AT TIME ZONE 'UTC')::date, now(), 'pending')
            RETURNING id, partition_month
            """
        ).fetchone()
        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_api")
            conn.execute(
                "INSERT INTO decode_queue (raw_telegram_id, raw_partition_month, attempts) "
                "VALUES (%s, %s, 0)",
                (api_telegram[0], api_telegram[1]),
            )
        expect_sqlstate(conn, "sjv_api", "SELECT raw_telegram_id FROM decode_queue", "42501")
        expect_sqlstate(conn, "sjv_api", "UPDATE decode_queue SET attempts = 2", "42501")
        expect_sqlstate(conn, "sjv_api", "DELETE FROM decode_queue", "42501")
        expect_sqlstate(
            conn,
            "sjv_worker",
            """
            INSERT INTO decode_queue (raw_telegram_id, raw_partition_month)
            VALUES (1, DATE '2026-11-01')
            """,
            "42501",
        )
        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_worker")
            locked = conn.execute(
                """
                SELECT raw_telegram_id
                FROM decode_queue
                ORDER BY raw_telegram_id
                FOR UPDATE SKIP LOCKED
                """
            ).fetchall()
            if len(locked) != 2:
                fail(f"worker locked {len(locked)} queue rows")
            conn.execute(
                """
                UPDATE decode_queue
                SET attempts = 1, next_attempt_at = now(), locked_by = 'worker-1',
                    locked_at = now(), last_error = NULL
                WHERE raw_telegram_id = %s
                """,
                (locked[0][0],),
            )
            conn.execute(
                "DELETE FROM decode_queue WHERE raw_telegram_id = %s",
                (locked[1][0],),
            )
        expect_sqlstate(
            conn,
            "sjv_worker",
            "UPDATE decode_queue SET raw_partition_month = raw_partition_month",
            "42501",
        )
        print("PASS decode queue privileges")

        received_null = conn.execute(
            """
            SELECT attnotnull
            FROM pg_attribute
            WHERE attrelid = 'device_events'::regclass
              AND attname = 'received_at'
              AND NOT attisdropped
            """
        ).fetchone()
        occurred_null = conn.execute(
            """
            SELECT attnotnull
            FROM pg_attribute
            WHERE attrelid = 'device_events'::regclass
              AND attname = 'occurred_at'
              AND NOT attisdropped
            """
        ).fetchone()
        if received_null != (True,) or occurred_null != (False,):
            fail(f"device event nullability is received {received_null}, occurred {occurred_null}")
        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_collector")
            conn.execute(
                """
                INSERT INTO device_events (
                    partition_month, device_id, occurred_at, received_at
                )
                SELECT DATE '2026-11-01', id,
                       TIMESTAMPTZ '2026-12-15 12:00:00+00',
                       TIMESTAMPTZ '2026-11-20 12:00:00+00'
                FROM devices WHERE code = 'ESP-SJV-001'
                """
            )
            conn.execute(
                """
                INSERT INTO device_events (partition_month, device_id, received_at)
                SELECT DATE '2026-11-01', id, TIMESTAMPTZ '2026-11-30 23:30:00+00'
                FROM devices WHERE code = 'ESP-SJV-001'
                """
            )
            conn.execute(
                """
                INSERT INTO device_events (partition_month, device_id, received_at)
                SELECT DATE '2026-11-01', id, TIMESTAMPTZ '2026-12-01 00:30:00+01'
                FROM devices WHERE code = 'ESP-SJV-001'
                """
            )
        expect_sqlstate(
            conn,
            "sjv_collector",
            """
            INSERT INTO device_events (partition_month, device_id, occurred_at)
            SELECT DATE '2026-11-01', id, TIMESTAMPTZ '2026-11-20 12:00:00+00'
            FROM devices WHERE code = 'ESP-SJV-001'
            """,
            "23502",
        )
        expect_sqlstate(
            conn,
            "sjv_collector",
            """
            INSERT INTO device_events (
                partition_month, device_id, occurred_at, received_at
            )
            SELECT DATE '2026-12-01', id,
                   TIMESTAMPTZ '2026-12-15 12:00:00+00',
                   TIMESTAMPTZ '2026-11-20 12:00:00+00'
            FROM devices WHERE code = 'ESP-SJV-001'
            """,
            "23514",
        )
        print("PASS device event month")

        conn.execute(
            """
            INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_hash)
            SELECT id, 'bearer', 'hash', 'hash-bearer'
            FROM ingest_endpoints WHERE code = 'esp-https'
            """
        )
        conn.execute(
            """
            INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_hash)
            SELECT id, 'basic', 'hash', 'hash-basic'
            FROM ingest_endpoints WHERE code = 'esp-https'
            """
        )
        conn.execute(
            """
            INSERT INTO endpoint_credentials (endpoint_id, kind, storage, cert_fingerprint)
            SELECT id, 'client_cert', 'hash', 'fingerprint-cert'
            FROM ingest_endpoints WHERE code = 'esp-https'
            """
        )
        for statement in (
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_enc) "
            "SELECT id, 'bearer', 'kek_enc', decode('2211', 'hex') FROM ingest_endpoints WHERE code = 'esp-https'",
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, cert_fingerprint) "
            "SELECT id, 'bearer', 'hash', 'fingerprint-bearer' FROM ingest_endpoints WHERE code = 'esp-https'",
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_hash, cert_fingerprint) "
            "SELECT id, 'basic', 'hash', 'hash-basic-2', 'fingerprint-basic' "
            "FROM ingest_endpoints WHERE code = 'esp-https'",
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_hash) "
            "SELECT id, 'client_cert', 'hash', 'hash-cert' FROM ingest_endpoints WHERE code = 'esp-https'",
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_hash) "
            "SELECT id, 'dtls_psk', 'hash', 'hash-psk' FROM ingest_endpoints WHERE code = 'esp-https'",
            "INSERT INTO endpoint_credentials (endpoint_id, kind, storage, secret_enc, secret_hash) "
            "SELECT id, 'dtls_psk', 'kek_enc', decode('3311', 'hex'), 'hash-psk' "
            "FROM ingest_endpoints WHERE code = 'esp-https'",
        ):
            expect_sqlstate(conn, "sjv_owner", statement, "23514")
        print("PASS endpoint credential mapping")

        membership = conn.execute(
            """
            SELECT count(*)
            FROM pg_auth_members AS pam
            JOIN pg_roles AS member ON member.oid = pam.member
            JOIN pg_roles AS granted ON granted.oid = pam.roleid
            WHERE member.rolname = 'sjv_readonly' OR granted.rolname = 'sjv_readonly'
            """
        ).fetchone()[0]
        if membership != 0:
            fail(f"sjv_readonly has role membership: {membership}")
        inherit = conn.execute(
            "SELECT rolinherit FROM pg_roles WHERE rolname = 'sjv_readonly'"
        ).fetchone()[0]
        if inherit:
            fail("sjv_readonly inherits another role")
        table_acl = conn.execute(
            """
            SELECT privilege_type
            FROM aclexplode((SELECT relacl FROM pg_class WHERE oid = 'endpoint_credentials'::regclass)) AS priv
            JOIN pg_roles AS grantee ON grantee.oid = priv.grantee
            WHERE grantee.rolname = 'sjv_readonly'
            """
        ).fetchall()
        if table_acl:
            fail(f"sjv_readonly has table privileges: {table_acl}")
        if conn.execute(
            "SELECT has_table_privilege('sjv_readonly', 'endpoint_credentials', 'SELECT')"
        ).fetchone()[0]:
            fail("sjv_readonly has table SELECT")
        for column, allowed in (
            ("id", True),
            ("endpoint_id", True),
            ("kind", True),
            ("storage", True),
            ("created_at", True),
            ("revoked_at", True),
            ("secret_hash", False),
            ("cert_fingerprint", False),
            ("secret_enc", False),
        ):
            actual = conn.execute(
                "SELECT has_column_privilege('sjv_readonly', 'endpoint_credentials', %s, 'SELECT')",
                (column,),
            ).fetchone()[0]
            if actual is not allowed:
                fail(f"sjv_readonly column {column} privilege is {actual}")
        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_readonly")
            visible = conn.execute(
                """
                SELECT kind, storage
                FROM endpoint_credentials
                WHERE kind = 'dtls_psk' AND storage = 'kek_enc'
                """
            ).fetchone()
            if visible != ("dtls_psk", "kek_enc"):
                fail(f"readonly metadata read returned {visible}")
        expect_sqlstate(conn, "sjv_readonly", "SELECT secret_enc FROM endpoint_credentials", "42501")
        expect_sqlstate(conn, "sjv_readonly", "SELECT secret_hash FROM endpoint_credentials", "42501")
        expect_sqlstate(conn, "sjv_readonly", "SELECT cert_fingerprint FROM endpoint_credentials", "42501")
        expect_sqlstate(conn, "sjv_readonly", "SELECT * FROM endpoint_credentials", "42501")
        for role in ("sjv_collector", "sjv_api", "sjv_worker"):
            if conn.execute(
                "SELECT has_column_privilege(%s, 'endpoint_credentials', 'secret_enc', 'SELECT')",
                (role,),
            ).fetchone()[0]:
                fail(f"{role} can read secret_enc")
            expect_sqlstate(conn, role, "SELECT secret_enc FROM endpoint_credentials", "42501")
        owner = conn.execute(
            """
            SELECT
                relowner::regrole::text = 'sjv_owner',
                has_table_privilege('sjv_owner', 'endpoint_credentials', 'SELECT'),
                has_table_privilege('sjv_owner', 'endpoint_credentials', 'INSERT'),
                has_table_privilege('sjv_owner', 'endpoint_credentials', 'UPDATE'),
                has_table_privilege('sjv_owner', 'endpoint_credentials', 'DELETE'),
                has_column_privilege('sjv_owner', 'endpoint_credentials', 'secret_enc', 'SELECT')
            FROM pg_class
            WHERE oid = 'endpoint_credentials'::regclass
            """
        ).fetchone()
        if owner != (True, True, True, True, True, True):
            fail(f"owner privileges changed: {owner}")
        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_owner")
            owned = conn.execute(
                "SELECT encode(secret_enc, 'hex') FROM endpoint_credentials WHERE kind = 'dtls_psk'"
            ).fetchone()
            if owned != ("0011",):
                fail(f"owner secret read returned {owned}")
        print("PASS endpoint credential privileges")

        with conn.transaction():
            conn.execute("SET LOCAL ROLE sjv_maintenance")
            conn.execute("SELECT sjv_create_month_partition('ingest_payloads'::regclass, DATE '2020-01-01')")
            conn.execute("SELECT sjv_create_month_partition('ingest_payload_items'::regclass, DATE '2020-01-01')")
            conn.execute("SELECT sjv_create_month_partition('ingest_receipts'::regclass, DATE '2020-01-01')")
        conn.execute(
            """
            INSERT INTO ingest_payloads (
                partition_month, ingest_source_id, transport, received_at,
                content_kind, payload, origin
            )
            SELECT DATE '2020-01-01', id, 'https', TIMESTAMPTZ '2020-01-15 00:00:00+00',
                   'json', convert_to('old', 'UTF8'), 'received'
            FROM ingest_sources WHERE code = 'esp-sjv-001'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_payload_items (
                partition_month, payload_id, payload_partition_month, item_index, original
            )
            SELECT partition_month, id, partition_month, 0, convert_to('item', 'UTF8')
            FROM ingest_payloads
            WHERE partition_month = DATE '2020-01-01'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_receipts (
                partition_month, server_received_at, payload_id, payload_partition_month,
                content_hash, item_index, ingest_source_id, status
            )
            SELECT DATE '2020-01-01', TIMESTAMPTZ '2020-01-15 00:00:00+00', id, partition_month,
                   sha256('old'), 0, ingest_source_id, 'accepted'
            FROM ingest_payloads
            WHERE partition_month = DATE '2020-01-01'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragment_sets (
                ingest_source_id, group_key, status, first_received_at
            )
            SELECT id, 'old-group', 'isolated', TIMESTAMPTZ '2020-01-15 00:00:00+00'
            FROM ingest_sources WHERE code = 'esp-sjv-001'
            """
        )
        conn.execute(
            """
            INSERT INTO ingest_fragments (
                fragment_set_id, fragment_index, payload_id, payload_partition_month,
                content_hash, received_at, delivery_role
            )
            SELECT sets.id, 0, payloads.id, payloads.partition_month, sha256('old-fragment'),
                   TIMESTAMPTZ '2020-01-15 00:00:00+00', 'first'
            FROM ingest_fragment_sets AS sets
            JOIN ingest_payloads AS payloads ON payloads.partition_month = DATE '2020-01-01'
            WHERE sets.group_key = 'old-group'
            """
        )
        conn.execute(
            """
            INSERT INTO meter_readings (
                meter_id, source_stream_id, source_key, source_kind, reading_kind,
                quality, measured_at, primary_value, receipt_count
            )
            SELECT meters.id, source_streams.id, 'manual:retention', 'manual', 'cumulative',
                   'valid', TIMESTAMPTZ '2020-01-15 00:00:00+00', 1, 1
            FROM meters, source_streams
            WHERE source_streams.code = 'radio'
            """
        )
        conn.execute(
            """
            INSERT INTO reading_provenance (
                reading_id, ingest_source_id, content_hash, transport, endpoint_code
            )
            SELECT readings.id, sources.id, sha256('old'), 'manual', 'esp-https'
            FROM meter_readings AS readings
            JOIN ingest_sources AS sources ON sources.code = 'esp-sjv-001'
            WHERE readings.source_key = 'manual:retention'
            """
        )
        print("PASS retention fixture")

        conn.execute(
            "ALTER TABLE ingest_receipts DETACH PARTITION ingest_receipts_p202001 CONCURRENTLY"
        )
        conn.execute("DROP TABLE ingest_receipts_p202001")
        conn.execute("DELETE FROM ingest_fragments WHERE received_at < TIMESTAMPTZ '2020-02-01 00:00:00+00'")
        conn.execute(
            """
            DELETE FROM ingest_fragment_sets AS sets
            WHERE sets.first_received_at < TIMESTAMPTZ '2020-02-01 00:00:00+00'
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_fragments WHERE fragment_set_id = sets.id
              )
            """
        )
        try:
            conn.execute(
                "ALTER TABLE ingest_payloads DETACH PARTITION ingest_payloads_p202001 CONCURRENTLY"
            )
        except psycopg.Error:
            pass
        else:
            fail("payload partition detached while its items remained")
        conn.execute(
            "ALTER TABLE ingest_payload_items DETACH PARTITION ingest_payload_items_p202001 CONCURRENTLY"
        )
        conn.execute("DROP TABLE ingest_payload_items_p202001")
        conn.execute(
            "ALTER TABLE ingest_payloads DETACH PARTITION ingest_payloads_p202001 CONCURRENTLY"
        )
        conn.execute("DROP TABLE ingest_payloads_p202001")
        print("PASS retention order")
        kept = conn.execute(
            """
            SELECT readings.source_key, provenance.transport
            FROM meter_readings AS readings
            JOIN reading_provenance AS provenance ON provenance.reading_id = readings.id
            WHERE readings.source_key = 'manual:retention'
            """
        ).fetchone()
        if kept != ("manual:retention", "manual"):
            fail(f"reading did not survive retention: {kept}")
        dependency = conn.execute(
            """
            SELECT conrelid::regclass::text, confrelid::regclass::text
            FROM pg_constraint
            WHERE contype = 'f'
              AND conrelid IN ('meter_readings'::regclass, 'reading_provenance'::regclass)
              AND confrelid IN ('ingest_receipts'::regclass, 'ingest_payloads'::regclass)
            """
        ).fetchall()
        if dependency:
            fail(f"reading tables reference retained data: {dependency}")
        print("PASS retention")
        print("SCHEMA_TESTS_OK")


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as exc:
        fail(f"database error {exc.sqlstate}: {exc}")
