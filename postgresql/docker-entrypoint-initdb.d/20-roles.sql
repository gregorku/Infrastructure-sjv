-- Roles from .env.example. Passwords come from \getenv, never from a process argument.
-- sjv_bootstrap already exists: the official entrypoint creates it as the superuser.
-- Table grants wait for the schema. Default privileges only give read access.
-- A broad write grant would hand later tables to every application role.

\getenv owner_password POSTGRES_SJV_OWNER_PASSWORD
\getenv api_password POSTGRES_SJV_API_PASSWORD
\getenv collector_password POSTGRES_SJV_COLLECTOR_PASSWORD
\getenv worker_password POSTGRES_SJV_WORKER_PASSWORD
\getenv maintenance_password POSTGRES_SJV_MAINTENANCE_PASSWORD
\getenv readonly_password POSTGRES_SJV_READONLY_PASSWORD

SELECT format(
    'CREATE ROLE sjv_owner LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'owner_password'
) \gexec
SELECT format(
    'CREATE ROLE sjv_api LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'api_password'
) \gexec
SELECT format(
    'CREATE ROLE sjv_collector LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'collector_password'
) \gexec
SELECT format(
    'CREATE ROLE sjv_worker LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'worker_password'
) \gexec
SELECT format(
    'CREATE ROLE sjv_maintenance LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'maintenance_password'
) \gexec
SELECT format(
    'CREATE ROLE sjv_readonly LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS',
    :'readonly_password'
) \gexec

CREATE ROLE pgbackrest LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;

REVOKE ALL ON DATABASE sjv FROM PUBLIC;
GRANT CONNECT ON DATABASE sjv TO sjv_owner, sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest;
ALTER DATABASE sjv OWNER TO sjv_owner;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO sjv_owner;
GRANT USAGE ON SCHEMA public TO sjv_api, sjv_collector, sjv_worker, sjv_maintenance, sjv_readonly, pgbackrest;

ALTER DEFAULT PRIVILEGES FOR ROLE sjv_owner IN SCHEMA public
    GRANT SELECT ON TABLES TO sjv_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE sjv_owner IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO sjv_readonly;

-- The role stays NOINHERIT. PostgreSQL 19 then leaves inherit_option false
-- unless the membership itself sets INHERIT TRUE.
GRANT pg_checkpoint, pg_read_all_settings, pg_read_all_stats TO pgbackrest WITH INHERIT TRUE;

-- Membership in pg_checkpoint does not grant EXECUTE on these functions.
-- PostgreSQL 19.0 keeps that privilege on the bootstrap superuser unless it
-- is granted explicitly. Signatures match pg_get_function_identity_arguments
-- from that version; OUT arguments of pg_backup_stop are not part of the grant.
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_start(text, boolean)
    TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_backup_stop(boolean)
    TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_create_restore_point(text)
    TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_switch_wal()
    TO pgbackrest;
