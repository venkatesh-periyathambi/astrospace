---
author: Venkatesh Periyathambi
pubDatetime: 2025-09-27T10:00:00Z
title: "Why Is My Aurora PostgreSQL Major Version Upgrade So Slow?"
slug: aurora-postgresql-major-version-upgrade-slow
featured: true
draft: false
tags:
  - postgres
  - aurora
  - aws
  - databases
  - troubleshooting
description: "A deep dive into why Aurora PostgreSQL major version upgrades take longer than expected — what actually happens under the hood, why parallelism won't save you, and how to diagnose the bottleneck."
---

"We upgraded a 2.8 TB database in 1.5 hours. But this other cluster — same size — took over 6 hours. What's going on?"

I've heard variations of this question more times than I can count. Teams assume database size is the primary factor in upgrade duration. It's not. Let me explain what actually drives upgrade time in Aurora PostgreSQL, and what you can do about it.

## Table of Contents

## What Happens During a Major Version Upgrade

Aurora PostgreSQL uses the `pg_upgrade` utility under the hood. Here's the simplified sequence:

```
┌──────────────────────────────────────────────────────┐
│           Aurora PostgreSQL Major Upgrade             │
├──────────────────────────────────────────────────────┤
│                                                      │
│  1. Pre-upgrade snapshot                             │
│  2. Shut down the cluster                            │
│  3. Export and re-create users        (sequential)   │
│  4. For EACH database in the cluster  (sequential):  │
│     ├─ pg_dump --schema-only          (sequential)   │
│     └─ pg_restore (schema)            (sequential)   │
│  5. Link/copy data files                             │
│  6. Post-upgrade tasks (ANALYZE, etc)                │
│  7. Post-upgrade snapshot                            │
│                                                      │
└──────────────────────────────────────────────────────┘
```

The critical insight: **steps 3 and 4 are entirely sequential**. Every database is processed one at a time. Within each database, the schema dump and restore happen serially.

## Size Doesn't Matter — Object Count Does

This is the part that surprises people.

A 2.8 TB database with 500 tables and minimal foreign keys can upgrade in 1.5 hours. A 200 GB database with 50,000 tables, thousands of foreign keys, complex views, and materialized views can take 6+ hours.

Why? Because the upgrade isn't moving your data. Aurora's storage layer handles that through file linking. What takes time is **rebuilding the metadata** — every table definition, every index, every constraint, every view, every function, every trigger.

The formula is roughly:

```
Upgrade time ≈ f(object count, constraint complexity, database count)
```

Not:

```
Upgrade time ≈ f(data size)
```

## Why Can't We Just Parallelize It?

This is the most common follow-up question. "Can we use the `-j` flag? Can we scale the instance up to get more parallelism?"

The short answer: **no, not for the metadata phase**.

Here's why, based on how [`pg_upgrade`](https://www.postgresql.org/docs/current/pgupgrade.html) works internally:

**Schema extraction (`pg_dump --schema-only`) is inherently sequential.** It queries the old cluster's system catalogs and serializes the schema into a SQL script. There's no way to parallelize catalog reads that must produce a dependency-ordered output.

**Schema restoration (`pg_restore`) must respect dependency ordering.** A foreign key depends on the referenced table existing first. A view depends on its underlying tables. A function might depend on a custom type. These dependencies force a specific execution order.

**The `-j` (jobs) parameter helps — but only for post-upgrade tasks.** Things like running `ANALYZE` on multiple tables concurrently, or rebuilding indexes in parallel. These happen *after* the metadata is already restored.

```
┌─────────────────────────────────────────────────────┐
│  Phase              │ Parallelizable? │ Bottleneck?  │
├─────────────────────┼─────────────────┼──────────────┤
│  Schema dump        │ No              │ Yes          │
│  Schema restore     │ No              │ Yes          │
│  Data file linking  │ Partially       │ Rarely       │
│  Post-upgrade tasks │ Yes (-j flag)   │ Sometimes    │
│  FK validation      │ No              │ Yes          │
└─────────────────────────────────────────────────────┘
```

## Foreign Keys: The Silent Killer

During `pg_restore`, foreign key constraint creation can be particularly expensive:

- PostgreSQL validates all existing data against the FK constraints
- It creates indexes to support the foreign key relationships
- It checks referential integrity across tables

If your database has thousands of foreign keys across large tables, this single phase can dominate the entire upgrade time.

## Large Objects, TOAST, and JSONB: The Other Bottleneck

This is one people often miss. There's an important distinction between how PostgreSQL stores large data:

**JSONB and BYTEA columns** use [TOAST](https://www.postgresql.org/docs/current/storage-toast.html) (The Oversized-Attribute Storage Technique). TOAST transparently compresses and slices large values into chunks stored alongside the table. During `pg_upgrade`, TOAST data is handled via file linking — the data files are linked or copied directly without being processed through `pg_dump`/`pg_restore`. So **JSONB and BYTEA columns stored via TOAST do not significantly impact upgrade time**.

**Large Objects** (`lo_creat`, `pg_largeobject`) are a completely different story. These are stored in a dedicated system catalog table (`pg_largeobject`) and each object has metadata in `pg_largeobject_metadata`. During the upgrade:

- `pg_dump` and `pg_restore` must process every large object's metadata
- If you have millions of large objects, the memory consumption during dump/restore can cause the upgrade to either take extremely long or fail with an OOM (Out of Memory) condition
- The OOM failure can happen silently — no error in the upgrade logs, just an abrupt termination

```sql
-- Check how many large objects you have
SELECT COUNT(*) AS large_object_count FROM pg_largeobject_metadata;

-- Check the total size of large objects
SELECT pg_size_pretty(pg_total_relation_size('pg_largeobject'));
```

### Orphaned Large Objects: The Hidden Multiplier

Large objects have a lifecycle: create (`lo_creat`), populate (`lo_put`), and delete (`lo_unlink`). The problem is that deleting a row that *references* a large object doesn't automatically delete the large object itself. This creates **orphaned large objects** — entries in `pg_largeobject` with no referencing row anywhere in your schema.

Common causes of orphaned large objects:
- Deleting rows without calling `lo_unlink()`
- Dropping tables that stored large object OIDs
- Updating rows that change a large object reference without unlinking the old one

These orphans accumulate silently over time and can number in the millions. They all get processed during the upgrade even though they serve no purpose.

**Detect orphaned large objects:**

```bash
# Dry run — shows what would be removed without deleting anything
vacuumlo -v -n -h your-cluster-endpoint -p 5432 -U postgres your_database
```

**Remove orphaned large objects (before upgrading):**

```bash
# Actually remove orphaned large objects
vacuumlo -v -h your-cluster-endpoint -p 5432 -U postgres your_database
```

**Prevent future orphans** by using the `lo_manage` trigger function:

```sql
-- Automatically unlinks large objects when rows are deleted or updated
CREATE TRIGGER t_cleanup
  BEFORE UPDATE OR DELETE ON your_table
  FOR EACH ROW EXECUTE FUNCTION lo_manage(your_lo_column);
```

### The Bottom Line on Data Types and Upgrades

| Storage Method | Stored In | Upgrade Impact |
|---------------|-----------|---------------|
| JSONB (inline/TOAST) | Table + TOAST table | Low — file linking, no dump/restore of data |
| BYTEA (inline/TOAST) | Table + TOAST table | Low — same as JSONB |
| Large Objects (`lo`) | `pg_largeobject` catalog | High — all metadata processed during dump/restore |
| Orphaned Large Objects | `pg_largeobject` catalog | High — processed but serve no purpose |

If your application uses the Large Object API (`lo_creat`, `lo_open`, `lo_write`), clean up orphans before upgrading. If you're using JSONB or BYTEA, you're fine — those won't slow your upgrade regardless of how large the values are.

## How to Diagnose Your Specific Bottleneck

Before upgrading production, run the [pg-collector](https://github.com/awslabs/pg-collector) script on both your lower environment and production:

```bash
# Run on your non-production environment
./pg-collector.sh --host your-non-prod-endpoint --port 5432 --user postgres

# Run on production
./pg-collector.sh --host your-prod-endpoint --port 5432 --user postgres

# Compare the outputs
```

What to look for in the comparison:

| Metric | Impact on Upgrade Time |
|--------|----------------------|
| Total number of relations | High — each one needs schema dump/restore |
| Number of foreign keys | High — each needs validation during restore |
| Number of databases | High — processed sequentially |
| Number of views/materialized views | Medium — complex dependency chains |
| Number of functions/procedures | Medium — must be recreated in order |
| Data size | Low — file linking is fast |

If your non-prod has the same object count as production and upgraded in one hour, production should take roughly the same time. If there's a major discrepancy, dig into the pg-collector output to find what differs — extra schemas, more constraints, or additional databases in one environment.

## Getting a Realistic Upgrade Estimate

The most reliable way to estimate upgrade time:

1. **Take an Aurora clone** of your production cluster (this is fast — it's copy-on-write)
2. **Perform the upgrade** on the clone
3. **Measure the time**

This gives you a realistic estimate because the clone has identical metadata, object counts, and data distribution.

```bash
# Create a clone
aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier your-prod-cluster \
  --db-cluster-identifier upgrade-test-clone \
  --restore-type copy-on-write \
  --use-latest-restorable-time

# After clone is available, modify to trigger upgrade
aws rds modify-db-cluster \
  --db-cluster-identifier upgrade-test-clone \
  --engine-version 16.4 \
  --apply-immediately
```

## What You Can Actually Do to Speed Things Up

Since you can't parallelize the core metadata phase, focus on reducing what needs to be processed:

**Before the upgrade:**

1. **Drop unused objects.** Unused tables, stale views, orphaned functions — every object adds to the sequential processing time.

2. **Consolidate databases.** Each database in the cluster is processed sequentially. If you have test databases or unused databases in the same cluster, remove them.

3. **Clean up extensions.** Drop extensions you're not using. Each extension adds objects to the catalog.

4. **Remove unnecessary foreign keys in non-production.** If you have FK constraints that exist only for data integrity in dev/staging and you're comfortable without them during upgrade, dropping and recreating them post-upgrade can save significant time.

5. **Drop and recreate materialized views.** They'll need to be refreshed post-upgrade anyway.

**During the upgrade:**

6. **Scale up the instance class.** While it won't help with parallelism, more memory and CPU can speed up the sequential catalog operations and constraint validation.

7. **Ensure no long-running transactions.** Open prepared transactions block the upgrade entirely.

## The Upgrade Progress Visibility Gap

One of the most frustrating aspects of Aurora PostgreSQL major version upgrades is the lack of visibility. You initiate the upgrade and then... wait. There's no progress bar, no percentage complete, no indication of which phase you're in.

As of this writing, there's no built-in way to monitor upgrade progress in real time. The community has long asked for:
- Upgrade progress/status visibility
- Increased parallelism in the metadata phase
- Exposing the `-j` option for applicable phases

Until these land, your best bet is to estimate duration upfront using the clone approach described above, and plan your maintenance window accordingly.

## Key Takeaways

1. **Upgrade time is driven by object count and constraint complexity, not data size.** A small database with complex schemas can take longer than a large database with simple schemas.

2. **The metadata rebuild phase is sequential by design.** Dependency ordering in PostgreSQL schemas prevents parallelization of `pg_dump` and `pg_restore`.

3. **The `-j` flag only helps post-upgrade tasks** like `ANALYZE` and index rebuilds — not the core schema migration.

4. **Use Aurora clones to get realistic time estimates.** Don't guess based on data size.

5. **Reduce object count before upgrading** if upgrade time is critical. Drop unused objects, consolidate databases, clean up extensions.

6. **Run pg-collector on both environments** to compare and identify what's driving the time difference.

---

*Based on real-world upgrade experiences across multiple Aurora PostgreSQL clusters of varying sizes and complexity.*

## References

1. PostgreSQL Global Development Group, 'pg_upgrade', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/pgupgrade.html](https://www.postgresql.org/docs/current/pgupgrade.html) (accessed 27 September 2025).

2. PostgreSQL Global Development Group, 'pg_upgrade source code (version.c)', *GitHub*, available at: [https://github.com/postgres/postgres/blob/master/src/bin/pg_upgrade/pg_upgrade.c](https://github.com/postgres/postgres/blob/master/src/bin/pg_upgrade/pg_upgrade.c) (accessed 27 September 2025).

3. Amazon Web Services, 'Performing a major version upgrade', *Amazon Aurora User Guide*, available at: [https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.MajorVersion.html](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.MajorVersion.html) (accessed 27 September 2025).

4. Amazon Web Services, 'Upgrading Amazon Aurora PostgreSQL DB clusters', *Amazon Aurora User Guide*, available at: [https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.html) (accessed 27 September 2025).

5. AWS Labs, 'pg-collector', *GitHub*, available at: [https://github.com/awslabs/pg-collector](https://github.com/awslabs/pg-collector) (accessed 27 September 2025).

6. Amazon Web Services, 'Minimize downtime for RDS PostgreSQL major version upgrades', *AWS re:Post Knowledge Center*, available at: [https://repost.aws/knowledge-center/rds-postgresql-optimize-major-upgrade](https://repost.aws/knowledge-center/rds-postgresql-optimize-major-upgrade) (accessed 27 September 2025).

7. Khera, B., 'Why do large objects lead to slowness or failure of major version upgrades in RDS/Aurora PostgreSQL?', *AWS re:Post*, available at: [https://repost.aws/articles/AR3nlE9KEgSX6Z0quBt9ENXQ](https://repost.aws/articles/AR3nlE9KEgSX6Z0quBt9ENXQ) (accessed 27 September 2025).

8. Amazon Web Services, 'Managing high object counts in Amazon Aurora PostgreSQL', *Amazon Aurora User Guide*, available at: [https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/PostgreSQL.HighObjectCount.html](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/PostgreSQL.HighObjectCount.html) (accessed 27 September 2025).

9. PostgreSQL Global Development Group, 'TOAST (The Oversized-Attribute Storage Technique)', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/storage-toast.html](https://www.postgresql.org/docs/current/storage-toast.html) (accessed 27 September 2025).

10. PostgreSQL Global Development Group, 'vacuumlo — remove orphaned large objects', *PostgreSQL Documentation*, available at: [https://www.postgresql.org/docs/current/vacuumlo.html](https://www.postgresql.org/docs/current/vacuumlo.html) (accessed 27 September 2025).
