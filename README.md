# git-ai-commit

Copilot-style **ghost-text completion** for `git commit -m "…"` in Zsh,
powered by a local `llama-server` (llama.cpp) model. As you type a commit
message, it suggests the rest of the message inline, based on your staged
diff — completely offline.

```
$ git commit -m "feat(auth): add logi▊
                                    ^ ghost text suggests: "n validation"
```

**Git never runs.** The plugin only edits the text in your Zsh buffer.
You still press Enter / run `git commit` yourself.

## How it works (4 processes)

```
Zsh + plugin  --pty-->  worker.py  --socket-->  daemon.py  --HTTP-->  llama-server
```

| Component | Role |
|---|---|
| `zsh/git-ai-commit.plugin.zsh` | ZLE widgets: ghost text, Tab-accept, async callback (`zpty` + `zle -F`) |
| `bin/worker.py` | per-shell bridge: pty stdio <-> Unix socket (never blocks Zsh) |
| `src/git_ai_commit/daemon.py` | debounce, per-`cwd` diff cache, llama-server HTTP client, socket peer-auth |
| `bin/llama-server.sh` | pinned `llama-server` invocation (causal decoder GGUF) |

For the full design rationale (fact-checked against Zsh + llama.cpp docs),
see [`docs/README.md`](docs/README.md) and the ADRs in
[`docs/adr/`](docs/adr/README.md).

## Requirements

- **Zsh** 5.x with the `zsh/zpty` module (standard in mainstream Linux/macOS builds)
- **Python** 3.10+ (`aiohttp`; `tomli` on 3.10)
- **llama-server** from [llama.cpp](https://github.com/ggerganov/llama.cpp) on your `$PATH`
- A small **causal-decoder instruct GGUF** model (~1-3B, Q4) — e.g. Qwen/SmolLM/Phi family
- **git** (any recent version)

## Install

### Option A — Zsh plugin manager (recommended, oh-my-zsh / zgen / antigen / zim)

Clone the repo anywhere and enable it by name. Most managers look for
`git-ai-commit.plugin.zsh` at the repo root:

```sh
# oh-my-zsh example
git clone https://github.com/Franck-Sorel/git-ai-commit ~/.oh-my-zsh/custom/plugins/git-ai-commit
# then add `git-ai-commit` to plugins=(...) in ~/.zshrc
```

The plugin **auto-starts the daemon** on the first zsh load (unless
`GIT_AI_AUTOSTART=0`), so you don't need a separate manual step. You still
need a running `llama-server` and a model for suggestions to appear.

### Option B — manual `source`

```sh
# 1. Install Python deps (the plugin can also run from source via PYTHONPATH)
pip install -e .

# 2. Get a model (or set GIT_AI_MODEL_URL to any .gguf you prefer)
GIT_AI_MODEL_URL="<url-to-a-small-instruct-model.gguf>" ./scripts/download-model.sh

# 3. Enable the plugin in your ~/.zshrc
./scripts/apply-to-zshrc.sh

# 4. Start the LLM server (one terminal)
GIT_AI_MODEL_PATH="$HOME/.cache/git-ai-commit/<model>.gguf" ./bin/llama-server.sh

# 5. Open a new zsh, stage some changes, and type:
git commit -m "feat(auth): add "
#          Ghost text appears.  Press Tab to accept.
```

The daemon is started automatically on load. To manage it yourself instead,
set `GIT_AI_AUTOSTART=0` and run `python -m git_ai_commit.daemon` in a
terminal.

### Not working? Diagnose in one command

```sh
./scripts/doctor.sh
```

Checks every link (zsh/zpty, python+aiohttp, daemon socket, worker round
trip, llama-server) and tells you which one to fix.

## Usage

- In a git repo with a staged diff, type `git commit -m "…"`.
- Ghost text appears on **space** (whitespace-triggered by default —
  best for CPU inference). `GIT_AI_TRIGGER=keystroke` opts into
  per-keystroke updates (only on sufficiently fast hardware).
- **Tab** accepts the suggestion; with no suggestion it falls back to
  normal completion.
- **Ctrl+Space** forces a suggestion now.
- Typing the character that matches the ghost's first character *shrinks*
  it; any other character clears it.

## Configuration

Env var > config file (`~/.config/git-ai-commit/config.toml`) > defaults.
Env prefix `GIT_AI_`. Common settings:

| Env var | Default | Meaning |
|---|---|---|
| `GIT_AI_MODEL_PATH` | — | path to the .gguf model |
| `GIT_AI_LLAMA_URL` | `http://127.0.0.1:8080/v1/completions` | model HTTP endpoint |
| `GIT_AI_TRIGGER` | `space` | `space` \| `keystroke` \| `manual` |
| `GIT_AI_DEBOUNCE_MS` | `250` | debounce window |
| `GIT_AI_SOCKET_PATH` | XDG `/tmp/git-ai-commit-UID/daemon.sock` | daemon socket |
| `GIT_AI_AUTOSTART` | `1` | `0` disables lazy daemon auto-start |
| `GIT_AI_PYTHON` | auto | explicit python for daemon/worker |
| `GIT_AI_HIGHLIGHT_STYLE` | `fg=244` | ghost-text style |
| `GIT_AI_CTX_SIZE` | `4096` | model context (llama-server) |
| `GIT_AI_PARALLEL` | `4` | concurrent slots (llama-server) |

## Test

```sh
make test          # everything below
pytest -q          # daemon unit tests (no llama-server needed; uses a mock)
zsh -f tests/smoke.zsh   # plugin load + context-detection smoke test
zsh tests/interactive.zsh # plugin load in a real ZLE (pytest + zpty)
bash tests/e2e-workflow.sh # cross-env: plugin-manager load, ZLE, real daemon+worker vs mock LLM, auto-start
bash tests/integration.sh  # real daemon + worker vs mock LLM
```

### CI on GitHub

All of the above run automatically on **GitHub Actions** (see
`.github/workflows/ci.yml`) across Linux (Ubuntu) and macOS, and on Python
3.10/3.11/3.12 — so every PR is verified end-to-end before merge.

## Docs / design baseline

`AGENTS.md` is the compressed must-obey summary. The authoritative
baseline (fact-check, architecture, ADRs, security, closeout) is in
[`docs/`](docs/README.md). Highlights:

- Async is **`zsh/zpty` + `zle -F`** — never FIFO/polling (ADR-0001).
- The main Zsh thread is **never blocked** in a widget.
- The daemon **verifies the socket peer UID** on every connection
  (ADR-0005) and never logs staged-diff content.
- **Graceful degradation**: a `zpty` self-test at load; on failure only
  the suggestions are disabled, the shell is untouched.

## License

MIT
