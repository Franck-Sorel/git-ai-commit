# ADR-0004: Causal decoder-only instruct model (not T5/CodeT5)

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Implements `docs/01-fact-check-and-refinements.md` §3.1-3.2; corrects the original proposal's CodeT5 recommendation and the refined doc's "T5 unsupported" flat claim.

## Context

The original proposal selected CodeT5-Small. Follow-up found that
"T5 is unsupported in llama.cpp" is overly flat — T5 encoder-decoder
support exists but is second-class, batching-incompatible, and
lower-priority. More importantly, `llama-server`'s continuous-batching
slot machinery is built around causal decoder-only KV-cache slots, and
CodeT5 has no confirmed community GGUF conversion.

## Decision

Require a **causal decoder-only ("LLaMA-style") instruct model** that
is GGUF-convertible and small enough for CPU inference within the
latency budget. The concrete model name is NOT pinned (it ages
quickly); it is selected at deployment time against the durable
requirement. Model path is configurable (ADR-0010).

## Consequences

- **Positive:** Uses the well-trodden, well-supported path through
  `llama-server`'s batching/slot system.
- **Positive:** Broad GGUF model availability and community support.
- **Negative:** Model choice is a moving target — must re-verify
  availability/quality at implementation time (per `07` item 7).

## Related

- ADR-0003 (OpenAI-compatible endpoint used with the chosen model)
- ADR-0010 (configurable model path)
