---
author: Venkatesh Periyathambi
pubDatetime: 2026-03-24T09:00:00Z
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

[Part 1](/posts/rag-retrieval-nondeterminism-causes) walked through about ten different reasons an identical query can return a different top 10. This post is about finding out which one is yours and what to do about it.

One thing to get straight before any of it. The goal is almost never determinism.

Byte stable retrieval is achievable, but you pay for it in throughput, freshness and replica independence, and most teams who think they want it actually want something else: results that don't move _enough to matter_, and a way to know when that changes. That reframe makes the whole problem tractable. You stop trying to eliminate variance and start bounding it.

## Start with the step that costs nothing

Before you change any config, run one request twice and diff the trace.

![A diagnostic ladder with eight rungs, cheapest at the top. Rung one, trace-diff two identical requests. Rung two, log scores not just IDs. Rung three, bypass caches. Rung four, pin the query vector bytes. Rung five, turn the reranker off. Rung six, turn fusion off and run each leg alone. Rung seven, pin to one shard and one replica with partial results disabled. Rung eight, compare against brute force exact search. Each rung is annotated with what it rules out when the variance disappears](@/assets/images/rag-nondeterminism-fixes/01-diagnostic-ladder.svg)

Most investigations end on the first rung, and it costs you nothing but logging. Instrument a single request scoped trace carrying:

- the raw query, and every rewritten version of it
- a hash of the query embedding bytes
- the fully materialised filter expression, with relative times resolved to absolute timestamps and the principal list expanded
- the experiment arm, if you run experiments
- cache hit or miss per tier, with entry age
- per leg candidate ID lists **with raw scores**
- fusion parameters, the fused list, the reranker's input hash and its output scores
- shard success and timeout counts
- index version and embedding model version

Run it twice, diff field by field. The first field that differs names your layer. That's the whole technique, and it beats guessing by a wide margin.

The second rung is nearly as cheap and catches a surprising number of cases: **log scores, not just document IDs.** If the score multiset is identical across runs and only the IDs permute, you have a tie breaking problem. Stop there, skip to the total order fix below, and go home early.

After that, pin one stage at a time, working down the ladder. Each rung has a clean interpretation: if the variance disappears when you pin stage N, stage N or something upstream of it is responsible.

The last rung is worth its own sentence. **Brute force the full filtered set to get the true top K, then report recall@10 per run.** This is what separates "my ordering churns" from "my index is inaccurate", and they are completely different problems. A stable index with 70% recall is a tuning problem. An unstable index with 95% recall is a reproducibility problem. Teams routinely spend weeks on the second when they have the first.

One more trick: **replay the pinned input under load.** Variance that only appears when the system is busy means dynamic batching, deadline truncation, queue rejection or partial results. Variance that appears when idle is structural.

## Fixes by layer

### Text preparation

This is where the real correctness bugs live, so fix it first even if it isn't causing your flapping.

- **One normalizer, one function, called by both paths.** Not two implementations that agree today. One function, shared by ingest and query. Pick a canonical form, NFC unless you have a reason, and document it.
- **Pin and vendor the tokenizer.** Don't resolve it from a hub at runtime.
- **Truncate explicitly, in tokens, with a declared policy.** Decide whether over length input is an error or a silent trim, and make it the same on both sides.
- **Derive chunk IDs from content**, something like `hash(doc_id, start_offset, end_offset, normalizer_version, chunker_version)`, rather than from enumeration order. Now a re-ingest that produces identical text produces identical IDs, and a re-ingest that doesn't is immediately visible.
- **Gate it in CI.** Store `sha256(normalized_text)` and `sha256(token_ids)` per chunk. Re-run ingest on fixed input and assert set equality. This catches a tokenizer bump or a library upgrade the day it lands instead of three weeks later.

If you use a semantic chunker that thresholds on embedding similarity, either cache its boundary decisions or accept that your chunk set is not reproducible. A float wobble flipping a boundary changes chunk text by whole sentences, and that is a much bigger problem than anything else in this post.

### Embedding

- **Pin dated model IDs**, never floating aliases, wherever the provider offers them.
- **Store the vector space version on every vector.** Model ID, model version, tokenizer version, normalization form, dimensions, embedding type, and a content hash. Treat "which vector space is this index in" as a first class immutable property, and never mix two versions in one index.
- **Make the query path and the document path numerically identical.** Same batch size, same padding policy, same dtype, same normalization. Right now you almost certainly embed documents in large offline batches and queries one at a time, which puts them through different kernels. Sorting inputs into length buckets helps, because then batch composition is a deterministic function of the input set rather than of arrival order.
- **Compute the L2 norm and the division in fp32**, whatever precision the model runs in. A norm computed in fp16 adds roughly 5e-4 relative error to every component at the very last step, which can be the single largest error source in an otherwise clean pipeline.
- **Run a canary corpus.** Two hundred fixed strings embedded hourly, full vectors stored, alarming on cosine drift against the day one baseline. Small drift means host or kernel variation. Large drift means the model changed and you need to reindex. Watch the distribution rather than just the maximum, because bimodality is the fingerprint of a heterogeneous fleet or an A/B split.
- Only after all of that, pin container digests, library versions and GPU SKU, and disable autotuning and reduced precision accumulation. This is necessary for bitwise reproducibility and it fixes the smallest term in the whole system. Doing it first is the classic mistake.

### Index and search

- **Build once, ship the artifact.** The single highest leverage change here. Instead of letting every replica index the same documents independently, build the index once and replicate the files. Now your replicas are byte identical and the whole replica divergence class disappears.
- **Force merge read only indexes to one segment.** Fewer segments means fewer per segment candidate pools to merge, and it usually raises recall for the same candidate budget as a bonus.
- **Pin routing** per query or per session when you need consistency within a user's interaction.
- **Set the candidate budget well above K.** `ef_search` or `nprobe` or whatever your engine calls it. A tight budget doesn't create instability on its own, but it amplifies every other cause into the visible top 10 rather than leaving it at rank 400. Sweep it upward and watch stability improve monotonically; the point where it stops improving tells you the residual is something else.
- **Take timeouts and visit budgets out of the path** where reproducibility matters, or at least set them above p99.9 rather than near the median. Pre-warm so the index is resident, and size memory so eviction never fires. These budgets are functions of machine state, which is why they produce variance that correlates with latency.
- **Single threaded search** for paths that must be reproducible, or make sure the candidate budget is per partition and fixed rather than globally shared.
- **Keep deletes under control.** Deleted vectors usually stay in the graph as routing nodes, consuming visit budget while contributing nothing, until compaction purges them and rebuilds the graph. Regular compaction, or a vacuum discipline if you're on Postgres.
- **Homogeneous instance types.** Mixed CPU generations select different SIMD kernels, which score the same pair of vectors slightly differently.

### Pipeline

- **Replace candidate relative score normalization.** If you min-max normalize using bounds taken from the returned candidate set, the normalizer depends on its own output and one document entering at rank 80 reshuffles your top 10. Either calibrate global bounds offline and clip to them, or switch to rank based fusion.
- **If you use RRF, set the fusion depth well above the final K.** That moves the window boundary, where a document's contribution drops to zero, far away from the ranks a user sees.
- **Get global term statistics** if you run hybrid search across shards. Lexical scoring computed from per shard document frequency means the same document scores differently depending on which shard holds it. The distributed frequency search mode fixes it at the cost of an extra round trip.
- **Disable partial results on precision critical paths.** Fail loudly and retry instead of returning a 200 with six results. And assert on every response that every shard succeeded and nothing timed out. If you aren't checking those fields, you genuinely do not know how often this happens.
- **Fix your cache keys.** Include embedding model ID, index version, the resolved filter expression, tenant, and a hash of the ACL set. Add a bypass flag for debugging. Be careful with semantic caching on precision critical paths, because whether you hit depends on what other users put in the cache. Prefer a shared cache over per pod caches, so load balancer placement doesn't decide outcomes.
- **Resolve relative times once, upstream.** Turn `last 7 days` into an absolute timestamp at the edge and thread it through the whole request. This fixes the drifting window and makes your cache key sound at the same time.
- **Pre-filter rather than post-filter** where the engine supports it, so an ACL change at rank 40 can't change how many documents survive to fill your ten.
- **Seed deliberately.** Any RNG in the request path should be seeded from a stable key, something like a hash of query plus user plus day. Set temperature to zero in query rewriting and cache the rewrites. Log the experiment arm. If you use an LLM reranker, canonicalise the candidate order before sending it so position bias is at least reproducible, and treat a parse failure as an error rather than a silent passthrough.

## The cheap fix most people skip

Here is the highest leverage change per line of code in either of these posts.

**Make your ranking a total order.**

```text
sort by (-round(score, 6), stable_doc_id)
```

![Two ranking tables side by side. On the left, raw scores with tiny differences in the seventh decimal place produce two different orders across two runs. On the right, the same scores rounded to six decimal places become equal, and the stable document ID breaks the tie, so both runs produce an identical order](@/assets/images/rag-nondeterminism-fixes/02-total-order.svg)

Round the score to just above your measured noise floor, then break ties on an immutable external ID. Any perturbation smaller than the rounding step now cannot change your output at all. You have converted an unbounded, undiagnosable non-determinism into a bounded one that you chose deliberately and can write down.

Two things pair with it:

- **Deduplicate near identical chunks at ingest.** This removes the collapsed score gap pathology at source. Versioned documents, repeated boilerplate, templated pages and overlapping chunks of the same passage are what make scores cluster densely enough to reorder, and no precision setting fixes that.
- **Retrieve with margin.** Fetch 30, rerank, return 10. The fragile boundary is wherever you cut, so move the cut away from where the user sees it.

## Make it a metric, not a bug report

The last piece, and the one that keeps this fixed.

Track **Jaccard@10** and a rank correlation measure, Kendall tau or rank biased overlap, between repeated identical runs. Continuously, as an SLI, and gate releases on it.

A binary "is retrieval deterministic" question hides the regression, because the answer is always no and everyone stops caring. A number catches the day somebody changed the fusion depth, added a shard, swapped an embedding model or turned on quantization. Pair it with recall@10 against a periodically recomputed brute force ground truth, so you can tell apart the two failure modes that look identical from the outside.

And when you report these, bucket by local filter pass rate and by tenant. Pooled averages hide exactly the cases that break, which is the same lesson as [the filtering cliff](/posts/vector-search-pre-filter-post-filter-cliff).

## What good looks like

You will not get set equality, and you shouldn't want it. What you should have:

- One shared text normalization path, gated in CI
- Model and index versions stamped on every vector, pinned, never mixed
- Index built once as an artifact and replicated, not rebuilt per replica
- A total order on results with a stable tie breaker
- Candidate budgets generous enough that they aren't the binding constraint
- Partial results treated as failures on paths where precision matters
- Jaccard@10 and recall@10 on a dashboard, bucketed, release gated

That gets you variance that's small, bounded, explainable, and monitored. Which is what people actually mean when they say they want reproducible retrieval.
