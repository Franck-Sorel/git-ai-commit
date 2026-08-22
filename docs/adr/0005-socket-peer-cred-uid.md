# ADR-0005: Socket peer-credential UID verification

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Implements `docs/06-security-hardening.md`; closes risk #6 in `docs/05-open-risks-and-decisions.md` and `docs/07-project-closeout.md`.

## Context

The daemon's Unix socket can trigger `git diff` reads and LLM calls
from any process able to connect. `chmod 0600` on the socket file
stops *other users* but NOT other processes running as the *same
user*. The initial guidance proposed a uniform struct that merely
reorders fields across platforms — that is incorrect and would
misread memory on macOS.

## Decision

On **every** accepted connection, in addition to `chmod 0600`, verify
the connecting process's UID via peer credentials:

- Linux: `getsockopt(SOL_SOCKET, SO_PEERCRED)` -> `struct ucred`,
  readonly the `uid` field.
- macOS: `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` -> `struct xucred`,
  readonly the `cr_uid` field (the first two fields, version + uid,
  are layout-stable enough to read safely).
- Unknown platform: **fails closed** (returns False).

The verification **depends only on UID**, which is available on every
target platform, and deliberately does **not** rely on PID (absent on
stock macOS). PID is optional best-effort diagnostic only.

## Consequences

- **Positive:** Closes the same-user process-abuse gap that file
  permissions cannot.
- **Positive:** UID-only check sidesteps the cross-platform struct
  divergence rather than papering over it.
- **Negative:** Requires platform branching in the daemon; macOS
  constants/struct sizes should be verified against the actual SDK
  before a macOS release (per `06` §4).
- **Negative:** Diffs (potentially containing staged secrets) still go
  to a local model process — local, but must never be logged to disk
  by the daemon.

## Related

- ADR-0002 (daemon over Unix socket)
