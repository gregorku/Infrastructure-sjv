"""Retention of ingest months older than 24 months on PostgreSQL 19."""

import os
from datetime import date, datetime, timezone

import psycopg
from psycopg import ClientCursor

URL = os.environ["SJV_DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)

PARENTS = (
    "ingest_payloads",
    "ingest_payload_items",
    "ingest_receipts",
    "ingest_dedup_candidates",
    "ingest_rejections",
    "decoded_observations",
    "raw_telegrams",
)


def fail(message):
    raise SystemExit(message)


def at(month, day=15):
    return datetime(month.year, month.month, day, tzinfo=timezone.utc)


def child(parent, month):
    return f"{parent}_p{month.strftime('%Y%m')}"


def partition_exists(conn, parent, month):
    return conn.execute(
        "SELECT to_regclass(%s) IS NOT NULL",
        (child(parent, month),),
    ).fetchone()[0]


def logs(conn, month):
    return conn.execute(
        """
        SELECT step, result, reason
        FROM retention_log
        WHERE partition_month = %s
        ORDER BY id
        """,
        (month,),
    ).fetchall()


def create_partitions(conn, month, parents=PARENTS):
    for parent in parents:
        conn.execute(
            "SELECT sjv_create_month_partition(%s::regclass, %s)",
            (parent, month),
        )


def insert_payload(conn, source_id, month):
    return conn.execute(
        """
        INSERT INTO ingest_payloads (
            partition_month, ingest_source_id, transport, received_at,
            content_kind, payload, origin
        ) VALUES (%s, %s, 'https', %s, 'opaque', %s, 'received')
        RETURNING id
        """,
        (month, source_id, at(month), b"\x01"),
    ).fetchone()[0]


def insert_telegram(conn, month, status):
    return conn.execute(
        """
        INSERT INTO raw_telegrams (partition_month, anchor_at, decode_status)
        VALUES (%s, %s, %s)
        RETURNING id
        """,
        (month, at(month), status),
    ).fetchone()[0]


def retain(conn, month):
    conn.execute("CALL sjv_retain_ingest_month(%s)", (month,))


def session():
    return psycopg.connect(URL, autocommit=True, cursor_factory=ClientCursor)


def lock_is_free():
    with session() as other:
        got = other.execute("SELECT pg_catalog.pg_try_advisory_lock(83422027)").fetchone()[0]
        if got:
            other.execute("SELECT pg_catalog.pg_advisory_unlock(83422027)")
        return got


def release_lock(conn):
    conn.execute("CALL sjv_retention_release_lock()")


def main():
    with psycopg.connect(URL, autocommit=True, cursor_factory=ClientCursor) as conn:
        version = conn.execute("SELECT version_num FROM alembic_version").fetchone()
        if version != ("0003_retention",):
            fail(f"alembic version is {version}")
        receipt_fk = conn.execute(
            """
            SELECT count(*)
            FROM pg_constraint
            WHERE contype = 'f'
              AND conrelid = 'public.ingest_receipts'::regclass
              AND confrelid = 'public.ingest_payloads'::regclass
            """
        ).fetchone()[0]
        if receipt_fk != 0:
            fail("ingest_receipts has a foreign key to ingest_payloads")
        body = conn.execute(
            "SELECT pg_get_functiondef('sjv_retention_actual_payload_refs(date)'::regprocedure)"
        ).fetchone()[0]
        for table in (
            "ingest_receipts",
            "ingest_payload_items",
            "decoded_observations",
            "ingest_fragments",
            "ingest_fragment_sets",
            "ingest_rejections",
        ):
            if table not in body:
                fail(f"payload reference count omits {table}")
        privileges = conn.execute(
            """
            SELECT
                has_function_privilege(
                    'sjv_maintenance', 'sjv_retain_ingest_month(date)', 'EXECUTE'
                ),
                has_function_privilege(
                    'sjv_collector', 'sjv_retain_ingest_month(date)', 'EXECUTE'
                ),
                has_table_privilege('sjv_maintenance', 'retention_log', 'INSERT'),
                has_table_privilege('sjv_maintenance', 'retention_log', 'UPDATE'),
                has_table_privilege('sjv_maintenance', 'retention_log', 'DELETE')
            """
        ).fetchone()
        if privileges != (True, False, False, False, False):
            fail(f"retention privileges are {privileges}")
        print("PASS receipt foreign key is absent and maintenance cannot write the log")

        source_id = conn.execute(
            "SELECT id FROM ingest_sources WHERE code = 'esp-sjv-001'"
        ).fetchone()[0]
        device_id = conn.execute(
            "SELECT id FROM devices WHERE code = 'ESP-SJV-001'"
        ).fetchone()[0]

        current = datetime.now(timezone.utc).date().replace(day=1)
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, current)
        except psycopg.Error as exc:
            if "not older than 24 months" not in str(exc):
                fail(f"current month failed for the wrong reason: {exc}")
        else:
            fail("current month was retained")
        finally:
            conn.execute("RESET ROLE")
        print("PASS a month inside 24 months is refused")

        _lock_predicate_and_foreign_lock(conn)
        _privileges(conn)
        _queue(conn, source_id)
        _decoded(conn, source_id)
        _nonblocking(conn, source_id)
        _cross_month_reference(conn, source_id)
        _success_and_r27(conn, source_id, device_id)
        _failure_stops(conn, source_id)
        _deferred_error_releases_lock(conn, source_id)
        _defer_reason_error_releases_lock(conn)
        _commit_after_lock_needs_release(conn, source_id)
        _open_transaction_takes_no_lock(conn)
        _concurrent_runs_and_failure_record(conn)
        _invalid_failure_records(conn)
        print("PASS retention role reset")


def _queue(conn, source_id):
    month = date(2019, 4, 1)
    create_partitions(conn, month)
    payload_id = insert_payload(conn, source_id, month)
    telegram_id = insert_telegram(conn, month, "pending")
    conn.execute(
        """
        INSERT INTO decode_queue (raw_telegram_id, raw_partition_month)
        VALUES (%s, %s)
        """,
        (telegram_id, month),
    )
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    finally:
        conn.execute("RESET ROLE")
    if logs(conn, month) != [("gate", "deferred", "decode_queue")]:
        fail(f"queue deferral log is {logs(conn, month)}")
    if not partition_exists(conn, "ingest_payloads", month):
        fail("queue deferral removed the payload partition")
    if conn.execute("SELECT count(*) FROM decode_queue WHERE raw_partition_month = %s", (month,)).fetchone()[0] != 1:
        fail("queue deferral removed the decode queue row")
    if payload_id is None:
        fail("queue payload was not stored")
    print("PASS decode queue defers the whole month")


def _decoded(conn, source_id):
    month = date(2019, 3, 1)
    create_partitions(conn, month)
    insert_payload(conn, source_id, month)
    insert_telegram(conn, month, "decoded")
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    finally:
        conn.execute("RESET ROLE")
    if logs(conn, month) != [("gate", "deferred", "decoded_without_reading")]:
        fail(f"decoded deferral log is {logs(conn, month)}")
    if not partition_exists(conn, "raw_telegrams", month):
        fail("decoded deferral removed the telegram partition")
    print("PASS decoded telegram without a reading defers the whole month")


def _nonblocking(conn, source_id):
    month = date(2019, 2, 1)
    create_partitions(conn, month)
    for status in ("needs_review", "ambiguous", "pending", "failed", "no_key", "suspect_replay"):
        insert_telegram(conn, month, status)
    readings = conn.execute("SELECT count(*) FROM meter_readings").fetchone()[0]
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    finally:
        conn.execute("RESET ROLE")
    recorded = logs(conn, month)
    if any(row[1] == "deferred" for row in recorded):
        fail(f"nonblocking statuses deferred the month: {recorded}")
    if partition_exists(conn, "raw_telegrams", month):
        fail("nonblocking telegram partition remained")
    if conn.execute("SELECT count(*) FROM meter_readings").fetchone()[0] != readings:
        fail("nonblocking retention changed meter readings")
    print("PASS nonblocking telegram statuses do not defer retention")


def _cross_month_reference(conn, source_id):
    payload_month = date(2018, 12, 1)
    rejection_month = date(2018, 11, 1)
    create_partitions(conn, payload_month)
    create_partitions(conn, rejection_month, ("ingest_rejections",))
    payload_id = insert_payload(conn, source_id, payload_month)
    conn.execute(
        """
        INSERT INTO ingest_payload_items (
            partition_month, payload_id, payload_partition_month, item_index, original
        ) VALUES (%s, %s, %s, 0, %s)
        """,
        (payload_month, payload_id, payload_month, b"\x02"),
    )
    conn.execute(
        """
        INSERT INTO ingest_rejections (
            partition_month, received_at, reason, payload_id, payload_partition_month
        ) VALUES (%s, %s, 'unparseable', %s, %s)
        """,
        (rejection_month, at(rejection_month), payload_id, payload_month),
    )
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, payload_month)
    finally:
        conn.execute("RESET ROLE")
    if logs(conn, payload_month) != [("gate", "deferred", "payload_references")]:
        fail(f"cross-month reference log is {logs(conn, payload_month)}")
    if not partition_exists(conn, "ingest_payloads", payload_month):
        fail("a surviving payload reference was removed")
    if not partition_exists(conn, "ingest_payload_items", payload_month):
        fail("deferral removed payload items")
    if not partition_exists(conn, "ingest_rejections", rejection_month):
        fail("deferral removed the other month's rejections")
    print("PASS a payload reference that would survive defers the month")


def _success_and_r27(conn, source_id, device_id):
    month = date(2019, 1, 1)
    later = date(2019, 5, 1)
    create_partitions(conn, month)
    create_partitions(conn, month, ("device_events",))
    create_partitions(conn, later, ("ingest_payloads", "ingest_receipts"))
    payload_id = insert_payload(conn, source_id, month)
    later_payload = insert_payload(conn, source_id, later)
    telegram_id = insert_telegram(conn, month, "needs_review")
    conn.execute(
        """
        INSERT INTO device_events (partition_month, device_id, received_at)
        VALUES (%s, %s, %s)
        """,
        (month, device_id, at(month)),
    )
    conn.execute(
        """
        INSERT INTO ingest_payload_items (
            partition_month, payload_id, payload_partition_month, item_index, original
        ) VALUES (%s, %s, %s, 0, %s)
        """,
        (month, payload_id, month, b"\x03"),
    )
    receipt_id = conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, transport, status,
            raw_telegram_id, raw_partition_month
        ) VALUES (%s, %s, %s, %s, sha256(%s), 0, %s, 'https', 'invalid', %s, %s)
        RETURNING id
        """,
        (month, at(month), payload_id, month, b"item", source_id, telegram_id, month),
    ).fetchone()[0]
    later_receipt = conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, transport, status,
            raw_telegram_id, raw_partition_month
        ) VALUES (%s, %s, %s, %s, sha256(%s), 0, %s, 'https', 'invalid', %s, %s)
        RETURNING id
        """,
        (later, at(later), later_payload, later, b"later", source_id, telegram_id, month),
    ).fetchone()[0]
    conn.execute(
        """
        INSERT INTO ingest_message_keys (
            ingest_source_id, msg_key_namespace, msg_key, item_index, message_kind,
            receipt_id, receipt_partition_month
        ) VALUES (%s, 'https', 'retention-2019-01', 0, 'telegram', %s, %s)
        """,
        (source_id, receipt_id, month),
    )
    conn.execute(
        """
        INSERT INTO ingest_dedup_candidates (
            receipt_id, receipt_partition_month, candidate_raw_telegram_id, candidate_partition_month
        ) VALUES (%s, %s, %s, %s)
        """,
        (receipt_id, month, telegram_id, month),
    )
    conn.execute(
        """
        INSERT INTO ingest_rejections (
            partition_month, received_at, reason, payload_id, payload_partition_month
        ) VALUES (%s, %s, 'unparseable', %s, %s)
        """,
        (month, at(month), payload_id, month),
    )
    set_id = conn.execute(
        """
        INSERT INTO ingest_fragment_sets (
            ingest_source_id, message_ref, status, first_received_at, deadline_at,
            assembled_payload_id, assembled_payload_partition_month
        ) VALUES (%s, 'retention-set', 'complete', %s, %s, %s, %s)
        RETURNING id
        """,
        (source_id, at(month), at(month, 20), payload_id, month),
    ).fetchone()[0]
    conn.execute(
        """
        INSERT INTO ingest_fragments (
            fragment_set_id, fragment_index, payload_id, payload_partition_month,
            content_hash, received_at, delivery_role
        ) VALUES (%s, 0, %s, %s, sha256(%s), %s, 'first')
        """,
        (set_id, payload_id, month, b"fragment", at(month)),
    )
    conn.execute(
        """
        INSERT INTO telegram_dedup_keys (
            meter_key, access_number, frame_hash, anchor_at, dedup_window,
            raw_telegram_id, raw_partition_month
        ) VALUES (
            decode('11', 'hex'), 1, decode('22', 'hex'), %s,
            tstzrange(%s, %s), %s, %s
        )
        """,
        (at(month), at(month, 1), at(month, 28), telegram_id, month),
    )
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    finally:
        conn.execute("RESET ROLE")
    recorded = logs(conn, month)
    steps = [row[0] for row in recorded]
    expected = [
        "message_keys",
        "dedup_candidates",
        "receipts",
        "rejections",
        "observations",
        "fragments",
        "fragment_sets",
        "payload_items",
        "payload_references",
        "payloads",
        "telegram_dedup_keys",
        "raw_telegrams",
    ]
    if steps != expected or any(row[1] != "completed" for row in recorded):
        fail(f"successful retention log is {recorded}")
    if steps.index("payload_items") > steps.index("payloads"):
        fail("payload items were not removed before payloads")
    if steps.index("telegram_dedup_keys") > steps.index("raw_telegrams"):
        fail("telegram dedup keys were not removed before telegrams")
    for parent in PARENTS:
        if partition_exists(conn, parent, month):
            fail(f"{parent} partition remained after retention")
    if not partition_exists(conn, "device_events", month):
        fail("device events were removed by ingest retention")
    if conn.execute(
        "SELECT count(*) FROM device_events WHERE partition_month = %s",
        (month,),
    ).fetchone()[0] != 1:
        fail("device event row was removed")
    if not partition_exists(conn, "ingest_receipts", later):
        fail("retention removed a receipt from another month")
    if not partition_exists(conn, "ingest_payloads", later):
        fail("retention removed a payload from another month")
    if conn.execute(
        "SELECT count(*) FROM ingest_receipts WHERE id = %s AND partition_month = %s",
        (later_receipt, later),
    ).fetchone()[0] != 1:
        fail("the later receipt was removed with the earlier telegram")
    if conn.execute(
        "SELECT count(*) FROM telegram_dedup_keys WHERE raw_partition_month = %s",
        (month,),
    ).fetchone()[0] != 0:
        fail("telegram dedup keys remained")
    payload_log = next(row for row in recorded if row[0] == "payloads")
    if payload_log != ("payloads", "completed", None):
        fail(f"payload completion was not recorded with the drop: {payload_log}")
    print("PASS month retention order, other months, device events and R27")


def _failure_stops(conn, source_id):
    month = date(2018, 10, 1)
    create_partitions(conn, month)
    payload_id = insert_payload(conn, source_id, month)
    conn.execute(
        """
        INSERT INTO ingest_payload_items (
            partition_month, payload_id, payload_partition_month, item_index, original
        ) VALUES (%s, %s, %s, 0, %s)
        """,
        (month, payload_id, month, b"\x04"),
    )
    conn.execute(
        """
        INSERT INTO ingest_receipts (
            partition_month, server_received_at, payload_id, payload_partition_month,
            content_hash, item_index, ingest_source_id, transport, status
        ) VALUES (%s, %s, %s, %s, sha256(%s), 0, %s, 'https', 'invalid')
        """,
        (month, at(month), payload_id, month, b"stop", source_id),
    )
    set_id = conn.execute(
        """
        INSERT INTO ingest_fragment_sets (
            ingest_source_id, status, first_received_at
        ) VALUES (%s, 'isolated', %s)
        RETURNING id
        """,
        (source_id, at(month)),
    ).fetchone()[0]
    conn.execute(
        """
        INSERT INTO ingest_fragments (
            fragment_set_id, fragment_index, payload_id, payload_partition_month,
            content_hash, received_at, delivery_role
        ) VALUES (%s, 0, %s, %s, sha256(%s), %s, 'first')
        """,
        (set_id, payload_id, month, b"stop-fragment", at(month)),
    )
    conn.execute(
        """
        CREATE FUNCTION sjv_test_block_fragment_delete()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
            RAISE EXCEPTION 'forced retention failure';
        END;
        $$
        """
    )
    conn.execute(
        """
        CREATE TRIGGER sjv_test_block_fragment_delete
        BEFORE DELETE ON ingest_fragments
        FOR EACH ROW
        EXECUTE FUNCTION sjv_test_block_fragment_delete()
        """
    )
    try:
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, month)
        except psycopg.Error as exc:
            text = str(exc)
            if "retention step fragments failed" not in text:
                fail(f"retention stopped with the wrong error: {exc}")
        else:
            fail("fragment failure did not stop retention")
        finally:
            conn.execute("RESET ROLE")
        if any(row[0] == "fragments" and row[1] == "completed" for row in logs(conn, month)):
            fail("rolled back fragment delete left a completed log row")
        if not lock_is_free():
            fail("fragment failure left the retention lock held")
        if partition_exists(conn, "ingest_receipts", month):
            fail("receipt partition was not committed before the failure")
        if not partition_exists(conn, "ingest_payload_items", month):
            fail("failure continued and removed payload items")
        if not partition_exists(conn, "ingest_payloads", month):
            fail("failure continued and removed payloads")
        if conn.execute("SELECT count(*) FROM ingest_fragments WHERE fragment_set_id = %s", (set_id,)).fetchone()[0] != 1:
            fail("rolled back fragment delete removed the fragment")
        conn.execute("SET ROLE sjv_maintenance")
        try:
            conn.execute(
                "CALL sjv_retention_record_failure(%s, 'fragments', 'forced retention failure')",
                (month,),
            )
        finally:
            conn.execute("RESET ROLE")
        failed = [
            row for row in logs(conn, month)
            if row[0] == "fragments"
        ]
        if failed != [("fragments", "failed", "forced retention failure")]:
            fail(f"failure log is {failed}")
        print("PASS a retention error stops the month and does not record success")
    finally:
        conn.execute("DROP TRIGGER IF EXISTS sjv_test_block_fragment_delete ON ingest_fragments")
        conn.execute("DROP FUNCTION IF EXISTS sjv_test_block_fragment_delete()")


def _lock_predicate_and_foreign_lock(conn):
    conn.execute("SELECT pg_catalog.pg_advisory_lock(83422027)")
    try:
        if not conn.execute("SELECT sjv_retention_lock_held()").fetchone()[0]:
            fail("advisory lock catalog predicate does not see the held lock")
        if lock_is_free():
            fail("another session acquired the retention lock")
        current = datetime.now(timezone.utc).date().replace(day=1)
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, current)
        except psycopg.Error as exc:
            if "not older than 24 months" not in str(exc):
                fail(f"current month failed for the wrong reason: {exc}")
        else:
            fail("current month was retained while a foreign lock was held")
        finally:
            conn.execute("RESET ROLE")
        if lock_is_free():
            fail("month rejection released a lock it had not acquired")
    finally:
        release_lock(conn)
    if not lock_is_free():
        fail("release_lock left the session lock held")
    conn.execute("SET ROLE sjv_maintenance")
    try:
        conn.execute(
            "CALL sjv_retention_apply_one(%s, 'message_keys')",
            (date(2018, 2, 1),),
        )
    except psycopg.Error as exc:
        if "retention lock is not held" not in str(exc):
            fail(f"direct step without the lock failed unexpectedly: {exc}")
    else:
        fail("direct step ran without the retention lock")
    finally:
        conn.execute("RESET ROLE")
    if not lock_is_free():
        fail("direct step without the lock left it held")
    if logs(conn, date(2018, 2, 1)):
        fail("direct step without the lock wrote a retention log")
    print("PASS retention lock release does not drop a foreign hold")


def _privileges(conn):
    maintenance_execute = {
        "sjv_retain_ingest_month(date)",
        "sjv_retention_record_failure(date, text, text)",
        "sjv_retention_release_lock()",
        "sjv_retention_capture_gate(date, date, text)",
        "sjv_retention_apply_one(date, text)",
        "sjv_retention_log_failed(date, text, text)",
    }
    internal = {
        "sjv_retention_month_ok(date)",
        "sjv_retention_defer_reason(date)",
        "sjv_retention_actual_payload_refs(date)",
        "sjv_retention_detach(regclass, date)",
        "sjv_retention_lock_held()",
        "sjv_retention_apply_step(date, text)",
        "sjv_retention_log_deferred(date, text)",
        "sjv_retention_log_protect()",
    }
    signatures = maintenance_execute | internal
    for signature in signatures:
        for role in ("sjv_collector", "sjv_api", "sjv_readonly"):
            allowed = conn.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (role, signature),
            ).fetchone()[0]
            if allowed:
                fail(f"{role} can execute {signature}")
        maintenance = conn.execute(
            "SELECT has_function_privilege('sjv_maintenance', %s, 'EXECUTE')",
            (signature,),
        ).fetchone()[0]
        owner = conn.execute(
            "SELECT has_function_privilege('sjv_owner', %s, 'EXECUTE')",
            (signature,),
        ).fetchone()[0]
        if maintenance != (signature in maintenance_execute) or not owner:
            fail(f"execute on {signature} is maintenance={maintenance} owner={owner}")
    public_execute = conn.execute(
        """
        SELECT count(*)
        FROM pg_proc AS procedures
        JOIN pg_namespace AS namespaces ON namespaces.oid = procedures.pronamespace
        CROSS JOIN LATERAL aclexplode(procedures.proacl) AS acl
        WHERE namespaces.nspname = 'public'
          AND (
              procedures.proname LIKE 'sjv_retention%'
              OR procedures.proname = 'sjv_retain_ingest_month'
          )
          AND acl.grantee = 0
          AND acl.privilege_type = 'EXECUTE'
        """
    ).fetchone()[0]
    if public_execute != 0:
        fail("PUBLIC can execute a retention routine")
    missing_acl = conn.execute(
        """
        SELECT count(*)
        FROM pg_proc AS procedures
        JOIN pg_namespace AS namespaces ON namespaces.oid = procedures.pronamespace
        WHERE namespaces.nspname = 'public'
          AND (
              procedures.proname LIKE 'sjv_retention%'
              OR procedures.proname = 'sjv_retain_ingest_month'
          )
          AND procedures.proacl IS NULL
        """
    ).fetchone()[0]
    if missing_acl != 0:
        fail("a retention routine keeps the default PUBLIC execute ACL")
    rows = conn.execute(
        """
        SELECT procedures.proname, pg_get_userbyid(procedures.proowner),
               procedures.prosecdef, procedures.proconfig::text
        FROM pg_proc AS procedures
        JOIN pg_namespace AS namespaces ON namespaces.oid = procedures.pronamespace
        WHERE namespaces.nspname = 'public'
          AND (
              procedures.proname LIKE 'sjv_retention%'
              OR procedures.proname = 'sjv_retain_ingest_month'
          )
        ORDER BY procedures.proname
        """
    ).fetchall()
    definers = {
        "sjv_retention_actual_payload_refs",
        "sjv_retention_apply_one",
        "sjv_retention_apply_step",
        "sjv_retention_capture_gate",
        "sjv_retention_defer_reason",
        "sjv_retention_detach",
        "sjv_retention_lock_held",
        "sjv_retention_log_deferred",
        "sjv_retention_log_failed",
        "sjv_retention_month_ok",
        "sjv_retention_release_lock",
    }
    invokers = {
        "sjv_retain_ingest_month",
        "sjv_retention_record_failure",
    }
    seen = set()
    for name, owner, definer, config in rows:
        seen.add(name)
        if owner != "sjv_owner":
            fail(f"{name} is owned by {owner}")
        if name in definers:
            if not definer or config != "{search_path=public}":
                fail(f"{name} security is definer={definer} config={config}")
        elif name in invokers:
            if definer or config is not None:
                fail(f"{name} security is definer={definer} config={config}")
        elif name == "sjv_retention_log_protect":
            if definer or config != "{search_path=pg_catalog}":
                fail(f"log protection security is definer={definer} config={config}")
        else:
            fail(f"unexpected retention routine {name}")
    if seen != definers | invokers | {"sjv_retention_log_protect"}:
        fail(f"retention routines are {sorted(seen)}")
    schema = conn.execute(
        """
        SELECT
            has_schema_privilege('sjv_owner', 'public', 'CREATE'),
            has_schema_privilege('sjv_maintenance', 'public', 'CREATE'),
            has_schema_privilege('sjv_collector', 'public', 'CREATE'),
            has_schema_privilege('sjv_api', 'public', 'CREATE'),
            has_schema_privilege('sjv_readonly', 'public', 'CREATE'),
            has_schema_privilege('sjv_maintenance', 'public', 'USAGE'),
            (
                SELECT count(*)
                FROM aclexplode(namespaces.nspacl) AS acl
                WHERE acl.grantee = 0 AND acl.privilege_type = 'CREATE'
            )
        FROM pg_namespace AS namespaces
        WHERE namespaces.nspname = 'public'
        """
    ).fetchone()
    if schema != (True, False, False, False, False, True, 0):
        fail(f"public schema privileges are {schema}")
    body = conn.execute(
        "SELECT pg_get_functiondef('sjv_retention_detach(regclass, date)'::regprocedure)"
    ).fetchone()[0]
    if "%I" not in body or "device_events" in body:
        fail("detach does not keep quoted identifiers inside the allowlist")
    conn.execute("SET ROLE sjv_maintenance")
    try:
        conn.execute("SELECT sjv_retention_month_ok(%s)", (date(2018, 1, 1),))
    except psycopg.Error as exc:
        if "permission denied" not in str(exc):
            fail(f"month check denial was {exc}")
    else:
        fail("maintenance executed the internal month check")
    finally:
        conn.execute("RESET ROLE")
    print("PASS retention ownership, execute privileges and schema create")


def _arm_queue(conn, source_id, month):
    create_partitions(conn, month)
    insert_payload(conn, source_id, month)
    telegram_id = insert_telegram(conn, month, "pending")
    conn.execute(
        """
        INSERT INTO decode_queue (raw_telegram_id, raw_partition_month)
        VALUES (%s, %s)
        """,
        (telegram_id, month),
    )


def _deferred_error_releases_lock(conn, source_id):
    month = date(2018, 8, 1)
    _arm_queue(conn, source_id, month)
    conn.execute(
        """
        CREATE FUNCTION sjv_test_block_deferred()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
            IF NEW.result = 'deferred' THEN
                RAISE EXCEPTION 'forced deferred failure';
            END IF;
            RETURN NEW;
        END;
        $$
        """
    )
    conn.execute(
        """
        CREATE TRIGGER sjv_test_block_deferred
        BEFORE INSERT ON retention_log
        FOR EACH ROW
        EXECUTE FUNCTION sjv_test_block_deferred()
        """
    )
    try:
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, month)
        except psycopg.Error as exc:
            if "forced deferred failure" not in str(exc):
                fail(f"deferred path failed unexpectedly: {exc}")
        else:
            fail("deferred insert failure did not stop retention")
        finally:
            conn.execute("RESET ROLE")
        if not lock_is_free():
            fail("deferred path failure left the retention lock held")
        if logs(conn, month):
            fail("rolled back deferred insert left a log row")
        if conn.execute(
            "SELECT count(*) FROM decode_queue WHERE raw_partition_month = %s",
            (month,),
        ).fetchone()[0] != 1:
            fail("deferred path failure removed the decode queue row")
        print("PASS deferred path failure releases the retention lock")
    finally:
        release_lock(conn)
        conn.execute("DROP TRIGGER IF EXISTS sjv_test_block_deferred ON retention_log")
        conn.execute("DROP FUNCTION IF EXISTS sjv_test_block_deferred()")


def _defer_reason_error_releases_lock(conn):
    month = date(2018, 7, 1)
    definition = conn.execute(
        "SELECT pg_get_functiondef('sjv_retention_defer_reason(date)'::regprocedure)"
    ).fetchone()[0]
    conn.execute(
        """
        CREATE OR REPLACE FUNCTION sjv_retention_defer_reason(month_start date)
        RETURNS text
        LANGUAGE plpgsql
        STABLE
        SECURITY DEFINER
        SET search_path = public
        AS $$
        BEGIN
            RAISE EXCEPTION 'forced defer reason failure';
        END;
        $$
        """
    )
    try:
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, month)
        except psycopg.Error as exc:
            if "forced defer reason failure" not in str(exc):
                fail(f"deferral check failed unexpectedly: {exc}")
        else:
            fail("deferral check failure did not stop retention")
        finally:
            conn.execute("RESET ROLE")
        if not lock_is_free():
            fail("deferral check failure left the retention lock held")
        if logs(conn, month):
            fail("deferral check failure wrote a retention log")
        print("PASS deferral check failure releases the retention lock")
    finally:
        release_lock(conn)
        conn.execute(definition)


def _commit_after_lock_needs_release(conn, source_id):
    month = date(2018, 4, 1)
    _arm_queue(conn, source_id, month)
    conn.execute(
        """
        CREATE FUNCTION sjv_test_fail_commit()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
            RAISE EXCEPTION 'forced commit failure';
        END;
        $$
        """
    )
    conn.execute(
        """
        CREATE CONSTRAINT TRIGGER sjv_test_fail_commit
        AFTER INSERT ON retention_log
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW
        EXECUTE FUNCTION sjv_test_fail_commit()
        """
    )
    try:
        conn.execute("SET ROLE sjv_maintenance")
        try:
            retain(conn, month)
        except psycopg.Error as exc:
            if "forced commit failure" not in str(exc):
                fail(f"commit after the lock failed unexpectedly: {exc}")
        else:
            fail("commit failure did not stop retention")
        finally:
            conn.execute("RESET ROLE")
        if lock_is_free():
            fail("commit failure was reported as leaving no session lock")
        release_lock(conn)
        if not lock_is_free():
            fail("release_lock did not clear the lock left by commit failure")
        if logs(conn, month):
            fail("failed commit left a retention log row")
        if not partition_exists(conn, "ingest_payloads", month):
            fail("commit failure removed the payload partition")
        print("PASS commit after the lock is released by the recovery procedure")
    finally:
        release_lock(conn)
        conn.execute("DROP TRIGGER IF EXISTS sjv_test_fail_commit ON retention_log")
        conn.execute("DROP FUNCTION IF EXISTS sjv_test_fail_commit()")


def _open_transaction_takes_no_lock(conn):
    month = date(2018, 3, 1)
    failure = None
    conn.execute("BEGIN")
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    except psycopg.Error as exc:
        failure = exc
    conn.execute("ROLLBACK")
    conn.execute("RESET ROLE")
    if failure is None or "invalid transaction termination" not in str(failure):
        fail(f"open transaction failed unexpectedly: {failure}")
    if not lock_is_free():
        fail("open transaction left the retention lock held")
    if logs(conn, month):
        fail("open transaction wrote a retention log")
    print("PASS an open transaction fails before the retention lock")


def _concurrent_runs_and_failure_record(conn):
    month = date(2018, 9, 1)
    with session() as holder:
        holder.execute("SELECT pg_catalog.pg_advisory_lock(83422027)")
        try:
            if lock_is_free():
                fail("held retention lock was free for another session")
            with session() as runner:
                runner.execute("SET lock_timeout = '500ms'")
                runner.execute("SET ROLE sjv_maintenance")
                try:
                    retain(runner, month)
                except psycopg.Error as exc:
                    if "lock timeout" not in str(exc):
                        fail(f"concurrent retention failed unexpectedly: {exc}")
                else:
                    fail("concurrent retention ran while the lock was held")
                finally:
                    runner.execute("RESET ROLE")
                runner.execute("SET statement_timeout = '2s'")
                runner.execute("SET ROLE sjv_maintenance")
                try:
                    runner.execute(
                        "CALL sjv_retention_record_failure(%s, 'message_keys', 'operator stop')",
                        (date(2018, 6, 1),),
                    )
                finally:
                    runner.execute("RESET ROLE")
            if lock_is_free():
                fail("failure record released the lock held by another session")
            if logs(conn, date(2018, 6, 1)) != [("message_keys", "failed", "operator stop")]:
                fail(f"failure record while a lock is held is {logs(conn, date(2018, 6, 1))}")
        finally:
            holder.execute("SELECT pg_catalog.pg_advisory_unlock(83422027)")
    if not lock_is_free():
        fail("unlocking the holder did not free the retention lock")
    conn.execute("SET ROLE sjv_maintenance")
    try:
        retain(conn, month)
    finally:
        conn.execute("RESET ROLE")
    recorded = logs(conn, month)
    if [row[0] for row in recorded] != [
        "message_keys",
        "dedup_candidates",
        "receipts",
        "rejections",
        "observations",
        "fragments",
        "fragment_sets",
        "payload_items",
        "payload_references",
        "payloads",
        "telegram_dedup_keys",
        "raw_telegrams",
    ] or any(row[1] != "completed" for row in recorded):
        fail(f"retention after the lock was released is {recorded}")
    if not lock_is_free():
        fail("completed retention left the lock held")
    print("PASS concurrent retention waits and a later run acquires the lock")


def _invalid_failure_records(conn):
    current = datetime.now(timezone.utc).date().replace(day=1)
    cases = (
        (date(2019, 4, 15), "message_keys", "reason", "first day"),
        (current, "message_keys", "reason", "not older than 24 months"),
        (date(2018, 5, 1), "gate", "reason", "not allowed"),
        (date(2018, 5, 1), "not_a_step", "reason", "not allowed"),
        (date(2018, 5, 1), "message_keys", None, "reason is empty"),
        (date(2018, 5, 1), "message_keys", "", "reason is empty"),
        (date(2018, 5, 1), "message_keys", "   ", "reason is empty"),
    )
    conn.execute("SET ROLE sjv_maintenance")
    try:
        for month, step, reason, needle in cases:
            try:
                conn.execute(
                    "CALL sjv_retention_record_failure(%s, %s, %s)",
                    (month, step, reason),
                )
            except psycopg.Error as exc:
                if needle not in str(exc):
                    fail(f"invalid failure {month} {step!r} {reason!r} was {exc}")
            else:
                fail(f"invalid failure {month} {step!r} {reason!r} was stored")
    finally:
        conn.execute("RESET ROLE")
    if logs(conn, date(2018, 5, 1)) or logs(conn, current) or logs(conn, date(2019, 4, 15)):
        fail("an invalid failure record remained")
    if not lock_is_free():
        fail("invalid failure record left the retention lock held")
    print("PASS invalid failure records are rejected")


if __name__ == "__main__":
    try:
        main()
    except psycopg.Error as exc:
        raise SystemExit(f"retention test failed: {exc}") from exc
