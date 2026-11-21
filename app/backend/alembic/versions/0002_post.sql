-- R35. The table already exists. Partitions and grants follow the payload rules.

CREATE OR REPLACE FUNCTION sjv_create_month_partition(parent regclass, month_start date)
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
        'public.ingest_payload_items'::regclass,
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

DO $$
DECLARE
    start_month date;
    step integer;
BEGIN
    start_month := date_trunc('month', (now() AT TIME ZONE 'UTC'))::date;
    FOR step IN 0..3 LOOP
        PERFORM sjv_create_month_partition(
            'public.ingest_payload_items'::regclass,
            (start_month + make_interval(months => step))::date
        );
    END LOOP;
END $$;

GRANT SELECT, INSERT ON ingest_payload_items TO sjv_collector;
GRANT SELECT ON ingest_payload_items TO sjv_readonly;

RESET ROLE;
