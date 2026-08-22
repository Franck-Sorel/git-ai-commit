# ADR-0003: OpenAI-compatible `/v1/completions` endpoint

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Implements `docs/01-fact-check-and-refinements.md` §4.5; corrects both source docs' silence on which endpoint to target.

## Context

`llama-server` exposes both a legacy `/completion` endpoint and an
OpenAI-compatible surface (`/v1/completions`, `/v1/chat/completions`).
Neither source document specified which to use.

## Decision

Target the OpenAI-compatible endpoint (`/v1/completions` for a plain
instruct prompt). This is the actively maintained, documented,
portable surface, and lets the daemon swap `llama-server` for any
other OpenAI-compatible local server without changing the HTTP client
code.

## Consequences

- **Positive:** Portability — the daemon's HTTP contract is standard.
- **Positive:** Future-proof — can point at llama.cpp, Ollama, LM
  Studio, or even a remote provider (with appropriate security review,
  since diffs would then leave the machine).
- **Negative:** None material; `/v1/completions` requires the same
  prompt-building discipline as the legacy route.

## Related

- ADR-0004 (causal decoder-only model driving this choice)
