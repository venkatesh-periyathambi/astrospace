---
author: Venkatesh Periyathambi
pubDatetime: 2026-03-24T09:00:00Z
modDatetime: 2026-10-24T09:00:00Z
title: "Fixing Unstable RAG Retrieval (Part 2)"
slug: rag-retrieval-nondeterminism-fixes
featured: false
draft: false
tags:
  - rag
  - vector-search
  - embeddings
  - ann
  - search
description: "How to find out which layer is making your RAG results move, in an order that costs almost nothing to start, and what to actually do about each one."
---

In [Part 1](/posts/rag-retrieval-nondeterminism-causes) I went through about ten reasons an identical query can come back with a different top 10. This part is about finding out which one is yours, and what to do about it.

First, though, the thing I end up saying on almost every one of these calls: you probably don't want determinism.

You can get byte stable retrieval, but you pay for it in throughput, freshness and how independently your replicas can run. Most teams who say they want it actually want something else. They want results that don't move _enough to matter_, and a way to find out when that changes. Once you look at it that way the problem gets a lot more manageable. You stop trying to get rid of variance and start putting a bound on it.

## Start with the check that costs nothing

Before changing any config, run the same request twice and compare the traces.

![A diagnostic ladder with eight rungs, cheapest at the top. Rung one, trace-diff two identical requests. Rung two, log scores not just IDs. Rung three, bypass caches. Rung four, pin the query vector bytes. Rung five, turn the reranker off. Rung six, turn fusion off and run each leg alone. Rung seven, pin to one shard and one replica with partial results disabled. Rung eight, compare against brute force exact search. Each rung is annotated with what it rules out when the variance disappears](@/assets/images/rag-nondeterminism-fixes/01-diagnostic-ladder.svg)

Most investigations I've seen end on the first rung, and it costs nothing but some logging. Give each request a trace that carries:

- the raw query, and every rewritten version of it
- a hash of the query embedding bytes
- the full filter expression, with relative times turned into absolute timestamps and permission lists expanded
- the experiment arm, if you run experiments
- cache hit or miss for each cache tier, and how old the entry was
- each leg's candidate IDs **with their raw scores**
- the fusion settings, the fused list, a hash of what went into the reranker and the scores that came out
- how many shards succeeded and how many timed out
- the index version and the embedding model version

Run the request twice and diff the traces field by field. The first field that differs tells you the layer. That's the whole technique, and it beats guessing every time.

The second rung is nearly as cheap and catches a surprising number of cases: **log scores, not just document IDs.** If the scores are identical across runs and only the IDs swap places, it's a tie breaking problem. You can stop there and jump to the total order fix below.

After that, pin one stage at a time and work down the ladder. If the variance disappears when you pin a stage, that stage, or something before it, is your culprit.

The last rung deserves its own paragraph. **Brute force the full filtered set to get the true top K, then measure recall@10 on each run.** That's what separates "my ordering moves around" from "my index isn't accurate", and they're completely different problems. A stable index with 70% recall needs tuning. An unstable index with 95% recall has a reproducibility problem. I've watched teams spend weeks on the second when what they actually had was the first.

One more trick: **replay the pinned request under load.** Variance that only shows up when the system is busy points at dynamic batching, timeouts, rejected requests or partial results. Variance that shows up when it's idle is structural.

## Fixes, layer by layer

### Text preparation

This is where the real correctness bugs live, so fix it first, even if it isn't what's making your results flap.

- **Use one normalizer for both paths.** Not two implementations that happen to agree today. One function, called at ingest and at query time. Pick a form, NFC unless you have a reason not to, and write it down.
- **Pin the tokenizer, and ship it with your code.** Don't pull it from a model hub at runtime.
- **Truncate on purpose, in tokens.** Decide whether over length input is an error or gets trimmed, and do the same on both paths.
- **Build chunk IDs from content**, something like `hash(doc_id, start_offset, end_offset, normalizer_version, chunker_version)`, not from the order chunks came out in. Then re-ingesting identical text gives identical IDs, and anything that changed shows up straight away.
- **Check it in CI.** Store a hash of the normalized text and of the token IDs for each chunk, re-run ingest on a fixed sample, and assert they match. That catches a tokenizer or library bump the day it lands, not three weeks later.

If you use a semantic chunker that splits on an embedding similarity threshold, either cache its decisions or accept that your chunks won't reproduce. A tiny float wobble that moves a boundary changes chunk text by whole sentences, which is a far bigger effect than anything else in this post.

### Embedding

- **Pin dated model IDs**, never floating aliases, wherever the provider offers them.
- **Stamp every vector with its vector space.** Model ID, model version, tokenizer version, normalization form, dimensions and a content hash. Treat "which vector space is this index in" as a fixed property of the index, and never mix two in one index.
- **Embed queries and documents the same way.** Same batch size, padding, data type and normalization. Today you almost certainly embed documents in big offline batches and queries one at a time, which sends them through different kernels. Grouping inputs into length buckets helps, because then batching depends on the inputs rather than on what arrived when.
- **Compute the vector norm and the division in fp32**, whatever precision the model runs in. A norm computed in fp16 adds about 5e-4 relative error to every component at the very last step, which can be the biggest single error in an otherwise clean pipeline.
- **Run a canary set.** Embed a couple of hundred fixed strings every hour, store the full vectors, and alert on drift from the day one baseline. Small drift means host or kernel differences. Large drift means the model changed and you need to reindex. Watch the whole distribution, not just the maximum, because two clusters of results is the fingerprint of a mixed fleet or an A/B split.
- **Only then**, pin container images, library versions and GPU type, and turn off autotuning and reduced precision accumulation. That's what bitwise reproducibility takes, and it fixes the smallest effect in the whole system. Doing it first is the classic mistake.

### Index and search

- **Build the index once and ship it.** This is the highest leverage change in this layer. Instead of every replica indexing the same documents on its own, build once and copy the files. Now the replicas really are identical, and replica divergence goes away completely.
- **Merge read only indexes down to one segment.** It takes per segment merging out of the picture and makes latency more predictable. It can change recall in either direction, because some engines search each segment separately, so measure recall again afterwards.
- **Pin routing** per query or per session when a user needs consistent results within one conversation.
- **Give the search a candidate budget well above K.** That's `ef_search`, `nprobe` or whatever your engine calls it. A tight budget doesn't cause instability on its own, but it drags every other cause up into the visible top 10 instead of leaving it down at rank 400. Raise it in steps. Stability usually improves, and the point where it stops improving tells you the rest is coming from somewhere else.
- **Take timeouts and visit limits out of the path** where reproducibility matters, or at least set them above p99.9 rather than near the median. Warm the index up so it's in memory, and size memory so nothing gets evicted. These limits depend on machine state, which is why the variance they cause tracks latency.
- **Search single threaded** on paths that must reproduce, or make sure each partition gets its own fixed budget instead of sharing one.
- **Keep deletes under control.** Deleted vectors usually stay in the graph as routing nodes, using up visit budget without contributing anything, until compaction cleans them out. Compact regularly, or vacuum if you're on Postgres.
- **Use one instance type.** Mixed CPU generations pick different SIMD kernels and score the same pair of vectors slightly differently.

### Pipeline

- **Stop normalizing scores against the candidate set.** Min-max with bounds taken from this run's own candidates means one document entering at rank 80 reshuffles your top 10. Either calibrate fixed bounds offline and clip to them, or switch to rank based fusion.
- **If you use RRF, fuse well beyond the final K.** That pushes the cliff, where a document's contribution drops to zero, far away from anything a user sees.
- **Use global term statistics** for hybrid search across shards. In Elasticsearch and OpenSearch that's the `dfs_query_then_fetch` search type. It costs an extra round trip, and in return a document scores the same whichever shard it lives on.
- **Turn off partial results on paths where precision matters.** Fail loudly and retry rather than return a 200 with six results. And check on every response that every shard succeeded and nothing timed out. If you're not checking, you really don't know how often it happens.
- **Fix your cache keys.** Include the embedding model ID, index version, resolved filter, tenant and a hash of the permission set, and add a bypass flag for debugging. Be careful with semantic caching on precision critical paths, since a hit depends on what other users put there. A shared cache beats one per pod, so that which pod you land on doesn't decide the answer.
- **Resolve relative times once, at the edge.** Turn "last 7 days" into a fixed timestamp when the request arrives and pass it all the way through. That fixes the drifting window and makes your cache keys correct at the same time.
- **Filter inside the search rather than after it**, where your engine supports it, so a permission change at rank 40 can't change how many results are left to fill your ten.
- **Seed on purpose.** Any random number in the request path should be seeded from something stable, like a hash of the query, the user and the date. Set temperature to zero for query rewriting and cache the rewrites. Log the experiment arm. If an LLM reranks, sort the candidates into a fixed order before sending them, so its position bias is at least repeatable, and treat a response it can't parse as an error, not a silent pass through.

## The cheap fix most people skip

If I could only make one change, it would be this one. Per line of code, nothing else in either post comes close.

**Make your ranking a total order.**

```text
sort by (-round(score, 6), stable_doc_id)
```

![Two ranking tables side by side. On the left, raw scores with tiny differences in the seventh decimal place produce two different orders across two runs. On the right, the same scores rounded to six decimal places become equal, and the stable document ID breaks the tie, so both runs produce an identical order](@/assets/images/rag-nondeterminism-fixes/02-total-order.svg)

Round the score to just above your measured noise floor, then break ties on an ID that never changes. Noise smaller than the rounding step now almost never changes the order. The one exception is a score sitting right on a rounding edge, which can still tip either way, so you'll still see the odd flip. But you've gone from variance nobody can explain to a small, known amount that you chose and can write down.

Two things go well with it:

- **Remove near duplicate chunks at ingest.** That fixes the collapsed score gap problem at the source. Versioned documents, repeated boilerplate, templated pages and overlapping chunks are what pack scores tightly enough to reorder, and no precision setting changes that.
- **Retrieve with some margin.** Fetch 30, rerank, return 10. The fragile boundary is wherever you cut, so move the cut away from what the user sees.

## Make it a metric, not a bug report

This is the piece that keeps it fixed.

Track **Jaccard@10** and a rank correlation, Kendall's tau or rank biased overlap, between repeated identical runs. Track it continuously, like any other service level indicator, and gate releases on it.

Asking "is retrieval deterministic?" doesn't help, because the answer is always no and everyone stops paying attention. A number catches the day someone changes the fusion depth, adds a shard, swaps the embedding model or turns on quantization. Pair it with recall@10 against a brute force ground truth you recompute now and then, so you can tell the two failure modes apart. From the outside they look identical.

When you report these numbers, break them down by how selective the filters were and by tenant. Averages hide exactly the cases that break, which is the same lesson as [the filtering cliff](/posts/vector-search-pre-filter-post-filter-cliff).

## What good looks like

You won't get identical results every time, and you shouldn't want to. Here's what I'd want to see instead:

- One shared text normalization path, checked in CI
- Model and index versions stamped on every vector, pinned and never mixed
- The index built once and copied, not rebuilt on every replica
- A total order on results, with a stable tie breaker
- Candidate budgets big enough that they're never the limiting factor
- Partial results treated as failures where precision matters
- Jaccard@10 and recall@10 on a dashboard, broken down, and gating releases

That gets you variance that's small, bounded, explained and watched. In my experience, that's what people actually mean when they ask for reproducible retrieval.
