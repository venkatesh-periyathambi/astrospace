---
author: Venkatesh Periyathambi
pubDatetime: 2026-05-26T09:00:00Z
title: "RDS MySQL Blue/Green Upgrades: Don't Let Debezium Lose Its Place"
slug: rds-mysql-bluegreen-debezium-cdc-continuity
featured: true
draft: false
tags:
  - aws
  - rds
  - mysql
  - debezium
  - cdc
  - blue-green
  - redshift
  - databases
description: "How to run a major version upgrade on RDS MySQL without breaking your Debezium CDC pipeline. Covers binlog position recovery, GTID auto-positioning, and how to verify you did not lose any changes."
---

"We need to do a major version upgrade. Debezium is streaming to Redshift. How do we avoid a full re-snapshot?"

This comes up whenever a team has a multi-terabyte MySQL database with a CDC pipeline hanging off it, and the worry is always the same one. Binlog coordinates reset when the database is upgraded, the offset Debezium has stored stops meaning anything, and you are looking at days of re-snapshotting while the data team stares at stale dashboards.

You do not need a re-snapshot. The awkward part is that the documentation does not explain how this behaves when Debezium reads from a *replica* rather than the writer, which is how most people run it. That is the gap I want to fill.

## Table of Contents

---

## The setup

![Architecture: an RDS MySQL cluster with a writer and two replicas, Debezium reading binlog from Replica 2 and streaming into Amazon Redshift](@/assets/images/rds-bluegreen-debezium/01-architecture.svg)

One writer and two replicas. One of those replicas has `log_bin = ON` and `binlog_format = ROW`, and Debezium connects to it. The connector tracks its place in the stream as a filename and an offset, something like `mysql-bin-changelog.000042` at position `985632`.

If you have not turned binary logging on for that replica, the connector will not even start. Debezium runs `SHOW MASTER STATUS` during its snapshot, gets an empty result, and throws `Cannot read the binlog filename and position via 'SHOW MASTER STATUS'`. On RDS, `log_bin` is managed by AWS and defaults to off, so this catches people out regularly.

After a major version upgrade, the coordinates the connector has stored do not exist on the new instance any more. That is the problem this post is about.

## Why Blue/Green helps

![Blue and Green environments side by side, each with a writer and two replicas, with the reader endpoint flipping from Blue to Green at switchover](@/assets/images/rds-bluegreen-debezium/02-bluegreen-topology.svg)

RDS Blue/Green Deployments copy your whole environment into a staging area, upgrade the copy, and then swap the endpoints over. Four things about that matter for a CDC pipeline.

The topology is copied in full, so the writer and every replica get recreated on the green side without you doing anything. Parameter settings come across too, which means `log_bin = ON` and `binlog_format = ROW` are still in place on the green replica. Your connection strings resolve to green after switchover, so no application changes are needed. And the switchover itself takes seconds rather than hours.

There is one catch, and it is the reason this post exists. Every instance in the green environment starts a fresh binlog sequence, so the file and position Debezium has stored no longer point at anything real.

## Option A: binlog position recovery

![Option A flow: pause Debezium, trigger the switchover, read the new binlog coordinates from the green replica, update the stored offset, resume the connector](@/assets/images/rds-bluegreen-debezium/03-option-a-binlog-recovery.svg)

This works today and needs nothing set up in advance.

### Before the switchover

1. Check that Debezium has caught up and is showing zero lag.
2. Stop the connector.

### The switchover

3. Trigger the Blue/Green switchover. RDS syncs the two environments and swaps the endpoints over, which takes seconds.

### After the switchover

4. **Read the new binlog coordinates off the green replica.**

   In the RDS console, open the green replica and go to **Logs & events**. You are looking for a line like this:

   > `Binlog position from crash recovery is mysql-bin-changelog.000004 490`

   Every instance emits its own coordinates, so take the ones from the replica rather than the writer. That replica is where Debezium connects.

5. **Write those coordinates into the connector's stored offset.**

   This is the step most write-ups skip over, and it is the fiddly one. Kafka Connect keeps source offsets in an internal compacted topic, named by the `offset.storage.topic` setting and usually called something like `connect-offsets`. You do not edit it by hand.

   On Kafka Connect 3.6 or later there are REST endpoints for exactly this job. The connector has to be stopped first, which you already did in step 2:

   ```bash
   # stop the connector (a paused connector is not enough)
   curl -X PUT http://connect:8083/connectors/mysql-cdc/stop

   # look at what it currently has stored
   curl http://connect:8083/connectors/mysql-cdc/offsets

   # write the new coordinates
   curl -X PATCH -H "Content-Type: application/json" \
     http://connect:8083/connectors/mysql-cdc/offsets \
     -d '{
       "offsets": [
         {
           "partition": { "server": "my-topic-prefix" },
           "offset": { "file": "mysql-bin-changelog.000004", "pos": 490 }
         }
       ]
     }'
   ```

   Use `GET` first and copy the exact shape of the `partition` object it returns. Getting that key wrong means your `PATCH` writes an offset the connector never reads, and it will quietly start from scratch instead.

   On older versions of Connect there is no such endpoint, and you have to produce a record onto the offsets topic yourself with something like `kcat`. If you are on MSK Connect, the REST API is not exposed to you at all, so check what your platform actually allows before you plan a maintenance window around these calls.

6. Resume the connector with `PUT /connectors/mysql-cdc/resume`.

**What you get:** a few minutes of CDC downtime, no re-snapshot, and a moderate amount of manual work.

**What it costs you:** you do this again on every upgrade, and a mistyped offset gives you either a gap in the data or a batch of duplicates.

---

## Option B: GTID

![Option B flow: Debezium stores a GTID set, the switchover swaps endpoints, and the green replica auto-positions from that GTID set with no manual steps](@/assets/images/rds-bluegreen-debezium/04-option-b-gtid.svg)

This one takes some setting up. Once it is done, upgrades, failovers, and topology changes stop being something Debezium notices.

### How it works

When GTID is on, every transaction gets a globally unique identifier that has nothing to do with which binlog file it happens to sit in. Debezium stores the set of identifiers it has already seen:

```json
{
  "ts_sec": 1711929600,
  "file": "mysql-bin.000123",
  "pos": 4567890,
  "gtids": "3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5000",
  "snapshot": false
}
```

After the switchover the connector reconnects and asks for everything after GTID `...:1-5000`. The server works out where that sits in its own binlog and carries on from there. Nobody has to look up a file name or a position.

### Turning GTID on without downtime

Both settings are dynamic system variables in MySQL, so on RDS you change them in the DB parameter group and they take effect without a reboot. Confirm the Apply type column says dynamic for your engine version before you plan around that.

The order of these steps is not negotiable. MySQL requires `enforce_gtid_consistency` to reach `ON` before `gtid_mode` starts moving, and skipping ahead can leave you with transactions that cannot be replicated.

| Step | What you change | Move on when |
| --- | --- | --- |
| 1 | `enforce_gtid_consistency = WARN` | Your normal workload has run for a while and the error log shows no GTID consistency warnings. Fix any warnings before continuing. |
| 2 | `enforce_gtid_consistency = ON` | Applied on every instance. |
| 3 | `gtid_mode = OFF_PERMISSIVE` | Every instance has finished this step. None may move ahead early. |
| 4 | `gtid_mode = ON_PERMISSIVE` | Every instance has finished this step. |
| 5 | Nothing to change | `ONGOING_ANONYMOUS_TRANSACTION_COUNT` reads zero on each instance, and every anonymous transaction has replicated everywhere. |
| 6 | Nothing to change | You no longer need any binlog that still holds pre-GTID transactions. Read the warning below before you skip this. |
| 7 | `gtid_mode = ON` | Done. |

Step 6 is the one that will bite a CDC pipeline, and it is missing from most guides. Once `gtid_mode` is `ON`, binlogs containing transactions without GTIDs can no longer be used. If Debezium is still reading an older binlog when you make that change, it stops dead and your only way out is a re-snapshot, which is the exact outcome you were trying to avoid. So before step 7, confirm the connector has caught up past every one of those older transactions.

Once GTID is on, add `"gtid.source.includes": ".*"` to the connector config, restart it, and check that the stored offset now has a `gtids` field in it. If that field is missing, the connector is still tracking file and position, and none of this will help you.

### Why it works on the green replica

Every instance shares the same `gtid_executed` set. Green replicates the full GTID history from blue while it is being staged, so after the switchover the green replica can serve the binlog from any GTID position the connector asks for.

### What the switchover looks like

You trigger the switchover, the connector loses its connection for a few seconds, and the reader endpoint starts resolving to the green replica. The connector reconnects, sends its GTID set, and the green replica works out where to carry on from. CDC resumes on its own, with nothing for you to do.

---

## Which one to use

| | Binlog file and position | GTID |
| --- | --- | --- |
| CDC downtime | Minutes | Seconds |
| Manual steps | Read the event log, then patch the offset | None |
| Re-snapshot | No | No |
| Works for the next upgrade too | No | Yes |
| Setup needed first | None | One-time enablement |
| Room for human error | You are typing a binlog offset by hand | Much smaller, though not zero |

GTID removes the manual offset editing, which is where most mistakes happen. It does not make the upgrade risk-free. Errant transactions on one instance and the pre-GTID binlog trap in step 6 are both still yours to manage.

If this is a one-off upgrade, use Option A. Ten minutes of careful work and you are done. If it is a production pipeline you would rather not be paged about at 3am, spend an afternoon on GTID and stop thinking about binlog positions altogether.

## Checklist

Before the switchover:

- [ ] `binlog_format = ROW` on the CDC replica
- [ ] `log_bin = ON` on the CDC replica
- [ ] `binlog retention hours` set to something between 24 and 72, not left at NULL
- [ ] Debezium pointed at the reader endpoint, not a hardcoded instance
- [ ] For GTID: `gtid_mode = ON` and `enforce_gtid_consistency = ON`
- [ ] For GTID: the stored offset contains a `gtids` field
- [ ] Note the connector's current offset somewhere outside Kafka, so you can compare later

After the switchover:

- [ ] `SHOW VARIABLES LIKE 'log_bin';` returns ON
- [ ] `SHOW VARIABLES LIKE 'gtid_mode';` returns ON
- [ ] `SELECT @@global.gtid_executed;` shows the full history, not a fresh set
- [ ] Connector status is RUNNING
- [ ] Lag is falling back towards zero
- [ ] Redshift is receiving changes again

## Proving you did not lose anything

"Lag is back to zero" and "rows are arriving" tell you the pipeline is alive. Neither tells you whether a gap opened up while you were switching over, and that is the thing you actually care about. Two checks worth running.

Compare what the connector has consumed against what the server has produced. On the green replica, run `SELECT @@global.gtid_executed;` and compare it to the `gtids` value in the connector's stored offset. The connector should be at or just behind the server, with no missing ranges in the middle.

Then count rows over the switchover window. Pick a table with a reliable modification timestamp and compare both sides across a window that covers the outage with room to spare:

```sql
-- on the MySQL source
SELECT COUNT(*), MAX(updated_at)
FROM   orders
WHERE  updated_at >= '2026-05-26 09:00:00'
AND    updated_at <  '2026-05-26 10:00:00';

-- the same window in Redshift
SELECT COUNT(*), MAX(updated_at)
FROM   orders
WHERE  updated_at >= '2026-05-26 09:00:00'
AND    updated_at <  '2026-05-26 10:00:00';
```

Matching counts across that window mean you came through clean. A short count on the target means you lost changes and need to backfill that window. Run this before you tell anyone the upgrade went fine.

One last thing to keep an eye on. The connector's schema history topic survives the upgrade untouched, which is what you want, but a major version upgrade can change how the server reports types for some columns. Check the first few change events after the switchover against what your sink expects, rather than assuming the schema came through unchanged.

## References

1. [Creating a blue/green deployment](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-creating.html), Amazon RDS User Guide
2. [Switching a blue/green deployment](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-switching.html), Amazon RDS User Guide
3. [Using GTID-based replication](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/mysql-replication-gtid.html), Amazon RDS User Guide
4. [Enabling GTID Transactions Online](https://dev.mysql.com/doc/refman/8.0/en/replication-mode-change-online-enable-gtids.html), MySQL 8.0 Reference Manual
5. [MySQL Connector](https://debezium.io/documentation/reference/stable/connectors/mysql.html), Debezium Documentation
6. [Frequently Asked Questions](https://debezium.io/documentation/faq/), Debezium Documentation
7. [Kafka Connect REST API](https://kafka.apache.org/documentation/#connect_rest), Apache Kafka Documentation
8. [Binary log configuration](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/mysql-stored-proc-configuring.html), Amazon RDS User Guide
