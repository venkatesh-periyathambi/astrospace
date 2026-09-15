---
author: Venkatesh Periyathambi
pubDatetime: 2026-09-15T09:00:00Z
title: "Cut Your LLM Bill by 80% Without Shipping a Worse Product"
slug: cost-tiered-model-routing
featured: true
draft: false
tags:
  - ai
  - llm
  - genai
  - cost-optimization
  - architecture
  - platform-engineering
description: "Cost-tiered model routing: send the routine 80% of traffic to a small model, verify the answer before you trust it, and keep the expensive model for the work that actually needs it. Provider-neutral architecture, the arithmetic, and the parts that go wrong."
---

"Our token spend went up 9x this quarter and the product didn't get 9x better. Do we just move everything to a cheaper model?"

I get some version of this question every few weeks now. The volume is real, the panic is real, and the proposed fix is almost always wrong. Moving everything to a cheaper model is how you trade a cost problem for a quality problem, and the quality problem shows up in front of customers about two weeks later.

There is a better answer, and it isn't clever. Send the boring work to a small model, keep the expensive model for the work that earns it, and check the cheap answer before you trust it. That last clause is where all the engineering lives.

## Table of Contents

---

## It's arithmetic, not magic

Small models are somewhere between 10 and 60 times cheaper per token than frontier models, depending on which pair you compare. That spread is the entire opportunity. If you can safely move the routine majority of your traffic down a tier, your blended cost collapses even though the hard requests still hit the expensive model.

Here is the shape of it. Illustrative bands per million tokens, and please check current list prices before you quote any of these to a CFO, because they move every few months:

| Tier | Typical models | Rough band per 1M tokens |
| --- | --- | --- |
| Small | Claude Haiku, Gemini Flash, Nova Lite, small Llama or Mistral | $0.10 to $1 |
| Mid | Claude Sonnet, Gemini Pro, Nova Pro | $1 to $5 |
| Frontier | Claude Opus, GPT flagship, the reasoning models | $10 to $75 |

Now put a realistic traffic mix through it. Index everything to the frontier tier at 1.0, call mid 0.2, call small 0.067 (about fifteen times cheaper), and include the cost of retrying the requests that fail their quality check:

| Traffic | Share | Unit cost | Cost |
| --- | --- | --- | --- |
| Small tier | 75% | 0.067 | 0.050 |
| Mid tier | 20% | 0.2 | 0.040 |
| Frontier | 5% | 1.0 | 0.050 |
| Retries: 15% of small calls redone at mid | 11% | 0.2 | 0.023 |
| Retries: 10% of mid calls redone at frontier | 2% | 1.0 | 0.020 |
| **Blended** | | | **0.183** |

That's an 82% reduction against sending everything to the frontier model, with the retry cost paid for honestly rather than hidden. Notice something in that table: the 5% of traffic that goes straight to frontier costs as much as the 75% that goes to the small tier. The frontier share is the number to watch, not the small-tier share.

## Why the cheap tier is so much cheaper

You're paying for compute, and several factors stack up.

The dominant one is parameter count. Cost tracks how many parameters have to fire to produce each token. A frontier model runs hundreds of billions to trillions; a small model runs a fraction of that. Fewer parameters means fewer operations per token, which means less accelerator time, which means a lower price. Roughly linear, and it swamps everything else on this list.

Then there's distillation. A large teacher model trains a small student to imitate its behaviour on a target distribution of tasks. The student keeps most of the everyday quality at a fraction of the size, and at inference time you pay for the student, not the teacher that produced it.

Small models also fit on fewer and cheaper accelerators, and they batch better. A provider can pack far more concurrent requests onto the same hardware, which spreads the fixed cost over more billable tokens. Architectures like mixture-of-experts push the same way from the other direction: only a subset of parameters activates per token, so effective compute stays low even when total parameter count is large.

Here's the part that matters for your architecture:

![Cost climbs faster than quality: a chart indexed to the frontier tier, showing price per token rising steeply from small to frontier while quality on routine work stays nearly flat](@/assets/images/model-routing/02-cost-vs-quality.svg)

Capability does not scale linearly with price. A model that costs fifteen times less is not fifteen times worse. On "classify this ticket", "pull these six fields out of this document", or "summarise this paragraph", the outputs are often indistinguishable in a blind comparison. The gap between the cost curve and the quality curve on easy work is the whole trade, and it narrows as the work gets harder. Your job is to figure out where, for your traffic, it closes.

## What the pipeline looks like

None of this is provider-specific. Every major platform now gives you the same set of pieces: one API in front of many model families, a guardrail service, a batch endpoint at roughly half price, prompt caching, and per-request usage metering. AWS Bedrock, Azure AI Foundry, and Google Vertex AI all qualify, and so does an open-source gateway like LiteLLM or Portkey in front of direct provider APIs. Pick whichever your platform team already runs. What matters is that swapping the model on a request is a config change and not a new integration, because that's the property routing depends on.

![The request path: caller, gateway, input checks, router, three model tiers, quality gate with an escalation loop back to the router, then output checks and metering](@/assets/images/model-routing/01-routing-pipeline.svg)

Six things are happening there, and only one of them is interesting.

**The gateway** authenticates the caller, enforces a per-tenant quota, and tags every single call with a team, a use case, and a cost centre. Do this on day one. Retrofitting attribution onto a year of untagged traffic is miserable, and without it you cannot tell whether your bill went up because usage grew or because someone shipped a prompt that tripled in size.

**Input checks** redact PII, screen for injection, and assemble the prompt with the static parts first so the cacheable prefix is as long as possible. Cache reads cost a fraction of fresh input tokens on every major platform, and this is free money that most teams leave on the floor.

**The router** scores how hard the request is and picks a tier. More on it below.

**The tiers** are just model IDs. Keep three. Two isn't enough resolution and four is more than you'll be able to reason about when you're tuning thresholds at 11pm.

**The quality gate** decides whether the cheap answer was good enough to return. This is the load-bearing component.

**Output checks and metering** do the grounding check, the output PII scan, and the schema validation, then emit tokens by tier, cache hit ratio, escalation rate, and latency percentiles. If you only instrument one thing, instrument escalation rate by tier.

## The router: three options, in order of effort

**Start with your platform's managed router if it has one.** Several vendors now offer a serverless endpoint that predicts, per request, whether the small or the strong model in a family will produce an equivalent answer, and routes accordingly. Vendor benchmarks report savings in the 30 to 60 percent range with a small latency penalty. Treat those numbers as marketing until you've measured your own traffic, but the ops burden is close to zero, so it's the cheapest way to find out whether the pattern works for you at all. The usual constraints are that it's pairwise, same region, and within one model family.

**Then write rules.** Deterministic, free to run, and you can explain them to an auditor without hand-waving:

```python
def route(req):
    if req.requires_tools or req.is_multi_step_reasoning:
        return FRONTIER
    if req.input_tokens > 4000 or req.has_code_blocks:
        return MID
    if req.task_type in ("classify", "extract", "summarize_short"):
        return SMALL
    return MID  # when in doubt, don't be clever
```

This looks too simple to work. For narrow, well-understood workloads it works very well. A fraud investigation queue is the canonical case: most alerts are routine pattern matches and a small minority are genuinely tangled, and you usually know which is which from metadata you already have before the model sees anything.

**Add a classifier only when rules plateau.** A small model or an embedding plus a logistic regression scores complexity between 0 and 1, and you set a threshold. Higher ceiling, more accurate on messy input, and now you own a model that needs monitoring and retraining. Earn your way to this one.

Most teams land on rules plus the quality gate, which is the combination I'd recommend by default. Cheap rules make the obvious calls and the gate catches what they get wrong.

## The quality gate is the actual product

Aggressive downward routing is only safe if you verify the cheap answer before returning it. Route optimistically, then check:

- Structured output doesn't parse or fails schema validation, so escalate.
- The model self-reports low confidence, because you asked it to in the prompt, so escalate.
- The grounding check fails, meaning the answer isn't supported by the retrieved source, so escalate.
- A downstream validator rejects it, for example an extracted invoice total that doesn't match the line items, so escalate.

![The escalation loop: request goes to the small model, through a gate checking validity, grounding and confidence; passing answers return, failing ones retry at the next tier up and then return](@/assets/images/model-routing/03-escalation-loop.svg)

Note the direction of the loop. A failed attempt escalates one tier and returns; it does not bounce back to the router to be re-scored. Re-scoring gives you a path to an infinite loop on a request the router keeps classifying the same way, and I've seen exactly that burn a weekend of budget on a handful of malformed inputs.

Design the checks so they're cheap. Schema validation and a downstream sanity check cost you nothing. A grounding check on every response is not free, so sample it rather than running it inline on all traffic once you trust the tier.

## Does self-hosting help?

It comes up in every one of these conversations, so let's deal with it.

Self-hosting saves you exactly zero tokens. Token count is a property of the model and your prompts, not of where the weights happen to sit. Running Llama on your own GPUs does not shorten a prompt. Drop "save tokens" from the self-hosting case entirely, because caching, routing, and prompt compression are identical either way.

On cost, it depends entirely on utilisation. Managed inference bills per token with no idle cost. Dedicated GPUs bill per hour whether traffic arrives or not, and frontier-class open models need expensive multi-accelerator instances to serve at all. If your GPUs run above roughly 70 to 80 percent busy around the clock, self-hosting can beat per-token pricing. Most enterprise traffic is spiky and business-hours shaped, which means you'd be paying for idle silicon. Provisioned or reserved throughput from your platform captures much of the steady-high-volume discount without you owning any infrastructure.

There's also a category error hiding in the question. The flagship closed models have no self-hosting option at all, so "let's self-host to cut our Claude bill" is not a hosting decision, it's a decision to use a different model. Self-hosting means open weights: Llama, Mistral, Qwen, DeepSeek, and the open-weight releases from the big labs. That may well be the right call, but evaluate it as a model swap, with a quality bar, not as an infrastructure optimisation.

![Decision tree: are the weights open, will the GPUs run hot around the clock, do you have a team to run inference as a product; any no leads to the managed service](@/assets/images/model-routing/04-managed-or-self-host.svg)

Governance is the genuine argument, and it's a good one. The weights are physically yours, they don't change under you when a vendor deprecates a version, the data never crosses your boundary, and you can instrument the model internals. For the strictest data sovereignty and reproducibility requirements, that's decisive. But be honest about the increment: managed platforms already offer in-region processing, private network paths, contractual commitments that your data isn't used for training, and built-in guardrails. The remaining gain is narrower than most people assume, and it's usually "the weights never leave our walls."

Then there's the cost nobody puts in the spreadsheet. Self-hosting means you own capacity planning, autoscaling, model server tuning, patching, failover, and the team that does all of it. That line item routinely dwarfs the GPU-hour versus token comparison that motivated the exercise.

My default: use the managed service. Self-host only when you have a hard requirement that in-region managed inference genuinely cannot satisfy, or sustained near-continuous high utilisation on an open-weight model, and you have the platform capability to run inference as a first-class product. For most teams, routing and caching on a managed platform gets you the large majority of the value without hiring a GPU operations team.

## Where this goes wrong

**The router costs more than it saves.** If your complexity classifier is itself an LLM call on every request, you've added a tax to 100 percent of traffic to save money on 75 percent of it. Keep the router to rules, an embedding lookup, or a managed endpoint.

**Nobody watches the escalation rate.** This is your single most important metric and it's the one I most often find unmonitored. Below 15 percent, your small tier is well scoped. Above 40 percent you're paying twice for a large fraction of traffic and you should move those request types up a tier permanently.

**Caching and routing fight each other.** Prompt caches are per model. If a similar request bounces between two models, you halve your hit rate on both. Route first, then cache within the tier, and don't route on anything that varies request to request when the prefix is otherwise identical.

**Quality regression is silent.** Nothing pages you when the small tier gets 4 percent worse at an extraction task after a prompt change. Log a sample of small-tier outputs and run them through an offline evaluation on a schedule. Every platform has an evaluation service now, and it doesn't matter which you use as long as something is comparing tiers on a fixed test set.

**Batch traffic shouldn't touch the router at all.** If it's asynchronous and tolerates a delay, send it to the batch endpoint at roughly half price and skip the tiering entirely. Routing is a real-time optimisation. I've seen a team run their nightly backfill through a latency-optimised routing path and pay double for work nobody was waiting on.

## The short version

It's arithmetic. Small models are 10 to 60 times cheaper per token, so if you can safely send the routine 80 percent of your work to one and verify the answer before trusting it, your blended cost drops by roughly 80 percent while the hard cases still get the expensive model. The routing isn't the hard part. The check that makes aggressive routing safe is the hard part, and it's the part worth your best engineer.
