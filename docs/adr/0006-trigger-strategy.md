# ADR-0006: Whitespace-triggered default, per-keystroke opt-in

- **Status:** ACCEPTED (latency-conditional)
- **Date:** 2026-08-22
- **Source:** Resolves risk #4 in `docs/05-open-risks-and-decisions.md` and `docs/07-project-closeout.md`.

## Context

The suggestion trigger strategy is a genuine product decision with no
universally correct answer: per-keystroke (debounced), whitespace-
triggered, or explicit-key. It hinges on measured end-to-end latency,
which is unbenchmarked (risk #1, OPEN).

## Decision

- **Default: whitespace-triggered.** Issue a suggestion request when
  the buffer enters/extends a completed word boundary (space typed) in
  commit context. Fewer, more semantically meaningful requests; robust
  to slower CPU inference.
- **Opt-in: per-keystroke (debounced).** Only if the user locally
  measures time-to-first-token below a UX threshold (~100-150ms
  heuristic, not a benchmarked cutoff) and enables it in config.
- **Fallback: Ctrl+Space explicit key** always available for a manual
  "suggest now" bound, zero background load.

## Consequences

- **Positive:** Default is safe on typical CPU inference without a
  benchmark gate.
- **Positive:** Per-keystroke "live" feel available to fast hardware.
- **Negative:** Whitespace-triggered feels stale mid-word by design; a
  documented UX trade-off, not a bug.

## Related

- ADR-0010 (config flag to choose strategy)
- Risk #1 latency (OPEN — must be measured before trusting the opt-in
  path).
