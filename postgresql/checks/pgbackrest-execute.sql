-- Runtime check. All four columns must be true.
-- These EXECUTE privileges are separate from membership in pg_checkpoint.
SELECT
    has_function_privilege(
        'pgbackrest',
        'pg_catalog.pg_backup_start(text,boolean)',
        'EXECUTE'
    ) AS backup_start,
    has_function_privilege(
        'pgbackrest',
        'pg_catalog.pg_backup_stop(boolean)',
        'EXECUTE'
    ) AS backup_stop,
    has_function_privilege(
        'pgbackrest',
        'pg_catalog.pg_create_restore_point(text)',
        'EXECUTE'
    ) AS restore_point,
    has_function_privilege(
        'pgbackrest',
        'pg_catalog.pg_switch_wal()',
        'EXECUTE'
    ) AS switch_wal;
