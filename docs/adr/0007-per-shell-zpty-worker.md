# ADR-0007: Per-shell worker bridging pty <-> socket

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Resolves risk #3 in `docs/05-open-risks-and-decisions.md` / `docs/07-project-closeout.md`; implements the `bin/worker.py` in `docs/04-implementation-guide.md` §3.

## Context

The `zpty` module communicates with a real subprocess over a pty,
while the daemon speaks a plain Unix socket. The two I/O models differ,
and the worker's lifecycle is a trade-off between per-shell isolation
and shared-resource efficiency.

## Decision

- **Per-shell worker for the MVP.** Each interactive shell spawns one
  lightweight `worker.py` inside its own `zpty`. Simple isolation and
  crash containment; acceptable for a small number of tabs (<10).
- The worker's only job: read newline-delimited JSON from stdin (via
  `zpty -w`), forward it over the Unix socket to the daemon, and write
  the daemon's response back to stdout (read by the `zle -F` callback).
- The worker detects a down/broken daemon and returns a
  `status: "error"` response rather than hanging Zsh.
- Shared supervision (systemd/launchd) is a **future optimization**,
  not part of the MVP.

## Consequences

- **Positive:** Crash of one worker cannot affect another shell.
- **Positive:** No shared-worker supervision/restart machinery needed
  for MVP.
- **Negative:** N shells = N pty fds + N Python processes (lightweight
  but nonzero).
- **Negative:** Worker must be respawned if it dies — `zpty -t`
  liveness check + respawn on next commit-context keystroke (per
  `03` §3 / `05` risk 3).

## Related

- ADR-0001 (zpty + zle -F)
- ADR-0002 (daemon)
- ADR-0012 (IPC contract)
