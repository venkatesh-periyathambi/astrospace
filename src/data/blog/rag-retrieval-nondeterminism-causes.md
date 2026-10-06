---
author: Venkatesh Periyathambi
pubDatetime: 2026-10-06T09:00:00Z
title: "Why Your RAG Search Returns Different Results Every Time (Part 1)"
slug: rag-retrieval-nondeterminism-causes
featured: false
draft: true
tags:
  - rag
  - vector-search
  - embeddings
  - ann
  - search
description: "Same query, same corpus, different top 10. A tour of every layer in a RAG pipeline that can make retrieval results move, from Unicode normalization to replica divergence to fusion scoring."
---

"I ask for the top 10 documents. I run the same query again. I get a different set back. Nothing changed. What is going on?"

This is the single most common question I get asked about RAG, and the reason it's confusing is that it isn't one bug. It's about eight different mechanisms wearing the same costume. Some of them are harmless, some mean you have a real correctness problem, and the fix for one makes another worse.

This post is just the causes. [Part 2](/posts/rag-retrieval-nondeterminism-fixes) covers how to work out which one is yours and what to do about it.

## Where the variance can enter

![A four-layer stack showing where retrieval variance originates. Layer one, text preparation: normalization, tokenizer, chunking, truncation. Layer two, embedding: model version, batch shape, precision. Layer three, index and search: replica copies, traversal order, budget cutoffs, tie-breaking. Layer four, pipeline: fusion scoring, shard merge, reranker, caches, filters. Each layer is annotated with the typical size of the effect it introduces](@/assets/images/rag-nondeterminism/01-four-layers.svg)

Look at the magnitudes on the right. The top two layers alone span seven orders of magnitude, and that matters more than anything else in this post. Almost everybody debugging this reaches for CUDA flags and floating point precision, which is the smallest term in the whole system, and never checks the text preparation layer, where the damage is five orders of magnitude larger.

So let's go top down.

## 1. Your text never reached the model unchanged

This is the big one, and it's boring, which is why people skip it.

Your documents go through one code path: a PDF extractor or an HTML scraper, a normalizer, a chunker, a tokenizer. Your queries go through a completely different code path: a browser text box, maybe a trim, then the same tokenizer if you're lucky. Those two paths disagree far more often than anyone expects.

The usual suspects:

- **Mixed Unicode normalization.** NFC in one path, raw bytes in the other. Smart quotes from a PDF, straight quotes from a keyboard. Non breaking spaces, zero width joiners, full width CJK characters. Each one changes the token sequence, and changing tokens moves the vector by 1e-2 or more in cosine terms.
- **Tokenizer version drift.** Someone bumps a library, the pre-tokenizer regex changes, and the same string now produces different tokens than it did when you built the index.
- **Truncation counted in the wrong unit.** One path truncates at 8,000 characters, the other at 8,000 tokens. Both call it "the limit".
- **Chunk boundaries that aren't reproducible.** This one is nastier than it sounds. Semantic chunkers decide where to split by computing embedding similarity and thresholding it, using the same embedding model that has tiny numerical noise in it. A wobble in the seventh decimal place flips a boundary decision, and now your chunk contains a different sentence. Re-ingesting the same document gives you a different chunk set.

If your documents and queries live in subtly different text spaces, your retrieval is quietly wrong all the time. The flapping top 10 is a symptom, not the disease.

## 2. The model behind that API is not a function

An embedding endpoint is a fleet of machines, not a mathematical function, and it's worth being blunt about what that means.

If you call a model by a floating alias rather than a dated snapshot, it can be retrained or refreshed underneath you. When that happens your index is sitting in the old vector space and your queries are being computed in the new one. This degrades silently. Nothing errors. Results just get worse and move around.

I went looking for a bitwise reproducibility guarantee from the major hosted embedding providers and couldn't find one. That isn't evidence they're unstable, but it does mean you have to engineer as though no such guarantee exists. Pin dated model IDs where they're offered, and store the model version as metadata on every single vector you write.

There's also a hardware angle. Vendor numerical libraries typically promise bit identical results only on the same GPU architecture with the same SM count and the same toolkit version. A fleet mixing GPU generations cannot be bitwise reproducible by construction, however good the intentions.

## 3. Your queries and documents go through different kernels

Here's one that surprises nearly everyone.

You embed your documents offline, in big batches, because that's efficient. You embed queries online, one at a time, because that's what latency demands. Same model, same weights, same input text.

Different answer, slightly.

A batch of 1 is a skinny matrix multiply and a batch of 64 is a fat one. Different shapes get different tile decompositions, and small batches often get split across cores with the partial sums recombined afterwards. Floating point addition isn't associative, so changing the order of the additions changes the last bits. Padding to the batch maximum length changes reduction lengths too.

So your query vectors and your document vectors come out of different numerical paths of the same model. The difference is small, around 1e-6 relative, but it's **systematic rather than random**, which is worse than it sounds. And if your serving stack uses dynamic batching, your query gets grouped with whatever other requests happened to arrive in the same window, which means your vector depends on other people's traffic.

## 4. Why a wobble in the seventh decimal can reorder ten results

This is the part that feels like it shouldn't be true, so it's worth doing the arithmetic.

Ranking is a comparison operation. What matters isn't the absolute size of your numerical noise, it's the noise relative to the **gap between adjacent scores** at the rank boundary you care about.

![A vertical score axis showing ten retrieved candidates. Ranks one through seven are widely separated. Ranks eight through twelve are clustered tightly together, with the gaps between them smaller than a shaded noise band, so those candidates can swap places and move across the top-ten cutoff line. A second panel shows a near-duplicate corpus where all candidate gaps collapse inside the noise band](@/assets/images/rag-nondeterminism/02-score-gaps.svg)

Two candidates swap when the gap between them is smaller than roughly twice your noise floor. Work through it with real numbers:

- Clean corpus, average gap around 1e-2, fp32 noise around 1e-7. Swap probability per boundary is about 2e-5. Rare for any single query. At 10 million queries a day, that's a couple of thousand queries a day returning a reordered top 10. Which is exactly why this arrives on your desk as an unreproducible bug report.
- **Near duplicate corpus**, where gaps collapse toward 1e-6. Now the swap probability is around 20% per boundary, and reordering is the normal case, not the exception.
- bf16 compute, which raises the noise floor to about 1e-3. Unstable even on a clean corpus.

The conclusion is the important bit: **the instability is driven by your corpus, not your arithmetic.** If you have versioned documents, repeated boilerplate headers, templated pages, or overlapping chunks of the same passage, your scores are densely clustered and your ranking will never be stable at any achievable precision. No amount of pinning CUDA versions will fix a corpus full of near duplicates.

And note which boundary is most fragile: the gap between rank 10 and rank 11, right where you cut. In a long tailed score distribution that's typically where the gaps are smallest.

## 5. ANN search doesn't roll dice

Now for the layer everyone blames first, and the correction that solves most real cases.

**There is no randomness in ANN search at query time.** HNSW's entry point is a stored pointer, not a random pick. Greedy descent, IVF cell probing and beam search are all deterministic functions of the query vector, the index state, the parameters and the traversal order. "Approximate" means systematically wrong compared to exhaustive search. It does not mean randomly varying.

So the two usual first guesses, HNSW's level assignment RNG and k-means centroid initialisation, are the wrong suspects for results that flap from one second to the next. Those seeds are typically fixed by default anyway. What they actually explain is "the answers changed after we reindexed", which is a different complaint with a different fix.

If your results move on an index that nobody is writing to, it's one of four things.

**Different index copies.** Each replica builds its own graph from its own ingestion order and its own merge history. Two replicas holding byte identical documents hold structurally different indexes, and your load balancer picks one per request.

![Two replicas holding the same five documents. Each replica has built a different HNSW graph because the documents arrived in a different order, so the same query entering replica A and replica B traverses different edges and returns a different top three. A note explains that no data differs between the replicas, only the structure built over it](@/assets/images/rag-nondeterminism/03-replica-divergence.svg)

This one catches people out because they check whether the data is the same, confirm that it is, and conclude the index must be fine. The data was never the problem. The structures built over it were never identical in the first place.

**Traversal order under concurrency.** When a query is split across threads that share a global "best so far" collector or a shared visit budget, thread scheduling decides which candidates get examined before the cutoff fires. Different interleaving, different result.

**Budget bounded early exit.** Visit limits, query timeouts and memory circuit breakers all stop the search and return whatever has been collected so far. These are functions of _machine_ state rather than index state, so they move with cache warmth, garbage collection, co-tenancy and whether the index pages are resident. A cold index can legitimately return a different set than the same index fully warm. If your odd runs are also your slow runs, this is your answer.

**Tie breaking.** Near equal scores resolved by an unstable sort, or by an internal document ordinal that gets reassigned during compaction. There's a hardware flavour of this too: different SIMD kernels produce last bit different scores for the same pair of vectors, so a cluster with mixed CPU generations can score the same document inconsistently across nodes.

## 6. Your query gets split up and partially lost

If your index is sharded, each shard returns its own top K and a coordinator merges them.

![Scatter-gather retrieval across three shards. Each shard returns its own top three. A document that would rank eighth globally sits fourth within its own shard, so it is never returned to the coordinator and cannot appear in the final top ten. A second panel shows one shard timing out and contributing nothing, with the coordinator still returning a successful response](@/assets/images/rag-nondeterminism/04-shard-merge.svg)

Two separate problems in that picture.

The first is structural. A document at global rank 8 that happens to be rank K+1 _within its own shard_ never becomes a candidate at all. Change how documents map to shards and your top 10 changes without a single score moving.

The second is the silent one. A shard that times out, trips a circuit breaker, gets queue rejected or pauses for garbage collection contributes nothing to the merge, and search engines commonly return a **200 OK with partial results** rather than failing the request. So your result set becomes a function of wall clock luck and current load. If you aren't asserting that every shard succeeded on every response, you have no idea how often this is happening to you.

## 7. Fusion scoring that depends on its own output

If you run hybrid search, combining BM25 with vector similarity, this is a prime suspect.

The common approach is min-max normalization: take each leg's scores, subtract the minimum, divide by the range. The problem is that the minimum and maximum come from _this run's returned candidates_. The normalizer's parameters are a function of its own output.

So one document entering or leaving at rank 80, far below anything you'd ever show a user, rescales every other document's normalized score, including documents whose raw scores never moved at all. Your top 10 reshuffles because of churn you can't even see.

Reciprocal Rank Fusion sidesteps that by using only ranks, so it's immune to score scale and to one leg's outliers. It has a different weakness: a cliff at the candidate window. A document that falls outside a leg's returned depth contributes exactly zero from that leg, so a document oscillating around that depth boundary swings a full term in the fused score.

There's a sharding wrinkle here too. Lexical scoring computes IDF from the local shard's document frequency and document count, so the same document scores differently depending on which shard holds it and what else happens to live there. Replicas can disagree as well, through differing deleted document accounting.

## 8. Randomness you deployed on purpose and then forgot

Worth walking your own config before blaming the database:

- **Query rewriting, HyDE or multi-query retrieval running at temperature above zero.** This is the highest impact item on the list. A different rewrite means a different query vector and different lexical terms. Your "identical query" stopped being identical at the first hop.
- **MMR or diversity reranking.** No RNG involved, but it's a greedy argmax over pairwise similarity, so one swap at position 2 changes the redundancy penalty for every slot after it. It takes small upstream churn and amplifies it into a cascade.
- **A/B bucketing keyed on request ID** rather than a stable hash of user or query, so the same user lands in different arms on consecutive calls.
- **Agentic retrieval routing**, where a model picks the index, the filter or the tool per call. Here the whole _plan_ differs, not just the ranking.
- **Rerankers.** A cross encoder is deterministic given fixed input, which is exactly what you don't have: the candidate list changed, and batch composition on a shared inference server depends on other users' traffic. If you use an LLM as a reranker, note that LLM inference isn't bitwise deterministic even at temperature 0, because batch dependent kernels perturb the logits and greedy decoding only needs one near tied argmax to flip.

## 9. Caches that couple you to strangers

A semantic cache matches an incoming query against cached entries by similarity threshold. Whether you land inside some cached neighbour's radius depends on **what's currently in the cache**, which depends on other users' traffic. Your identical query can hit a stranger's entry on run 2 and miss on run 3.

Plain caches cause a tamer version of the same thing. A hit serves a frozen top 10, and the one request that crosses the TTL boundary recomputes and can differ for any reason in this entire post. The signature symptom is "it changed exactly once and then was stable for a few minutes".

Also check what's in your cache key. An embedding cache keyed on text alone, without the model ID, will cheerfully serve you vectors computed by a model you retired last quarter.

## 10. Filters over data that is quietly moving

Last one, and it's the case where the different results are simply correct.

`now - 7d` is resolved at request time. At sub second precision, every request has a slightly different window, so documents near the boundary drift in and out. ACL and permission filters shift with group membership, sharing changes and directory sync lag. Tenant and subscription state changes.

And if you apply filters _after_ retrieval rather than inside the query, an ACL change affecting a document at rank 40 changes how many documents survive to fill your ten, which moves rank 9.

## So which one is it

If I had to bet on an unseen system, in this order:

1. Preprocessing or model version mismatch between the ingest path and the query path
2. Replica divergence plus load balancer routing
3. Min-max fusion normalization, or per shard IDF statistics
4. Silent partial results under load
5. Temperature above zero somewhere in query rewriting
6. Tie breaking on a corpus full of near duplicates

Notice that only one of those six is about the vector index itself, and none of them is about floating point on a GPU.

[Part 2](/posts/rag-retrieval-nondeterminism-fixes) covers how to find out which one you actually have, in an order that costs you almost nothing to start, and the fixes for each. The short version of the punchline: stop chasing determinism and start bounding your variance instead.
