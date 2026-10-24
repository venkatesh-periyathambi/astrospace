---
author: Venkatesh Periyathambi
pubDatetime: 2024-10-14T09:00:00Z
title: "Zero-Downtime Multi-TB Migrations: Cutover, Validation and Rollback (Part 2)"
slug: zero-downtime-migrations-execution
featured: false
draft: false
tags:
  - databases
  - migration
  - logical-replication
  - cdc
  - architecture
description: "Planning the second half of a zero-downtime multi-terabyte migration and version upgrade: how to prove the data matches, rehearse, run the cutover for each wave, and keep a real rollback path."
---

"The plan looks great. So what actually happens at 2am on Sunday?"

That was the CTO again, once we'd walked through [Part 1](/posts/zero-downtime-migrations-strategy): logical replication, the database split into units, five waves, the last one fixed on Sunday 6. Fair question. A plan is only as good as the night you run it.

So this part is about that night: how we proved the data matched, how a cutover fits into five minutes, how to keep a way back you can actually use, and why we rehearsed until it was dull. Functional testing of the apps is still out of scope. What customers see during the pause, and when a payment gets rolled back, is very much in.

<style>
.zl{margin:1.5rem 0 2.5rem}
.zl-legend{display:flex;flex-wrap:wrap;gap:.9rem;font-size:.72rem;opacity:.75;margin-bottom:.6rem}
.zl-legend span{display:inline-flex;align-items:center;gap:.35rem}
.zl-sw{width:.8rem;height:.8rem;border-radius:.2rem;border:1.5px solid var(--accent)}
.zl-sw1{background:var(--accent)}.zl-sw2{border-style:dashed}
.zl-lanes{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.5rem}
@media (max-width:720px){.zl-lanes{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:440px){.zl-lanes{grid-template-columns:1fr}}
.zl-lane{border:1px solid var(--border);border-radius:.6rem;padding:.55rem .5rem;display:flex;flex-direction:column;gap:.35rem}
.zl-name{font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.07em;color:var(--accent);padding:0 .15rem .15rem}
.zl-chip{display:flex;gap:.45rem;align-items:flex-start;border-radius:.4rem;padding:.4rem .5rem;font-size:.8rem;line-height:1.3;text-decoration:none!important;color:inherit!important}
.zl-deep{background:color-mix(in srgb,var(--accent) 14%,transparent);font-weight:600}
a.zl-deep:hover{background:color-mix(in srgb,var(--accent) 24%,transparent)}
.zl-brief{border:1px dashed color-mix(in srgb,var(--accent) 45%,transparent)}
.zl-n{flex:none;font-size:.7rem;font-weight:700;color:var(--accent);min-width:1.1rem;padding-top:.05rem}
.zl-sub{display:block;font-size:.72rem;opacity:.7;font-weight:400;margin-top:.1rem}
.zl-other{opacity:.5}
.zl-parts{display:grid;grid-template-columns:3fr 1fr;gap:.5rem;margin-top:.45rem;font-size:.7rem;text-align:center}
@media (max-width:720px){.zl-parts{display:none}}
.zl-part{border-top:2px solid var(--accent);padding-top:.25rem;opacity:.75}
.zl-part.zl-now{font-weight:700;opacity:1}
.zl-part.zl-dim{border-top-color:var(--border)}
</style>
<nav class="zl" aria-label="The fifteen steps of the migration">
<div class="zl-legend"><span><i class="zl-sw zl-sw1"></i>covered in depth (click to jump)</span><span><i class="zl-sw zl-sw2"></i>in brief</span></div>
<div class="zl-lanes">
<div class="zl-lane zl-other"><div class="zl-name">Decide</div>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#agree-what-zero-downtime-means"><span class="zl-n">1</span><span>Agree what "zero downtime" means</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#why-logical-replication"><span class="zl-n">2</span><span>Rule out dump, restore and replicas</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#why-logical-replication"><span class="zl-n">3</span><span>Choose logical replication</span></a>
</div>
<div class="zl-lane zl-other"><div class="zl-name">Prepare</div>
<div class="zl-chip zl-brief"><span class="zl-n">4</span><span>Land on V16 in the same move<span class="zl-sub">The rows arrive upgraded. Read the release notes</span></span></div>
<div class="zl-chip zl-brief"><span class="zl-n">5</span><span>Build the network link<span class="zl-sub">The new side connects out to the old one, then the old one has to connect back. Both tickets in week one.</span></span></div>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#take-inventory"><span class="zl-n">6</span><span>Take inventory</span></a>
<div class="zl-chip zl-brief"><span class="zl-n">7</span><span>Build roles and schema first<span class="zl-sub">Rows come across. Roles and indexes don't, so build them yourself, and add the indexes after the copy.</span></span></div>
<div class="zl-chip zl-brief"><span class="zl-n">8</span><span>Measure the change rate<span class="zl-sub">One apply worker per subscription. 16 can use more, but not from an 11 source, so test at peak.</span></span></div>
</div>
<div class="zl-lane zl-other"><div class="zl-name">Split and schedule</div>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#split-into-units"><span class="zl-n">9</span><span>Split into units</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-strategy#plan-the-waves-backwards"><span class="zl-n">10</span><span>Plan the waves backwards</span></a>
</div>
<div class="zl-lane"><div class="zl-name">Run</div>
<a class="zl-chip zl-deep" href="#prove-the-data-matches"><span class="zl-n">11</span><span>Prove the data matches</span></a>
<a class="zl-chip zl-deep" href="#rehearse-at-full-size"><span class="zl-n">12</span><span>Rehearse at full size</span></a>
<a class="zl-chip zl-deep" href="#cut-over-one-wave-at-a-time"><span class="zl-n">13</span><span>Cut over one wave at a time</span></a>
<a class="zl-chip zl-deep" href="#run-two-databases-at-once"><span class="zl-n">14</span><span>Run two databases at once</span></a>
<a class="zl-chip zl-deep" href="#keep-a-way-back"><span class="zl-n">15</span><span>Keep a way back</span></a>
</div>
</div>
<div class="zl-parts"><div class="zl-part zl-dim">Part 1: Plan</div><div class="zl-part zl-now">Part 2: Run (you are here)</div></div>
</nav>

## Prove the data matches

We agreed what "matching" meant before we started, because 3am is a bad time for that argument. We checked in three layers, cheapest first:

1. **Row counts per table.** They catch the embarrassing stuff, like a table that never started replicating.
2. **Checksums by primary key range.** A mismatch points at one chunk instead of 3 TB. Frozen ranges you can compare any time. Hot tables need a fixed snapshot, because a live comparison reports lag as corruption. And please don't hash 3 TB on the primary in the middle of the business day.
3. **Business checks.** Yesterday's payment total, merchant balances, the highest order ID. Whatever finance will check on Monday, check it first.

Collation deserves its own warning. Compare by key, not by sorted text, because a newer glibc or ICU can put the same rows in a different order, and that's just a false alarm. A unique text index that won't build, or that treats two values differently, is a real failure, and we treated it as one.

We validated continuously during catch up, unit by unit. And since this was an upgrade as well, we ran ANALYZE after each copy and compared the plans of the busiest queries on both sides. Not load testing, just making sure 16 hadn't picked a very different route.

## Rehearse at full size

You can't copy 12 TB five times inside a twelve week lease, so we didn't try. We did two full size rehearsals against real replication, a second subscription off production into a scratch instance, with real lag and the real roles, and used smaller copies to drill the SQL. A 50 GB sample would never have shown us the WAL pressure, the apply lag or the CTE regression.

We ran each one like the real night and timed every step. And we proved the way back: a PostgreSQL 11 database subscribed to 16, applying a real peak hour. If you skip one rehearsal, don't let it be that one.

Here's some of what the rehearsals turned up:

- a dozen tables with no primary key, one with 400 million rows
- a sequence in another schema that the reset script skipped
- WAL filling the source disk during the biggest initial copy
- lag hitting forty minutes in the month end batch, because authorisations and the ledger share one apply worker
- a runbook step that only worked from one engineer's laptop
- a settlement report going from 2 seconds to 3 minutes after 16 folded its CTE into the main query. One word fixed it: `AS MATERIALIZED`
- an old batch client that couldn't log in with SCRAM. A driver upgrade fixed it

Every one of those would have been a bad night in production. In rehearsal, they were just tickets.

## Cut over one wave at a time

Every cutover follows the same idea. Everything that's moving has been replicating old to new since day one, one publication per unit. A cutover just flips one unit: its tables stop being written on the old side and copied across, and start being written on the new side and copied back. At any moment each table has exactly one writing side, and both databases hold all the live data.

The runbook was short, and every step had a named owner (shown by role in the card below).

**An hour before, we ran the go or no go.** Every answer had to be yes:

- **Initial copy finished** for every table in the unit. We checked pg_subscription_rel for state r, meaning ready, because a subscription can look healthy while one big table is still copying.
- **Lag in seconds**, the last validation green, and fresh statistics on the new side.
- **Grants scripted, not applied.** An app that connects early would write into tables a live subscription is still filling.
- **Reverse path staged.** A publication on the new side, and a subscription on the old side created with connect = false, so no slot exists yet. A slot made days early would collect changes still arriving from the old side and send them straight back.
- **The way back proved in rehearsal**, and the rollback owner on the call.

One no, and we used a spare Sunday. That's what they're for.

**Then the clock started.** These are wave 1's times from its final rehearsal:

<style>
.zc-card{border:1px solid var(--border);border-radius:.6rem;padding:1rem 1rem .5rem;margin:1.25rem 0 1.5rem}
.zc-bar{display:flex;height:1.9rem;border-radius:.4rem;overflow:hidden;gap:2px}
.zc-seg{background:var(--accent);color:var(--background);display:flex;align-items:center;justify-content:center;font-size:.75rem;font-weight:700;min-width:1.1rem}
.zc-seg:nth-child(even){background:color-mix(in srgb,var(--accent) 70%,var(--background))}
.zc-buf{background:repeating-linear-gradient(135deg,color-mix(in srgb,var(--accent) 12%,transparent) 0 6px,transparent 6px 12px)!important;color:var(--foreground);font-weight:400;opacity:.8}
.zc-scale{display:flex;justify-content:space-between;font-size:.7rem;opacity:.6;margin:.3rem 0 1rem}
.zc-row{display:grid;grid-template-columns:2.8rem 1.9rem 1fr;gap:.6rem;align-items:start;padding:.55rem 0;border-top:1px solid var(--border)}
.zc-time{font-size:.8rem;font-weight:700;color:var(--accent);padding-top:.2rem}
.zc-dot{width:1.6rem;height:1.6rem;border-radius:9999px;border:2px solid var(--accent);color:var(--accent);display:flex;align-items:center;justify-content:center;font-size:.75rem;font-weight:700}
.zc-title{font-weight:700;display:flex;flex-wrap:wrap;gap:.5rem;align-items:center}
.zc-owner{font-weight:600;font-size:.68rem;text-transform:uppercase;letter-spacing:.05em;padding:0 .45rem;border:1px solid var(--border);border-radius:9999px;opacity:.75}
.zc-desc{font-size:.85rem;line-height:1.45;opacity:.85;margin-top:.15rem}
.zc-end{display:grid;grid-template-columns:2.8rem 1fr;gap:.6rem;padding:.55rem 0;border-top:1px solid var(--border);font-size:.85rem}
.zc-end strong{color:var(--accent)}
</style>
<div class="zc-card">
<div class="zc-bar"><div class="zc-seg" style="flex:20"><span>1</span></div><div class="zc-seg" style="flex:50"><span>2</span></div><div class="zc-seg" style="flex:40"><span>3</span></div><div class="zc-seg" style="flex:15"><span>4</span></div><div class="zc-seg" style="flex:20"><span>5</span></div><div class="zc-seg" style="flex:25"><span>6</span></div><div class="zc-seg zc-buf" style="flex:130"><span>buffer</span></div></div>
<div class="zc-scale"><span>0:00</span><span>1:00</span><span>2:00</span><span>3:00</span><span>4:00</span><span>5:00</span></div>
<div class="zc-row"><div class="zc-time">0:00</div><div class="zc-dot">1</div><div class="zc-body"><div class="zc-title">Stop writes for this unit<span class="zc-owner">DBA</span></div><div class="zc-desc">Revoke insert, update and delete from every role that writes these tables, the owner too if the app connects as it. Then cancel only the sessions holding locks on them. Reads and the other waves carry on. Any transaction still in flight rolls back and the app retries, which for payments is a business event, so agree up front what customers see. Note the WAL position on the old side.</div></div></div>
<div class="zc-row"><div class="zc-time">0:20</div><div class="zc-dot">2</div><div class="zc-body"><div class="zc-title">Wait for lag to hit zero<span class="zc-owner">DBA</span></div><div class="zc-desc">Other waves are still writing, so the old side's WAL never stops moving. Ignore that. Watch this unit's slot on the old side instead: its confirmed_flush_lsn in pg_replication_slots shows how far the new side has applied. Wait until it reaches the step 1 position. Not close. All of it.</div></div></div>
<div class="zc-row"><div class="zc-time">1:10</div><div class="zc-dot">3</div><div class="zc-body"><div class="zc-title">Quick final check<span class="zc-owner">DBA</span></div><div class="zc-desc">Row counts and checksums on the newest chunks only. Writes are stopped, so this is a stable point to compare.</div></div></div>
<div class="zc-row"><div class="zc-time">1:50</div><div class="zc-dot">4</div><div class="zc-body"><div class="zc-title">Set the sequences<span class="zc-owner">DBA</span></div><div class="zc-desc">Read each sequence's last_value on the old side and set the new side above it, with a gap. Not max(id): too slow on 3.1 billion rows, and it can be lower than what's already been handed out.</div></div></div>
<div class="zc-row"><div class="zc-time">2:05</div><div class="zc-dot">5</div><div class="zc-body"><div class="zc-title">Flip the replication<span class="zc-owner">DBA</span></div><div class="zc-desc">Disable the old to new subscription and drop its slot, or it holds WAL until the disk fills. That's the only loop protection 11 gives you. Then create the slot on the new side, enable the staged reverse subscription, and refresh it without copying data.</div></div></div>
<div class="zc-row"><div class="zc-time">2:25</div><div class="zc-dot">6</div><div class="zc-body"><div class="zc-title">Point the services at the new side<span class="zc-owner">App lead</span></div><div class="zc-desc">Apply the write grants on the new side, switch the connection strings and restart the pools. If you switch by DNS, lower the TTL days ahead. Anything still pointing at the old side hits the revoked grants and fails loudly. The pause ends here.</div></div></div>
<div class="zc-end"><strong>2:50</strong><div>Writes are flowing on the new side. Everything after this is two minutes of buffer you hope not to need.</div></div>
</div>

The first time we rehearsed wave 1 it took eleven minutes. On the night it was under three, mostly because steps 2 to 5 were scripted and nobody was typing SQL under pressure.

## Run two databases at once

For a few weeks you're running two databases, with replication flowing both ways, and it feels odd. These were the rules that kept it safe:

- **Lag is visible.** Reads on the side that isn't writing are a second or two old, so the reads that care stay with the writer.
- **No transaction spans units**, and no insert depends on a parent written seconds ago on the other side.
- **Triggers fire on the writer only.** Replicated changes skip ordinary triggers, so the audit row travels as its own change. Set the trigger to ENABLE ALWAYS and you'll get every audit row twice.
- **DDL stays frozen**, apart from the next monthly partitions, which have to exist on both sides already and be published in the right direction.
- **Don't fail over casually.** On 11, slots live only on the primary (failover slots arrived in 17), so a failover breaks every subscription and the big tables copy again. We wrote the resync procedure first and agreed nobody would fail over for convenience during a 1.4 TB copy.
- **Drop each wave's dead slot the same night**, and keep watching slots, disk and the oldest transaction right to the end.

## Keep a way back

How you roll back depends on where you are in the runbook when something goes wrong. We planned for three cases:

<style>
.zb{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.6rem;margin:1.25rem 0 1.5rem}
@media (max-width:720px){.zb{grid-template-columns:1fr}}
.zb-c{border:1px solid var(--border);border-top:4px solid var(--accent);border-radius:.6rem;padding:.7rem .8rem;line-height:1.4;display:flex;flex-direction:column;gap:.35rem}
.zb-when{font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:var(--accent)}
.zb-name{font-weight:700}
.zb-do{font-size:.83rem}
.zb-cost{margin-top:auto;padding-top:.4rem;font-size:.75rem;opacity:.75;border-top:1px dashed var(--border)}
.zb-2{background:color-mix(in srgb,var(--accent) 7%,transparent)}
.zb-3{background:color-mix(in srgb,var(--accent) 15%,transparent)}
</style>
<div class="zb" role="figure" aria-label="Three rollback cases, from easiest to hardest">
<div class="zb-c"><div class="zb-when">Before step 5</div><div class="zb-name">Just go home</div><div class="zb-do">Nothing has changed on the new side. Grant writes back on the old side and point the services home.</div><div class="zb-cost">Costs: one spare Sunday</div></div>
<div class="zb-c zb-2"><div class="zb-when">After step 5, before any new write</div><div class="zb-name">Rebuild the forward stream</div><div class="zb-do">The forward slot is gone. Disable the reverse subscription and drop its slot, recreate old to new without copying data, then grant and point home.</div><div class="zb-cost">Costs: the rest of the night. Wait a week and it's a fresh copy</div></div>
<div class="zb-c zb-3"><div class="zb-when">After the new side takes writes</div><div class="zb-name">Run the cutover backwards</div><div class="zb-do">Only works if 11 can keep up with 16. Stop writes on the new side, let the old side catch up, set its sequences, flip the replication, grant writes back, point home.</div><div class="zb-cost">Costs: the same five minutes, if rehearsal proved it</div></div>
</div>

The first two are mostly about keeping your nerve. We used the first one once, in a rehearsal, when the lag check stalled at 1:40 and nobody wanted to guess why. The apps were back on the old side a couple of minutes later.

The third case took the most work. Going from 16 back to 11 means replicating down five major versions, and PostgreSQL doesn't promise that works, so we tested it: an 11 database subscribed to 16 through a full peak hour in rehearsal. It held. If it hadn't, we'd have told the CTO plainly that once the new side takes its first write there's no clean way back, and then either lived with that or built a separate feed of changes that 11 could replay. And don't forget to grant writes back on the old side. We nearly did, in rehearsal, and the apps came home to a database that wouldn't let them write.

If you ever have to undo more than one wave, go in reverse order, one unit at a time, or a payment can end up pointing at a category the old side hasn't got yet.

We kept the old database running, patched and monitored for two weeks after the last wave, or until the first schema change on the new side, whichever came first. That was our point of no return, and it's why Sunday 6 had to be the last cutover. Finance asked twice whether we really needed to keep paying for it. We did.

## What bites people

If I had to name the ones I see most often:

- **Planning the copy and forgetting the catch up.** The catch up decides whether you can ever cut over.
- **Big tables with no primary key**, found in week ten instead of week one.
- **Sequences not reset**, so the first insert on the new side collides.
- **Forgotten consumers** still pointing at the old database. Revoked grants are what catch them.
- **Treating the upgrade as free**, until one important query picks a terrible plan.
- **A forgotten slot.** A disabled subscription keeps its slot, the slot keeps WAL, and 11 lets it fill the disk.
- **Splitting a transaction across two waves.** Fine until someone checks the ledger.
- **No proven way back**, because "it went fine in test."

None of these are exotic. They're just what gets skipped under deadline pressure, which is always.

Several of them you can catch on day one, before a single subscription exists. I've put the read-only check we wish we'd run first into a script: [pg-logical-replication-precheck.sql](/downloads/pg-logical-replication-precheck.sql). Point it at the source with `psql -X -f`. It lists tables without a primary key, sequences and their current values, partitions, large objects, triggers that would fire twice, extensions, MD5 passwords, risky unique text indexes, and any replication slot already quietly holding WAL. It doesn't write or lock anything, and it won't find the cron job on the old VM. That still takes a month of connection logs.

## Wrapping up

So how did it go? Mostly to plan. One wave slipped a week after a validation false alarm (the check had compared a live chunk while the subscriber was a second behind), and that's exactly what the spare Sunday was for. All five cutovers finished inside four minutes, and the old database was switched off before the lease ran out.

Looking back, nothing we used was new. Logical replication has been in PostgreSQL since version 10, moving in waves is old project management, and the runbook was a checklist on one page. What got us through was doing the dull parts properly: a month of connection logging, rehearsing until the times stopped changing, and keeping a spare Sunday that nobody wanted to give up. The upgrade came along inside the same project instead of becoming a second one. At this size, the plan matters far more than the tool.

## References

1. [Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html), PostgreSQL 16 documentation
2. [CREATE SUBSCRIPTION](https://www.postgresql.org/docs/16/sql-createsubscription.html), PostgreSQL 16 documentation, including the copy_data option used when starting reverse replication
3. [Logical Replication Restrictions](https://www.postgresql.org/docs/16/logical-replication-restrictions.html), PostgreSQL 16 documentation
4. [Monitoring Logical Replication](https://www.postgresql.org/docs/16/logical-replication-monitoring.html), PostgreSQL 16 documentation
5. [Sequence Manipulation Functions](https://www.postgresql.org/docs/16/functions-sequence.html), PostgreSQL 16 documentation
6. [pg_replication_slots](https://www.postgresql.org/docs/16/view-pg-replication-slots.html), PostgreSQL 16 documentation, for confirmed_flush_lsn and restart_lsn
7. [pg_subscription_rel](https://www.postgresql.org/docs/16/catalog-pg-subscription-rel.html), PostgreSQL 16 documentation, for per table sync state
8. [PostgreSQL 17 Release Notes](https://www.postgresql.org/docs/release/17.0/), including failover of logical replication slots
