# ADR-0010: Configuration via environment + TOML config file

- **Status:** ACCEPTED
- **Date:** 2026-08-22
- **Source:** Resolves the "moving target" of model choice (risk #7) and the tunable parameters (debounce, trigger, highlight style).

## Context

Several values must be tunable at deployment time without editing
code: model path, llama URL, debounce interval, trigger strategy,
highlight style, diff max chars, socket path. Named-model choices age
quickly; hardcoding them would make the project brittle.

## Decision

Configuration precedence: **environment variable overrides config-file
value overrides built-in default.**

- A single TOML config file (default `~/.config/git-ai-commit/config.toml`).
- Env vars prefixed `GIT_AI_` (e.g. `GIT_AI_MODEL_PATH`,
  `GIT_AI_LLAMA_URL`, `GIT_AI_TRIGGER`, `GIT_AI_DEBOUNCE_MS`,
  `GIT_AI_SOCKET_PATH`, `GIT_AI_HIGHLIGHT_STYLE`).
- The daemon reads config; the Zsh plugin reads the few shell-side
  values (highlight style, trigger, socket path).

## Consequences

- **Positive:** Model + tuning choices are deploy-time, not code-time.
- **Positive:** The friend who tests it can point at their own model
  without forking.
- **Negative:** Two config surfaces (env + file) to document; needs a
  clear precedence rule (env wins).

## Related

- ADR-0004 (configurable model path)
- ADR-0006 (trigger strategy config flag)
