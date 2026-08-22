#!/usr/bin/env bash
# Pinned llama-server invocation (docs/01 §4, ADR-0004, rule 9).
#
# Flags are passed EXPLICITLY because the shipped defaults for
# --cont-batching and --parallel have changed across llama.cpp versions.
# --load-mode mlock replaces the deprecated --mlock.
#
# Usage:
#   GIT_AI_MODEL_PATH=/path/to/model.gguf ./llama-server.sh
#
# Config is read from env (ADR-0010); defaults match src/git_ai_commit/config.py.
set -euo pipefail

MODEL_PATH="${GIT_AI_MODEL_PATH:-}"
LLAMA_HOST="${GIT_AI_LLAMA_HOST:-127.0.0.1}"
LLAMA_PORT="${GIT_AI_LLAMA_PORT:-8080}"
CTX_SIZE="${GIT_AI_CTX_SIZE:-4096}"
PARALLEL="${GIT_AI_PARALLEL:-4}"
THREADS="${GIT_AI_THREADS:-$(nproc)}"
LOAD_MODE="${GIT_AI_LOAD_MODE:-mlock}"

if [[ -z "$MODEL_PATH" || ! -f "$MODEL_PATH" ]]; then
  echo "error: GIT_AI_MODEL_PATH must point to an existing .gguf file" >&2
  echo "  got: '$MODEL_PATH'" >&2
  echo "  set it, or run scripts/download-model.sh first" >&2
  exit 1
fi

exec llama-server \
  --model "$MODEL_PATH" \
  --host "$LLAMA_HOST" \
  --port "$LLAMA_PORT" \
  --ctx-size "$CTX_SIZE" \
  --parallel "$PARALLEL" \
  --cont-batching \
  --load-mode "$LOAD_MODE" \
  --threads "$THREADS"
