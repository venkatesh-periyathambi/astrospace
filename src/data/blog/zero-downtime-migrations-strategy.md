---
author: Venkatesh Periyathambi
pubDatetime: 2024-09-23T09:00:00Z
title: "Zero-Downtime Multi-TB Migrations: Strategy and Grouping (Part 1)"
slug: zero-downtime-migrations-strategy
featured: false
draft: false
tags:
  - databases
  - migration
  - logical-replication
  - cdc
  - architecture
description: "How to plan a zero-downtime migration and major version upgrade of a multi-terabyte database. Why physical replication does not fit, why logical replication does, and how to split databases and tables into groups you can migrate one at a time."
---

"We have a migration. It's a big one. And we've already tried twice."

<style>.zr{background:color-mix(in srgb,var(--accent) 16%,transparent);color:inherit;padding:0 .2em;border-radius:.2em;font-weight:600}</style>

That's how the call opened. A payments company, <mark class="zr">12 TB</mark> on PostgreSQL 11 in <mark class="zr">their own data centre</mark>, and <mark class="zr">twelve weeks</mark> until the hardware lease ran out. They needed to land on a <mark class="zr">managed cloud service</mark> and <mark class="zr">upgrade to PostgreSQL 16</mark> on the way, five major versions in one jump. The CTO wanted <mark class="zr">zero downtime</mark>. Their test restore was still running four days later, and the only window anyone would sign off was <mark class="zr">two hours early on a Sunday</mark>.

I've seen some version of this story plenty of times, and the teams that get through it never do it by finding a cleverer tool. They stop treating it as one huge migration, break it into smaller ones, and let the upgrade ride along. There are about fifteen steps between that phone call and switching off the old database. Here's the whole map. I'll go deep on the ones that make or break the project, and leave the rest at a line each. This post is the planning. [Part 2](/posts/zero-downtime-migrations-execution) is how we ran it. Functional testing of the apps isn't covered in either.

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
<div class="zl-lane"><div class="zl-name">Decide</div>
<a class="zl-chip zl-deep" href="#agree-what-zero-downtime-means"><span class="zl-n">1</span><span>Agree what "zero downtime" means</span></a>
<a class="zl-chip zl-deep" href="#why-logical-replication"><span class="zl-n">2</span><span>Rule out dump, restore and replicas</span></a>
<a class="zl-chip zl-deep" href="#why-logical-replication"><span class="zl-n">3</span><span>Choose logical replication</span></a>
</div>
<div class="zl-lane"><div class="zl-name">Prepare</div>
<div class="zl-chip zl-brief"><span class="zl-n">4</span><span>Land on V16 in the same move<span class="zl-sub">The rows arrive upgraded. Read the release notes</span></span></div>
<div class="zl-chip zl-brief"><span class="zl-n">5</span><span>Build the network link<span class="zl-sub">The new side connects out to the old one, then the old one has to connect back. Both tickets in week one.</span></span></div>
<a class="zl-chip zl-deep" href="#take-inventory"><span class="zl-n">6</span><span>Take inventory</span></a>
<div class="zl-chip zl-brief"><span class="zl-n">7</span><span>Build roles and schema first<span class="zl-sub">Rows come across. Roles and indexes don't, so build them yourself, and add the indexes after the copy.</span></span></div>
<div class="zl-chip zl-brief"><span class="zl-n">8</span><span>Measure the change rate<span class="zl-sub">One apply worker per subscription. 16 can use more, but not from an 11 source, so test at peak.</span></span></div>
</div>
<div class="zl-lane"><div class="zl-name">Split and schedule</div>
<a class="zl-chip zl-deep" href="#split-into-units"><span class="zl-n">9</span><span>Split into units</span></a>
<a class="zl-chip zl-deep" href="#plan-the-waves-backwards"><span class="zl-n">10</span><span>Plan the waves backwards</span></a>
</div>
<div class="zl-lane zl-other"><div class="zl-name">Run</div>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-execution#prove-the-data-matches"><span class="zl-n">11</span><span>Prove the data matches</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-execution#rehearse-at-full-size"><span class="zl-n">12</span><span>Rehearse at full size</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-execution#cut-over-one-wave-at-a-time"><span class="zl-n">13</span><span>Cut over one wave at a time</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-execution#run-two-databases-at-once"><span class="zl-n">14</span><span>Run two databases at once</span></a>
<a class="zl-chip zl-deep" href="/posts/zero-downtime-migrations-execution#keep-a-way-back"><span class="zl-n">15</span><span>Keep a way back</span></a>
</div>
</div>
<div class="zl-parts"><div class="zl-part zl-now">Part 1: Plan (you are here)</div><div class="zl-part zl-dim">Part 2: Run</div></div>
</nav>

## Agree what "zero downtime" means

"Zero downtime" was the first thing we pushed back on. Nobody really gets zero, so we sat down with the business owner and agreed a number we could actually plan against.

What we landed on: reads keep working the whole time, and writes pause for no more than five minutes per cutover. That's something you can design for, rehearse and measure. "Zero" on its own is a wish.

The window came out of the same conversation. Payments traffic bottoms out between 2 and 4 on a Sunday morning, so that's the only time the business would sign off a cutover. Five minutes was what they could absorb, short enough for retries and queued payouts to catch up before any customer noticed. The rest of the two hours is for checks before and watching after.

## Why logical replication

At 50 GB you can dump and restore over lunch. At 12 TB, the maths just stops working:

<style>
.zs-card{border:1px solid var(--border);border-radius:.6rem;padding:1rem 1rem .9rem;margin:1.25rem 0 1.5rem}
.zs-title{font-weight:700;font-size:.9rem;margin-bottom:.75rem}
.zs-row{display:grid;grid-template-columns:13rem 1fr;gap:.75rem;align-items:center;padding:.35rem 0}
@media (max-width:640px){.zs-row{grid-template-columns:1fr;gap:.2rem}}
.zs-label{font-size:.82rem;line-height:1.3}
.zs-track{display:flex;align-items:center;gap:.5rem;min-height:1.1rem}
.zs-bar{height:.9rem;min-width:4px;background:var(--accent);border-radius:0 4px 4px 0}
.zs-val{font-size:.78rem;opacity:.75;white-space:nowrap}
.zs-tiles{display:flex;flex-wrap:wrap;gap:.6rem;margin-top:.9rem;padding-top:.9rem;border-top:1px solid var(--border)}
.zs-tile{flex:1 1 12rem}
.zs-num{font-size:1.5rem;font-weight:700;line-height:1.1}
.zs-cap{font-size:.8rem;opacity:.75;line-height:1.35}
.zs-phases{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.6rem;margin:1.25rem 0 1rem}
@media (max-width:640px){.zs-phases{grid-template-columns:1fr}}
.zs-phase{border:1px solid var(--border);border-radius:.6rem;padding:.75rem .85rem;line-height:1.4;position:relative}
.zs-step{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;opacity:.6}
.zs-name{font-weight:700;margin:.1rem 0 .3rem}
.zs-desc{font-size:.83rem;opacity:.85}
.zs-tag{display:inline-block;margin-top:.55rem;padding:0 .5rem;border-radius:9999px;font-size:.7rem;font-weight:700;border:1px solid var(--border)}
.zs-risk{border-color:var(--accent);color:var(--accent)}
.zs-phase.zs-hot{background:color-mix(in srgb,var(--accent) 10%,transparent)}
</style>
<div class="zs-card" role="figure" aria-label="Bar chart: a 2 hour cutover window, about 22 hours of pure copying, and a test restore still running after 4 days">
<div class="zs-title">How long 12 TB takes, against the time they had</div>
<div class="zs-row" title="The cutover window: 2 hours"><div class="zs-label">The cutover window</div><div class="zs-track"><div class="zs-bar" style="width:2.08%"></div><span class="zs-val">2 hours</span></div></div>
<div class="zs-row" title="Pure copy at 150 MB a second: about 22 hours"><div class="zs-label">Pure copy at 150 MB a second</div><div class="zs-track"><div class="zs-bar" style="width:22.92%"></div><span class="zs-val">about 22 hours</span></div></div>
<div class="zs-row" title="Their test restore, with index builds: 4 days and still going"><div class="zs-label">Their test restore, with index builds</div><div class="zs-track"><div class="zs-bar" style="width:100.00%"></div><span class="zs-val">4 days and still going</span></div></div>
<div class="zs-tiles"><div class="zs-tile"><div class="zs-num">300 GB</div><div class="zs-cap">of new changes every day while you copy</div></div><div class="zs-tile"><div class="zs-num">+1.2 TB</div><div class="zs-cap">waiting for you after a four day copy</div></div></div>
</div>

Even the best case needed eleven of those two hour windows back to back, so dump and restore was out. The usual on-prem trick, building a replica and promoting it, went next. A managed service won't act as a physical replica of your own server, and physical replication can't cross major versions anyway.

That left logical replication. It sends row changes rather than disk blocks, so it works across major versions, and every row lands on 16 as it arrives. The upgrade rides along with the move instead of becoming a second project. Two words you'll see a lot from here: a **publication** is the list of tables the source offers, and a **subscription** is the target pulling their changes, applied by a single worker.

It comes with homework, and the parts that bite hardest on PostgreSQL 11 are these:

- **Every table needs a primary key**, or updates and deletes won't replicate.
- **DDL and sequences don't replicate.** We froze schema changes and set sequences by hand at cutover. The exception was monthly partitions: 11 publishes each one separately, so someone had to create next month's on both sides ahead of time.
- **The source holds WAL** until the target catches up, and 11 has no cap. We watched slots and free disk every day.
- **No dual writes** from the app. Nothing keeps two databases in step, and that's a hill I'm happy to stand on.

Whatever the tool, a migration this size always takes the same shape:

<div class="zs-phases">
<div class="zs-phase"><div class="zs-step">Phase 1</div><div class="zs-name">Bulk copy</div><div class="zs-desc">Get the existing data across. Takes days, but nobody notices.</div><span class="zs-tag">most of the effort</span></div>
<div class="zs-phase zs-hot"><div class="zs-step">Phase 2</div><div class="zs-name">Catch up</div><div class="zs-desc">Stream every change made during and after the copy, until the target is seconds behind.</div><span class="zs-tag zs-risk">where the risk is</span></div>
<div class="zs-phase zs-hot"><div class="zs-step">Phase 3</div><div class="zs-name">Cut over</div><div class="zs-desc">Pause writes, let the last changes land, point the apps at the new side.</div><span class="zs-tag zs-risk">where the risk is</span></div>
</div>

Most of the effort goes into phase 1. Almost all the risk lives in phases 2 and 3.

## Take inventory

Before we planned a single wave, we built an inventory, one entry per table. It's dull work, and every decision after it leans on it. Here's the entry for one of the busiest tables, boiled down:

<style>
.zt2{border-left:3px solid var(--accent);padding:.6rem .9rem;margin:1.1rem 0 1.4rem;background:color-mix(in srgb,var(--accent) 6%,transparent);border-radius:0 .5rem .5rem 0}
.zt2-name{font-weight:700;font-size:.9rem;margin-bottom:.45rem}
.zt2-tags{display:flex;flex-wrap:wrap;gap:.35rem}
.zt2-tag{font-size:.75rem;padding:.1rem .55rem;border:1px solid var(--border);border-radius:9999px;background:var(--background)}
.zt2-flag{border-color:var(--accent);color:var(--accent);font-weight:700}
</style>
<div class="zt2"><div class="zt2-name"><code>payments.authorisations</code></div><div class="zt2-tags"><span class="zt2-tag">1.4 TB</span><span class="zt2-tag">2,300 writes/s at Friday peak</span><span class="zt2-tag">has a primary key</span><span class="zt2-tag">audit trigger, same transaction</span><span class="zt2-tag">read by 2 CTE reports</span><span class="zt2-tag">wave 4, shares a stream with the ledger</span><span class="zt2-tag zt2-flag">3rd writer nobody knew about</span></div></div>

That last tag is the one that nearly got us. The third writer was a reconciliation script on an old VM. It ran at 3am on the first of the month, connected by IP address and wrote straight into the payments tables. Nobody in the room knew it existed. We only found it because we left connection logging on for a full month, so it caught a first of the month before any payments wave. A week would have missed it.

## Split into units

This is the bit that turned the project around. Instead of one 12 TB move, we planned several, each with its own cutover. A **migration unit** is a set of tables that switch over together, along with the services that write them. Each wave repoints those services at the new database, so it's an app change as well as a database one.

What makes it safe is simple. From day one, everything that's moving copies from old to new, so both databases always hold all the live data, and a cutover only changes which side writes to one unit's tables.

We drew the lines with three questions:

1. **Which tables are written in the same transaction?** They go in the same unit and the same stream. That's the only hard rule. Break it and the new side can show a payment without its ledger entry. It's why authorisations, the ledger and the audit log's current month shared one subscription, and one worker.
2. **Which service writes them?** We grouped by writer, so each cutover was simply "move this service's writes."
3. **What breaks if the data is a second old?** Reads across units work on either side, just slightly behind. Inserts are trickier: a payment against a merchant category created seconds ago on the other side fails its foreign key. A new merchant doesn't take a payment for hours, so a second of lag there is harmless. A new category can be used on the very next payment, so we froze those until their writer moved.

Inside each unit, two more questions decided how each table travelled: how big is it, and how often does it change?

<style>
.zq-wrap{display:grid;grid-template-columns:1.6rem 1fr 1fr;grid-template-rows:auto 1fr 1fr;gap:.6rem;margin:1.25rem 0 .75rem}
.zq-axis{font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--accent);display:flex;align-items:center;justify-content:center}
.zq-axis-v{writing-mode:vertical-rl;transform:rotate(180deg)}
.zq-cell{border:1px solid var(--border);border-radius:.6rem;padding:.75rem .85rem;line-height:1.4;display:flex;flex-direction:column;gap:.2rem}
.zq-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;opacity:.6}
.zq-name{font-weight:700;font-size:1rem}
.zq-eg{font-size:.82rem;opacity:.8}
.zq-verdict{margin-top:auto;padding-top:.5rem;font-size:.82rem;font-weight:600;color:var(--accent)}
.zq-hot{background:color-mix(in srgb,var(--accent) 14%,transparent);border-color:color-mix(in srgb,var(--accent) 40%,transparent)}
.zq-cold{border-style:dashed}
.zq-notes{display:flex;flex-wrap:wrap;gap:.6rem;margin:0 0 1.5rem 2.2rem}
.zq-note{flex:1 1 14rem;border:1px solid var(--border);border-left:4px solid var(--accent);border-radius:.5rem;padding:.55rem .8rem;font-size:.85rem;line-height:1.4}
.zq-note strong{display:block;font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:var(--accent)}
@media (max-width:640px){.zq-notes{margin-left:0}}
</style>
<div class="zq-wrap">
<div></div><div class="zq-axis">Small</div><div class="zq-axis">Large</div>
<div class="zq-axis zq-axis-v">Busy</div>
<div class="zq-cell "><div class="zq-label">Small and busy</div><div class="zq-name">Working tables</div><div class="zq-eg">queues, sessions, job state</div><div class="zq-verdict">Move with the service that owns them</div></div>
<div class="zq-cell zq-hot"><div class="zq-label">Large and busy</div><div class="zq-name">Hot transactional</div><div class="zq-eg">payments, authorisations, ledger</div><div class="zq-verdict">One stream per transaction group, goes last</div></div>
<div class="zq-axis zq-axis-v">Quiet</div>
<div class="zq-cell "><div class="zq-label">Small and quiet</div><div class="zq-name">Reference</div><div class="zq-eg">currencies, merchant categories</div><div class="zq-verdict">Sync first, keep syncing, move the writer last</div></div>
<div class="zq-cell zq-cold"><div class="zq-label">Large and quiet</div><div class="zq-name">Cold</div><div class="zq-eg">old exports, abandoned features</div><div class="zq-verdict">Ask if it needs to move at all</div></div>
</div>
<div class="zq-notes"><div class="zq-note"><strong>Big append only</strong>Audit logs and events sit in two boxes at once. The current month is busy, everything older is cold. Split them along that line.</div><div class="zq-note"><strong>Problem tables</strong>No primary key, large objects, triggers. They turn up in any box. Fix them before their wave, not during it.</div></div>

The big win was in the append only box. The audit log was 5 TB, and its old partitions never change, so we copied 4.5 TB of them ahead of time and replicated only the current month. The cold box saved another 1.3 TB: with compliance's blessing, the old exports went to object storage and never moved at all.

## Plan the waves backwards

The most useful planning habit I know: don't start from the first cutover and see where you end up. Start from the date you can't move and work backwards.

<style>
.zp-strip{display:flex;gap:3px;margin:1.25rem 0 .4rem;border-radius:.5rem;overflow:hidden}
.zp-blk{padding:.6rem .55rem;font-size:.78rem;line-height:1.3;background:color-mix(in srgb,var(--accent) 10%,transparent)}
.zp-blk strong{display:block;font-size:.82rem;color:inherit!important}
.zp-prep{flex:4}.zp-waves{flex:5;background:color-mix(in srgb,var(--accent) 22%,transparent)}.zp-spare{flex:1.4;background:repeating-linear-gradient(135deg,color-mix(in srgb,var(--accent) 14%,transparent) 0 6px,transparent 6px 12px)}.zp-last{flex:1.4;background:var(--accent);color:var(--background)}.zp-fall{flex:2.4}
.zp-hard{flex:1.2;background:var(--foreground);color:var(--background)}
.zp-dir{display:flex;justify-content:space-between;font-size:.72rem;opacity:.65;margin-bottom:1.25rem}
@media (max-width:640px){.zp-strip{flex-direction:column}.zp-blk{flex:none!important}}
.zx{border:1px solid var(--border);border-radius:.6rem;padding:.8rem .9rem;margin:1.25rem 0 1rem}
.zx-title{font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:var(--accent);margin-bottom:.6rem}
.zx-row{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:3px}
@media (max-width:640px){.zx-row{grid-template-columns:repeat(4,minmax(0,1fr))}}
.zx-c{border-top:3px solid var(--accent);background:color-mix(in srgb,var(--accent) 8%,transparent);padding:.35rem .4rem;font-size:.72rem;line-height:1.25}
.zx-c b{display:block;font-size:.66rem;opacity:.65;font-weight:600}
.zx-hot{background:color-mix(in srgb,var(--accent) 20%,transparent)}
.zx-free{border-top-style:dashed;background:transparent;border:1px dashed color-mix(in srgb,var(--accent) 50%,transparent)}
.zx-ext{border-top:3px solid var(--border);background:transparent;opacity:.6}
.zx-note{font-size:.78rem;opacity:.8;margin-top:.6rem;line-height:1.4}
</style>
<div class="zp-strip" role="figure" aria-label="Planning timeline, built backwards from the hard date: preparation, waves, a free spare, the last cutover, the fallback period, then the hard date">
<div class="zp-blk zp-prep"><strong>Preparation</strong>inventory, network, schema, bulk copy</div>
<div class="zp-blk zp-waves"><strong>Waves</strong>one a week, cheapest first</div>
<div class="zp-blk zp-spare"><strong>Free spare</strong>before the riskiest</div>
<div class="zp-blk zp-last"><strong>Last cutover</strong></div>
<div class="zp-blk zp-fall"><strong>Fallback</strong>about two weeks</div>
<div class="zp-blk zp-hard"><strong>Hard date</strong>lease, support, contract</div>
</div>
<div class="zp-dir"><span>time runs this way →</span><span>← plan this way</span></div>

1. **Find the hard date.** The lease end, the end of support, the contract renewal.
2. **Subtract the fallback.** The old database stays alive and current for a while after the last cutover. Two weeks is typical.
3. **That's your last cutover.**
4. **Place the waves backwards, a week apart,** cheapest first, with a free spare right before the riskiest one.
5. **What's left is preparation.** If that's under about four weeks, push back on the date now, not in week six.

Two rules kept our calendar honest. A spare after the hard date isn't a spare, it's a lease extension. And a freeze lasts until the writer moves, so if a wave slips, the freeze slips with it.

Here's how it came out for the payments team:

<div class="zx" role="figure" aria-label="Payments plan across eight Sundays">
<div class="zx-title">Worked example: the payments plan</div>
<div class="zx-row">
<div class="zx-c"><b>Sun 1</b>Wave 1 back office</div>
<div class="zx-c"><b>Sun 2</b>Wave 2 merchants</div>
<div class="zx-c"><b>Sun 3</b>Wave 3 payouts</div>
<div class="zx-c zx-free"><b>Sun 4</b>Free spare</div>
<div class="zx-c zx-hot"><b>Sun 5</b>Wave 4 payments core</div>
<div class="zx-c"><b>Sun 6</b>Wave 5 reference data</div>
<div class="zx-c zx-ext"><b>Sun 7</b>Needs extension</div>
<div class="zx-c zx-ext"><b>Sun 8</b>Lease weekend</div>
</div>
<div class="zx-note">Before Sunday 1: the 4.5 TB of old audit partitions, bulk copied. Never moved: the 1.3 TB of old exports, archived.</div>
</div>

The lease was the hard date. Two weeks of fallback put the last cutover on Sunday 6, which left about five weeks to prepare. Payments, the riskiest wave at 3.5 TB, got the free spare in front of it. Reference data went last, so new currencies and categories were frozen from Sunday 5 until it moved.

## What's next

By this point we had a downtime number everyone had agreed to, logical replication carrying the upgrade, and the database sorted into waves. [Part 2](/posts/zero-downtime-migrations-execution) is about running them: proving the data matches, the five minute cutover, an honest way back, and a lot of rehearsal.

## References

1. [Logical Replication](https://www.postgresql.org/docs/16/logical-replication.html), PostgreSQL 16 documentation
2. [Logical Replication Restrictions](https://www.postgresql.org/docs/16/logical-replication-restrictions.html), PostgreSQL 16 documentation, covering DDL, sequences and large objects
3. [Log-Shipping Standby Servers](https://www.postgresql.org/docs/16/warm-standby.html), PostgreSQL 16 documentation, including the note on major versions
4. [Versioning Policy](https://www.postgresql.org/support/versioning/), PostgreSQL
5. [PostgreSQL 12 Release Notes](https://www.postgresql.org/docs/release/12.0/), including CTE inlining and removal of WITH OIDS
6. [PostgreSQL 14 Release Notes](https://www.postgresql.org/docs/release/14.0/), including the SCRAM password default
7. [PostgreSQL 15 Release Notes](https://www.postgresql.org/docs/release/15.0/), including public schema permissions
8. [PostgreSQL 13 Release Notes](https://www.postgresql.org/docs/release/13.0/), including publish_via_partition_root and max_slot_wal_keep_size
9. [PostgreSQL 16 Release Notes](https://www.postgresql.org/docs/release/16.0/), including parallel apply and the origin option
