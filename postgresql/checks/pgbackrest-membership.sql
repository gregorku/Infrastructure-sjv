-- Read pgbackrest membership from the catalog.
-- member is the role that receives the grant. roleid is the granted role.
-- A NOINHERIT member inherits only a membership created WITH INHERIT TRUE.
-- SET defaults to true. The check passes only when all three rows are inherited.
SELECT member_role.rolname AS member_role,
       granted_role.rolname AS granted_role,
       m.inherit_option,
       m.set_option
FROM pg_auth_members AS m
JOIN pg_roles AS member_role ON member_role.oid = m.member
JOIN pg_roles AS granted_role ON granted_role.oid = m.roleid
WHERE member_role.rolname = 'pgbackrest'
  AND granted_role.rolname IN ('pg_checkpoint', 'pg_read_all_settings', 'pg_read_all_stats')
  AND m.inherit_option
ORDER BY granted_role.rolname;
