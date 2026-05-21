---
author: Venkatesh Periyathambi
pubDatetime: 2025-05-01T10:00:00Z
modDatetime: 2026-05-21T10:00:00Z
title: "Altering a big table online: ADD column with near-zero downtime on MySQL 8+ and Postgres 14+"
slug: online-alter-big-table
featured: true
draft: false
tags:
  - mysql
  - postgres
  - schema-migration
  - databases
  - online-ddl
description: A practical, cloud-agnostic look at adding columns to large tables without downtime — what MySQL 8+ and Postgres 14+ actually let you do, the expand-contract pattern that beats native DDL alone, the OSS tools, and the managed-service caveats.
---

You've got a 500-million-row table in production and product wants a new column on it by the end of the sprint. The schema change is trivial. The deploy is the scary part.

If you've been here before, you know the real problem isn't usually the `ALTER TABLE` — modern engines have online DDL that handles most ADD COLUMN cases in milliseconds. The real problem is everything around it: the lock that piles up behind a long-running transaction; the rolling app deploy where v1 and v2 coexist for ten minutes; the replica that lags an hour while a copy-rebuild crawls through 400 GB; the drop column you can't undo.

This post is a tour of how to think about it on **MySQL 8+** and **Postgres 14+**. It's focused on **ADD COLUMN** — that's where most of the pain lives — with a quick word at the end on DROP and RENAME. It's cloud-agnostic, but I'll flag managed-service caveats where they bite. And I'll list the OSS tools without picking favourites: each makes different tradeoffs, and the right one depends on your topology, your tolerance for triggers, and what you're allowed to run in your environment.

## Table of contents

---

## 1. Why "online DDL" doesn't mean "no downtime"

Before getting into engine specifics, the framing that matters most:

> Online DDL solves the *table-locking* problem. It does not solve the *deploy-atomicity* problem.

Even an instant DDL still needs a brief metadata-level lock to swap the table definition. If a long-running query — or just an idle-in-transaction session — is holding any lock on the table when your `ALTER` arrives, the `ALTER` waits. Worse, every statement that arrives *after* the `ALTER` queues behind it, because the queue is FIFO. What started as a millisecond DDL becomes an outage that lasts as long as that one slow query.

Separately, your application doesn't deploy atomically. A rolling rollout means v1 pods (which write to the old schema) run alongside v2 pods (which write to the new) for minutes at a time. If the schema change is anything more than purely additive, you can lose data in that window unless the application is explicitly tolerant of mixed schemas.

So "online DDL" is necessary, not sufficient. The native engine capability is the floor; the application choreography around it is where near-zero downtime is actually won. We'll come back to that pattern in §4.

---

## 2. MySQL 8+: INSTANT, INPLACE, COPY

InnoDB exposes three algorithms for `ALTER TABLE`. You pick by adding `ALGORITHM=...` to the statement; if you don't, MySQL picks the cheapest one that works for your operation.

### `ALGORITHM=INSTANT` — the happy path

INSTANT became the default for `ADD COLUMN` in **8.0.12** and was substantially relaxed in **8.0.29** to allow adding a column at any position (not just last) and to allow `INSTANT` for `DROP COLUMN`.

The mechanism is on-disk row versions. Existing rows aren't touched; the new column's metadata is recorded, and reads reconstruct the column virtually. The work is O(1) regardless of table size.

What blocks INSTANT (per the [InnoDB Online DDL docs](https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html)):

- The table uses `ROW_FORMAT=COMPRESSED`, has a `FULLTEXT` index, or is a system schema table.
- The new column is a stored generated column, an identity column, or has a domain type with constraints.
- The change is combined in the same `ALTER` with another action that doesn't support INSTANT.
- The row size after the addition would exceed the max permissible row size (you'll get `ERROR 4092`).

There are two distinct numerical limits worth knowing — the AWS-knowledge-style write-up of this often conflates them:

- **64 row versions per table.** Each `INSTANT` add or drop increments `INFORMATION_SCHEMA.INNODB_TABLES.TOTAL_ROW_VERSIONS`. Hit 64 and the next instant change is rejected (`ERROR 4092: Maximum row versions reached`); you have to rebuild the table to reset.
- **1022 columns** in the internal representation post-instant-add. Adding more rejects with `ERROR 4158`.

A table-rebuilding `ALTER` or `OPTIMIZE TABLE` resets `TOTAL_ROW_VERSIONS` to 0.

### `ALGORITHM=INPLACE` — when INSTANT can't apply

INPLACE rebuilds the data using an online log to capture concurrent DML, allowing reads and writes throughout most of the operation. Brief exclusive metadata locks bookend the run. Cost scales with table size — hours for terabyte tables, with extra IO and tablespace.

This is what you fall through to for changes INSTANT won't take: adding a column on a `COMPRESSED` table, certain primary-key changes, virtual generated columns being added to a *non-partitioned* table (partitioned tables block INPLACE for virtual columns).

### `ALGORITHM=COPY` — the one to avoid

Triggered when neither INSTANT nor INPLACE can satisfy the change. Takes a `LOCK=SHARED`, blocking writes for the entire rebuild. On a multi-TB table this is hours of read-only or full downtime, plus the same duration of replica lag because the single statement serializes through the SQL applier on every replica.

If you find yourself looking at COPY, that's the signal to use one of the OSS tools (§5) instead.

### Replication implications

INSTANT DDL flows statement-by-statement through replication. Each replica executes the same `ALTER` and applies it instantly too — *if* it's also on 8.0.29+. Mixed-version topologies (primary on 8.0.29+ writing INSTANT shapes, replica on something older) will fail replay. Treat 8.0.29 as a hard floor before you start using the new INSTANT shapes routinely.

INPLACE and COPY ALTERs serialize on the SQL applier and lag replicas for the full duration. Plan accordingly.

### The MDL pile-up — the real production failure mode

Even an instant-class DDL needs a brief exclusive metadata lock. If a long-running transaction has *any* lock on the target table — including just holding a result set open with the table referenced — the `ALTER` waits behind it, and every subsequent query queues behind the `ALTER`. Twenty seconds of "instant" DDL becomes a queue of thousands of stuck connections, and the symptom is indistinguishable from the database being down.

Mitigations are non-optional:

- Set a short `lock_wait_timeout` on the DDL session (5–30 seconds) so it bails out and retries instead of holding the queue forever.
- Watch `performance_schema.metadata_locks` for waiters before issuing.
- Kill long-running and idle-in-transaction sessions on the target table before the DDL window.

"Instant" describes the work, not the lock.

---

## 3. Postgres 14+: ALTER TABLE and the lock-mode lottery

Postgres takes a different approach. There's no `ALGORITHM=` knob, but there are sharp rules about which sub-operations rewrite the table, which scan it, and which are pure metadata. The default lock for `ALTER TABLE` is `ACCESS EXCLUSIVE` "unless explicitly noted" ([docs](https://www.postgresql.org/docs/current/sql-altertable.html)) — and `ACCESS EXCLUSIVE` blocks everything, including reads. So the game is structuring your change to *avoid* either a rewrite or a long scan while holding that lock.

### `ADD COLUMN` — the rewrite vs. metadata distinction

This is the headline number, straight from the docs:

> *When a column is added with ADD COLUMN and a non-volatile DEFAULT is specified, the default value is evaluated at the time of the statement and the result stored in the table's metadata, where it will be returned when any existing rows are accessed. The value will be only applied when the table is rewritten, making the ALTER TABLE very fast even on large tables.*

This is the **fast-default** optimisation, [introduced in PG 11](https://www.postgresql.org/docs/release/11.0/) ("Allow ALTER TABLE to add a column with a non-null default without doing a table rewrite … This is enabled when the default value is a constant.") and present in every major version since.

- **No default, or constant DEFAULT, or no constraints**: metadata-only. Effectively instant.
- **Volatile DEFAULT** (`clock_timestamp()`, `gen_random_uuid()`), **stored generated column**, **identity column**, **constrained domain type**: full table + index rewrite. On a 500 GB table, this is hours of `ACCESS EXCLUSIVE`.
- **Virtual generated column**: never requires a rewrite.

So the rule is simple: if you need a default value, make sure it's a constant. If it's `now()`, you don't get the optimisation.

### `SET NOT NULL` without a table scan

This is the part lots of people miss. Naïvely, `ALTER COLUMN ... SET NOT NULL` scans the entire table to verify no NULLs exist, holding `ACCESS EXCLUSIVE` for the whole scan.

Since [PG 12](https://www.postgresql.org/docs/release/12.0/) ("Allow ALTER TABLE ... SET NOT NULL to avoid unnecessary table scans") there's a shortcut: if a valid `CHECK (col IS NOT NULL)` constraint already exists on the column, `SET NOT NULL` skips the scan and just flips the catalog bit.

That gives you the standard production pattern for adding a `NOT NULL` column without locking out the table:

```sql
-- 1. Add nullable, with a constant default. Metadata-only since PG 11.
ALTER TABLE big ADD COLUMN status text DEFAULT 'pending';

-- 2. Backfill any rows that need a different value, in batches. (See §4.)

-- 3. Add a CHECK constraint as NOT VALID — does not scan, commits immediately.
ALTER TABLE big ADD CONSTRAINT status_not_null CHECK (status IS NOT NULL) NOT VALID;

-- 4. Validate it. Takes only SHARE UPDATE EXCLUSIVE, doesn't block reads or writes.
ALTER TABLE big VALIDATE CONSTRAINT status_not_null;

-- 5. Promote to a real NOT NULL. Skips the scan because the CHECK already proves it.
ALTER TABLE big ALTER COLUMN status SET NOT NULL;

-- 6. Drop the redundant CHECK if you want.
ALTER TABLE big DROP CONSTRAINT status_not_null;
```

Each step takes a brief lock — never a long-running one. The longest step in elapsed time is `VALIDATE CONSTRAINT`, but it doesn't lock writers.

### `ALTER COLUMN TYPE` — usually a rewrite, sometimes not

Type changes normally rewrite the table and rebuild indexes. The exception: when the new type is binary-coercible from the old (the canonical example is `text` ↔ `varchar`) and the `USING` clause doesn't change values, a rewrite isn't needed. Indexes still rebuild unless the system can prove logical equivalence — a collation change, for example, forces an index rebuild.

For most genuine type widenings (`int4` → `int8`, `varchar(50)` → `varchar(200)` is fine but `varchar(50)` → `int` is not) you're rewriting. That's a candidate for the application-level approach in §4.

### `lock_timeout` is your circuit breaker

Same pile-up problem as MySQL: if anything is holding a lock when your `ALTER` lands, you queue forever and so does everything behind you. The Postgres mitigation is a session-level timeout:

```sql
SET lock_timeout = '2s';
ALTER TABLE big ADD COLUMN status text DEFAULT 'pending';
```

If the lock can't be acquired in two seconds, the statement fails and you retry. Better a flaky deploy than an outage.

In practice, wrap it in a retry loop so the migration script handles this automatically:

```sql
DO $$
DECLARE attempts INT := 0;
BEGIN
  LOOP
    BEGIN
      SET LOCAL lock_timeout = '2s';
      ALTER TABLE big ADD COLUMN status text DEFAULT 'pending';
      RETURN;
    EXCEPTION WHEN lock_not_available THEN
      attempts := attempts + 1;
      IF attempts >= 30 THEN RAISE; END IF;
      PERFORM pg_sleep(0.5 + random());  -- jittered backoff
    END;
  END LOOP;
END $$;
```

This prevents the cascading pileup: the DDL either gets the lock quickly or backs off without blocking everything behind it.

### Logical replication

DDL is *not* automatically replicated through logical replication in PG 14+. If you're using logical replication for HA, cross-region copies, or zero-downtime version upgrades, you have to apply schema changes on each side. PG 16 added some primitives for replicating DDL but it's still off by default and limited; treat schema as a per-cluster operation.

---

## 4. Expand-contract: the pattern that actually wins

This is the part you'll keep coming back to. Engine capabilities tell you what's *possible* in a single DDL; expand-contract tells you how to evolve the schema *across* a rolling deploy without ever requiring the database and the application fleet to be in lockstep.

The pattern, originally [Martin Fowler's "Parallel Change"](https://martinfowler.com/bliki/ParallelChange.html) and later catalogued in Sadalage and Ambler's *Refactoring Databases*, looks like this when you're adding a column:

1. **Expand.** Add the new column as nullable with a safe constant default. No app change. Old code unaffected because nothing references the new column yet.
2. **Dual-write.** Deploy code that writes to both old and new columns on every INSERT/UPDATE. Reads still come from the old. This step is what makes the application tolerant of mixed-version peers during the rollout — v1 pods write only to old, v2 pods write to both, and both behaviours are correct.
3. **Backfill.** A background job copies old → new for existing rows, in batches, throttled. New writes are already correct thanks to dual-write, so the backfill only chases history.
4. **Switch reads.** Deploy again. Reads now come from the new column; writes still go to both. Verify with shadow comparisons or row-level checksums while you can.
5. **Stop writing the old column.** Another deploy.
6. **Contract.** Drop the old column once you're confident no code path or replica references it.

Each step is independently reversible. At no point does correctness depend on the database and every application replica cutting over in the same instant.

It looks like a lot of steps because it is. The point is that each one is *boring*. You can pause for a week between any two of them. A typo in step 4 doesn't corrupt data — it just lets you roll back.

### Why this beats "just use online DDL"

Online DDL solves the table lock. It does not solve the rolling-deploy problem. If you `ALTER TABLE big ADD COLUMN status text NOT NULL DEFAULT 'pending'` and immediately deploy code that requires the column, the v1 pods still running for the next ten minutes will continue to write rows missing fields the new code reads. Even if the DDL was instant, your application's state is inconsistent during the deploy.

Expand-contract decouples the schema timeline from the deploy timeline.

### Where it falls short

- **Renames** require the full dance — you can't shortcut. Add new column, dual-write, backfill, switch reads, stop writing old, drop. The whole thing.
- **Large backfills** dominate wall-clock time. A billion-row table backfilled at 10k rows/sec is a 28-hour job. Throttle aggressively against replica lag, not wall time.
- **Strict ordering or uniqueness constraints** complicate dual-write — you may need a temporary trigger or a compare-and-swap to avoid races.

### Backfill mechanics

A few patterns that are worth getting right the first time:

- **Cursor by primary key, not `OFFSET`.** `OFFSET` gets quadratic on big tables. Track `last_id`, `WHERE id > :last_id ORDER BY id LIMIT :batch_size`, commit, sleep, repeat.
- **Make the update idempotent.** `UPDATE ... SET new_col = :value WHERE new_col IS NULL AND id IN (...)` — reruns are safe.
- **Throttle on replica lag, not wall time.** Stripe's [Online migrations at scale](https://stripe.com/blog/online-migrations) and Block's [Shifting Trillions](https://developer.squareup.com/blog/shifting-trillions-of-financial-records-with-no-downtime/) both gate batch rate on replica health. If lag exceeds N seconds, sleep until it recovers.
- **Feature-flag the read switch.** Wrapping step 4 in a flag means flipping read source is a config change, not a deploy. Roll back instantly if something looks wrong.

---

## 5. The OSS tooling landscape

When native DDL won't cut it — your change can't be made INSTANT, you can't afford INPLACE's hours of replica lag, or you're on Postgres and need to rewrite the table without holding `ACCESS EXCLUSIVE` — these are the tools that get reached for. They split into a few mechanism families. Each makes different tradeoffs; pick by what your environment supports and what failure modes you can tolerate.

The repo activity below was pulled from the GitHub API on 2026-05-21 — verify before you adopt anything, since maintenance status changes.

### MySQL

**[pt-online-schema-change](https://github.com/percona/percona-toolkit) (Percona Toolkit)** — *Trigger-based.* Creates a shadow table, installs `AFTER INSERT/UPDATE/DELETE` triggers on the original to mirror writes, chunk-copies existing rows, atomic rename at the end. The industry workhorse since the early 2010s. Very mature; handles almost any DDL. Triggers double the write cost on the source table during the run; foreign keys are painful (`--alter-foreign-keys-method` has three modes, each with sharp edges). Actively maintained.

**[gh-ost](https://github.com/github/gh-ost) (GitHub)** — *Binlog-based, no triggers.* Connects as a replica, tails the binlog to apply concurrent DML to the ghost table while chunk-copying rows, atomic rename at the end. Lower and more predictable write overhead than triggers; can throttle on replica lag, custom queries, or load metrics; can pause and resume; can hand off the cut-over to a human. Foreign keys essentially unsupported. Requires `binlog_format=ROW` and `binlog_row_image=FULL`. Actively maintained — v1.1.9 GA on 2026-05-01, recent commits in the repo today.

**[Spirit](https://github.com/block/spirit) (Block / formerly Cashapp)** — *Hybrid.* Uses MySQL 8.0's native INSTANT/INPLACE algorithms when the DDL qualifies, falls back to a gh-ost-style binlog-tailed copy when it doesn't. Designed to be invoked inline by application deploy pipelines rather than as a long-lived ops process. MySQL 8.0+ only. Younger and narrower than gh-ost; smaller community. Actively maintained.

This INSTANT-first approach is worth internalising as a principle: why copy 500 GB of data if the engine can do it in milliseconds? Spirit codifies what you should be doing mentally — check INSTANT first, fall back to copy only when you must. Its parallel copy threads and delta-map deduplication also make it significantly faster than gh-ost when a copy *is* needed (CashApp reports 5x+ improvements on large tables when the buffer pool can hold secondary indexes).

### Postgres

**[pg_repack](https://github.com/reorg/pg_repack)** — *Trigger-based, but for table rewriting, not online ALTER.* Worth listing because it gets confused with online-DDL tools. It does online table rebuilds (the `VACUUM FULL` replacement) and re-clustering, but it cannot add or drop columns. You use it to clean up bloat *after* you've evolved the schema some other way.

**[pg-osc](https://github.com/shayonj/pg-osc)** — *Trigger-based.* The pt-osc model ported to Postgres: shadow table, triggers mirror writes, chunk-copy backfill, swap. Familiar mental model for teams coming from MySQL. Same trigger write-amplification cost as pt-osc. Works for column type changes and other DDL that PG won't do without rewriting. Single-maintainer; commits in 2026 but slower cadence than the bigger projects.

**[pgroll](https://github.com/xataio/pgroll) (Xata)** — *Multi-version schema using views.* A genuinely different mechanism: each migration creates new views over the underlying tables, with triggers translating writes between the old and new shapes. Old and new application versions read/write their own view set simultaneously. You `complete` the migration when all clients have moved. PG 14+. Declarative JSON migration spec; reversible until completion. Application has to connect to the right schema; ORMs that introspect schemas can get confused. Actively maintained.

**[Reshape](https://github.com/fabianlindfors/reshape)** — *Multi-version schema using views.* Same idea as pgroll, predates it, influenced its design. Rust implementation, TOML migration files. Slower release cadence in 2026; pgroll has more momentum in this category.

### Orchestrators (a layer up)

The conversation in 2026 has shifted from "which copy tool" toward "which orchestrator drives the copy tool." If you're standardising across a fleet of services, these are worth a look:

- **[Bytebase](https://github.com/bytebase/bytebase)** — schema-change workflow platform with review/rollout governance; runs gh-ost or pt-osc under the hood.
- **[Atlas](https://github.com/ariga/atlas)** — declarative schema management for MySQL/Postgres/SQLite/MSSQL; integrates with pt-osc/gh-ost for the online execution step.
- **[Skeema](https://github.com/skeema/skeema)** — pure-MySQL declarative schema-as-code; can shell out to pt-osc or gh-ost for unsafe ALTERs.

### Out of scope (but readers will ask)

**Liquibase** and **Flyway** are migration *runners* — they sequence and version your DDL but don't perform online ALTERs themselves. You'd use them to drive the *steps* of the expand-contract pattern, with one of the tools above (or native DDL) doing the actual mechanism for any step that needs it.

---

## 6. Managed services: what changes

If you're on RDS, Aurora, or Cloud SQL, several primitives this post assumes — `SUPER`, direct binlog access, custom replication topologies — are restricted or replaced by service-specific equivalents. The headline: **all the tools above still work, but you have to enable some of them deliberately.**

### AWS RDS Blue/Green

[RDS Blue/Green Deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-overview.html) clone your primary into a fully-synchronised "green" stack, let you make schema changes there, and switch over typically in under a minute. Supported on RDS for MySQL 5.7+/8.0/8.4, MariaDB 10.2+, and PostgreSQL 11.1+. Sync uses binlog replication for MySQL and logical replication for Postgres, so changes must be **replication-safe** — additive column adds and index creates are fine; destructive renames the green doesn't have rows for break sync.

### Aurora Blue/Green

Aurora MySQL has had Blue/Green since 2022. Aurora PostgreSQL Blue/Green is GA on 11.21+, 12.16+, 13.12+, 14.9+, 15.4+ and later. For Aurora PostgreSQL specifically: Blue/Green sync is logical-replication-based and is **single-threaded on apply** — high-write workloads can lag the green significantly. Aurora PG Blue/Green also does **not replicate DDL or DCL** between blue and green, so you typically run schema changes on the green directly during the staging window, not on the blue.

### gh-ost on Aurora MySQL

Aurora doesn't need binlogs for HA (storage-level replication), so they're **off by default**. To run gh-ost you must enable `binlog_format=ROW` in the cluster parameter group and reboot the writer. The default binlog write overhead is about 50%; Aurora MySQL 3.03.1+ offers an [enhanced binlog](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Enhanced.binlog.html) that cuts this to ~13%.

### pt-osc on Aurora

`--check-replica-lag` historically uses `SHOW SLAVE STATUS`, which doesn't exist on Aurora (replication is storage-level, not binlog-based). Either skip the check or wire it to Aurora's `aurora_replica_status` view.

### RDS MySQL gotchas

The master user lacks `SUPER`, so pt-osc needs `log_bin_trust_function_creators=1` in the parameter group to install its triggers. Also raise binlog retention with `CALL mysql.rds_set_configuration('binlog retention hours', 24)` or RDS purges them more aggressively than gh-ost expects.

### Google Cloud SQL

No exact Blue/Green equivalent. Cloud SQL Enterprise Plus offers [near-zero-downtime planned maintenance](https://cloud.google.com/sql/docs/mysql/maintenance) (a quick connection failover during maintenance windows, typically ~60 seconds), and the [Database Migration Service](https://cloud.google.com/database-migration) handles staged version migrations.

For everyday schema changes, the recommended path is the same OSS tooling — pt-osc/gh-ost for MySQL, pg-osc or pgroll for Postgres. Cloud SQL exposes binlogs and grants `REPLICATION CLIENT`/`REPLICATION SLAVE` to user-created replication users, so gh-ost works. For Postgres, `cloudsqlsuperuser` is not a true superuser, but [logical decoding can be enabled](https://cloud.google.com/sql/docs/postgres/replication/configure-logical-replication) via the `cloudsql.logical_decoding=on` flag, which is what most logical-replication-based tools need.

---

## 7. DROP and RENAME, briefly

### DROP COLUMN

On both engines, this is the easy direction. MySQL 8.0.29+ supports `ALGORITHM=INSTANT` for DROP COLUMN with the same row-version mechanism as ADD. Postgres marks the column as dropped in metadata; physical removal happens on the next table rewrite.

The catch is application coordination, not the DDL itself. If v1 pods are still writing to a column the schema no longer has, every write fails. Drop the column only after all application versions that reference it are out of rotation — run it as the final step of an expand-contract sequence, not the first.

### RENAME COLUMN

This is the one with no shortcut. Both engines support it as a fast, lock-light operation:

- **MySQL 8.0.28+** added `ALGORITHM=INSTANT` for renames, *unless* the column is referenced by a foreign key in another table — that case requires `ALGORITHM=INPLACE`.
- **Postgres** takes `ACCESS EXCLUSIVE` briefly to flip the catalog. Same MDL pile-up risk as any other DDL; use `lock_timeout`.

But the DDL being fast doesn't matter, because the application can't atomically rename a column. v1 code references the old name; v2 code references the new name; they coexist for the duration of a rolling deploy. The only safe path is full expand-contract: add new column, dual-write, backfill, switch reads, stop writing old, drop old. There is no shortcut.

---

## 8. Quick reference: MySQL vs PostgreSQL side-by-side

| Operation | MySQL 8.0+ | PostgreSQL 14+ |
|-----------|-----------|----------------|
| ADD COLUMN + constant default | INSTANT (8.0.29+ any position; 8.0.12 last only) | Instant (metadata-only since PG 11) |
| ADD COLUMN + volatile default | INPLACE (table rebuild, allows DML) | ACCESS EXCLUSIVE (full rewrite) |
| DROP COLUMN | INSTANT (8.0.29+) | Instant (marks dropped, no rewrite) |
| RENAME COLUMN | INSTANT (8.0.28+) | Brief ACCESS EXCLUSIVE (catalog flip) |
| ADD INDEX | INPLACE, LOCK=NONE (blocks replicas) | CREATE INDEX CONCURRENTLY (blocks nothing) |
| SET NOT NULL | INPLACE, LOCK=NONE (blocks replicas) | CHECK trick: no blocking (PG 12+) |
| Change type (rewrite needed) | COPY or external tool | Expand/contract or pg-osc |
| Lock queue mitigation | `lock_wait_timeout` + retry | `lock_timeout` + retry |
| Replica impact of native DDL | Blocks replicas for full duration | Physical: replays instantly; Logical: manual DDL |
| Best external tool (general) | gh-ost (no triggers, runtime control) | pgroll (multi-version schema) |
| Best external tool (FK tables) | pt-online-schema-change | pg-osc |
| Managed Blue/Green | RDS/Aurora Blue/Green Deployments | Aurora PG Blue/Green (PG 11.21+) |

---

## 9. Putting it together

A practical playbook for "I need to add a column to a 500 GB table this week":

1. **Check whether the change qualifies for native instant DDL.** MySQL: is `ALGORITHM=INSTANT` accepted? Postgres: is the default a constant? If yes, the DDL itself is essentially free.
2. **Plan the lock window.** Set `lock_timeout` (Postgres) or `lock_wait_timeout` (MySQL) to a short value. Pick a low-traffic window. Watch for and kill long-running transactions on the target table beforehand.
3. **If the change can't be made instant**, decide between (a) `INPLACE`/native rewrite during a maintenance window, (b) a managed Blue/Green, or (c) a tool from §5. Each is a different tradeoff; none is universally right.
4. **For anything beyond a purely additive change** — non-constant defaults, NOT NULL, type changes, renames, drops — drive it through expand-contract. The DDL is one step in a six-step deploy sequence, not the deploy itself.
5. **Verify on a copy first.** Whatever you're about to run, run it against a recent restore. INSTANT not applying when you expect it to is the kind of thing that should fail in staging, not at 2am on Friday.

A few rules to internalise:

- "Online DDL" is the floor, not the ceiling. Expand-contract is the ceiling.
- The MDL pile-up is the failure mode that gets you, not the DDL itself. `lock_timeout` is non-optional.
- On Postgres, the rule is: constant defaults, `NOT VALID` then `VALIDATE`, then `SET NOT NULL`. Memorise it.
- On MySQL, the rule is: try `ALGORITHM=INSTANT` first; understand why it might fall back; never accept a silent `ALGORITHM=COPY`.
- Drop and rename always go last. The DDL is the easy part; the application coordination is the rest.
- Pick a tool when you need one; don't standardise on one before you do.

The schema change is rarely the hard part. The choreography is.

---

## References

1. Oracle Corporation, 'InnoDB Online DDL Operations', *MySQL 8.0 Reference Manual*, available at: [https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html](https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html) (accessed 1 May 2025).

2. Oracle Corporation, 'MySQL 8.0: InnoDB now supports Instant ADD/DROP Columns', *MySQL Server Blog*, available at: [https://blogs.oracle.com/mysql/mysql-80-instant-add-drop-columns](https://blogs.oracle.com/mysql/mysql-80-instant-add-drop-columns) (accessed 1 May 2025).

3. PostgreSQL Global Development Group, 'ALTER TABLE', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/sql-altertable.html](https://www.postgresql.org/docs/current/sql-altertable.html) (accessed 1 May 2025).

4. PostgreSQL Global Development Group, 'Building Indexes Concurrently', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/sql-createindex.html](https://www.postgresql.org/docs/current/sql-createindex.html) (accessed 1 May 2025).

5. GitHub, 'gh-ost: GitHub's Online Schema-migration Tool for MySQL', available at: [https://github.com/github/gh-ost](https://github.com/github/gh-ost) (accessed 1 May 2025).

6. Percona, 'pt-online-schema-change', *Percona Toolkit Documentation*, available at: [https://docs.percona.com/percona-toolkit/pt-online-schema-change.html](https://docs.percona.com/percona-toolkit/pt-online-schema-change.html) (accessed 1 May 2025).

7. Block Inc., 'Introducing Spirit', *CashApp Code Blog*, available at: [https://code.cash.app/introducing-spirit](https://code.cash.app/introducing-spirit) (accessed 1 May 2025).

8. Xata, 'pgroll: Zero-downtime, reversible, schema migrations for PostgreSQL', available at: [https://github.com/xataio/pgroll](https://github.com/xataio/pgroll) (accessed 1 May 2025).

9. Samokhvalov, N., 'Zero-downtime Postgres schema migrations need this: lock_timeout and retries', *postgres.ai*, available at: [https://postgres.ai/blog/20210923-zero-downtime-postgres-schema-migrations-lock-timeout-and-retries](https://postgres.ai/blog/20210923-zero-downtime-postgres-schema-migrations-lock-timeout-and-retries) (accessed 1 May 2025).

10. Fowler, M., 'Parallel Change', *martinfowler.com*, available at: [https://martinfowler.com/bliki/ParallelChange.html](https://martinfowler.com/bliki/ParallelChange.html) (accessed 1 May 2025).

11. Stripe Engineering, 'Online migrations at scale', *Stripe Blog*, available at: [https://stripe.com/blog/online-migrations](https://stripe.com/blog/online-migrations) (accessed 1 May 2025).

12. pg_repack Development Team, 'pg_repack — Reorganize tables in PostgreSQL databases with minimal locks', available at: [https://github.com/reorg/pg_repack](https://github.com/reorg/pg_repack) (accessed 1 May 2025).

13. Amazon Web Services, 'Using Amazon RDS Blue/Green Deployments for database updates', *Amazon RDS User Guide*, available at: [https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-overview.html](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-overview.html) (accessed 1 May 2025).
