-- 24-month ingest retention. DETACH and DROP of one child share one transaction.
-- retention_log is the operational protocol. It is not audit_logs.

CREATE FUNCTION sjv_retention_log_protect()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    RAISE EXCEPTION 'retention_log is append-only';
END;
$$;

CREATE TRIGGER trg_retention_log_protect
BEFORE UPDATE OR DELETE ON retention_log
FOR EACH ROW
EXECUTE FUNCTION sjv_retention_log_protect();

REVOKE ALL ON TABLE retention_log FROM PUBLIC;

CREATE FUNCTION sjv_retention_month_ok(month_start date)
RETURNS date
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    month date;
    cutoff date;
BEGIN
    month := date_trunc('month', month_start::timestamp)::date;
    IF month IS DISTINCT FROM month_start THEN
        RAISE EXCEPTION 'retention month must be the first day of a month';
    END IF;
    cutoff := (date_trunc('month', (now() AT TIME ZONE 'UTC')) - interval '24 months')::date;
    IF month >= cutoff THEN
        RAISE EXCEPTION 'retention month is not older than 24 months';
    END IF;
    RETURN month;
END;
$$;

CREATE FUNCTION sjv_retention_actual_payload_refs(month_start date)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        (SELECT count(*) FROM ingest_receipts
          WHERE payload_partition_month = month_start)
      + (SELECT count(*) FROM ingest_payload_items
          WHERE payload_partition_month = month_start)
      + (SELECT count(*) FROM decoded_observations
          WHERE payload_partition_month = month_start)
      + (SELECT count(*) FROM ingest_fragments
          WHERE payload_partition_month = month_start)
      + (SELECT count(*) FROM ingest_fragment_sets
          WHERE assembled_payload_partition_month = month_start)
      + (SELECT count(*) FROM ingest_rejections
          WHERE payload_partition_month = month_start);
$$;

CREATE FUNCTION sjv_retention_defer_reason(month_start date)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    month date := month_start;
    start_at timestamptz;
    end_at timestamptz;
    cutoff date;
    remaining bigint;
BEGIN
    IF EXISTS (
        SELECT 1 FROM decode_queue WHERE raw_partition_month = month
    ) THEN
        RETURN 'decode_queue';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM raw_telegrams AS telegrams
        WHERE telegrams.partition_month = month
          AND telegrams.decode_status = 'decoded'
          AND NOT EXISTS (
              SELECT 1 FROM meter_readings AS readings
              WHERE readings.source_key = 'raw:' || telegrams.id::text
          )
    ) THEN
        RETURN 'decoded_without_reading';
    END IF;

    start_at := month::timestamp AT TIME ZONE 'UTC';
    end_at := (month + interval '1 month')::timestamp AT TIME ZONE 'UTC';
    cutoff := (date_trunc('month', (now() AT TIME ZONE 'UTC')) - interval '24 months')::date;
    SELECT count(*) INTO remaining
    FROM (
        SELECT 1
        FROM ingest_receipts
        WHERE payload_partition_month = month AND partition_month <> month
        UNION ALL
        SELECT 1
        FROM ingest_payload_items
        WHERE payload_partition_month = month AND partition_month <> month
        UNION ALL
        SELECT 1
        FROM decoded_observations
        WHERE payload_partition_month = month AND partition_month <> month
        UNION ALL
        SELECT 1
        FROM ingest_rejections
        WHERE payload_partition_month = month AND partition_month <> month
        UNION ALL
        SELECT 1
        FROM ingest_fragments
        WHERE payload_partition_month = month
          AND (
              received_at IS NULL
              OR received_at < start_at
              OR received_at >= end_at
          )
        UNION ALL
        SELECT 1
        FROM ingest_fragment_sets AS sets
        WHERE sets.assembled_payload_partition_month = month
          AND NOT (
              sets.first_received_at IS NOT NULL
              AND date_trunc('month', sets.first_received_at AT TIME ZONE 'UTC')::date < cutoff
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_fragments AS fragments
                  WHERE fragments.fragment_set_id = sets.id
                    AND (
                        fragments.received_at IS NULL
                        OR fragments.received_at < start_at
                        OR fragments.received_at >= end_at
                    )
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_receipts AS receipts
                  WHERE receipts.payload_id = sets.assembled_payload_id
                    AND receipts.payload_partition_month = month
                    AND receipts.partition_month <> month
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_payload_items AS items
                  WHERE items.payload_id = sets.assembled_payload_id
                    AND items.payload_partition_month = month
                    AND items.partition_month <> month
              )
              AND NOT EXISTS (
                  SELECT 1 FROM decoded_observations AS observations
                  WHERE observations.payload_id = sets.assembled_payload_id
                    AND observations.payload_partition_month = month
                    AND observations.partition_month <> month
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_rejections AS rejections
                  WHERE rejections.payload_id = sets.assembled_payload_id
                    AND rejections.payload_partition_month = month
                    AND rejections.partition_month <> month
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_fragments AS fragments
                  WHERE fragments.payload_id = sets.assembled_payload_id
                    AND fragments.payload_partition_month = month
                    AND (
                        fragments.received_at IS NULL
                        OR fragments.received_at < start_at
                        OR fragments.received_at >= end_at
                    )
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ingest_fragment_sets AS other
                  WHERE other.id <> sets.id
                    AND other.assembled_payload_id = sets.assembled_payload_id
                    AND other.assembled_payload_partition_month = month
              )
          )
    ) AS refs;
    IF remaining <> 0 THEN
        RETURN 'payload_references';
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION sjv_retention_detach(parent regclass, month_start date)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    parent_name text;
    child text;
    found text;
    bound text;
    expected_from text;
    expected_to text;
    deleted bigint;
BEGIN
    IF parent NOT IN (
        'public.ingest_dedup_candidates'::regclass,
        'public.ingest_receipts'::regclass,
        'public.ingest_rejections'::regclass,
        'public.decoded_observations'::regclass,
        'public.ingest_payload_items'::regclass,
        'public.ingest_payloads'::regclass,
        'public.raw_telegrams'::regclass
    ) THEN
        RAISE EXCEPTION 'retention parent is not an ingest month table';
    END IF;
    parent_name := regexp_replace(parent::text, '^public\.', '');
    child := parent_name || '_p' || to_char(month_start, 'YYYYMM');
    expected_from := to_char(month_start, 'YYYY-MM-DD');
    expected_to := to_char((month_start + interval '1 month')::date, 'YYYY-MM-DD');
    SELECT relations.relname, pg_get_expr(relations.relpartbound, relations.oid)
    INTO found, bound
    FROM pg_class AS relations
    JOIN pg_inherits AS inheritance ON inheritance.inhrelid = relations.oid
    WHERE inheritance.inhparent = parent
      AND relations.relname = child;
    IF found IS NULL THEN
        RETURN -1;
    END IF;
    IF bound NOT LIKE '%' || expected_from || '%'
       OR bound NOT LIKE '%' || expected_to || '%' THEN
        RAISE EXCEPTION 'partition bound % does not match %', bound, month_start;
    END IF;
    EXECUTE format('SELECT count(*) FROM %I', child) INTO deleted;
    EXECUTE format('ALTER TABLE %I DETACH PARTITION %I', parent_name, child);
    EXECUTE format('DROP TABLE %I', child);
    RETURN deleted;
END;
$$;

CREATE FUNCTION sjv_retention_lock_held()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_locks
        WHERE locktype = 'advisory'
          AND pid = pg_catalog.pg_backend_pid()
          AND classid = 0
          AND objid = 83422027
          AND objsubid = 1
          AND granted
    );
$$;

CREATE FUNCTION sjv_retention_apply_step(month_start date, step text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    deleted bigint;
    start_at timestamptz;
    end_at timestamptz;
    cutoff date;
    parent regclass;
    blocked text;
BEGIN
    IF NOT sjv_retention_lock_held() THEN
        RAISE EXCEPTION 'retention lock is not held';
    END IF;
    PERFORM sjv_retention_month_ok(month_start);
    blocked := sjv_retention_defer_reason(month_start);
    IF blocked IS NOT NULL THEN
        RAISE EXCEPTION 'retention month is deferred: %', blocked;
    END IF;
    IF step = 'message_keys' THEN
        DELETE FROM ingest_message_keys WHERE receipt_partition_month = month_start;
        GET DIAGNOSTICS deleted = ROW_COUNT;
    ELSIF step = 'fragments' THEN
        start_at := month_start::timestamp AT TIME ZONE 'UTC';
        end_at := (month_start + interval '1 month')::timestamp AT TIME ZONE 'UTC';
        DELETE FROM ingest_fragments
        WHERE received_at >= start_at AND received_at < end_at;
        GET DIAGNOSTICS deleted = ROW_COUNT;
    ELSIF step = 'fragment_sets' THEN
        cutoff := (date_trunc('month', (now() AT TIME ZONE 'UTC')) - interval '24 months')::date;
        DELETE FROM ingest_fragment_sets AS sets
        WHERE sets.first_received_at IS NOT NULL
          AND date_trunc('month', sets.first_received_at AT TIME ZONE 'UTC')::date < cutoff
          AND NOT EXISTS (
              SELECT 1 FROM ingest_fragments AS fragments
              WHERE fragments.fragment_set_id = sets.id
          )
          AND (
              (
                  sets.assembled_payload_id IS NULL
                  AND date_trunc('month', sets.first_received_at AT TIME ZONE 'UTC')::date = month_start
              )
              OR (
                  sets.assembled_payload_partition_month = month_start
                  AND NOT EXISTS (
                      SELECT 1 FROM ingest_receipts AS receipts
                      WHERE receipts.payload_id = sets.assembled_payload_id
                        AND receipts.payload_partition_month = month_start
                        AND receipts.partition_month <> month_start
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ingest_payload_items AS items
                      WHERE items.payload_id = sets.assembled_payload_id
                        AND items.payload_partition_month = month_start
                        AND items.partition_month <> month_start
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM decoded_observations AS observations
                      WHERE observations.payload_id = sets.assembled_payload_id
                        AND observations.payload_partition_month = month_start
                        AND observations.partition_month <> month_start
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ingest_rejections AS rejections
                      WHERE rejections.payload_id = sets.assembled_payload_id
                        AND rejections.payload_partition_month = month_start
                        AND rejections.partition_month <> month_start
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ingest_fragments AS fragments
                      WHERE fragments.payload_id = sets.assembled_payload_id
                        AND fragments.payload_partition_month = month_start
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ingest_fragment_sets AS other
                      WHERE other.id <> sets.id
                        AND other.assembled_payload_id = sets.assembled_payload_id
                        AND other.assembled_payload_partition_month = month_start
                  )
              )
          );
        GET DIAGNOSTICS deleted = ROW_COUNT;
    ELSIF step = 'telegram_dedup_keys' THEN
        DELETE FROM telegram_dedup_keys WHERE raw_partition_month = month_start;
        GET DIAGNOSTICS deleted = ROW_COUNT;
    ELSIF step = 'payload_references' THEN
        deleted := sjv_retention_actual_payload_refs(month_start);
        IF deleted <> 0 THEN
            RAISE EXCEPTION 'payload references remain';
        END IF;
        deleted := 0;
    ELSIF step = 'dedup_candidates' THEN
        parent := 'public.ingest_dedup_candidates'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'receipts' THEN
        parent := 'public.ingest_receipts'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'rejections' THEN
        parent := 'public.ingest_rejections'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'observations' THEN
        parent := 'public.decoded_observations'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'payload_items' THEN
        parent := 'public.ingest_payload_items'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'payloads' THEN
        parent := 'public.ingest_payloads'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSIF step = 'raw_telegrams' THEN
        parent := 'public.raw_telegrams'::regclass;
        deleted := sjv_retention_detach(parent, month_start);
    ELSE
        RAISE EXCEPTION 'unknown retention step %', step;
    END IF;

    IF deleted < 0 THEN
        INSERT INTO retention_log (partition_month, step, result, reason, row_count)
        VALUES (month_start, step, 'completed', 'absent', 0);
    ELSE
        INSERT INTO retention_log (partition_month, step, result, row_count)
        VALUES (month_start, step, 'completed', deleted);
    END IF;
END;
$$;

CREATE PROCEDURE sjv_retention_apply_one(month_start date, step text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    err text;
BEGIN
    PERFORM sjv_retention_apply_step(month_start, step);
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS err = MESSAGE_TEXT;
    IF sjv_retention_lock_held() THEN
        PERFORM pg_catalog.pg_advisory_unlock(83422027);
    END IF;
    RAISE EXCEPTION 'retention step % failed: %', step, err;
END;
$$;

CREATE PROCEDURE sjv_retention_capture_gate(
    month_start date,
    INOUT month date,
    INOUT reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    acquired boolean := false;
BEGIN
    month := sjv_retention_month_ok(month_start);
    PERFORM pg_catalog.pg_advisory_lock(83422027);
    acquired := true;
    reason := sjv_retention_defer_reason(month);
    IF reason IS NOT NULL THEN
        PERFORM sjv_retention_log_deferred(month, reason);
    END IF;
EXCEPTION WHEN OTHERS THEN
    IF acquired THEN
        PERFORM pg_catalog.pg_advisory_unlock(83422027);
    END IF;
    RAISE;
END;
$$;

CREATE FUNCTION sjv_retention_log_deferred(month_start date, reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF sjv_retention_defer_reason(month_start) IS DISTINCT FROM reason THEN
        RAISE EXCEPTION 'retention deferral does not match the month';
    END IF;
    INSERT INTO retention_log (partition_month, step, result, reason, row_count)
    VALUES (month_start, 'gate', 'deferred', reason, 0);
END;
$$;

CREATE FUNCTION sjv_retention_log_failed(month_start date, step text, reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM sjv_retention_month_ok(month_start);
    IF step IS NULL OR step <> ALL (ARRAY[
        'message_keys',
        'dedup_candidates',
        'receipts',
        'rejections',
        'observations',
        'fragments',
        'fragment_sets',
        'payload_items',
        'payload_references',
        'payloads',
        'telegram_dedup_keys',
        'raw_telegrams'
    ]::text[]) THEN
        RAISE EXCEPTION 'retention failure step is not allowed';
    END IF;
    IF reason IS NULL OR btrim(reason) = '' THEN
        RAISE EXCEPTION 'retention failure reason is empty';
    END IF;
    INSERT INTO retention_log (partition_month, step, result, reason)
    VALUES (month_start, step, 'failed', reason);
END;
$$;

CREATE PROCEDURE sjv_retain_ingest_month(month_start date)
LANGUAGE plpgsql
AS $$
DECLARE
    month date;
    reason text;
    step text;
    steps text[] := ARRAY[
        'message_keys',
        'dedup_candidates',
        'receipts',
        'rejections',
        'observations',
        'fragments',
        'fragment_sets',
        'payload_items',
        'payload_references',
        'payloads',
        'telegram_dedup_keys',
        'raw_telegrams'
    ];
BEGIN
    -- An enclosing transaction cannot be committed from here. Fail before the
    -- session lock exists. A later COMMIT still cannot be caught in this
    -- procedure: an EXCEPTION block would forbid COMMIT.
    COMMIT;
    CALL public.sjv_retention_capture_gate(month_start, month, reason);
    IF reason IS NOT NULL THEN
        COMMIT;
        PERFORM pg_catalog.pg_advisory_unlock(83422027);
        RETURN;
    END IF;

    FOREACH step IN ARRAY steps LOOP
        CALL public.sjv_retention_apply_one(month, step);
        COMMIT;
    END LOOP;
    PERFORM pg_catalog.pg_advisory_unlock(83422027);
END;
$$;

CREATE PROCEDURE sjv_retention_release_lock()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    WHILE sjv_retention_lock_held() LOOP
        PERFORM pg_catalog.pg_advisory_unlock(83422027);
    END LOOP;
END;
$$;

CREATE PROCEDURE sjv_retention_record_failure(month_start date, step text, reason text)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM public.sjv_retention_log_failed(month_start, step, reason);
    COMMIT;
END;
$$;

REVOKE ALL ON FUNCTION sjv_retention_log_protect() FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_month_ok(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_actual_payload_refs(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_defer_reason(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_detach(regclass, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_lock_held() FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_apply_step(date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_log_deferred(date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION sjv_retention_log_failed(date, text, text) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sjv_retention_apply_one(date, text) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sjv_retention_capture_gate(date, date, text) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sjv_retain_ingest_month(date) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sjv_retention_record_failure(date, text, text) FROM PUBLIC;
REVOKE ALL ON PROCEDURE sjv_retention_release_lock() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sjv_retention_log_failed(date, text, text) TO sjv_maintenance;
GRANT EXECUTE ON PROCEDURE sjv_retention_apply_one(date, text) TO sjv_maintenance;
GRANT EXECUTE ON PROCEDURE sjv_retention_capture_gate(date, date, text) TO sjv_maintenance;
GRANT EXECUTE ON PROCEDURE sjv_retain_ingest_month(date) TO sjv_maintenance;
GRANT EXECUTE ON PROCEDURE sjv_retention_record_failure(date, text, text) TO sjv_maintenance;
GRANT EXECUTE ON PROCEDURE sjv_retention_release_lock() TO sjv_maintenance;

RESET ROLE;
