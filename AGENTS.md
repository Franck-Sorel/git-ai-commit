# AGENTS.md — For AI agents and human contributors

> **READ THIS FIRST.** This file gives any agent (AI or human) the
> mindset of this project before it touches code. The authoritative,
> full documentation lives in [`docs/`](docs/README.md). This file is
> the compressed must-obey summary. If anything here conflicts with
> `docs/`, `docs/` wins.

## Project in one sentence

A Zsh plugin that shows Copilot-style ghost-text completion for
`git commit -m "…"` messages, using a local `llama-server` model via a
Python daemon, with `zsh/zpty` async transport.

**Git never runs.** The plugin only edits what you type in the ZLE
buffer. The user still presses Enter to actually commit.

## Architecture (4 processes)

```
Zsh + plugin  --pty (zsh/zpty)-->  worker.py  --AF_UNIX-->  daemon.py  --HTTP /v1/completions-->  llama-server
```

- `zsh/` — the Zle plugin (self-insert wrapper, Tab accept, `zle -F` callback).
- `bin/worker.py` — per-shell pty<->socket bridge.
- `src/git_ai_commit/daemon.py` — long-lived daemon: debounce, diff cache, HTTP client, socket auth.
- `bin/llama-server.sh` — pinned `llama-server` invocation.
- `scripts/apply-to-zshrc.sh` — install/enable for the user.

## Non-negotiable rules (violating any = design bug)

1. **Never block Zsh's main thread in a widget.** No sync subprocess/
   network inside `self-insert`. (docs/02 §2.1)
2. **Async transport is `zsh/zpty` + `zle -F`. NO FIFO/sleep-polling**
   loops. (ADR-0001)
3. **In widgets, call `zle .self-insert`** — never reimplement char
   insertion by hand (breaks multibyte/repeat/paste). (docs/01 §1.2)
4. **`POSTDISPLAY`/highlight only when cursor is at end of buffer.**
5. **`region_highlight` elements are `"start end fg=N"`** — never the
   invalid `"p0 0 0 244"` form. (docs/01 §1.4)
6. **Tab falls back to `zle expand-or-complete`** when no suggestion.
7. **Use OpenAI-compatible `/v1/completions`**, not legacy
   `/completion`. (ADR-0003)
8. **Model is causal-decoder instruct + GGUF; NO T5/CodeT5.** (ADR-0004)
9. **Pin `llama-server` flags explicitly** (`--cont-batching`,
   `--parallel N`, prefer `--load-mode mlock`). (docs/01 §4)
10. **Verify socket peers by UID** on every connection (+ `chmod 0600`).
    UID only; never rely on PID. (ADR-0005, docs/06)
11. **Diff cache keyed by `cwd`, never global.** (ADR-0008)
12. **Never log staged diff / prompt content to disk.**
13. **Degrade gracefully**: run a `zpty` self-test at load; on failure
    disable only suggestions, never break completion/shell. (ADR-0011)
14. **Discard stale async responses** by `id` + buffer-prefix re-check.
15. **Debounce + cancel every inference** (~250ms default); one keystroke
    must not equal one network call.

## Trigger strategy (ADR-0006)

- **Default: whitespace-triggered** (space in commit context fires a
  request). Robust to CPU inference.
- Per-keystroke is an **opt-in** gated on a locally measured low
  time-to-first-token.
- `Ctrl+Space` / explicit accept always available.

## Config (ADR-0010)

Env vars override a TOML config (`~/.config/git-ai-commit/config.toml`)
override defaults. Env prefix `GIT_AI_` (e.g. `GIT_AI_MODEL_PATH`,
`GIT_AI_LLAMA_URL`, `GIT_AI_TRIGGER`, `GIT_AI_DEBOUNCE_MS`,
`GIT_AI_SOCKET_PATH`, `GIT_AI_HIGHLIGHT_STYLE`).

## Commands

- Install deps: `pip install -e .` (aiohttp)
- Run daemon (dev): `python -m git_ai_commit.daemon`
- Enable plugin: `scripts/apply-to-zshrc.sh` (or install as a plugin-manager
  plugin via the root `git-ai-commit.plugin.zsh` loader)
- Diagnose: `scripts/doctor.sh` (one-command self-check)
- Tests: `make test` runs everything below —
  `pytest -q` (daemon) + `zsh tests/smoke.zsh` (plugin logic) +
  `zsh tests/interactive.zsh` (plugin load in a real ZLE) +
  `bash tests/e2e-workflow.sh` (cross-env: plugin-manager load, ZLE,
  real daemon+worker vs mock LLM, lazy daemon auto-start) +
  `bash tests/integration.sh` (real processes vs mock LLM)
- CI: `.github/workflows/ci.yml` runs all tests on Ubuntu + macOS and
  Python 3.10/3.11/3.12 for every PR.
- Lint: `ruff check` (if present); keep Python 3.10+ compatible.

## Do NOT

- Do not re-introduce FIFO/polling async.
- Do not add a hard dependency on `jq` in the ZLE callback (hand-rolled
  JSON parse or a guaranteed-fast local python3 call only).
- Do not pin a specific model name in code (config only).
- Do not let the daemon buffer/log prompt or diff contents.

## Lifecycle note

`daemon.py` is a single long-lived process shared across shells (future
systemd/launchd); `worker.py` is per-shell and lazily spawned/respawned
by the plugin.

Full details: [`docs/README.md`](docs/README.md) then the ADRs in
[`docs/adr/`](docs/adr/README.md).
