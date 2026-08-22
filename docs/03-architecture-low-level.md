# Low-Level Architecture

## 1. Zsh-side state

Declared once, at plugin load, with `typeset -g` (global, so it
survives across widget invocations within the same shell):

| Variable | Type | Purpose |
|---|---|---|
| `AI_SUGGESTION` | scalar | The full text of the currently accepted/pending suggestion (mirrors `POSTDISPLAY` when active). |
| `AI_REQUEST_ID` | integer, monotonically increasing | Identifies the most recently *sent* request. |
| `AI_LAST_APPLIED_ID` | integer | ID of the response currently reflected in `POSTDISPLAY`, for idempotency. |
| `AI_CONTEXT_PREFIX` | scalar | The exact buffer text a suggestion was computed for; used to validate that a stale response still matches the current buffer before applying it. |
| `AI_PTY_NAME` | scalar | Name registered with `zpty` for the worker process (`zpty -t $AI_PTY_NAME` checks liveness; spawn if absent). |

`POSTDISPLAY` and `region_highlight` are Zsh's own ZLE special
parameters, not plugin-defined — see `zshzle(1)`.

## 2. Widget inventory

| Widget name | Bound to / registered as | Responsibility |
|---|---|---|
| `ai-self-insert` | `zle -N self-insert ai-self-insert` | Insert the typed char via `zle .self-insert`; shrink/clear ghost text; detect context; enqueue a request. |
| `ai-accept-suggestion` | `bindkey '^I' ai-accept-suggestion` | Accept `POSTDISPLAY` into `LBUFFER`, or fall back to `zle expand-or-complete`. |
| `_ai_on_pty_readable` | `zle -F $AI_PTY_FD _ai_on_pty_readable` | Fires when the worker pty has output ready; parses and applies (or discards) the response. |
| `ai-clear-suggestion` | called internally, not bound | Resets `POSTDISPLAY`, `region_highlight`, `AI_SUGGESTION` in one place, to avoid drift between call sites. |

**Correction versus both source documents:** neither one defines a
distinct "clear" helper — they inline `POSTDISPLAY=""` /
`region_highlight=()` at multiple call sites. That duplication is a
real bug risk (easy to clear one but not the other on a new code
path). Centralize it.

## 3. Context detection

A suggestion should only be requested when:

1. `LBUFFER` matches the pattern for an *open, unterminated* `-m`
   argument to `git commit`, e.g. (conceptually):
   `^git commit ... -m "([^"]*)$` — an opening quote with no closing
   quote yet before the cursor.
2. `RBUFFER` is empty (cursor at end of buffer — required by
   `POSTDISPLAY` semantics, §1.5 of the fact-check).

Both source documents check only for the literal substring
`git commit -m "`. That is too narrow (misses `git commit --message=`,
multi-flag invocations like `git commit -am "`, and doesn't verify the
quote is still open) and too permissive (a `-m` string later in the
line, e.g. inside an already-completed message being edited, could
false-positive). A real implementation needs a small state machine or
a single anchored regex covering the common flag spellings — this is
called out as an implementation detail to get right, not a solved
fact in either source document.

## 4. IPC protocol (Zsh ⇄ worker ⇄ daemon)

### 4.1 Zsh ⇄ worker (over the pty, via `zpty`)
Newline-delimited JSON, one object per line, in both directions.

**Request (Zsh → worker → daemon):**
```json
{"id": 42, "prefix": "feat(auth): add", "cwd": "/home/user/project"}
```

**Response (daemon → worker → Zsh):**
```json
{"id": 42, "suggestion": " login validation", "status": "ok"}
```
or, while inference is in flight and the daemon wants to show a
"thinking" indicator (optional, matches the "visual feedback" idea in
the refined doc — genuinely useful, not just cosmetic, since local
CPU inference commonly runs 200–800ms):
```json
{"id": 42, "status": "pending"}
```
or on error (model unreachable, diff empty, etc.):
```json
{"id": 42, "status": "error", "message": "llama-server unreachable"}
```

`cwd` is included because the daemon may be shared across multiple
terminal tabs open in different repositories; the daemon must key its
diff cache by working directory, not assume a single repo.

### 4.2 Worker ⇄ daemon (Unix domain socket)
Same JSON envelope, forwarded essentially verbatim — the worker's job
is only to bridge the pty's blocking read/write model to the socket's
async model, and to survive/restart if the daemon is temporarily down
(returning a `status: "error"` response rather than hanging Zsh).

### 4.3 Why not reuse the original documents' file-based scheme
Per §2.2 of the fact-check: predictable `/tmp` filenames are a minor
local-privilege race concern (another local user could pre-create or
symlink the expected path), the polling loop wastes CPU, and — most
importantly — nothing in that scheme actually wakes Zsh's event loop
without also polling on the Zsh side, which neither source document
implements. A socket/pty-backed design with `zle -F` avoids all three
problems and is what the reference plugin actually ships.

## 5. Debounce and cancellation (daemon-side state machine)

```
        new request (id=N, prefix=P)
                 │
                 ▼
      ┌─────────────────────┐
      │ pending, sleeping    │──── newer request arrives (id=N+1) ──► cancel this task, restart with N+1
      │ for DEBOUNCE_MS      │
      └──────────┬───────────┘
                 │ debounce elapsed, still latest
                 ▼
      ┌─────────────────────┐
      │ refresh/read cached  │
      │ git diff (per cwd)   │
      └──────────┬───────────┘
                 ▼
      ┌─────────────────────┐
      │ call llama-server    │──── still latest when response arrives? ──► write response, id=N
      │ (async HTTP call)    │──── superseded while awaiting? ──► drop response, no write
      └─────────────────────┘
```

`DEBOUNCE_MS` (≈200–300ms per both source documents' suggestion) is a
tuning parameter, not a fact — it trades perceived latency against
request volume and should be adjustable via daemon config, not
hardcoded.

## 6. Ghost-text shrink/mismatch logic (`ai-self-insert` body)

```
on each self-insert invocation with typed char C:
    prev = POSTDISPLAY                    # snapshot before native insert
    zle .self-insert                      # real, correct character insertion
    if prev is non-empty:
        if C == prev[0]:
            POSTDISPLAY = prev[1:]        # shrink: user is "typing through" the ghost
            recompute region_highlight for new POSTDISPLAY length
        else:
            ai-clear-suggestion            # mismatch: abandon the suggestion entirely
    if buffer matches commit-message context AND cursor at end:
        AI_REQUEST_ID += 1
        enqueue request(AI_REQUEST_ID, LBUFFER) to worker
    zle -R
```

This matches the shrink-on-match / clear-on-mismatch behavior both
source documents describe, and mirrors the equivalent logic in
`zsh-autosuggestions`'s `_zsh_autosuggest_modify`, which performs the
same prefix-comparison trick (comparing what was typed against the
previous `POSTDISPLAY` to decide "widen the accepted match" vs. "throw
the suggestion away") rather than re-querying on every single
keystroke.

## 7. Timing budget (informative, not a guarantee)

| Stage | Approx. cost | Notes |
|---|---|---|
| `zle .self-insert` + shrink/clear logic | sub-millisecond | Pure in-shell string ops. |
| Debounce wait | 200–300 ms (configurable) | Intentional, absorbs fast typing. |
| `git diff --cached` (cache miss) | highly variable | Depends on repo size/diff size; cached on hit. |
| HTTP round trip to `llama-server` | model/hardware-dependent | Not a fact this document can assert a number for — benchmark on target hardware. |
| Redraw (`zle -R`) | sub-millisecond | Standard ZLE redraw cost. |

The only hard claim here is *ordering and mechanism*; actual millisecond
figures depend on the deployer's hardware and chosen model and must be
measured, not assumed from either source document (which asserted
"200–500ms inference latency" without a cited benchmark — treat that
as a plausible ballpark for a 1–2B parameter Q4 model on a modern CPU,
not a verified figure).
