# ADR-0008: Diff cache keyed by working directory

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Corrects `docs/04-implementation-guide.md` §4 daemon skeleton, which assumed a single repo per daemon instance.

## Context

The daemon is shared across multiple terminal tabs/shells, which may
be open in **different** git repositories. A single global diff cache
would cross-contaminate diffs between repos. Neither source document
raised this.

## Decision

Key the `git diff --cached` cache by the request's **working directory**
(`cwd`), which is carried in every request. A TTL (default 300s) bounds
staleness. The diff is truncated to `DIFF_MAX_CHARS` to fit the model's
context window.

## Consequences

- **Positive:** Multiple repos served correctly by one daemon instance.
- **Positive:** Diff is fetched once per repo per TTL window, not per
  keystroke.
- **Negative:** A very large staged diff is truncated — a known
  accuracy trade-off required by the context window (risk #1, ~§4.4 of
  fact-check).

## Related

- ADR-0002 (shared daemon; per-cwd state)
- ADR-0012 (cwd carried in the IPC envelope)
