# ADR-0012: Newline-delimited JSON IPC contract

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Formalizes `docs/03-architecture-low-level.md` §4 protocol and the JSON envelopes in `docs/04-implementation-guide.md` §3-4.

## Context

Three parties exchange messages across two hops (Zsh <-> worker over
pty; worker <-> daemon over Unix socket). Both hops need a single,
unambiguous framing and schema so any hop can be replaced or
reimplemented independently.

## Decision

**Framing:** one JSON object per line, newline-delimited, in both
directions on both hops. No length prefixes, no multi-line JSON.

**Request (Zsh -> daemon):**
```json
{"id": 42, "prefix": "feat(auth): add", "cwd": "/home/user/project", "trigger": "space"}
```

**Response (daemon -> Zsh):**
```json
{"id": 42, "suggestion": " login validation", "status": "ok"}
```
or `{"id": 42, "status": "pending"}` (thinking indicator, optional),
or `{"id": 42, "status": "error", "message": "..."}`.

Matching rules:
- `id` is a monotonic counter identifying the latest request; a
  response is applied only if `id == latest_id` (stale responses are
  discarded at Zsh).
- `cwd` keys the diff cache (ADR-0008).

## Consequences

- **Positive:** Simple to implement and debug; trivially testable.
- **Positive:** Any hop (worker) can be swapped without touching the
  others.
- **Negative:** Requires disciplined single-line JSON encoding
  (no embedded newlines in `suggestion`/`prefix`); newline is the
  framing sentinel.

## Related

- ADR-0002 (daemon), ADR-0007 (worker), ADR-0008 (cwd in envelope).
