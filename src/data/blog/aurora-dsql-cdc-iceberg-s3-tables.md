---
author: Venkatesh Periyathambi
pubDatetime: 2026-07-15T09:00:00Z
title: "Streaming Aurora DSQL Changes into an Iceberg Lakehouse with Firehose"
slug: aurora-dsql-cdc-iceberg-s3-tables
featured: true
draft: false
tags:
  - aws
  - aurora-dsql
  - cdc
  - iceberg
  - s3-tables
  - kinesis
  - firehose
  - databases
description: "Aurora DSQL CDC is GA. Here's how to build a fully managed pipeline that lands committed changes in Apache Iceberg on S3 Tables via Kinesis and Firehose, and the record-format details you need to get right."
---

"Our operational data lives in Aurora DSQL. The analytics team wants it in the lakehouse, in near real time, without us running a replication cluster. What's the path?"

As of July 2026 there's a clean answer: Aurora DSQL change data capture went generally available, and it streams committed row-level changes straight to Amazon Kinesis Data Streams — with, in AWS's words, "zero impact on your database workload performance." From Kinesis, a native Amazon Data Firehose integration lands those changes in **Apache Iceberg tables on S3 Tables**. No connector fleet, no WAL to babysit, no servers.

This post is the end-to-end pipeline: how it fits together, and the handful of record-format details worth getting right so your Iceberg table stays a faithful mirror of the source.

## Table of Contents

---

## Why this is a nice pattern

The thing that makes DSQL CDC pleasant to build on is that **change capture is a native, managed capability of the database itself**. You don't stand up a Debezium connector, you don't manage a Kafka Connect cluster, and you don't allocate replication slots that quietly retain WAL and pressure your storage if a consumer falls behind. DSQL reads committed transactions in the background, formats each net row-level change as a structured JSON record, and delivers it to a Kinesis stream you own. The database keeps doing what it does; capture rides alongside.

> **Coming from a Debezium/Postgres world?** The reflex is to reach for a logical-replication connector. With DSQL you don't need one — capture is built in, so there's simply nothing to install or operate. DSQL is PostgreSQL *dialect*-compatible (v16 wire protocol, `psql`/`pgjdbc`/`psycopg` all work), and its CDC envelope is deliberately Debezium-*shaped* — `op`, `before`, `after`, and a `source` block with `txId`, `schema`, `table` — so your mental models and downstream tooling carry over. If your organization is standardized on Kafka, you can still bridge Kinesis into MSK downstream and let Debezium-aware sink connectors consume the records. The native stream just means less to run.

With that framing, let's build the pipeline.

## The pipeline

```
Aurora DSQL ──▶ Kinesis Data Streams ──▶ Data Firehose ──▶ Apache Iceberg
   (CDC)          (bring-your-own)         (+ Lambda)        on S3 Tables
                                                            (Glue Catalog)
```

Every hop is managed:

- **DSQL → Kinesis.** DSQL captures the committed effect of every `INSERT`, `UPDATE`, and `DELETE` across all tables in the cluster and writes each as a JSON record to a Kinesis stream. It's a bring-your-own-target model: you create the stream and an IAM role DSQL assumes to write to it, and you own the stream's capacity, encryption, and retention. Creating the CDC stream is a single `CreateStream` call; status shows up via the `GetStream` API and CloudWatch. On a multi-Region cluster, one stream in any Region captures committed writes from *all* Regions.

- **Kinesis → Firehose → Iceberg.** Firehose has a native Apache Iceberg destination and accepts Kinesis Data Streams as a source, so this hop needs no glue code. Firehose can write to Iceberg tables hosted in **S3 Tables**, automatically applies row-level insert/update/delete, guarantees exactly-once delivery to Iceberg, and can route a single stream to different tables based on record content. It requires the Glue Data Catalog, Iceberg **V2** format, and writes Parquet in **Merge-on-Read** mode.

The one piece of code you write is a small Firehose transform Lambda. Here's what it handles and why.

## Reading the DSQL record format

DSQL delivers each change as a JSON envelope. An update looks like this:

```json
{
  "op": "u",
  "before": null,
  "after": {"order_id": 1001, "item_id": 42, "quantity": 10, "price": "29.99"},
  "source": {
    "ts_ns": 1705318300000000000,
    "txId": "qvtiesgmd55cvlfukm3dfuotji",
    "schema": "public", "table": "order_items", "db": "postgres"
  },
  "ts_ns": 1705318300125483291
}
```

A few properties of this format shape the transform. None of them are hard — they just need to be handled deliberately rather than assumed away.

### Operation codes

DSQL uses `op` values of `c` (create/insert), `u` (update), and `d` (delete):

- `c` — the row is new (didn't exist before the transaction, exists after)
- `u` — the row existed before and still exists
- `d` — the row existed before and doesn't exist after

Firehose's **Operation expression** — the field that tells it whether to insert, update, or delete in Iceberg — expects the literal values `insert`, `update`, `delete`. So the transform maps `c/u/d` → `insert/update/delete`. One lookup table.

### Where the primary key lives

For inserts and updates, the full row — primary key included — is under `after`. For **deletes**, `after` is `null` and `before` carries *just the primary key*:

```json
{ "op": "d", "before": {"order_id": 1001, "item_id": 42}, "after": null, ... }
```

Firehose's **Unique Keys** setting needs the primary key as a top-level column so it can find the row to merge. So the transform flattens the envelope — promoting `after` for inserts/updates and `before` for deletes — and normalizes the key to a consistent location across all three ops. This is the detail to test explicitly: if the key isn't where Firehose expects it, deletes quietly match nothing.

### At-least-once, unordered delivery

DSQL CDC uses `UNORDERED` mode with **at-least-once** delivery — the same design choice that lets it scale and stay out of your database's way. In practice records arrive in approximately commit order, but you should design for duplicates and for occasional out-of-order arrival.

The standard pattern handles both cleanly: **last-writer-wins keyed on commit time.** Every record carries `source.ts_ns`, the transaction commit timestamp in nanoseconds. Track the highest `ts_ns` per primary key and ignore anything less than or equal to it; that filters duplicates and stale out-of-order updates in one move. For deletes, write a tombstone that preserves the `ts_ns` so a late, earlier insert doesn't resurrect the row. Iceberg's Merge-on-Read model fits this naturally — you merge by key rather than rewriting files on every change.

> Keep `AppendOnly = false` on the Firehose Iceberg destination when you have updates and deletes. Append-only mode raises throughput but, per Firehose's docs, delivers out of order — fine for pure event logs, not what you want for a mirror that mutates rows.

## Two format details for your schema

**Some types serialize as strings.** DSQL serializes `numeric`/`decimal` as JSON strings (to preserve exact precision), `json` columns as JSON text within the record, and `bytea` as Base64. Define your Glue table schema and parse accordingly — a `numeric` arrives as a string, not a JSON number.

**Very large records are chunked.** If a serialized record exceeds 9 MiB, DSQL splits the image across multiple Kinesis records (a `chunked` main record plus `fragment` records linked by a stable `chunk_id`) so the change still gets through. If your rows can approach DSQL's 2 MiB row limit with wide JSON columns, have the transform buffer fragments by `chunk_id`, verify the `crc32c`, and rejoin. If large rows aren't possible in your schema, note that decision explicitly rather than leaving it implicit.

## A feature that works in your favor

**Write-set compaction** is a genuine advantage for an analytics sink. DSQL compacts each committed transaction before publishing and emits **at most one record per row per transaction**, reflecting the net effect. Ten updates to a row in one transaction become a single record with the final state; an insert-then-delete in the same transaction produces no record at all.

For a lakehouse that's ideal — fewer redundant Iceberg merges, less write amplification, a cleaner table — because dashboards want net state, not every intermediate keystroke. (If you ever need a record for *every* statement, run each in its own transaction; for analytics you rarely do.)

## What the transform does, end to end

The Firehose transform Lambda does five small things:

1. **Map** `op`: `c`→`insert`, `u`→`update`, `d`→`delete`.
2. **Flatten** the envelope — `after` for inserts/updates, `before` for deletes — into top-level columns.
3. **Normalize the primary key** to a fixed location for Firehose Unique Keys.
4. **Reassemble** chunked records by `chunk_id` (if large rows are possible).
5. **Carry `source.ts_ns`** through so last-writer-wins and dedup work downstream.

Firehose then handles table routing (static or JSON-query Table expression), the Iceberg merge, and exactly-once delivery to S3 Tables. Query the result with Athena, Spark, Trino, or Flink — and because it's S3 Tables, compaction and snapshot expiration are managed for you.

## Build checklist

Before:

- [ ] Kinesis stream created; DSQL IAM role can `PutRecord`/`PutRecords`
- [ ] Every table has a **primary key** (required for dedup and delete correlation)
- [ ] Glue Iceberg tables exist, **V2 format**, before creating the Firehose stream
- [ ] Firehose **Unique Keys** configured per table for update/delete
- [ ] `AppendOnly = false` for workloads with updates/deletes
- [ ] Transform maps op codes, flattens envelope, normalizes PK
- [ ] Glue schema expects `numeric`/`json` as strings, `bytea` as Base64
- [ ] Fragment reassembly handled, or large rows proven impossible

After:

- [ ] `GetStream` shows the CDC stream `ACTIVE`
- [ ] Firehose delivering; S3 error bucket empty
- [ ] Athena row counts reconcile against the DSQL source
- [ ] Deletes actually remove rows in Iceberg (verify the PK-location handling)
- [ ] Replay a stale update and confirm last-writer-wins holds

## The takeaway

Aurora DSQL CDC into Iceberg on S3 Tables is a fully managed, near-real-time lakehouse pipeline with almost nothing to operate — capture is native to the database, the Kinesis-to-Iceberg hop is built into Firehose, and S3 Tables manages the table maintenance. The one bit of code is a transform Lambda, and the details that make it correct are small and knowable: map the op codes, flatten the envelope and normalize the primary key, and use last-writer-wins on `source.ts_ns` to stay resilient to duplicates and reordering.

Get those right and you've got operational data flowing into your lakehouse in near real time, without running a single server to move it.

## References

1. [Amazon Aurora DSQL change data capture (CDC) is now generally available](https://aws.amazon.com/about-aws/whats-new/2026/07/amazon-aurora-dsql-cdc-ga/), AWS What's New
2. [Change data capture streams](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/cdc-streams.html), Amazon Aurora DSQL User Guide
3. [Understanding CDC records](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/cdc-record-format.html), Amazon Aurora DSQL User Guide
4. [Getting started with Change Data Capture in Amazon Aurora DSQL](https://aws.amazon.com/blogs/database/getting-started-with-change-data-capture-in-amazon-aurora-dsql/), AWS Database Blog
5. [Deliver data to Apache Iceberg Tables with Amazon Data Firehose](https://docs.aws.amazon.com/firehose/latest/dev/apache-iceberg-destination.html), Amazon Data Firehose Developer Guide
6. [Stream real-time data into Apache Iceberg tables in Amazon S3 using Amazon Data Firehose](https://aws.amazon.com/blogs/big-data/stream-real-time-data-into-apache-iceberg-tables-in-amazon-s3-using-amazon-data-firehose/), AWS Big Data Blog
