# Open Risks and Remaining Decisions

Things that are genuinely undetermined, environment-dependent, or a
matter of product judgment rather than a fact to verify. Listed
separately from the fact-check so engineering trade-offs aren't
mistaken for verified claims.

## 1. Latency is unmeasured, not just unverified

Neither source document cites a benchmark for its "200–500ms
inference latency" figure. This architecture's usability hinges
entirely on end-to-end latency (debounce + diff-cache lookup +
inference + IPC overhead) staying low enough that ghost text feels
responsive rather than laggy. **Action, not a fact:** benchmark on the
actual target hardware (CPU-only laptop vs. a machine with a GPU) with
the actual chosen model and quantization before treating "feels like
Copilot" as achieved. If CPU-only inference proves too slow for
comfortable typing, the debounce/whitespace-triggering strategy in
§4.4 below becomes load-bearing rather than optional polish.

## 2. `zsh/zpty` availability and portability

`zsh/zpty` is a standard Zsh module and ships with mainstream Zsh
builds on Linux and macOS, but:
- It is not guaranteed present in every minimal/embedded Zsh build
  (some distros split modules into separate packages).
- Pseudo-terminal behavior has platform quirks (line discipline,
  buffering) that can differ between Linux and macOS/BSD `zpty`
  implementations.
**This needs local verification on each target OS**, not an assumption
carried over from the fact-check (which confirms the module *exists*
and is the *right primitive*, not that it behaves identically
everywhere).

## 3. Worker process lifecycle

The implementation guide spawns the `zpty` worker lazily and leaves it
running for the shell's lifetime. Undecided trade-offs, not facts:
- **One worker per shell vs. one worker shared across all shells:** a
  per-shell worker is simpler and isolates crashes, but means N open
  terminal tabs hold N pty file descriptors and N Python processes
  (lightweight, but not free). A shared worker needs a supervision/
  restart story this document does not specify.
- **Restart-on-crash policy:** if the worker process dies (daemon
  killed the socket unexpectedly, Python exception, etc.), nothing in
  the code above automatically respawns it — `_ai_ensure_worker`
  checks liveness via `zpty -t` and would only respawn on the *next*
  keystroke that enters commit context. Decide whether that's
  acceptable or whether a `precmd`/`preexec` hook should actively
  health-check it.

## 4. Trigger strategy: per-keystroke vs. whitespace/pause-based

Both source documents ultimately recommend triggering on every
keystroke inside commit context (mitigated by debounce+cancellation),
with the refined document also suggesting an alternative of triggering
only on whitespace or a dedicated key. This is a genuine product
decision, not a settled fact:

| Strategy | Pro | Con |
|---|---|---|
| Every keystroke (debounced) | Feels most "live"; suggestion updates continuously | Highest request volume even with debouncing/cancellation; most sensitive to inference latency |
| Whitespace-triggered | Fewer, more semantically meaningful requests (aligns with how the model predicts phrases, not letters) | Suggestion feels "stale" until the next word boundary; user typing mid-word sees no live feedback |
| Explicit key (e.g. `Ctrl+Space`) | Zero background load; fully user-controlled | Least "magical"; closer to manual autocomplete than ghost text |

No universally correct answer — pick based on measured latency (§1)
and user preference; document the choice, don't treat either source
document's suggestion as final.

## 5. Prompt engineering vs. fine-tuning

The refined document recommends fine-tuning a small model on a
commit-message dataset. This is a legitimate future improvement but
represents significant additional engineering (dataset curation,
training infra, eval harness) beyond this architecture. **Recommended
sequencing, not a fact:** ship with prompt engineering only (explicit
system instruction, `stop` sequences, low temperature, possibly a
handful of few-shot examples in the prompt) first; only invest in
fine-tuning if the base instruct model's outputs prove unreliable in
practice (e.g., drifting into code output despite the system prompt).

## 6. Security surface

Not addressed by either source document at all:
- The Unix socket the daemon listens on can trigger `git diff` reads
  and LLM calls from any process able to connect to it. The
  implementation guide restricts socket permissions to the owning
  user (`0o600`), but a full threat model (e.g., should the daemon
  also verify the calling process's UID via `SO_PEERCRED`?) is out of
  scope here and should be decided before shipping this beyond a
  single-user local dev tool.
- Diffs — potentially containing secrets accidentally staged — are
  sent to a local model process. For a fully local `llama-server`, the
  data doesn't leave the machine, which is a meaningfully different
  risk profile than a cloud API, but it's worth stating explicitly
  rather than assuming "local" automatically means "no data-handling
  concerns" (e.g., if the daemon or `llama-server` logs prompts to
  disk for debugging, that's a new place a staged secret could persist).

## 7. Model choice is a moving target

Fact-check §3.2 already flags this: any specific model recommendation
(Qwen2.5-1.5B-Instruct, SmolLM2, Phi-3.5-mini, etc.) will age. Treat
"causal decoder-only, GGUF-convertible, small enough for CPU inference
within your latency budget" as the durable requirement, and re-check
current model availability/quality at implementation time rather than
locking in a name from this document set.
