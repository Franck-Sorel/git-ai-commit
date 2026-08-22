# ADR-0002: Persistent Python daemon over a Unix domain socket

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Implements `docs/02-architecture-high-level.md` §3-4; `docs/04-implementation-guide.md` §4.

## Context

The expensive state — debounce timer, per-repo `git diff --cached`
cache, and the HTTP connection pool to `llama-server` — must be
shared across all open terminal tabs, and must not be duplicated per
shell. Zsh itself cannot hold an async HTTP client or an inference
connection pool.

## Decision

A single long-lived Python daemon (`bin/daemon.py`) listens on a Unix
domain socket. Every Zsh shell reaches it through a lightweight
per-shell worker (`bin/worker.py`) that bridges the `zpty` stdio model
to the socket's async model. The daemon owns debounce, diff cache, and
the llama-server HTTP client.

## Consequences

- **Positive:** One debounce timer, one diff cache, one HTTP pool.
- **Positive:** `llama-server` loads the model once and every shell
  shares it.
- **Positive:** The daemon can outlive any single shell (hybrid
  systemd/launchd-managed lifecycle, per `07` item 3).
- **Negative:** Introduce one more IPC boundary (the socket); requires
  a robust wire contract (see ADR-0012) and security hardening
  (ADR-0005).

## Related

- ADR-0007 (per-shell worker bridging pty <-> socket)
- ADR-0005 (socket peer-credential verification)
- ADR-0012 (newline-delimited JSON IPC)
