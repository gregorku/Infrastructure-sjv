-- Triggers, month partitions and the collector grants.
-- message_ref has no unique constraint: its scope is not proven.
-- A delivery after timed_out has no approved status or rejection reason.

CREATE FUNCTION sjv_ingest_fragment_set_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status
       AND (OLD.status = 'isolated' OR NEW.status = 'isolated') THEN
        RAISE EXCEPTION 'isolated fragment set status cannot change'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ingest_fragment_sets_status
BEFORE UPDATE ON ingest_fragment_sets
FOR EACH ROW
EXECUTE FUNCTION sjv_ingest_fragment_set_status();

CREATE FUNCTION sjv_ingest_fragment_delivery_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    set_status text;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.delivery_role IS NOT DISTINCT FROM NEW.delivery_role THEN
        RETURN NEW;
    END IF;
    IF NEW.delivery_role IN ('repeat', 'conflict') THEN
        SELECT status INTO set_status
        FROM ingest_fragment_sets
        WHERE id = NEW.fragment_set_id
        FOR SHARE;
        IF set_status IS DISTINCT FROM 'collecting' THEN
            RAISE EXCEPTION 'repeat and conflict require a collecting fragment set'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ingest_fragments_delivery_role
BEFORE INSERT OR UPDATE OF delivery_role ON ingest_fragments
FOR EACH ROW
EXECUTE FUNCTION sjv_ingest_fragment_delivery_role();

CREATE FUNCTION sjv_meter_readings_protect()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.meter_id IS DISTINCT FROM OLD.meter_id
       OR NEW.source_stream_id IS DISTINCT FROM OLD.source_stream_id
       OR NEW.source_key IS DISTINCT FROM OLD.source_key
       OR NEW.source_kind IS DISTINCT FROM OLD.source_kind
       OR NEW.reading_kind IS DISTINCT FROM OLD.reading_kind
       OR NEW.quality IS DISTINCT FROM OLD.quality
       OR NEW.raw_telegram_id IS DISTINCT FROM OLD.raw_telegram_id
       OR NEW.decoded_observation_id IS DISTINCT FROM OLD.decoded_observation_id
       OR NEW.measured_at IS DISTINCT FROM OLD.measured_at
       OR NEW.time_basis IS DISTINCT FROM OLD.time_basis
       OR NEW.time_source IS DISTINCT FROM OLD.time_source
       OR NEW.primary_value IS DISTINCT FROM OLD.primary_value
       OR NEW.unit IS DISTINCT FROM OLD.unit
       OR NEW.quantity IS DISTINCT FROM OLD.quantity
       OR NEW.values IS DISTINCT FROM OLD.values
       OR NEW.status_flags IS DISTINCT FROM OLD.status_flags
       OR NEW.decoder_version IS DISTINCT FROM OLD.decoder_version
       OR NEW.adapter IS DISTINCT FROM OLD.adapter
       OR NEW.adapter_version IS DISTINCT FROM OLD.adapter_version
       OR NEW.normalizer_version IS DISTINCT FROM OLD.normalizer_version
       OR NEW.frame_hash IS DISTINCT FROM OLD.frame_hash
       OR NEW.access_number IS DISTINCT FROM OLD.access_number
       OR NEW.corrects_reading_id IS DISTINCT FROM OLD.corrects_reading_id
       OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at
       OR NEW.accepted_by IS DISTINCT FROM OLD.accepted_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'meter_readings update is limited to receipt_count, capture_device_ids and superseded_at'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_meter_readings_protect
BEFORE UPDATE ON meter_readings
FOR EACH ROW
EXECUTE FUNCTION sjv_meter_readings_protect();

CREATE FUNCTION sjv_create_month_partition(parent regclass, month_start date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    start_month date;
    end_month date;
    child text;
BEGIN
    IF parent NOT IN (
        'public.ingest_payloads'::regclass,
        'public.ingest_receipts'::regclass,
        'public.ingest_dedup_candidates'::regclass,
        'public.ingest_rejections'::regclass,
        'public.raw_telegrams'::regclass,
        'public.decoded_observations'::regclass,
        'public.device_events'::regclass
    ) THEN
        RAISE EXCEPTION 'partition parent is not an ingest table';
    END IF;
    start_month := date_trunc('month', month_start::timestamp)::date;
    end_month := (start_month + interval '1 month')::date;
    child := regexp_replace(parent::text, '^public\.', '') || '_p' || to_char(start_month, 'YYYYMM');
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
        child,
        parent,
        start_month,
        end_month
    );
END;
$$;

REVOKE ALL ON FUNCTION sjv_create_month_partition(regclass, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sjv_create_month_partition(regclass, date) TO sjv_maintenance;

DO $$
DECLARE
    parent regclass;
    start_month date;
    step integer;
    parents regclass[] := ARRAY[
        'public.ingest_payloads'::regclass,
        'public.ingest_receipts'::regclass,
        'public.ingest_dedup_candidates'::regclass,
        'public.ingest_rejections'::regclass,
        'public.raw_telegrams'::regclass,
        'public.decoded_observations'::regclass,
        'public.device_events'::regclass
    ];
BEGIN
    start_month := date_trunc('month', (now() AT TIME ZONE 'UTC'))::date;
    FOREACH parent IN ARRAY parents LOOP
        FOR step IN 0..3 LOOP
            PERFORM sjv_create_month_partition(
                parent,
                (start_month + make_interval(months => step))::date
            );
        END LOOP;
    END LOOP;
END $$;

GRANT SELECT ON devices TO sjv_collector;
GRANT UPDATE (last_seen_at) ON devices TO sjv_collector;

GRANT SELECT, INSERT ON ingest_sources, ingest_payloads, ingest_receipts,
    ingest_rejections, ingest_message_keys, ingest_fragments, ingest_fragment_sets,
    ingest_dedup_candidates, telegram_dedup_keys, raw_telegrams, decoded_observations,
    unknown_meter_sightings, device_boots, device_firmware_history, device_capabilities,
    device_events
    TO sjv_collector;

GRANT UPDATE (
    delivery_count, last_received_at, outcome, receipt_id, receipt_partition_month
) ON ingest_message_keys TO sjv_collector;

GRANT UPDATE (
    status, received_count, expected_count, deadline_at,
    assembled_payload_id, assembled_payload_partition_month
) ON ingest_fragment_sets TO sjv_collector;

GRANT UPDATE (last_seen_at, sighting_count, last_device_id, last_rssi)
    ON unknown_meter_sightings TO sjv_collector;
GRANT UPDATE (epoch_est, epoch_uncertainty_ms, last_seen_at)
    ON device_boots TO sjv_collector;
GRANT UPDATE (valid_to) ON device_firmware_history TO sjv_collector;
GRANT UPDATE (valid_to) ON device_capabilities TO sjv_collector;

GRANT SELECT ON ingest_endpoints, device_external_ids TO sjv_collector;
GRANT SELECT (
    id, manufacturer_code, wmbus_id, wmbus_version, wmbus_type, meter_key,
    driver, medium, primary_register, unit, dedup_window, max_flow_per_hour, status, note
) ON meters TO sjv_collector;

DO $$
DECLARE
    seq regclass;
BEGIN
    seq := pg_get_serial_sequence('raw_telegrams', 'id')::regclass;
    IF seq IS NULL THEN
        RAISE EXCEPTION 'raw_telegrams id sequence is missing';
    END IF;
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO sjv_collector', seq);
END $$;

-- The receiving transaction inserts the queue row. The worker only consumes it.
GRANT INSERT ON decode_queue TO sjv_collector;
GRANT INSERT ON decode_queue TO sjv_api;
GRANT SELECT ON decode_queue TO sjv_worker;
GRANT UPDATE (
    attempts, next_attempt_at, locked_by, locked_at, last_error
) ON decode_queue TO sjv_worker;
GRANT DELETE ON decode_queue TO sjv_worker;

-- Default privileges give this role table SELECT. That would include the
-- encrypted credential. Restore checks need the row identity only.
REVOKE SELECT ON TABLE endpoint_credentials FROM sjv_readonly;
GRANT SELECT (
    id, endpoint_id, kind, storage, created_at, revoked_at
) ON endpoint_credentials TO sjv_readonly;

RESET ROLE;
