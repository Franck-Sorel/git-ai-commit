#!/usr/bin/env bash
# git-ai-commit doctor: one-command self-check.
#
# Diagnoses the most common reasons the plugin "doesn't work" by checking
# each link in the chain, in order:
#
#   zsh/zpty  ->  python3  ->  daemon socket  ->  worker  ->  llama-server
#
# Exits non-zero if any *required* check fails. Optional checks (the model
# server) are reported but do not fail the run, because the daemon degrades
# gracefully and the suggestion just won't appear until the model is up.
#
# Usage:
#   ./scripts/doctor.sh
#   GIT_AI_LLAMA_URL=... ./scripts/doctor.sh   # point at your llama-server
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET_PATH="${GIT_AI_SOCKET_PATH:-${XDG_RUNTIME_DIR:-/tmp/git-ai-commit-$(id -u)}/daemon.sock}"
LLAMA_URL="${GIT_AI_LLAMA_URL:-http://127.0.0.1:8080/v1/completions}"

PASS=0; FAIL=0; WARN=0
say() { printf '  %s %s\n' "$1" "$2"; }
ok()   { say '✓' "$1"; PASS=$((PASS+1)); }
bad()  { say '✗' "$1"; FAIL=$((FAIL+1)); }
warn() { say '~' "$1"; WARN=$((WARN+1)); }

echo "git-ai-commit doctor"
echo "  repo:    $ROOT"
echo "  socket:  $SOCKET_PATH"
echo "  model:   $LLAMA_URL"
echo

# --- 1. zsh + zpty ---------------------------------------------------------
echo "[1/5] zsh + zsh/zpty"
if command -v zsh >/dev/null 2>&1; then
  ok "zsh found ($(zsh --version | awk '{print $2}'))"
else
  bad "zsh not found"
fi
if zsh -f -c 'zmodload zsh/zpty 2>/dev/null && print OK' 2>/dev/null | grep -q OK; then
  ok "zsh/zpty module loads"
else
  bad "zsh/zpty module unavailable — plugin is disabled (ADR-0011)"
fi

# --- 2. python + aiohttp ---------------------------------------------------
echo "[2/5] python3 + aiohttp"
PY="${GIT_AI_PYTHON:-}"
if [[ -z "$PY" && -x "$ROOT/.venv/bin/python" ]]; then PY="$ROOT/.venv/bin/python"; fi
if [[ -z "$PY" ]]; then PY="$(command -v python3 || echo python)"; fi
if command -v "$PY" >/dev/null 2>&1; then
  ok "python found ($("$PY" --version 2>&1))"
else
  bad "python not found at $PY — set GIT_AI_PYTHON"
fi
if "$PY" -c 'import aiohttp' 2>/dev/null; then
  ok "aiohttp installed"
else
  warn "aiohttp not installed for $PY (daemon won't start) — run: pip install -e ."
fi

# --- 3. daemon socket ------------------------------------------------------
echo "[3/5] daemon"
if [[ -S "$SOCKET_PATH" ]]; then
  ok "daemon socket present: $SOCKET_PATH"
else
  if [[ "${GIT_AI_AUTOSTART:-1}" == "1" ]]; then
    warn "daemon not running yet — the plugin auto-starts it on next zsh load"
  else
    warn "daemon not running — start it: PYTHONPATH=$ROOT/src $PY -m git_ai_commit.daemon &"
  fi
fi

# --- 4. worker round-trip --------------------------------------------------
echo "[4/5] worker <-> daemon round trip"
if [[ -S "$SOCKET_PATH" ]]; then
  RESP="$(printf '%s\n' '{"id":1,"prefix":"test","cwd":"/tmp"}' \
    | "$PY" "$ROOT/bin/worker.py" 2>/dev/null || true)"
  if echo "$RESP" | grep -q '"status": "ok"'; then
    ok "worker reached the daemon (suggestion: $(echo "$RESP" | sed -n 's/.*"suggestion": *"\([^"]*\)".*/\1/p'))"
  elif echo "$RESP" | grep -q '"status": "error"'; then
    bad "worker got an error from the daemon: $(echo "$RESP")"
  else
    warn "no response from worker (daemon may have just started; try again)"
  fi
else
  warn "skipped (no daemon socket)"
fi

# --- 5. llama-server -------------------------------------------------------
echo "[5/5] model server (llama-server)"
if command -v llama-server >/dev/null 2>&1; then
  ok "llama-server on PATH"
else
  warn "llama-server not on PATH — install llama.cpp or set a remote GIT_AI_LLAMA_URL"
fi
if curl -sf --max-time 3 -o /dev/null "$LLAMA_URL" 2>/dev/null \
  || curl -sf --max-time 3 -o /dev/null "${LLAMA_URL%/v1/completions}" 2>/dev/null; then
  ok "model endpoint reachable: $LLAMA_URL"
else
  warn "model endpoint not reachable at $LLAMA_URL — suggestions won't appear until it's up"
fi

echo
echo "summary: $PASS ok, $WARN warnings, $FAIL failures"
if (( FAIL )); then
  echo "FAIL: fix the ✗ items above, then restart zsh."
  exit 1
fi
echo "OK: required checks pass."
exit 0
