-- pg-logical-replication-precheck.sql
--
-- Read-only pre-checks for moving a PostgreSQL database with native logical
-- replication (publications and subscriptions). Written for a PostgreSQL 10 or
-- 11 source, and safe to run on newer versions.
--
-- Run it against the SOURCE database, once per database you plan to move:
--
--   psql -h <host> -p <port> -U <user> -d <database> -X -f pg-logical-replication-precheck.sql
--
-- Needs psql 10 or later. Any user that can read the catalogs will do. A few
-- checks (sequence values, slot details) show more with elevated privileges.
-- Nothing here writes, locks tables or reads table data.

\set ON_ERROR_STOP off
\pset pager off
\pset null '(null)'
SET default_transaction_read_only = on;
SET statement_timeout = '60s';

SELECT current_setting('server_version_num')::int >= 120000 AS pg12plus \gset

\echo
\echo '=== 1. Server settings logical replication depends on ==='
\echo 'wal_level must be logical. Slots and senders need one per subscription, plus headroom for the initial copy.'
SELECT name, setting, unit,
       CASE WHEN name = 'wal_level' AND setting <> 'logical' THEN 'CHANGE: needs logical, and a restart' END AS note
FROM pg_settings
WHERE name IN ('server_version', 'wal_level', 'max_replication_slots', 'max_wal_senders',
               'max_worker_processes', 'max_logical_replication_workers',
               'max_sync_workers_per_subscription', 'password_encryption',
               'idle_in_transaction_session_timeout')
ORDER BY name;

\echo
\echo '=== 2. Tables that cannot replicate UPDATE or DELETE ==='
\echo 'No primary key and no usable replica identity. Fix these first.'
SELECT n.nspname AS schema, c.relname AS table,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
       c.reltuples::bigint AS approx_rows,
       CASE c.relreplident WHEN 'd' THEN 'default (no primary key)'
                           WHEN 'n' THEN 'nothing' END AS replica_identity
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
  AND (c.relreplident = 'n'
       OR (c.relreplident = 'd' AND NOT EXISTS (
             SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)))
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo
\echo '=== 3. Tables using REPLICA IDENTITY FULL ==='
\echo 'They replicate, but every update and delete ships the whole row and is slow to apply.'
SELECT n.nspname AS schema, c.relname AS table,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND c.relreplident = 'f'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo
\echo '=== 4. Objects logical replication will not carry ==='
\echo 'Unlogged tables, materialized views and foreign tables. Rebuild or refresh them on the target.'
SELECT n.nspname AS schema, c.relname AS object,
       CASE c.relkind WHEN 'm' THEN 'materialized view'
                      WHEN 'f' THEN 'foreign table'
                      ELSE 'unlogged table' END AS kind,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
  AND (c.relkind IN ('m', 'f') OR (c.relkind = 'r' AND c.relpersistence = 'u'))
ORDER BY kind, schema, object;

\echo
\echo '=== 5. Partitioned tables ==='
\echo 'Before 13 the parent cannot be published. Each partition is published on its own, and every new'
\echo 'partition must exist on both sides and be added to the publication before its first row.'
SELECT n.nspname AS schema, p.relname AS partitioned_table,
       count(i.inhrelid) AS partitions,
       pg_size_pretty(sum(pg_total_relation_size(i.inhrelid))) AS total_size
FROM pg_class p
JOIN pg_namespace n ON n.oid = p.relnamespace
LEFT JOIN pg_inherits i ON i.inhparent = p.oid
WHERE p.relkind = 'p'
GROUP BY n.nspname, p.relname
ORDER BY sum(pg_total_relation_size(i.inhrelid)) DESC NULLS LAST;

\echo
\echo '=== 6. Large objects ==='
\echo 'Large objects (pg_largeobject) are not replicated. Plan a separate copy if this is not zero.'
SELECT count(*) AS large_objects FROM pg_largeobject_metadata;
SELECT n.nspname AS schema, c.relname AS table, a.attname AS column, format_type(a.atttypid, a.atttypmod) AS type
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
  AND format_type(a.atttypid, a.atttypmod) IN ('oid', 'lo')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2, 3;

\echo
\echo '=== 7. Sequences ==='
\echo 'Sequences are not replicated. Read last_value at cutover and set the target above it.'
\echo 'A null last_value means never used, or no permission to read it.'
SELECT s.schemaname AS schema, s.sequencename AS sequence, s.last_value, s.cache_size,
       COALESCE(dc.relname || '.' || a.attname, '(not owned by a column)') AS owned_by
FROM pg_sequences s
JOIN pg_namespace n ON n.nspname = s.schemaname
JOIN pg_class sc ON sc.relname = s.sequencename AND sc.relnamespace = n.oid
LEFT JOIN pg_depend d ON d.objid = sc.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
LEFT JOIN pg_class dc ON dc.oid = d.refobjid
LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
ORDER BY s.last_value DESC NULLS LAST;

\echo
\echo '=== 8. User triggers ==='
\echo 'Replicated changes skip ordinary triggers on the subscriber. ALWAYS triggers fire twice, once at the'
\echo 'source and again when the change is applied. REPLICA triggers fire only on applied changes.'
SELECT n.nspname AS schema, c.relname AS table, t.tgname AS trigger,
       CASE t.tgenabled WHEN 'O' THEN 'ordinary' WHEN 'A' THEN 'ALWAYS (check this)'
                        WHEN 'R' THEN 'REPLICA only' WHEN 'D' THEN 'disabled' END AS fires
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY (t.tgenabled = 'A') DESC, 1, 2, 3;

\echo
\echo '=== 9. Extensions ==='
\echo 'Each one has to exist on the target, in a version that works with the target major version.'
SELECT extname AS extension, extversion AS version FROM pg_extension ORDER BY 1;

\echo
\echo '=== 10. Features removed in newer versions ==='
\if :pg12plus
\echo 'Source is 12 or later: WITH OIDS tables and abstime/reltime/tinterval are already gone.'
\else
\echo 'Tables created WITH OIDS (removed in 12):'
SELECT n.nspname AS schema, c.relname AS table
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND c.relhasoids AND n.nspname NOT IN ('pg_catalog', 'information_schema');
\echo 'Columns using abstime, reltime or tinterval (removed in 12):'
SELECT n.nspname AS schema, c.relname AS table, a.attname AS column, t.typname AS type
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_type t ON t.oid = a.atttypid
WHERE a.attnum > 0 AND NOT a.attisdropped AND t.typname IN ('abstime', 'reltime', 'tinterval')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema');
\endif

\echo
\echo '=== 11. Collation exposure ==='
\echo 'A newer glibc or ICU on the target can sort text differently. Unique indexes on text are the ones'
\echo 'that can fail to build or behave differently. Rebuild and check these on the target.'
SELECT datname AS database, datcollate AS collate, datctype AS ctype
FROM pg_database WHERE datname = current_database();
SELECT n.nspname AS schema, ic.relname AS index, tc.relname AS table,
       pg_size_pretty(pg_relation_size(ic.oid)) AS index_size
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class tc ON tc.oid = i.indrelid
JOIN pg_namespace n ON n.oid = tc.relnamespace
WHERE i.indisunique AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND EXISTS (SELECT 1 FROM pg_attribute a
              WHERE a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype))
ORDER BY pg_relation_size(ic.oid) DESC;

\echo
\echo '=== 12. Biggest and busiest tables ==='
\echo 'Write counts are cumulative since the last stats reset. Sample twice, an hour apart at peak, to get a rate.'
SELECT s.schemaname AS schema, s.relname AS table,
       pg_size_pretty(pg_total_relation_size(s.relid)) AS size,
       s.n_tup_ins AS inserts, s.n_tup_upd AS updates, s.n_tup_del AS deletes,
       (SELECT count(*) FROM pg_index i WHERE i.indrelid = s.relid) AS indexes
FROM pg_stat_user_tables s
ORDER BY pg_total_relation_size(s.relid) DESC
LIMIT 25;
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();

\echo
\echo '=== 13. Foreign keys between tables ==='
\echo 'Use these when drawing migration units. A child inserted on one side needs its parent to exist there.'
SELECT cn.nspname || '.' || c.relname AS child, pn.nspname || '.' || p.relname AS parent, con.conname AS constraint
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
JOIN pg_class p ON p.oid = con.confrelid JOIN pg_namespace pn ON pn.oid = p.relnamespace
WHERE con.contype = 'f'
ORDER BY parent, child;

\echo
\echo '=== 14. Existing replication slots, publications and subscriptions ==='
\echo 'An inactive slot keeps WAL forever on 11 and earlier. retained_wal shows how much it is holding.'
SELECT slot_name, plugin, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete FROM pg_publication;
SELECT count(*) AS subscriptions_in_this_cluster FROM pg_subscription;

\echo
\echo '=== 15. Long transactions and snapshot age ==='
\echo 'Long open transactions hold back cleanup, and a long initial copy holds a snapshot open too.'
SELECT pid, usename, application_name, client_addr, state,
       now() - xact_start AS transaction_age, left(query, 80) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND pid <> pg_backend_pid()
ORDER BY xact_start
LIMIT 10;
SELECT datname, age(datfrozenxid) AS xid_age FROM pg_database ORDER BY 2 DESC;

\echo
\echo '=== 16. Who is connected right now ==='
\echo 'A snapshot only. Turn on log_connections for a full month to catch the monthly jobs.'
SELECT usename, application_name, client_addr, count(*) AS sessions
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
GROUP BY 1, 2, 3
ORDER BY sessions DESC;

\echo
\echo '=== 17. Passwords stored as MD5 ==='
\echo 'Newer targets default to SCRAM, and some managed services refuse MD5. Plan resets for these roles.'
SELECT rolsuper AS is_superuser FROM pg_roles WHERE rolname = current_user \gset
\if :is_superuser
SELECT rolname AS role, rolcanlogin AS can_login
FROM pg_authid WHERE rolpassword LIKE 'md5%' ORDER BY 1;
\else
\echo 'Skipped: reading password hashes needs a superuser.'
\endif

\echo
\echo 'Done. Nothing was changed.'
