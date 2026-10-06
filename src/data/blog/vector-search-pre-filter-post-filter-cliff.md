---
author: Venkatesh Periyathambi
pubDatetime: 2026-10-06T09:00:00Z
title: "The Pre-Filter and Post-Filter Cliff in Vector Search"
slug: vector-search-pre-filter-post-filter-cliff
featured: false
draft: false
tags:
  - vector-search
  - embeddings
  - ann
  - search
  - rag
description: "Why a metadata filter can make vector search suddenly slow or silently incomplete, and how to pick between pre-filtering, post-filtering, and filter-aware search."
---

"Our vector search works fine until the user picks a tenant and a date range. Then it either gets slow or returns three results instead of ten."

That is the filtering cliff, and almost every team building retrieval hits it in month two.

Vector search answers "which items are closest to this query?" A metadata filter answers "which items are allowed to participate?" Each is easy alone. Combining them efficiently is where engines differ — and where your latency and recall budgets go to die.

One note before we start: the labels are used inconsistently across engines. In this post, **post-filtering** means retrieve vector candidates first, then apply the predicate. **Pre-filtering** means resolve the eligible set first, then rank vectors within it. Your engine may swap the names; the trade-off underneath is identical.

## Table of Contents

---

## Two plans, two failure modes

![Two pipelines side by side. Post-filter: query vector, ANN search over the full index, top-M candidates, apply predicate, survivors, return top-K. Pre-filter: query vector, evaluate predicate, eligible ID set, rank vectors in set, scored matches, return top-K. The predicate step is highlighted in each](@/assets/images/vector-filter-cliff/01-two-plans.svg)

The highlighted box is where the predicate lands, and everything downstream follows from that one choice. Neither plan is wrong. Each has a region of the workload where it is the only sane option, and a region where it falls off a cliff.

## The post-filter cliff: silent incompleteness

Post-filtering is the default in most stacks because it asks nothing of the index. Retrieve `M`, drop what fails the predicate, return `K`.

It works beautifully while most vectors near the query pass the filter. Then the pass rate drops:

```text
usable results ≈ candidates retrieved × local filter pass rate
               ≈ 100 × 1%
               ≈ 1
```

You asked for ten results and got one. The engine did nothing wrong — it returned the nearest 100 vectors faithfully. They just belonged to the wrong tenant, region, or quarter.

The reflex fix is to over-fetch. At a 1% pass rate you need roughly 1,000 candidates to _expect_ ten matches, and more for any safety margin. So completeness falls while work rises, at the same time — and not gradually:

![A chart of fill rate against local filter pass rate at a fixed over-fetch budget of ten times K. Fill rate holds at 100 percent from a 100 percent pass rate down to 10 percent, then drops sharply to about 30 percent at a 3 percent pass rate and under 10 percent below that, forming a knee rather than a gradual slope](@/assets/images/vector-filter-cliff/02-fill-rate-cliff.svg)

The shape, not the exact numbers, is the point. A user narrowing a date range by one month can walk your query from the flat part to the floor.

> **Takeaway.** Post-filtering degrades silently. The query returns `200 OK` with two results and nothing in your logs says "incomplete." If you do not measure fill rate, you will hear about this from a customer, not a dashboard.

## The pre-filter cliff: the awkward middle

Pre-filtering gives clean semantics — resolve the eligible set, then score only inside it. If the filter leaves 500 rows, scoring all 500 exactly is both fast and perfectly accurate. Small filtered sets are the easy case, and exact search is genuinely the right answer there.

The pain is the middle: a set too large to brute-force cheaply, too sparse for graph traversal to work.

Most ANN indexes are graphs, and traversal depends on neighbours as stepping stones. A vector that fails your filter can still be the only bridge to one that passes:

![A graph index. The query vector connects to two nodes the filter excludes, and the second of those is the only link to a cluster of four vectors that pass the filter. That bridge node is ringed in red and labelled as excluded by the filter and the only bridge to every vector that passes it](@/assets/images/vector-filter-cliff/03-graph-bridge.svg)

Block the bridge and recall collapses. Allow traversal through it but collect only matches, and the search burns visits on nodes it must discard. Materialise every eligible ID and score it directly instead, and you are back to a scan whose cost grows with the filtered population.

> **Takeaway.** Pre-filtering trades a correctness problem for a cost problem. It cannot return an invalid result, but it can blow your p99 — and in graph indexes it can quietly lose recall, which looks exactly like a bad embedding model.

## The number that actually matters

Global selectivity — "this filter matches 10% of the table" — is the number everyone reaches for, and it is the wrong one. What governs behaviour is the **local pass rate in the neighbourhood of the query vector**.

![Two query neighbourhoods under the same running-shoes filter. Around a query for marathon footwear, most vectors inside the top-K neighbourhood pass the filter, giving a local pass rate of about 65 percent and a full result set. Around a query for laptop batteries, almost none of the nearby vectors pass, giving a local pass rate of about 2 percent and roughly one result out of ten, with the matching vectors sitting far outside the neighbourhood](@/assets/images/vector-filter-cliff/04-local-vs-global.svg)

Same predicate. Same 10% global selectivity. Opposite behaviour.

Metadata and embedding distance are correlated, often strongly. A globally rare category can form a tight semantic cluster and be trivial to search; a globally common one can be absent from a given neighbourhood. This is why a planner reasoning only from row counts picks the wrong strategy, and why a benchmark built on random predicates tells you almost nothing about production.

> **Takeaway.** Stop quoting global selectivity in design docs. Ask instead: for the filters our users actually send, what fraction of the top few hundred neighbours survive?

## Pick the plan per query, not per system

Treat filtering as a runtime planning decision with a correctness-preserving fallback:

| Situation                         | Plan                                      |
| --------------------------------- | ----------------------------------------- |
| Eligible set very small           | Pre-filter, exact vector scoring          |
| High local pass rate              | Post-filter with modest over-fetch        |
| Selective or embedding-correlated | Filter-aware ANN traversal                |
| Returned fewer than `K`           | Raise the budget, then fall back to exact |

For the post-filter path, a reasonable starting budget is:

```text
candidate budget ≈ K ÷ estimated local pass rate
```

Treat that as an estimate, cap the over-fetch, and keep the fallback. And set the exact-versus-approximate threshold from _your_ dimensions, index, hardware, and latency target — there is no portable percentage that is correct across engines.

Filter-aware ANN is the third option and increasingly the right one. Research systems such as Filtered-DiskANN and ACORN push the predicate _into_ traversal rather than applying it before or after, which is what makes the selective-and-correlated case tractable at all. Several commercial engines now ship some version of this; whether yours does — and whether it covers your predicate shapes, not just single-label equality — is worth asking your vendor directly.

> **Takeaway.** "Which filtering strategy did we choose?" is the wrong question to settle at design time. The right artefact is a planning rule plus a fallback that guarantees you never return an incomplete result silently.

## What to measure

Benchmarking an unfiltered index and assuming the numbers carry over is the most common mistake here. Test the filter combinations users actually send, and track:

- **Fill rate** — how often the query returns all `K` results. The cliff detector.
- **Filtered recall** — against exact search over the eligible set, not against unfiltered search.
- **p95 and p99 latency** — averages hide knees by construction.
- **Candidates examined per result** — the work the cliff is costing you.
- **Pass-rate buckets** — 100%, 10%, 1%, 0.1%. Report per bucket, never pooled.
- **Correlated vs random predicates** — the gap between them is your correlation penalty.

Add tenant and category skew to that matrix. A plan tuned on your largest tenant often behaves completely differently across a long tail of small ones.

## The takeaway

Pre-filtering protects validity and can turn search into a scan or break graph navigation. Post-filtering preserves index speed and can quietly hand back incomplete results. Both are correct answers to different workloads, and no single choice survives contact with real user filters.

So the question to ask an engine is not "does it support metadata filters?" — they all claim to. It is:

> How does the plan change as the eligible set shrinks and the local pass rate falls, and what does the engine do when it cannot fill `K`?

Measure fill rate, filtered recall, tail latency, and candidates examined across realistic filters, and the cliff stops being a mystery incident. It becomes a curve you can see — and plan around.

---

## References

1. S. Gollapudi et al., "Filtered-DiskANN: Graph Algorithms for Approximate Nearest Neighbor Search with Filters", available at: [https://doi.org/10.1145/3543507.3583552](https://doi.org/10.1145/3543507.3583552) (accessed 6 October 2026).
2. L. Patel et al., "ACORN: Performant and Predicate-Agnostic Search Over Vector Embeddings and Structured Data", available at: [https://arxiv.org/abs/2403.04871](https://arxiv.org/abs/2403.04871) (accessed 6 October 2026).
3. J. Engels et al., "Approximate Nearest Neighbor Search with Window Filters", available at: [https://arxiv.org/abs/2402.00943](https://arxiv.org/abs/2402.00943) (accessed 6 October 2026).
