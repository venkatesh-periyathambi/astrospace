---
author: Venkatesh Periyathambi
pubDatetime: 2025-09-27T10:00:00Z
title: "Why Is My Aurora PostgreSQL Major Version Upgrade So Slow?"
slug: aurora-postgresql-major-version-upgrade-slow
featured: true
draft: true
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

Here's why, based on how `pg_upgrade` works internally:

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
