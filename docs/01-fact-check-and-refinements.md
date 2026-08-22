# Fact-Check: Original Proposal vs. Primary Sources

Scope: every concrete technical claim in the original proposal and its
"refined" follow-up, checked against the Zsh manual, Zsh's own
source/mailing-list history, the `zsh-autosuggestions` source code
(the closest real-world precedent), and current `llama.cpp`
`tools/server/README.md`. Each item is marked:

- ✅ **Correct** — matches primary source.
- ⚠️ **Partially correct / imprecise** — the core idea is right but a
  detail is wrong, outdated, or overstated.
- ❌ **Incorrect** — contradicted by primary source.
- ❓ **Unverifiable / environment-dependent** — no single correct
  answer exists; depends on OS, Zsh version, or hardware.

---

## 1. Zsh ZLE mechanics

### 1.1 Intercepting `self-insert`
**Claim:** Override `self-insert` via `zle -N self-insert <fn>` to see every
typed character.
**Verdict: ✅ Correct.** This is exactly how `zsh-autosuggestions` works —
it rebinds `self-insert` (and a list of other buffer-modifying widgets)
to wrapper functions.

### 1.2 Calling the original widget
**Claim (refined doc):** You must call `zle .self-insert` inside your
wrapper, not reimplement character insertion yourself, or you lose
built-in behavior (multibyte input, numeric-argument repeat, etc.).
**Verdict: ✅ Correct**, and this is an important correction to the
*original* proposal, which reimplemented insertion by hand
(`LBUFFER="$LBUFFER$char"`) — that approach breaks multibyte
characters, the numeric-repeat prefix, and bracketed paste. The
`zsh-autosuggestions` source confirms the pattern: it calls the
original widget via `zle $original_widget_name -- $@` (a general
form of the same idea — invoke the underlying builtin rather than
reimplement it). The dot-prefixed form (`zle .self-insert`) is the
standard Zsh idiom for "call the un-wrapped builtin widget of this
name," and works whether or not other plugins have also wrapped
`self-insert`, as long as widget-wrapping order is respected.

### 1.3 `POSTDISPLAY` semantics
**Claim:** `POSTDISPLAY` renders text after the cursor without adding it
to the buffer.
**Verdict: ✅ Correct** — confirmed in `zshzle(1)`: `POSTDISPLAY` is
shell-parameter-documented as text displayed but not part of `BUFFER`.

### 1.4 `region_highlight` syntax
**Original proposal:** `region_highlight=("p0 0 0 244")`
**Verdict: ❌ Incorrect.** This is not valid `region_highlight` syntax
at all.

**Refined doc's fix:** `region_highlight=("$cursor $((cursor + ${#POSTDISPLAY})) fg=244")`
**Verdict: ✅ Correct, and independently confirmed.** The Zsh manual
(`zshzle(1)`, "Character Highlighting" section, confirmed via the
original Zsh source patch that introduced `region_highlight`) documents
each array element as three space-separated fields:

```
[P] <start-offset> <end-offset> <highlight-spec>
```

- `start-offset`/`end-offset` are in the same units as `$CURSOR`
  (character offsets into the displayed line).
- `highlight-spec` uses the same syntax as `zle_highlight` context
  values: `fg=COLOR`, `bg=COLOR`, `bold`, `standout`, `underline`, etc.
- The optional leading `P` flag means the offsets should be counted
  including any `PREDISPLAY` content — not needed here since we're
  highlighting `POSTDISPLAY`, which sits after `BUFFER`.

This is exactly what the production `zsh-autosuggestions` plugin does,
character-for-character:

```zsh
region_highlight+=("$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) $ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE")
```

where the default `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE` is `fg=8` (or
`fg=244` etc. for other 256-color terminals). Use `$#BUFFER` (buffer
length) as the start offset when the cursor is at the end of the
buffer, which will be the normal case for this feature (see §1.5).

### 1.5 Cursor-position restriction
**Claim (refined doc):** Restrict suggestions to `$CURSOR == ${#BUFFER}`
(cursor at end of line), because `POSTDISPLAY` always renders
immediately after the cursor, and a mid-line ghost suggestion would be
confusing.
**Verdict: ✅ Correct and well-founded**, and consistent with how
`zsh-autosuggestions` behaves — it only shows a suggestion when the
cursor is at the end of the buffer. This is a real Zsh constraint
(`POSTDISPLAY` is positioned relative to `CURSOR`, not `BUFFER`'s end),
not an implementer's preference.

### 1.6 Binding `Tab`
**Claim:** `Tab` is normally bound to `expand-or-complete`, so you need a
custom widget that checks for an active suggestion and falls back to
the standard completion widget otherwise.
**Verdict: ✅ Correct.** This is standard Zsh keymap behavior
(`bindkey` in emacs mode binds `^I` to `expand-or-complete` by
default), and the fallback pattern (`zle expand-or-complete` when no
suggestion is active) is exactly what you need to avoid breaking
normal Tab-completion everywhere else in the shell.

---

## 2. Asynchronous execution

### 2.1 The core claim: don't block ZLE
**Claim:** Calling a synchronous subprocess (Python script, `curl`, etc.)
directly inside `self-insert` will freeze the shell for the duration of
the call.
**Verdict: ✅ Correct**, and this is the single most important
correctness constraint in the whole design. ZLE widgets run on Zsh's
main thread; any blocking call inside one blocks keystroke processing
shell-wide, not just for this feature.

### 2.2 Proposed mechanism: named pipe (FIFO) + polling loop
**Refined doc's implementation:** spawn a background subshell that
loops `while [ ! -f "/tmp/ai_resp_$req_id" ]; do sleep 0.05; done`,
then `touch` a trigger file for Zsh to notice.
**Verdict: ⚠️ Works, but is not the real mechanism and has real
problems.** This is a home-grown polling hack:
- It creates a new background subshell (and a `sleep 0.05` busy-loop)
  per keystroke-triggered request — process-spawn overhead alone can
  exceed the debounce window on a loaded system.
- Polling a file with `[ -f ... ]` plus `sleep` cannot signal Zsh's
  event loop; Zsh has no way to "wake up" when the file appears except
  by *also* polling from the Zsh side (which nothing in that example
  actually does — there's no working glue from "file appeared" back
  into a redisplay).
- Leftover `/tmp/ai_resp_*` files accumulate and are a predictable
  race/security smell (predictable temp-file names in `/tmp`).

**What real Zsh plugins actually do:** the `zsh/zpty` module. This is
a built-in Zsh module (not a hack) purpose-built for exactly this: it
opens a pseudo-terminal, runs a command attached to it, and lets you
read/write to that pty asynchronously from ZLE, with **`zle -F`**
providing the callback: `zle -F <fd> <handler-widget>` tells Zsh's
event loop to invoke `<handler-widget>` whenever `<fd>` becomes
readable — this is a real, non-polling, kernel-`select`/`poll`-backed
callback, unlike the FIFO-touch scheme. `zsh-autosuggestions` has used
this since v0.4.0 (its `ZSH_AUTOSUGGEST_USE_ASYNC` mode); it is a
proven, widely-deployed pattern, not a theoretical one.

**Refinement:** Replace the FIFO-polling design with `zpty` + `zle -F`.
Working code is in `04-implementation-guide.md`.

### 2.3 Race conditions / stale-response handling
**Claim:** Tag each request with an ID; discard responses whose ID
doesn't match the latest request.
**Verdict: ✅ Correct in principle** and a real necessity — nothing in
Zsh or `llama.cpp` does this for you automatically. One addition: ID
comparison alone is not quite sufficient if you also allow the daemon
to *cancel* superseded in-flight requests (recommended, see §4); track
both "latest ID" and "in-flight ID" so the daemon can early-exit
instead of computing a discarded answer.

---

## 3. Model architecture and `llama.cpp` compatibility

### 3.1 CodeT5 / T5 support in `llama.cpp`
**Original proposal:** suggests `CodeT5-Small` as a candidate model.
**Refined doc's correction:** claims `llama.cpp` "does not support T5
models; it only supports LLaMA-style (GPT) architectures. You cannot
load CodeT5 into `llama-server` in GGUF format."
**Verdict: ⚠️ Overstated / partially incorrect as of current
`llama.cpp`.** T5-family encoder-decoder support was added to
`llama.cpp` via PR #8055 / #8141 (merged 2024) and does work for
models like `flan-t5-*` through `llama-cli` (community GGUF
conversions of `flan-t5-base` etc. run and generate text). So the flat
claim "T5 is unsupported" is no longer accurate.

That said, the practical conclusion — **don't use a T5/CodeT5 model
for this feature** — is still correct, for reasons more specific than
"unsupported":
- T5 support in `llama.cpp` is explicitly second-class: imatrix
  quantization is unsupported for T5 tensors, encoder-decoder loading
  has had open bugs (e.g., `T5Encoder` support being broken by
  refactors, per `llama.cpp` issue #12588), and it is not a focus of
  ongoing development.
- More fundamentally, `llama-server`'s continuous-batching / multi-slot
  design (the `-np`/`--parallel` + `-cb`/`--cont-batching` machinery
  this project depends on for low-latency concurrent requests) is
  built around causal decoder-only KV-cache slots. It is not designed
  for, or exercised with, encoder-decoder inference. Even where T5
  loads via `llama-cli`, there is no confirmed working path through
  `llama-server`'s slot/batching system for it.
- CodeT5 specifically (as distinct from Google's Flan-T5 checkpoints)
  has no confirmed, community-verified GGUF conversion at all.

**Refinement:** state the reason precisely — not "T5 is unsupported"
but "T5 is supported only in a limited, batching-incompatible,
lower-priority code path, and CodeT5 specifically is unconverted" — and
choose a causal decoder-only ("LLaMA-style") instruct model instead, as
both documents ultimately recommend.

### 3.2 Recommended replacement models
**Claim:** Qwen2.5-1.5B-Instruct, SmolLM2-1.7B-Instruct, or
Phi-3.5-mini-instruct as GGUF-compatible, causal-decoder alternatives.
**Verdict: ✅ Directionally correct** — all three are genuine causal
decoder-only instruct models with community GGUF conversions in
circulation. ❓ **Unverifiable as a permanent fact**: exact model
recommendations age quickly (new small instruct models ship
frequently); treat this as "pick a current small causal-decoder
instruct model with a GGUF conversion," not a fixed choice, and verify
the specific GGUF file/quantization you plan to use actually loads
with `llama-server --model <file>` before committing to it.

### 3.3 Fine-tuning for commit messages
**Claim:** fine-tune on a commit-message dataset rather than using a
generic instruct model as-is, to avoid the model emitting code instead
of a commit summary.
**Verdict: ❓ Reasonable engineering judgment, not a checkable fact.**
It is true that generic instruct models can drift into code-completion
mode on diff-shaped input; prompt engineering (explicit system
instruction, few-shot examples, a `stop` sequence at newline) can
mitigate this without fine-tuning and is the cheaper first step. Treat
fine-tuning as a stated future improvement, not a hard requirement for
a first working version.

---

## 4. `llama.cpp` server flags

### 4.1 `--cont-batching`
**Claim:** required to avoid queuing delays under rapid, concurrent
requests.
**Verdict: ⚠️ True in spirit, but the default has changed.** In
`llama.cpp` releases prior to mid-2024, continuous batching defaulted
to **disabled** and had to be passed explicitly. In the current
`tools/server` documentation, `-cb`/`--cont-batching` (with
`-nocb`/`--no-cont-batching` to turn it off) is now documented as
**enabled by default**. **Refinement:** don't rely on a specific
default — pin your deployment by passing the flag explicitly (or its
negation) regardless of which way the shipped default currently
points, and verify against the `llama-server --help` output for the
exact build/version you deploy.

### 4.2 `--mlock`
**Claim:** use `--mlock` to keep the model resident in RAM.
**Verdict: ⚠️ Works today but is a deprecated flag.** Current
`llama-server` documentation marks `--mlock` (and `--no-mmap`) as
**"DEPRECATED in favor of `--load-mode`"**, which now takes one value:
`none`, `mmap`, `mlock`, `mmap+mlock`, or `dio` (direct I/O).
**Refinement:** prefer `--load-mode mlock` (or `mmap+mlock`) in new
deployments; `--mlock` will likely keep working for a transition period
but should not be treated as the long-term-correct flag in new
documentation.

### 4.3 `--parallel` / slot count
**Claim (implicit):** `--parallel 4` gives four concurrent request
slots.
**Verdict: ✅ Mechanically correct**, but ❓ **the default value is not
a stable fact** — it has been documented as `1` in some historical
versions and `-1` ("auto") in current versions, and there are open
`llama.cpp` issues about the effective slot count not matching the
documented default in some builds. **Refinement:** always pass
`--parallel` explicitly; do not depend on the default.

### 4.4 Context size and diff truncation
**Claim:** cap the injected `git diff --cached` to fit comfortably
inside the context window (documents suggested 1500-6000 characters/
tokens depending on the passage).
**Verdict: ✅ Correct as a general principle** — `--ctx-size` is a hard
memory/token budget shared across the prompt and generation, and an
oversized diff will either truncate silently, error, or (with multiple
parallel slots) divide an already-limited context further per slot.
❓ **The exact token budget is not a fixed fact** — it depends on the
chosen model's native context length, the `--ctx-size` and
`--parallel` values you pick, and how much room you reserve for
generation. Treat "truncate the diff" as correct guidance and pick the
actual number empirically for your chosen model/config.

### 4.5 API endpoint
**Neither document specifies clearly** which HTTP endpoint to target.
**Fact:** `llama-server` exposes both a legacy `/completion` endpoint
and an OpenAI-compatible surface (`/v1/completions`,
`/v1/chat/completions`, etc.). **Refinement:** target the
OpenAI-compatible endpoint (`/v1/completions` for a plain instruct
prompt, or `/v1/chat/completions` if the chosen model ships a chat
template) — it is the actively maintained, documented, portable
surface, and lets you swap `llama-server` for another OpenAI-compatible
local server later without changing the daemon's HTTP client code.

---

## 5. Summary table

| Claim | Original doc | "Refined" doc | Verified verdict |
|---|---|---|---|
| Override `self-insert` | ✅ | ✅ | ✅ Correct |
| Reimplement char insert by hand | (did this) | fixed → `zle .self-insert` | Original ❌, refinement ✅ |
| `region_highlight=("p0 0 0 244")` | (used this) | fixed → `"$start $end fg=244"` | Original ❌, refinement ✅ |
| Restrict to cursor-at-end | not mentioned | ✅ added | ✅ Correct addition |
| Sync subprocess call in widget | (did this) | flagged as bug | Original ❌ |
| FIFO + polling for async | — | proposed as fix | ⚠️ Works but not the real mechanism — use `zpty`/`zle -F` |
| Race-condition IDs | mentioned | detailed | ✅ Correct, necessary |
| Tab fallback to `expand-or-complete` | mentioned | detailed | ✅ Correct |
| "T5 unsupported in llama.cpp" | (used CodeT5) | stated flatly | ⚠️ Overstated — T5 support exists but is second-class and batching-incompatible; conclusion (avoid it) still holds |
| `--cont-batching` required | ✅ | ✅ | ⚠️ Now defaults on in current builds — pin explicitly regardless |
| `--mlock` | — | ✅ recommended | ⚠️ Deprecated in favor of `--load-mode mlock` |
| Debounce / whitespace-triggered queries | — | ✅ recommended | ✅ Sound engineering judgment (not independently fact-checkable) |
