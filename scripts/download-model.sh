#!/usr/bin/env bash
# Download a small causal-decoder instruct GGUF model for local inference
# (ADR-0004, rule 8). Model choice is deploy-time, not code-time (ADR-0010).
#
# A single-model convenience wrapper: set GIT_AI_MODEL_URL to override.
# Otherwise it prints guidance, because model URLs age quickly and must be
# re-verified at implementation time (docs/07 item 4).
set -euo pipefail

DEST="${GIT_AI_MODEL_DIR:-${HOME}/.cache/git-ai-commit}"
mkdir -p "$DEST"

MODEL_URL="${GIT_AI_MODEL_URL:-}"
MODEL_NAME="${GIT_AI_MODEL_NAME:-}"

if [[ -z "$MODEL_URL" ]]; then
  echo "Set GIT_AI_MODEL_URL to a .gguf instruct model URL to auto-download."
  echo
  echo "Guidance (pick a current small causal-decoder instruct GGUF, e.g. a"
  echo "Qwen/SmolLM/Phi-family Q4_K_M quant):"
  echo "  GIT_AI_MODEL_URL=<...> ${BASH_SOURCE[0]}"
  echo
  echo "Place the .gguf in: $DEST"
  echo "Then start the server with:  GIT_AI_MODEL_PATH=\"$DEST/<model>.gguf\" ./bin/llama-server.sh"
  exit 1
fi

[[ -n "$MODEL_NAME" ]] || MODEL_NAME="$(basename "$MODEL_URL")"

if [[ -f "$DEST/$MODEL_NAME" ]]; then
  echo "already present: $DEST/$MODEL_NAME"
else
  echo "downloading $MODEL_URL -> $DEST/$MODEL_NAME"
  curl -L --fail --progress-bar -o "$DEST/$MODEL_NAME" "$MODEL_URL"
fi

echo
echo "Start the server:"
echo "  GIT_AI_MODEL_PATH=\"$DEST/$MODEL_NAME\" ./bin/llama-server.sh"
