---
author: Venkatesh Periyathambi
pubDatetime: 2026-03-03T09:00:00Z
modDatetime: 2026-10-24T09:00:00Z
title: "Why Your RAG Search Returns Different Results Every Time (Part 1)"
slug: rag-retrieval-nondeterminism-causes
featured: false
draft: false
tags:
  - rag
  - vector-search
  - embeddings
  - ann
  - search
description: "Same query, same corpus, different top 10. A tour of every layer in a RAG pipeline that can make retrieval results move, from Unicode normalization to replica divergence to fusion scoring."
---

"I ask for the top 10 documents. I run the same query again. I get a different set back. Nothing changed. What is going on?"

I get some version of that question more than any other about RAG. It's confusing because it isn't one bug. In my experience it's about ten different mechanisms that all look the same from the outside. Some are harmless. Some mean your retrieval is quietly wrong. And a couple of them get worse when you fix the others.

This post walks through the causes. [Part 2](/posts/rag-retrieval-nondeterminism-fixes) is about working out which one is yours and what to do about it.

## Where the variance gets in

![A four-layer stack showing where retrieval variance originates. Layer one, text preparation: normalization, tokenizer, chunking, truncation. Layer two, embedding: model version, batch shape, precision. Layer three, index and search: replica copies, traversal order, budget cutoffs, tie-breaking. Layer four, pipeline: fusion scoring, shard merge, reranker, caches, filters. Each layer is annotated with the typical size of the effect it introduces](@/assets/images/rag-nondeterminism/01-four-layers.svg)

Look at the magnitudes on the right before anything else. Between text preparation and embedding, the effects span about seven orders of magnitude. When a team calls me about this, they've almost always started with CUDA flags and floating point precision, which is the smallest effect in the whole system. Very few have looked at text preparation, where the damage is around five orders of magnitude bigger.

So I'll go top down.

## 1. Your text never reached the model unchanged

This is the big one. It's also the boring one, which is why it gets skipped.

Your documents go through one code path: a PDF extractor or HTML scraper, a normalizer, a chunker, a tokenizer. Your queries go through a completely different one: a text box, maybe a trim, then the same tokenizer if you're lucky. Those two paths disagree far more often than anyone expects.

The usual suspects:

- **Mixed Unicode normalization.** NFC on one path, raw bytes on the other. Smart quotes from a PDF, straight quotes from a keyboard. Non breaking spaces, zero width joiners, full width characters. Each one changes the tokens, and a change of tokens can move the vector by 1e-2 or more in cosine terms.
- **Tokenizer version drift.** Someone bumps a library, the pre-tokenizer rules change, and the same string now produces different tokens than it did when you built the index.
- **Truncation counted in different units.** One path cuts at 8,000 characters, the other at 8,000 tokens, and both call it "the limit".
- **Chunk boundaries that don't reproduce.** This one's nastier than it sounds. Semantic chunkers decide where to split by comparing embedding similarity against a threshold, using a model that has tiny numerical noise in it. A wobble in the seventh decimal place flips one boundary, and now a chunk holds a different sentence. Ingest the same document twice and you get two different chunk sets.

If your documents and your queries live in slightly different text spaces, retrieval is a little bit wrong all the time. The flapping top 10 is just the symptom you happened to notice.

## 2. The model behind the API isn't a fixed function

An embedding endpoint is a fleet of machines, not a mathematical function, and that has consequences.

If you call a model by a floating alias rather than a dated snapshot, it can be refreshed underneath you. Then your index sits in the old vector space while your queries are embedded in the new one. Nothing errors. Results just get a bit worse and start to move.

I went looking for a bitwise reproducibility guarantee from the big hosted embedding providers and couldn't find one. That doesn't mean they're unstable, but it does mean you should build as if no such guarantee exists. Pin dated model IDs wherever they're offered, and store the model version on every vector you write.

There's a hardware angle too. GPU math libraries generally only promise bit identical results on the same architecture, with the same number of compute units and the same library version. A fleet that mixes GPU generations can't be bitwise reproducible, however good everyone's intentions are.

## 3. Queries and documents go through different kernels

This one surprises nearly everyone.

You embed documents offline, in big batches, because that's efficient. You embed queries online, one at a time, because latency demands it. Same model, same weights, same text. Slightly different answer.

A batch of one is a skinny matrix multiply and a batch of 64 is a fat one, so they get split up differently, and small batches often get their partial sums recombined across cores. Floating point addition isn't associative, so a different order of additions changes the last few bits. Padding to the longest item in the batch changes things again.

The result is that your query vectors and document vectors come out of different numerical paths through the same model. The difference is tiny, somewhere around 1e-7 to 1e-6 relative, but it's **systematic, not random**, and that's worse than it sounds. If your serving stack batches requests dynamically, your query also gets grouped with whatever else arrived in the same few milliseconds, so your vector depends on other people's traffic.

## 4. How a wobble in the seventh decimal reorders ten results

This feels like it shouldn't be true, so let's do the arithmetic.

Ranking is a comparison. What matters isn't how big your numerical noise is. It's how big it is compared with the **gap between neighbouring scores** at the rank you care about.

![A vertical score axis showing ten retrieved candidates. Ranks one through seven are widely separated. Ranks eight through twelve are clustered tightly together, with the gaps between them smaller than a shaded noise band, so those candidates can swap places and move across the top-ten cutoff line. A second panel shows a near-duplicate corpus where all candidate gaps collapse inside the noise band](@/assets/images/rag-nondeterminism/02-score-gaps.svg)

Two candidates can swap when the gap between them is smaller than about twice the noise. With some real numbers:

- **A clean corpus.** Gaps average around 1e-2 and fp32 noise is around 1e-7, so the chance of a swap at any one rank boundary is about 2e-5. That's rare for a single query. But across the ten boundaries in a top 10, at 10 million queries a day, it's a couple of thousand queries a day getting a reordered list. That's exactly why it reaches you as a bug report nobody can reproduce.
- **A near duplicate corpus.** Gaps collapse towards 1e-6, the swap chance jumps to around 20% per boundary, and reordering becomes normal.
- **bf16 compute.** The noise floor rises to about 1e-3, and even a clean corpus becomes unstable.

The point I want you to take away: **the instability comes from your corpus, not your arithmetic.** Versioned documents, repeated boilerplate, templated pages and overlapping chunks all pack scores tightly together. No precision setting will stabilise a ranking over a corpus full of near duplicates.

And look at which boundary is most fragile: rank 10 against rank 11, right where you cut. In a long tailed score distribution, that's usually where the gaps are smallest.

## 5. ANN search doesn't roll dice

Now the layer everyone blames first, and the correction that clears up most real cases.

**There's no randomness in ANN search at query time.** The HNSW entry point is a stored pointer, not a random pick. Greedy descent, IVF probing and beam search are all deterministic, given the query vector, the index, the parameters and the traversal order. "Approximate" means consistently different from an exhaustive search. It doesn't mean randomly varying.

So the usual first guesses, the random level assignment in HNSW or the random start for k-means centroids, are the wrong suspects for results that change from one second to the next. Those seeds are usually fixed by default anyway. What they do explain is "the answers changed after we reindexed", which is a different complaint with a different fix.

If results move on an index nobody is writing to, it's almost always one of four things.

**Different copies of the index.** Each replica builds its own graph, from its own ingestion order and merge history. Two replicas holding identical documents hold structurally different indexes, and the load balancer picks one per request.

![Two replicas holding the same five documents. Each replica has built a different HNSW graph because the documents arrived in a different order, so the same query entering replica A and replica B traverses different edges and returns a different top three. A note explains that no data differs between the replicas, only the structure built over it](@/assets/images/rag-nondeterminism/03-replica-divergence.svg)

This one catches people because they check that the data matches, find that it does, and conclude the index must be fine. The data was never the problem. The structure built on top of it was never identical.

**Traversal order under concurrency.** When a search is split across threads that share a "best so far" list or a visit budget, thread scheduling decides which candidates get looked at before the cutoff. Different interleaving, different result.

**Early exit on a budget.** Visit limits, query timeouts and memory breakers all stop the search and return whatever's been collected. They depend on _machine_ state, not index state, so they move with cache warmth, garbage collection, noisy neighbours and whether the index is in memory. A cold index can legitimately return a different set from the same index warm. If your odd results are also your slow ones, start here.

**Tie breaking.** Near equal scores sorted by an unstable sort, or by an internal document number that gets reassigned during compaction. There's a hardware version too: different CPU generations pick different SIMD kernels, which score the same pair of vectors slightly differently, so a mixed cluster can score one document inconsistently across nodes.

## 6. Your query gets split up, and some of it goes missing

If your index is sharded, each shard returns its own top K and a coordinator merges them.

![Scatter-gather retrieval across three shards. Each shard returns its own top three. A document that would rank eighth globally sits fourth within its own shard, so it is never returned to the coordinator and cannot appear in the final top ten. A second panel shows one shard timing out and contributing nothing, with the coordinator still returning a successful response](@/assets/images/rag-nondeterminism/04-shard-merge.svg)

There are two separate problems in that picture.

The first is structural. A document that would rank eighth overall, but sits at K+1 within its own shard, never becomes a candidate at all. Change how documents are spread across shards and your top 10 changes without a single score moving.

The second is the quiet one. A shard that times out, trips a breaker, gets its request rejected or pauses for garbage collection contributes nothing, and search engines commonly return a **200 OK with partial results** instead of an error. So your results depend on load and luck. If you're not checking that every shard succeeded on every response, you have no idea how often this is happening.

## 7. Fusion scoring that depends on its own output

If you run hybrid search, combining BM25 with vector similarity, look hard at this one.

The common approach is min-max normalization: take each leg's scores, subtract the minimum and divide by the range. The trouble is that the minimum and maximum come from _this run's own candidates_. So a document drifting in or out at rank 80, far below anything a user sees, rescales every other score, including ones whose raw value never changed. Your top 10 reshuffles because of movement you can't even see.

Reciprocal Rank Fusion avoids that by using only ranks, so it doesn't care about score scales or one leg's outliers. It has its own weak spot, though: a cliff at the edge of each leg's candidate list. A document just outside a leg's returned depth gets exactly zero from that leg, so a document hovering around that depth swings a whole term in the fused score.

Sharding adds a wrinkle. Lexical scoring computes term statistics from each shard's own documents by default, so the same document scores differently depending on which shard holds it and what else lives there. Replicas can disagree too, because deleted documents are still counted until they're merged away.

## 8. Randomness you turned on and then forgot about

Before you blame the database, walk through your own config:

- **Query rewriting, HyDE or multi-query retrieval at a temperature above zero.** This is the one that matters most. A different rewrite means a different query vector and different keywords. Your "identical" query stopped being identical at the first step.
- **MMR or diversity reranking.** There's no random number in it, but it picks greedily, so one swap at position 2 changes the penalty for every slot after it. Small changes upstream turn into a cascade.
- **A/B bucketing on request ID** instead of a stable hash of the user or query, so the same person lands in different arms on back to back calls.
- **Agentic retrieval**, where a model picks the index, filter or tool on each call. Now the whole plan can change, not just the order.
- **Rerankers.** A cross encoder is deterministic given the same input, but that's exactly what you don't have: the candidate list moved, and batching on a shared inference server depends on other users. If you use an LLM to rerank, LLM inference isn't bitwise deterministic even at temperature zero. Batch dependent kernels nudge the logits, and greedy decoding only needs one near tie to flip.

## 9. Caches that tie you to strangers

A semantic cache matches an incoming query against cached ones by a similarity threshold. Whether you land close enough to a cached neighbour depends on **what's in the cache right now**, which depends on everyone else's traffic. Your identical query can hit a stranger's entry on the second run and miss on the third.

Ordinary caches cause a milder version. A hit serves a frozen top 10, and the one request that crosses the expiry recomputes, and can come out different for any reason in this post. The telltale sign is "it changed once, then stayed put for a few minutes".

And check your cache key. An embedding cache keyed on text alone, without the model ID, will happily serve vectors from a model you retired months ago.

## 10. Filters over data that's quietly moving

The last one, and the case where different results are simply correct.

A filter like `now - 7d` is resolved when the request arrives. At sub second precision every request gets a slightly different window, so documents near the edge drift in and out. Permission filters shift with group membership, sharing changes and directory sync delays. Tenant and subscription state changes too.

And if you filter _after_ retrieval rather than inside the query, a permission change on a document at rank 40 changes how many documents survive to fill your ten, which moves rank 9.

## So which one is it?

If I had to bet on a system I'd never seen, in this order:

1. A preprocessing or model version mismatch between the ingest path and the query path
2. Replicas that diverge, plus load balancer routing
3. Min-max fusion, or per shard term statistics
4. Silent partial results under load
5. A temperature above zero somewhere in query rewriting
6. Tie breaking on a corpus full of near duplicates

Only one of those six is really about the vector index, and none of them is about floating point on a GPU.

[Part 2](/posts/rag-retrieval-nondeterminism-fixes) is about finding out which one you've got, starting with the checks that cost almost nothing, and the fixes for each. The short version: stop chasing determinism, and start putting a bound on the variance instead.
