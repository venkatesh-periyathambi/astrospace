---
author: Venkatesh Periyathambi
pubDatetime: 2026-05-16T10:00:00Z
title: "Offloading reporting from Aurora PostgreSQL to Redshift with Zero-ETL: what you actually need to know"
slug: aurora-redshift-zero-etl
featured: true
draft: false
tags:
  - aws
  - redshift
  - postgres
  - aurora
  - zero-etl
  - databases
description: A practical look at Aurora PostgreSQL Zero-ETL into Redshift — how NOT NULL really behaves, why your PostgreSQL indexes don't translate, and how retries stay idempotent without enforced uniqueness.
---

If you're running reporting queries against your Aurora PostgreSQL read replicas and feeling the pinch — whether that's from contention with OLTP traffic, the cost of scaling replicas just to feed dashboards, or the fact that your "analytical" SQL was never really meant for a row store — Aurora PostgreSQL Zero-ETL integration with Redshift is probably on your shortlist.

The pitch is great: near real-time replication into a columnar warehouse with no pipelines to write, no Glue jobs to babysit, no DMS task tuning. But once you start planning a real migration, the questions get interesting fast. Two of the ones I keep getting asked:

1. *What happens to my NOT NULL columns? PostgreSQL enforces them strictly — does Redshift?*
2. *What about indexes and performance? Half my Aurora schema is held together by indexes and foreign keys.*

Let's go through both.

## Table of contents

---

## 1. NOT NULL: the question hiding three other questions

When people ask "how does Zero-ETL handle NOT NULL columns," they're usually conflating three different things. Splitting them apart is the key to a useful answer.

### The Redshift target is read-only

Before anything else: the database that Zero-ETL creates in Redshift is **read-only**. You can't `INSERT`, `UPDATE`, `ALTER TABLE`, or change constraints on the replicated tables. The integration owns them entirely. That fact reframes the whole conversation about constraints.

### Question A: will NULLs ever arrive in a NOT NULL column?

**No, unconditionally.** Aurora enforces NOT NULL at write time, *before* the row hits the logical replication stream that Zero-ETL consumes. Aurora is the gate, and Redshift just receives whatever Aurora already validated.

You do not need to worry about data integrity here. If a column is NOT NULL on Aurora, no NULL value will ever land in the Redshift copy.

### Question B: is the NOT NULL constraint *declared* on the Redshift table?

In practice, yes — the integration propagates NOT NULL onto replicated columns, and primary key columns are NOT NULL by definition (Zero-ETL requires a primary key to replicate at all).

But here's the catch: AWS's data type mapping table documents type translations meticulously and is **silent on nullability preservation**. So while you'll observe NOT NULL on your replicated tables, AWS doesn't formally guarantee this. Treat it as best-effort behavior, not a contract. Don't build logic that relies on the constraint declaration being there.

### Question C: can you change NOT NULL on the replicated table?

**No.** Read-only target. `ALTER TABLE ... ALTER COLUMN ... SET/DROP NOT NULL` is not available to you on Zero-ETL tables. If the constraint as replicated is wrong, your only lever is the curated layer downstream.

### Where NOT NULL actually becomes your problem

Since Aurora enforces the constraint and you can't modify the replicated table anyway, NOT NULL becomes an engineering concern in the **curated reporting layer** you build on top — the CTAS tables, materialized views, or transformed marts that your dashboards actually query. A few sharp edges:

- **Redshift `CTAS` does not preserve NOT NULL.** `CREATE TABLE foo AS SELECT ...` produces nullable columns regardless of the source's nullability. If you want NOT NULL on a curated fact table, declare it explicitly: `CREATE TABLE foo (col TYPE NOT NULL, ...)` then `INSERT INTO foo SELECT ...`.
- **`LEFT JOIN` produces NULLs even from a NOT NULL source.** Constraint metadata is not a guarantee about query output. A NOT NULL column on the base table can absolutely produce NULLs in a join result.
- **Materialized views** inherit nullability from the SELECT — same caveat as CTAS.
- **NOT NULL on curated tables is a useful tripwire.** If a column becomes nullable in Aurora due to schema drift, your curated INSERTs start failing — which is usually what you want, because silent NULLs in a fact table are much worse than a loud failure.

### Aurora PostgreSQL gotchas worth knowing

- **`serial` / `bigserial` / `smallserial`** map to `INTEGER` / `BIGINT` / `SMALLINT` on Redshift. Values replicate; auto-increment does not (which is fine — Aurora generates them before replication).
- **`ALTER TABLE ... ADD COLUMN NOT NULL`** on Aurora is replication-safe by construction: Aurora itself won't let you add a NOT NULL column without a default to a non-empty table, so any change that succeeds on the source is fine for replication.
- **Custom types and extension types are not supported.** Tables using them won't replicate at all — the NOT NULL question becomes moot because the table simply isn't there.
- **VARCHAR overflow.** Redshift `VARCHAR` caps at 65,535 bytes. A row that exceeds this puts the table into a `Failed` state. Set the database parameter `TRUNCATECOLUMNS=TRUE` to truncate-and-load instead of failing. NOT NULL still holds (a truncated string is non-null), but it's a constraint-adjacent failure mode that's easy to miss.

---

## 2. Indexes and performance: rewire your mental model

This is the part where a lot of people get burned. Redshift is not Aurora-with-more-storage. It's a **columnar MPP** store with a fundamentally different execution model. The instincts that serve you well in PostgreSQL — "this query is slow, let me add an index" — will lead you in completely the wrong direction.

### What gets created during Zero-ETL?

**No indexes from your PostgreSQL schema.** Redshift doesn't have B-tree, hash, GIN, or GiST indexes. Your PostgreSQL indexes are simply ignored.

Tables land with `DISTSTYLE AUTO` and `SORTKEY AUTO`. Redshift's autonomic optimizer eventually chooses distribution and sort keys based on observed query patterns — but it's reactive and conservative. For your hot reporting tables, you'll usually do better setting these explicitly. Foreign keys *do* replicate, but as **informational constraints only** — Redshift doesn't enforce them, though the optimizer uses them for things like join elimination.

### The Aurora → Redshift translation table

| Aurora PostgreSQL | Redshift equivalent |
|---|---|
| B-tree / hash / GIN indexes | **SORTKEY** (controls physical sort order) + zone maps (auto min/max per 1MB block) |
| (no concept) | **DISTKEY** — controls how rows shard across compute nodes; critical for join performance |
| Foreign keys (enforced) | Foreign keys (informational only — optimizer hint, not enforced) |
| Primary keys (enforced unique) | Primary keys (informational only) |

The two concepts that actually drive Redshift performance are DISTKEY and SORTKEY:

- **DISTKEY** decides which compute node a row lives on. Pick the column you most often join on, so matching rows from different tables land on the same node — otherwise Redshift shuffles data across the network for every join.
- **SORTKEY** controls the physical sort order on disk and powers zone maps. Pick the column you most often filter on (usually a timestamp). When a query filters by sort key, Redshift can skip entire 1MB blocks without reading them — this is where the 10–100× speedups come from.

### Tables with no indexes in PostgreSQL

These replicate fine. Performance in Redshift has nothing to do with whether the source had indexes. It depends entirely on DISTKEY/SORTKEY choice and how columnar scans plus zone maps prune blocks for your queries.

### What's actually faster?

Rough mental model:

- **Aurora wins**: point lookups, single-row updates, high-concurrency OLTP, queries selecting many columns from a single row.
- **Redshift wins**: large aggregations, scans across millions or billions of rows, joins between large fact tables, queries touching a few columns out of many. Often 10–100× faster for reporting at scale with good DIST/SORT key choices.
- **Redshift loses badly** if you treat it like OLTP: single-row inserts, frequent small updates, or queries with no sort-key pruning will be much slower than the same query on Aurora.

### The catch with Zero-ETL tables

You can't `ALTER` a Zero-ETL replicated table to set DIST/SORT keys. The target is read-only. So how do you get the performance benefits?

**The pattern is to treat replicated tables as a landing zone**, not as your reporting surface. Build a curated layer on top:

1. Land Zero-ETL replicated tables in a dedicated schema (e.g., `aurora_replica`).
2. For high-volume reporting tables, build a curated layer (regular Redshift tables, or materialized views) with explicit `DISTKEY` on the join column and `SORTKEY` on the most common filter column — usually a timestamp.
3. Point dashboards at the curated layer, not the raw replicated tables.

This gives you all the things Zero-ETL doesn't: explicit DIST/SORT keys, NOT NULL enforcement on the columns you care about, the ability to denormalize and pre-aggregate, and a stable interface for your BI tools that's decoupled from the source schema.

---

## 3. Retries, failures, and duplicates: what actually happens when things go wrong?

This is a great question to ask, especially since you've already noticed that Redshift treats `PRIMARY KEY` and `UNIQUE` as *informational only*. If Redshift won't reject a duplicate insert, what stops a retried replication event from creating one?

The short answer: **the integration is upsert-based, keyed on the primary key, not append-based** — and that's why Zero-ETL requires a primary key in the first place. Let's unpack that.

### Why the primary key requirement isn't just bureaucracy

You may have noticed Zero-ETL refuses to replicate any table without a primary key. That's not a stylistic choice — it's the mechanism that makes the replication idempotent. From the AWS docs on handling tables without primary keys: *"Primary keys are required for zero-ETL integrations because they tie each change log event to the specific row being modified."*

Each row in the Aurora WAL is identified by its primary key. When the integration applies a change event to Redshift, it's effectively doing a keyed merge — `INSERT ... ON CONFLICT`-style logic, conceptually — not a blind `INSERT`. So if a network blip causes the same change event to be delivered twice, the second application is a no-op (or an idempotent overwrite to the same value), not a duplicate row.

This is a subtle but important architectural detail: Redshift doesn't enforce uniqueness, but the *replication apply layer* does, by virtue of always merging on the primary key.

### What "retry" actually looks like in Zero-ETL

There are three different failure granularities, and they each behave differently:

**1. Transient stream-level retries (the common case)**
The replication stream is checkpointed against Aurora's WAL position (LSN). If the integration fails to apply a batch, it retries from the last acknowledged LSN. Because each event is keyed on the PK, replaying events that already landed is safe. You won't see duplicates; at worst you'll see momentary lag while the retry catches up.

**2. Table-level resync (`ResyncRequired` state)**
Certain operations on the source — adding a column in a specific position, adding a column with `DEFAULT CURRENT_TIMESTAMP`, multi-operation `ALTER TABLE` — put a single table into `ResyncRequired`. The integration doesn't append; it **fully reloads that table from source**. While the resync is happening, the table is unavailable for queries (unless you set `QUERY_ALL_STATES=TRUE`). When it finishes, you have a fresh, consistent copy. No duplicates, by construction — the old data was dropped first.

**3. Integration-level failure (`Failed` state / `Needs attention`)**
This happens when the integration itself can't proceed: tracked changes between source and target diverged, authorization broke, or the source was deleted. AWS's prescribed fix for several of these is "delete the integration and create a new one" — which fully re-initializes the pipeline. Again, full reload, not append. No duplicates.

### So where could duplicates actually sneak in?

In the steady-state Zero-ETL flow, they shouldn't — assuming a real primary key. The places to actually watch out:

- **A "primary key" that isn't really unique.** If you used a synthetic PK or a non-unique index that happens to be marked unique on a poorly-modeled source table, the upstream uniqueness assumption breaks and weird things can happen on resync. The fix is upstream: make sure PKs are actually unique in Aurora.
- **History mode is on.** If you've enabled history mode for a table, *every change* produces a new versioned row (with `_record_is_active` and `_record_delete_time` columns). That's not a bug — it's the feature working — but if you're not expecting it, the table will look "full of duplicates" because you're seeing every historical version, not just current state. Filter by `_record_is_active = true` (or just use plain mode) for current-state queries.
- **Your curated downstream layer.** Zero-ETL gives you a clean replicated table. The duplicate risk re-enters the picture in *your* CTAS/insert pipelines on top of the replica. If your `INSERT INTO reporting.fact SELECT ...` runs twice, Redshift will happily insert the rows twice — because, as you correctly noted, **PK and UNIQUE in Redshift are not enforced**. Idempotency in your curated layer is your problem to solve. Common patterns:
  - `MERGE INTO` (Redshift supports this) keyed on a stable identifier.
  - Stage → swap: load into a staging table, then `BEGIN; DELETE FROM target WHERE …; INSERT INTO target SELECT … FROM staging; COMMIT;`.
  - Recompute-from-scratch: drop and rebuild the curated table from the replica on each run. Cheaper than it sounds for small marts.

### One mental model that helps

Think of Zero-ETL as a **state-replicating** system, not a **log-replaying** system. It's continuously trying to make Redshift's copy of each row equal Aurora's copy of that row, identified by primary key. Retries don't accumulate — they re-converge. That's a fundamentally different shape from a "stream of events appended to a sink" system, which is what would expose you to duplicates if uniqueness weren't enforced.

That state-replicating shape is exactly why the absence of constraint enforcement in Redshift doesn't bite you for the replicated tables. It only bites you in the layers you build on top — and those, you control.

---

## Putting it together

A practical setup looks something like this:

```text
Aurora PostgreSQL  ──Zero-ETL──▶  Redshift `aurora_replica` schema  (read-only landing zone)
                                          │
                                          │  CTAS / materialized views with explicit
                                          │  DISTKEY, SORTKEY, NOT NULL constraints
                                          ▼
                                  Redshift `reporting` schema     (curated layer)
                                          │
                                          ▼
                                       Dashboards
```

A few rules to internalize:

- Trust Aurora to enforce NOT NULL. Don't trust the replicated table's declared constraints.
- Always declare NOT NULL explicitly when building curated tables — `CTAS` won't carry it.
- Set `TRUNCATECOLUMNS=TRUE` on the destination database if your text columns can exceed 65,535 bytes.
- Audit for unsupported types (custom types, extension types) before flipping the switch — those tables silently don't replicate.
- Pick DISTKEY and SORTKEY explicitly on curated tables. Don't lean on `AUTO` for tables that matter.
- Forget about indexes. The mental model is "sort the data well, distribute the data well, scan only the columns you need" — not "add an index."
- Trust Zero-ETL's idempotency for the replicated tables (it's keyed on the PK), but enforce idempotency yourself in your curated layer — `MERGE`, stage-and-swap, or recompute-from-scratch.

Zero-ETL is a great primitive. But it's a replication mechanism, not a reporting platform. The win comes from pairing it with a deliberately designed curated layer — which is the part you'd be writing anyway, just without the burden of also building and maintaining the pipeline that feeds it.
