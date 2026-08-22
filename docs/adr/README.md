# Architecture Decision Records (ADRs)

This directory records every significant architectural decision made
for the ghost-text commit assistant. Each ADR follows the classic
**Context / Decision / Consequences** format (from Nygard's ADR
pattern) and names the specific document/line that the decision
corrects or implements.

## How to read these

- ADRs are **append-only**. Never edit a record's *Decision* to match
  new code; supersede it with a new ADR that references the old one.
- Each ADR cites the exact source (`docs/0N-*.md`, line/section) it
  implements or corrects, so anyone can trace a code decision back to
  the verified baseline.
- The decisions here ARE the "hard baseline". Code must not silently
  contradict an ADR. If code and an ADR disagree, that is a bug in
  the code (or a deliberate change that requires a new ADR).

## Index

| ADR | Title | Status | Supersedes |
|---|---|---|---|
| [ADR-0001](0001-zpty-async-transport.md) | `zsh/zpty` + `zle -F` for async transport | ACCEPTED | - |
| [ADR-0002](0002-python-daemon-unix-socket.md) | Persistent Python daemon over a Unix domain socket | ACCEPTED | - |
| [ADR-0003](0003-openai-compatible-endpoint.md) | OpenAI-compatible `/v1/completions` endpoint | ACCEPTED | - |
| [ADR-0004](0004-causal-decoder-model.md) | Causal decoder-only instruct model (not T5/CodeT5) | ACCEPTED | - |
| [ADR-0005](0005-socket-peer-cred-uid.md) | Peer-credential UID verification on the socket | ACCEPTED | - |
| [ADR-0006](0006-trigger-strategy.md) | Whitespace-triggered default, per-keystroke opt-in | ACCEPTED | - |
| [ADR-0007](0007-per-shell-zpty-worker.md) | Per-shell worker bridging pty <-> socket | ACCEPTED | - |
| [ADR-0008](0008-diff-cache-per-cwd.md) | Diff cache keyed by working directory | ACCEPTED | - |
| [ADR-0009](0009-prompt-engineering-only.md) | Prompt engineering first; defer fine-tuning | ACCEPTED | - |
| [ADR-0010](0010-config-env-and-file.md) | Configuration via environment + TOML config file | ACCEPTED | - |
| [ADR-0011](0011-zpty-selftest-degrade.md) | `zpty` self-test at load; graceful degradation | ACCEPTED | - |
| [ADR-0012](0012-json-ipc-newline-delimited.md) | Newline-delimited JSON IPC contract | ACCEPTED | - |

## Decision timeline

```
ADR-0001 (async transport)   ────────────────────────────────────┐
ADR-0002 (daemon)            ────────────────────────────────────┤
ADR-0003 (endpoint)          ────────────────────────────────────┤
ADR-0004 (model arch)        ────────────────────────────────────┤
ADR-0005 (socket security)   ────────────────────────────────────┤
ADR-0006 (trigger)           ────────────────────────────────────┼── Implemented in src/ + zsh/
ADR-0007 (worker)            ────────────────────────────────────┤
ADR-0008 (diff cache)        ────────────────────────────────────┤
ADR-0009 (prompt)            ────────────────────────────────────┤
ADR-0010 (config)            ────────────────────────────────────┤
ADR-0011 (zpty selftest)     ────────────────────────────────────┤
ADR-0012 (IPC contract)      ────────────────────────────────────┘
```
