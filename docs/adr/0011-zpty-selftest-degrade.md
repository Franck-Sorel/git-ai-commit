# ADR-0011: `zpty` self-test at load; graceful degradation

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Mitigates risk #2 in `docs/05-open-risks-and-decisions.md` and `docs/07-project-closeout.md`.

## Context

`zsh/zpty` is standard on mainstream Linux/macOS Zsh builds, but is
not guaranteed in every minimal/embedded build, and pty behavior has
known macOS-vs-Linux buffering/timing quirks. No single canonical bug
report pins down exact failure conditions. Relying on it blindly risks
a broken or disruptive shell.

## Decision

At plugin load, run a **`zpty` self-test**: spawn a trivial echo
command on a pty, verify the round-trip output appears within a short
timeout, and clean up. If it fails:

- Disable suggestion features.
- **Do not** disrupt normal shell completion or keybindings (Tab must
  still fall through to `expand-or-complete`).
- Optionally print a one-line notice that the feature is disabled.

This is "mitigation by design", not resolution of the underlying
platform quirk.

## Consequences

- **Positive:** Never a broken-feature-from-a-broken-module experience;
  the shell always degrades safely.
- **Positive:** The feature fails fast and loud (one notice) instead
  of silently doing nothing.
- **Negative:** A few milliseconds of load-time self-test.

## Related

- ADR-0001 (relies on zpty)
- ADR-0007 (per-shell worker also invokes zpty)
