# Ghost-Text Commit Assistant — Documentation

> **READ THIS FIRST.** This index defines the *hard baseline* of what
> this project is, what it is not, and how it must behave. Anyone
> (human or AI) about to build, modify, review, or debug this codebase
> should absorb the constraints below and the linked documents before
> touching a single line of code.

## What this project is

A GitHub-Copilot-style **inline ("ghost text") completion of
`git commit -m "…"` messages** inside an interactive Zsh session, driven
by a small, locally-hosted LLM (`llama-server`) that sees the staged
diff. Git *does not run* — the feature only edits the text being typed
in the ZLE buffer; the user still presses Enter / runs `git commit`
themselves.

Four processes, three trust/lifetime boundaries (from
`02-architecture-high-level.md`):

```
Zsh + ZLE plugin  <--pty (zsh/zpty)-->  worker.py  <--AF_UNIX-->  daemon.py  <--HTTP-->  llama-server
```

## The hard baseline — constraints that are NOT negotiable

These fall directly out of how Zsh's Line Editor and the chosen
primitives actually work. Violating any of them is a design bug, not
an optimization:

1. **The main Zsh process must never block on I/O inside a ZLE
   widget.** (law of `self-insert`) — any sync subprocess/network call
   freezes the whole shell. (`02` §2.1)
2. **Async transport is `zsh/zpty` + `zle -F`**, backed by kernel
   `select`/`poll`. NOT a FIFO + `sleep` polling loop. (ADR-0001;
   `01` §2.2)
3. **`POSTDISPLAY` is only sensible when `$CURSOR` is at the end of
   `$BUFFER`.** It renders after the cursor; a mid-line ghost would be
   misleading. (`01` §1.5)
4. **Use `zle .self-insert`, never reimplement insertion by hand.**
   Handling it yourself breaks multibyte, numeric-repeat, and bracketed
   paste. (`01` §1.2)
5. **`region_highlight` elements are `"start end fg=N"`**
   (three space-separated fields). The pattern `"p0 0 0 244"` is invalid.
   (`01` §1.4)
6. **`Tab` already means `expand-or-complete`.** Any accept binding
   must fall back to it when no suggestion is active, or completion
   breaks everywhere. (`01` §1.6)
7. **Use the OpenAI-compatible `/v1/completions` endpoint**, not the
   legacy `/completion`. (ADR-0003; `01` §4.5)
8. **Model must be causal-decoder ("LLaMA-style") instruct + GGUF**,
   never T5/CodeT5. (ADR-0004; `01` §3.1)
9. **`llama-server` flags pinned explicitly**, never rely on defaults
   that have changed across versions: pass `--cont-batching`,
   `--parallel N`, and prefer `--load-mode mlock` (not deprecated
   `--mlock`). (`01` §4.1-4.3)
10. **Every socket connection is peer-credential verified by UID** on
    top of `chmod 0600`. UID only; never depend on PID (absent on
    macOS). (ADR-0005; `06`)
11. **Diff cache is keyed per working directory**, never global.
    (ADR-0008)
12. **Staged-diff data must never be logged to disk by the daemon.**
    (`05` risk 6; `06`)
13. **Graceful degradation is mandatory**: `zpty` self-test at load;
    on failure disable only the suggestions, never break completion or
    the shell. (ADR-0011)
14. **Stale responses MUST be discarded** by matching `id` against the
    latest-request counter, plus a buffer-prefix re-check before
    applying. (`01` §2.3; `03` §1)
15. **Every keystroke must not become a network inference.** Debounce
    (default ~250ms) and cancellation are load-bearing, per-trigger
    behavior. (ADR-0006; `03` §5)

## What this project is NOT (explicit non-goals, `02` §6)

- **Not** a general autocomplete replacement; it activates only inside
  detected `git commit -m "…"` context.
- **Not** dependent on any specific model; it needs only an
  OpenAI-compatible completion endpoint.
- **Not** guaranteed sub-100ms inference — latency is
  hardware-dependent and OPEN (must be measured; risk #1).

## Reading order

For the full picture, read in this order:

| Doc | Purpose |
|---|---|
| [00-README.md](00-README.md) | Original overview / headline correction |
| [01-fact-check-and-refinements.md](01-fact-check-and-refinements.md) | Every technical claim verified against primary sources; what's correct/wrong/version-dependent |
| [02-architecture-high-level.md](02-architecture-high-level.md) | Components, responsibilities, data flow, non-negotiable constraints |
| [03-architecture-low-level.md](03-architecture-low-level.md) | State machine, IPC protocol, widget contracts, timing budget |
| [04-implementation-guide.md](04-implementation-guide.md) | Working code: plugin, worker, daemon, `llama-server` invocation, test checklist |
| [05-open-risks-and-decisions.md](05-open-risks-and-decisions.md) | First-pass open risks (see 07 for final status) |
| [06-security-hardening.md](06-security-hardening.md) | Socket peer-credential UID verification (corrected) |
| [07-project-closeout.md](07-project-closeout.md) | FINAL status of every open risk. **Read last.** |
| [adr/](adr/README.md) | Architecture Decision Records — the baseline of every decision |

## How the ADRs lock the baseline

The ADRs in [`adr/`](adr/README.md) record every decision and the
source it implements or corrects. **Rule: code must not silently
contradict an ADR.** If code and an ADR disagree, it's a bug in the
code (or a deliberate change requiring a new superseding ADR).

> **Note on the daemon language:** ADR-0013 records the decision to keep
> the daemon in Python (rejecting Rust/Go migration), grounded in a
> 2026 re-verification of the competing proposals' claims — including
> that PyOxidizer is abandoned and that "uvloop lacks macOS support"
> is false but that uvloop is unnecessary for this I/O-bound proxy.
