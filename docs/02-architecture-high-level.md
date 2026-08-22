# High-Level Architecture

## 1. Goal

Provide GitHub-Copilot-style inline ("ghost text") completion of
`git commit -m "…"` messages inside an interactive Zsh session, driven
by a small, locally-hosted LLM that sees the staged diff.

## 2. Non-negotiable constraints (derived from §1–2 of the fact-check)

These fall directly out of how Zsh's Line Editor actually works —
they are not design preferences:

1. **The main Zsh process must never block on I/O inside a ZLE
   widget.** Any network/subprocess call synchronously inside
   `self-insert` freezes the whole interactive shell for its duration.
2. **`POSTDISPLAY` is only sensible when the cursor is at the end of
   the buffer.** It renders immediately after `$CURSOR`, not after
   `$BUFFER`'s end.
3. **`Tab` already has a job** (`expand-or-complete`). Any acceptance
   binding must fail over to it when no suggestion is active, or
   normal completion breaks everywhere else in the shell.
4. **Zsh has no native concept of a background LLM query.** The only
   real asynchronous-execution primitive for ZLE is the `zsh/zpty`
   module combined with `zle -F` (file-descriptor-ready callbacks).

## 3. Component diagram

```
┌─────────────────────────────┐      pty (zsh/zpty)      ┌──────────────────────────┐
│         Zsh (ZLE)            │◄────────────────────────►│   Worker process          │
│                               │   line-delimited JSON     │   (persistent, spawned    │
│  - my-self-insert  (wraps     │   over the pty's stdio    │    once per shell session│
│     self-insert)              │                            │    via `zpty -b`)         │
│  - accept-ai-suggestion       │                            │                          │
│     (wraps/bound to Tab)      │                            │  Talks to the daemon via  │
│  - _ai_on_pty_readable        │                            │  a Unix domain socket     │
│     (zle -F callback)         │                            └────────────┬─────────────┘
│                               │                                          │ AF_UNIX
│  State: POSTDISPLAY,          │                                          ▼
│  region_highlight, request ID │                             ┌──────────────────────────┐
└───────────────┬───────────────┘                             │   Python daemon            │
                │ triggers                                    │   (one per machine/repo,   │
                │ git context detection                       │    long-lived)             │
                ▼                                              │                            │
        (buffer matches                                       │  - debounces requests      │
         `git commit -m "…`)                                  │  - caches `git diff --cached`
                                                                │  - builds prompt            │
                                                                │  - calls llama-server HTTP  │
                                                                │  - cancels stale requests   │
                                                                └────────────┬───────────────┘
                                                                             │ HTTP (OpenAI-compatible)
                                                                             ▼
                                                                ┌──────────────────────────┐
                                                                │   llama-server              │
                                                                │   (--cont-batching,         │
                                                                │    --parallel N,            │
                                                                │    causal decoder-only GGUF)│
                                                                └──────────────────────────┘
```

Four processes, three trust/lifetime boundaries:

| Component | Lifetime | Why it exists as a separate process |
|---|---|---|
| Zsh + plugin | Per interactive shell session | Owns ZLE state; nothing else can touch `BUFFER`/`POSTDISPLAY`. |
| `zpty` worker | Spawned by the plugin, lives as long as the shell (or is respawned per request — see low-level doc) | Bridges Zsh's synchronous widget world and the daemon's async socket world without blocking ZLE. |
| Python daemon | One per user session/machine, outlives any single shell | Holds the debounce timer, the cached diff, and the HTTP connection pool to `llama-server`, so this state isn't duplicated per terminal tab. |
| `llama-server` | Long-running background service | Keeps the GGUF model resident in RAM/VRAM; this is the expensive resource every terminal shares. |

## 4. Why this shape (not the "call Python directly" shape)

The original proposal's "Python helper... running as a persistent
daemon or called via fast IPC" is right about *needing* a persistent
daemon, but underspecifies the IPC. Two designs were considered:

- **Rejected: Zsh calls a script synchronously per keystroke.**
  Violates constraint 1 outright — this is what both source documents
  correctly flag as the "blocking problem."
- **Rejected: Zsh writes request files, polls for response files.**
  This is what the "refined" document actually proposes in its code
  sample. It technically avoids blocking *if* the polling subshell is
  itself backgrounded, but it has no reliable way to notify Zsh's
  event loop when a response is ready — nothing in that sample
  actually re-enters ZLE to redraw when the file appears. It also
  spawns a new subshell + `sleep`-loop per request and leaves stale
  temp files behind.
- **Chosen: `zsh/zpty` + `zle -F`.** This is a Zsh-native async
  primitive, purpose-built for this exact problem, and already proven
  at scale by `zsh-autosuggestions`. The daemon is reached through a
  worker process attached to a pty that the `zpty` module manages;
  `zle -F <fd> <handler>` lets Zsh's own event loop wake the shell
  when the worker has written a response, with zero busy-polling.

## 5. Data flow (one suggestion cycle, high level)

1. User types a character. `self-insert` is intercepted.
2. The wrapper calls `zle .self-insert` (real character insertion,
   with correct multibyte/repeat-count handling), then checks: is the
   buffer inside `git commit -m "…"` and is the cursor at the end?
3. If yes, and the typed character doesn't already match the current
   ghost suggestion, a new request (buffer prefix + monotonic request
   ID) is written to the `zpty` worker's stdin.
4. The worker forwards it over a Unix socket to the daemon.
5. The daemon debounces (waits ~200–300 ms, canceling if a newer
   request supersedes it before that), refreshes/reuses its cached
   `git diff --cached`, builds a prompt, and calls `llama-server`'s
   OpenAI-compatible completion endpoint.
6. The daemon writes back a JSON response tagged with the same request
   ID over the socket, back through the worker, onto the pty.
7. `zle -F` fires the registered handler widget when the pty fd is
   readable. The handler checks the ID against the *current* latest
   request ID; if stale, it discards the response outright.
8. If current, it sets `POSTDISPLAY`, computes `region_highlight`
   using the verified `"$start $end fg=<n>"` format, and calls
   `zle -R` to redraw.
9. On `Tab`: if `POSTDISPLAY` is non-empty, its contents are appended
   to `LBUFFER` and cleared; otherwise the widget delegates to
   `zle expand-or-complete`.
10. On a mismatching keypress: `POSTDISPLAY` and highlighting are
    cleared before the character is inserted normally (matches the
    "clear ghost text on any deviation" behavior both source documents
    describe, and mirrors `zsh-autosuggestions`' own modify-widget
    logic).

## 6. Explicit non-goals

- **Not** a general-purpose shell autocomplete replacement — it only
  activates inside detected `git commit -m "…"` context, to avoid
  interfering with normal completion or `zsh-autosuggestions` (if
  installed) elsewhere.
- **Not** dependent on any specific model; the architecture only
  requires an OpenAI-compatible completion endpoint, so `llama-server`
  could be swapped for another local server without touching the Zsh
  or daemon code, as long as the HTTP contract in
  `03-architecture-low-level.md` is preserved.
- **Not** guaranteed sub-100ms on all hardware — inference latency is
  hardware- and model-size-dependent and is called out as an open risk
  in `05-open-risks-and-decisions.md`, not asserted as a fact here.
