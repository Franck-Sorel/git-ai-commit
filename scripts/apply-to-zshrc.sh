#!/usr/bin/env bash
# Enable the git-ai-commit plugin by adding a source line to ~/.zshrc.
# Idempotent: re-running does not duplicate the line.
#
# Usage: ./apply-to-zshrc.sh [path-to-plugin.zsh]
set -euo pipefail

PLUGIN_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zsh/git-ai-commit.plugin.zsh"
PLUGIN_PATH="${1:-$PLUGIN_DEFAULT}"
ZSHRC="${HOME}/.zshrc"

if [[ ! -f "$PLUGIN_PATH" ]]; then
  echo "error: plugin not found at $PLUGIN_PATH" >&2
  exit 1
fi

LINE="source \"$PLUGIN_PATH\""
if grep -qF "$LINE" "$ZSHRC" 2>/dev/null; then
  echo "already enabled in $ZSHRC"
else
  printf '\n# git-ai-commit: ghost-text commit message completion\n%s\n' "$LINE" >> "$ZSHRC"
  echo "added to $ZSHRC:"
  echo "  $LINE"
fi

echo
echo "Next steps:"
echo "  1) pip install -e .        # install python deps (aiohttp)"
echo "  2) ./scripts/download-model.sh   # fetch a small GGUF model"
echo "  3) ./bin/llama-server.sh   # start the model server"
echo "  4) python -m git_ai_commit.daemon &   # start the daemon"
echo "  5) open a new zsh, type:  git commit -m \"add login {\""
