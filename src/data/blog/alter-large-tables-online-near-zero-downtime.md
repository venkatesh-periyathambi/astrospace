---
author: Venkatesh Periyathambi
pubDatetime: 2025-05-01T10:00:00Z
title: "Altering Large Tables Online: Near-Zero Downtime in MySQL 8 and PostgreSQL 14+"
slug: alter-large-tables-online-near-zero-downtime
featured: true
draft: true
tags:
  - mysql
  - postgres
  - databases
  - troubleshooting
description: "A practical guide to adding, dropping, and modifying columns on large tables without taking your application offline — covering native DDL, external tools, and the patterns that make it all work."
---

"We need to add a column to a 500GB table. How much downtime do we need?"

The answer, in 2025, should be: **close to zero**. Both MySQL 8.0+ and PostgreSQL 14+ have come a long way in supporting online schema changes. But the details matter — pick the wrong approach and you're looking at hours of locked tables or cascading replica lag.

This post covers every viable option I know of, when to use each one, and the gotchas that bite people in production.

## Table of Contents

## The Core Problem

Altering a table's schema traditionally meant:
1. Lock the table (block all reads and writes)
2. Rewrite every row with the new structure
3. Rebuild all indexes
4. Unlock

For a 500GB table, that's hours of downtime. Unacceptable for any production system.

Modern approaches solve this in two fundamentally different ways:

- **Metadata-only changes** — modify the catalog, don't touch the data (instant)
- **Background migration** — copy data to a new structure while the old one keeps serving traffic, then swap

Which approach you can use depends on what you're changing and which engine you're on.

## MySQL 8.0+: Three Tiers of Online DDL

MySQL gives you three levels of online DDL, each with different trade-offs:

### Tier 1: INSTANT DDL (Zero Downtime)

Since MySQL 8.0.29, you can add columns, drop columns, and rename columns by modifying only the data dictionary. No data is touched. No rows are read. It completes in milliseconds regardless of table size.

```sql
-- Add a column anywhere in the table (8.0.29+)
ALTER TABLE orders ADD COLUMN priority TINYINT DEFAULT 0, ALGORITHM=INSTANT;

-- Drop a column (8.0.29+)
ALTER TABLE orders DROP COLUMN legacy_flag, ALGORITHM=INSTANT;

-- Rename a column (8.0.28+)
ALTER TABLE orders RENAME COLUMN ship_date TO shipped_at, ALGORITHM=INSTANT;
```

**How it works:** MySQL uses a row-versioning system. Each INSTANT change creates a new "row version." When reading older rows, InnoDB checks the version stamp and supplies defaults for added columns or skips dropped ones.

**What supports INSTANT:**
- ADD COLUMN (any position, 8.0.29+; last position only in 8.0.12–8.0.28)
- DROP COLUMN (8.0.29+)
- RENAME COLUMN (8.0.28+)
- Set or drop column default values
- Append values to ENUM/SET (if storage size unchanged)
- Add/drop virtual generated columns

**What doesn't:**
- Adding an auto-increment column
- Any change to `ROW_FORMAT=COMPRESSED` tables
- Tables with FULLTEXT indexes
- Combining INSTANT and non-INSTANT operations in one statement

**The 64-version limit:** Each INSTANT ADD or DROP increments a row version counter. After 64 operations, you must rebuild the table (`OPTIMIZE TABLE` or `ALTER TABLE ... ALGORITHM=INPLACE`) to reset it. Plan for this if you do frequent schema changes.

**Watch out for early 8.0.29 builds:** There were bugs around corruption when adding columns to the middle of a table (MySQL Bug #107941) and performance regressions in update-heavy workloads (Bug #116531). Make sure you're on a patched release.

### Tier 2: Native Online DDL (INPLACE, LOCK=NONE)

For operations that can't be INSTANT — like adding indexes, changing nullability, or reordering columns — MySQL can rebuild the table in-place while allowing concurrent reads and writes:

```sql
-- Add an index without blocking DML
ALTER TABLE orders ADD INDEX idx_customer (customer_id), ALGORITHM=INPLACE, LOCK=NONE;

-- Change a column to NOT NULL
ALTER TABLE orders MODIFY COLUMN email VARCHAR(255) NOT NULL, ALGORITHM=INPLACE, LOCK=NONE;
```

**The replica problem:** This is where most people get burned. On the primary, `LOCK=NONE` means your application keeps running. But on replicas, the DDL replays as a single event that **blocks all DML for the entire duration**. A 2-hour index build on the primary means 2 hours of blocked queries on every replica.

If your replicas serve read traffic (and they probably do), native INPLACE DDL on large tables is dangerous.

**When it's safe to use:**
- Tables under ~10GB
- No replicas serving production traffic
- You can tolerate replica lag equal to the DDL duration

### Tier 3: External Online Schema Change Tools

For large tables with replicas, you need a tool that migrates data as normal DML — so replicas process it row by row instead of as one blocking DDL event.

**gh-ost (GitHub):**

```bash
gh-ost \
  --host=primary.db \
  --database=myapp \
  --table=orders \
  --alter="ADD COLUMN priority TINYINT DEFAULT 0" \
  --execute
```

How it works: Creates a "ghost" table with the new schema, copies rows in chunks, and simultaneously tails the binlog to replay ongoing changes. Cut-over is a brief table rename.

Advantages:
- No triggers (zero write amplification on the source)
- Runtime control — pause, throttle, postpone cut-over via Unix socket
- Can read binlog from a replica to reduce primary load
- Works on tables with existing triggers

Limitations:
- Requires Row-Based Replication (RBR)
- No foreign key support
- Not resumable — if it dies, you restart from scratch
- Needs a shared unique key between old and new schema

**pt-online-schema-change (Percona):**

```bash
pt-online-schema-change \
  --alter="ADD COLUMN priority TINYINT DEFAULT 0" \
  D=myapp,t=orders \
  --execute
```

How it works: Creates a shadow table, installs AFTER triggers on the original to sync ongoing DML, copies rows in chunks, then does an atomic RENAME.

Advantages:
- Handles foreign keys (`--alter-foreign-keys-method`)
- Works with both SBR and RBR
- Resumable with `--resume`

Limitations:
- Cannot operate on tables that already have triggers
- Trigger overhead (~2x write cost during migration)
- Deadlock-prone under heavy concurrent writes

**Spirit (Block/CashApp):**

The newest entrant. Written for MySQL 8.0+ exclusively.

```bash
spirit --host primary.db --database myapp --table orders \
  --alter "ADD COLUMN priority TINYINT DEFAULT 0"
```

Key differentiator: **Tries INSTANT first.** If the operation supports `ALGORITHM=INSTANT`, Spirit applies it immediately and exits. Otherwise, it falls back to binlog-based migration with parallel copy threads and a delta-map that deduplicates binlog changes.

Advantages:
- INSTANT-first approach (why copy 500GB if you don't have to?)
- Parallel copy threads (significantly faster than gh-ost)
- Resumable (Kubernetes-friendly — kill and restart safely)
- Checksum verification during copy

Limitations:
- MySQL 8.0+ only
- Requires RBR
- No foreign key support
- Newer, less battle-tested than gh-ost

### MySQL Decision Framework

```
Is the operation INSTANT-compatible?
├─ YES → Use ALGORITHM=INSTANT. Done.
└─ NO
   ├─ Table < 10GB, no read replicas? → Native INPLACE, LOCK=NONE
   └─ Large table OR read replicas?
      ├─ Table has foreign keys? → pt-online-schema-change
      ├─ MySQL 8.0+ with auto_increment PK? → Spirit
      └─ Otherwise → gh-ost
```

## PostgreSQL 14+: Surprisingly Good Native DDL

PostgreSQL's approach to online DDL is fundamentally different from MySQL's. Many operations that require external tools in MySQL are already near-instant natively in PostgreSQL.

### ADD COLUMN with DEFAULT (Instant Since PG 11)

```sql
-- This is instant regardless of table size
ALTER TABLE orders ADD COLUMN priority INTEGER DEFAULT 0;
```

Since PostgreSQL 11, adding a column with a **constant** default stores the default in the system catalog (`pg_attribute.attmissingval`). Existing rows are never touched. When reading an old row, PostgreSQL returns the catalog default. The physical value is only written when the row is next updated.

**This is O(1) — a 1TB table and a 1KB table take the same time.**

The catch: the default must be immutable. `DEFAULT now()` or `DEFAULT random()` triggers a full table rewrite under ACCESS EXCLUSIVE lock. Stick to constants.

### DROP COLUMN (Always Instant)

```sql
-- This is instant — marks column as dropped in catalog
ALTER TABLE orders DROP COLUMN legacy_flag;
```

PostgreSQL never rewrites the table for DROP COLUMN. It sets `attisdropped = true` in the catalog and the column becomes invisible. The physical bytes remain in existing tuples until they're naturally rewritten by updates or VACUUM FULL.

### SET NOT NULL Without Full Table Lock

Naively adding NOT NULL scans the entire table under ACCESS EXCLUSIVE (blocking everything):

```sql
-- DON'T do this on large tables
ALTER TABLE orders ALTER COLUMN email SET NOT NULL;
```

Instead, use the CHECK constraint trick (works on PG 12+):

```sql
-- Step 1: Add NOT VALID constraint (instant, brief lock)
ALTER TABLE orders ADD CONSTRAINT orders_email_nn
  CHECK (email IS NOT NULL) NOT VALID;

-- Step 2: Validate in background (allows concurrent reads AND writes)
ALTER TABLE orders VALIDATE CONSTRAINT orders_email_nn;

-- Step 3: Now SET NOT NULL is instant (PG 12+ skips scan if CHECK exists)
ALTER TABLE orders ALTER COLUMN email SET NOT NULL;

-- Step 4: Clean up
ALTER TABLE orders DROP CONSTRAINT orders_email_nn;
```

Step 2 scans the full table but under `SHARE UPDATE EXCLUSIVE` — your application keeps reading and writing normally.

### CREATE INDEX CONCURRENTLY

```sql
-- Non-blocking index creation
CREATE INDEX CONCURRENTLY idx_orders_customer ON orders(customer_id);
```

Builds the index in two passes without blocking DML. Takes ~2-3x longer than a regular CREATE INDEX, but the table remains fully available.

**Gotcha:** If it fails (deadlock, uniqueness violation, disk full), it leaves behind an INVALID index that still gets maintained on writes. Always check and clean up:

```sql
-- Find invalid indexes
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;

-- Drop if found
DROP INDEX CONCURRENTLY idx_orders_customer;
```

### Column Type Changes

Some type changes are instant (binary coercible):
- `varchar(100)` → `varchar(200)` (increasing length)
- `varchar(N)` → `text`

Others require a full table rewrite under ACCESS EXCLUSIVE:
- `integer` → `bigint`
- `timestamp` → `timestamptz`
- Any change requiring data transformation

For rewrite-requiring type changes, use the **expand/contract pattern** (see below).

### pg_repack (External Tool)

When you need to do something that PostgreSQL can't do natively without a full lock — like changing a column type on a large table — [pg_repack](https://github.com/reorg/pg_repack) is the go-to:

```bash
# Repack a table (reclaim bloat, apply schema changes)
pg_repack --host=db.example.com --dbname=myapp --table=orders
```

Works similarly to pt-online-schema-change: creates a new table, installs triggers to capture changes, copies data, then swaps. Requires ~2x disk space and a PRIMARY KEY.

### The Lock Queue Problem (Critical for Both Engines)

This is the most dangerous gotcha in PostgreSQL DDL, and it applies to MySQL's metadata lock too.

When a DDL statement waits for ACCESS EXCLUSIVE, it enters the lock queue. **All subsequent queries — even SELECT — queue behind the waiting DDL.** A single ALTER TABLE waiting for one long-running query can cause a complete outage for that table.

The fix: always use `lock_timeout` with a retry loop:

```sql
-- Set a short timeout so DDL fails fast if it can't get the lock
SET lock_timeout = '3s';

-- Try the DDL — if it can't acquire the lock in 3s, it fails
-- instead of queuing and blocking everything
ALTER TABLE orders ADD COLUMN priority INTEGER DEFAULT 0;
```

In practice, wrap this in a retry loop:

```sql
DO $$
DECLARE attempts INT := 0;
BEGIN
  LOOP
    BEGIN
      SET LOCAL lock_timeout = '2s';
      ALTER TABLE orders ADD COLUMN priority INTEGER DEFAULT 0;
      RETURN;
    EXCEPTION WHEN lock_not_available THEN
      attempts := attempts + 1;
      IF attempts >= 30 THEN RAISE; END IF;
      PERFORM pg_sleep(0.5 + random());
    END;
  END LOOP;
END $$;
```

This pattern prevents the cascading pileup. The DDL either gets the lock quickly or backs off and retries.

### PostgreSQL Decision Framework

```
Is the operation metadata-only?
├─ ADD COLUMN + constant DEFAULT → Instant. Done.
├─ DROP COLUMN → Instant. Done.
├─ RENAME COLUMN → Instant. Done.
├─ Increase varchar length → Instant. Done.
└─ NO (requires rewrite or scan)
   ├─ SET NOT NULL → Use CHECK constraint trick
   ├─ CREATE INDEX → Use CONCURRENTLY
   ├─ Change column type (binary coercible) → Instant
   └─ Change column type (rewrite needed) → Expand/contract pattern
```

## The Expand/Contract Pattern (Universal)

When nothing else works — a type change that requires a rewrite, a complex structural change — the expand/contract pattern is your universal fallback. It works on both MySQL and PostgreSQL, any version, any hosting.

**Expand phase:**
1. Add new column (instant on both engines)
2. Deploy code that writes to BOTH old and new columns
3. Backfill existing rows in batches
4. Deploy code that reads from new column

**Contract phase:**
5. Deploy code that stops writing to old column
6. Drop old column (instant on both engines)

```sql
-- Step 1: Add new column (instant)
ALTER TABLE orders ADD COLUMN shipped_at TIMESTAMPTZ;

-- Step 3: Backfill in batches (doesn't block anything)
UPDATE orders SET shipped_at = ship_date::timestamptz
WHERE id BETWEEN 1 AND 10000 AND shipped_at IS NULL;
-- Repeat for next batch...

-- Step 6: Drop old column (instant)
ALTER TABLE orders DROP COLUMN ship_date;
```

The key: **at no point is the table locked for more than milliseconds.** The backfill is regular DML with row-level locks only. Batch it, throttle it, run it over hours or days — the application never notices.

**Batch size matters:** Too large = long transactions, lock contention, replication lag. Too small = slow progress. Start with 1,000–10,000 rows per batch with a short sleep between batches.

## Side-by-Side Comparison

| Operation | MySQL 8.0+ | PostgreSQL 14+ |
|-----------|-----------|----------------|
| ADD COLUMN + default | INSTANT (8.0.29+, any position) | Instant (since PG 11, constant default only) |
| DROP COLUMN | INSTANT (8.0.29+) | Instant (always) |
| RENAME COLUMN | INSTANT (8.0.28+) | Instant (always) |
| ADD INDEX | INPLACE, LOCK=NONE (blocks replicas) | CONCURRENTLY (blocks nothing) |
| SET NOT NULL | INPLACE, LOCK=NONE (blocks replicas) | CHECK trick (blocks nothing) |
| Change type (rewrite) | External tool or expand/contract | Expand/contract |
| FK support in tools | pt-osc only | pg_repack |
| Replica-safe large DDL | Requires external tool | Mostly native |

## Key Takeaways

1. **Check if your change is instant first.** Both MySQL 8.0.29+ and PostgreSQL 11+ can ADD/DROP columns in milliseconds. Don't reach for complex tools when a one-liner will do.

2. **MySQL's replica problem is real.** Native INPLACE DDL blocks replicas for the full duration. If you have read replicas serving traffic, use gh-ost or Spirit for anything beyond INSTANT.

3. **PostgreSQL is ahead on native online DDL.** Most common operations (ADD/DROP column, CREATE INDEX CONCURRENTLY, SET NOT NULL via CHECK trick) work without external tools.

4. **Always use lock_timeout.** On both engines, a waiting DDL can cascade into a full table outage. Fail fast and retry.

5. **The expand/contract pattern is your universal escape hatch.** When nothing else works, it works everywhere — any engine, any version, any hosting.

6. **Test on a copy of production.** Clone your database, run the DDL, measure the time and impact. Never surprise yourself in production.

## References

1. Oracle Corporation, 'InnoDB Online DDL Operations', *MySQL 8.0 Reference Manual*, available at: [https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html](https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html) (accessed 1 May 2025).

2. Oracle Corporation, 'MySQL 8.0: InnoDB now supports Instant ADD/DROP Columns', *MySQL Server Blog*, available at: [https://blogs.oracle.com/mysql/mysql-80-instant-add-drop-columns](https://blogs.oracle.com/mysql/mysql-80-instant-add-drop-columns) (accessed 1 May 2025).

3. PostgreSQL Global Development Group, 'ALTER TABLE', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/sql-altertable.html](https://www.postgresql.org/docs/current/sql-altertable.html) (accessed 1 May 2025).

4. PostgreSQL Global Development Group, 'Building Indexes Concurrently', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/sql-createindex.html](https://www.postgresql.org/docs/current/sql-createindex.html) (accessed 1 May 2025).

5. GitHub, 'gh-ost: GitHub's Online Schema-migration Tool for MySQL', *GitHub*, available at: [https://github.com/github/gh-ost](https://github.com/github/gh-ost) (accessed 1 May 2025).

6. Percona, 'pt-online-schema-change', *Percona Toolkit Documentation*, available at: [https://docs.percona.com/percona-toolkit/pt-online-schema-change.html](https://docs.percona.com/percona-toolkit/pt-online-schema-change.html) (accessed 1 May 2025).

7. Block Inc., 'Introducing Spirit', *CashApp Code Blog*, available at: [https://code.cash.app/introducing-spirit](https://code.cash.app/introducing-spirit) (accessed 1 May 2025).

8. pg_repack Development Team, 'pg_repack — Reorganize tables in PostgreSQL databases with minimal locks', *GitHub*, available at: [https://github.com/reorg/pg_repack](https://github.com/reorg/pg_repack) (accessed 1 May 2025).

9. Xata, 'pgroll: Zero-downtime, reversible, schema migrations for PostgreSQL', *GitHub*, available at: [https://github.com/xataio/pgroll](https://github.com/xataio/pgroll) (accessed 1 May 2025).

10. Nikolay Samokhvalov, 'Zero-downtime Postgres schema migrations need this: lock_timeout and retries', *postgres.ai*, available at: [https://postgres.ai/blog/20210923-zero-downtime-postgres-schema-migrations-lock-timeout-and-retries](https://postgres.ai/blog/20210923-zero-downtime-postgres-schema-migrations-lock-timeout-and-retries) (accessed 1 May 2025).
