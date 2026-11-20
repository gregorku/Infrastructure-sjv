-- Roles come from the database init. This migration does not create them
-- and does not store passwords.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sjv_owner') THEN
        RAISE EXCEPTION 'role sjv_owner must exist before the ingest migration';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sjv_collector') THEN
        RAISE EXCEPTION 'role sjv_collector must exist before the ingest migration';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sjv_maintenance') THEN
        RAISE EXCEPTION 'role sjv_maintenance must exist before the ingest migration';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sjv_api') THEN
        RAISE EXCEPTION 'role sjv_api must exist before the ingest migration';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sjv_worker') THEN
        RAISE EXCEPTION 'role sjv_worker must exist before the ingest migration';
    END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS btree_gist;
SET ROLE sjv_owner;
