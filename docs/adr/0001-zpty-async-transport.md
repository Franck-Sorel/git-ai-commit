# ADR-0001: `zsh/zpty` + `zle -F` for async transport

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Implements `docs/02-architecture-high-level.md` §2.4; corrects `docs/04-implementation-guide.md` §2 and both source docs' FIFO-polling scheme.

## Context

The plugin must render ghost text without ever blocking the Zsh main
thread. A synchronous subprocess call inside a ZLE widget freezes the
entire interactive shell. The original and "refined" proposals both
suggested a hand-rolled FIFO + `sleep 0.05` polling loop as the async
transport.

That FIFO scheme is unreliable: nothing in it actually wakes Zsh's
event loop (`zle -F` is absent), it spawns a fresh subshell per
keystroke, leaves predictable `/tmp` files behind (a minor local
race), and polls CPU needlessly.

## Decision

Use the Zsh-native `zsh/zpty` module to run the worker process, and
`zle -F <fd> <handler>` to register a callback that Zsh's own event
loop invokes (backed by kernel `select`/`poll`) when the pty becomes
readable. This is the exact mechanism `zsh-autosuggestions` (millions
of installs, in production since ~2013) uses for the same problem.

## Consequences

- **Positive:** Non-polling, event-driven, proven at scale, no temp
  files, no busy loops. `zle -F` re-enters ZLE safely.
- **Positive:** Correct async primitive; the shell stays responsive.
- **Negative:** Requires the `zsh/zpty` module, which is not in every
  embedded/minimal Zsh build and has OS-specific pty buffering quirks
  (mitigated by ADR-0011 `zpty` self-test + graceful degradation).

## Related

- ADR-0011 (zpty self-test / degradation)
- ADR-0007 (per-shell worker)
