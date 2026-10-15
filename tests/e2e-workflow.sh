#!/usr/bin/env bash
# End-to-end workflow test — cross-environment (Linux + macOS).
#
# Exercises the REAL load path a user experiences:
#
#   1. Plugin-manager style load of the root loader
#      (git-ai-commit.plugin.zsh) and confirm it wires bin/ onto PATH
#      and sources the real plugin. This is how oh-my-zsh / zgen /
#      antigen / zim load it.
#   2. zpty self-test + context detection in a real interactive zsh.
#   3. The real daemon + real worker against the mock LLM (the exact
#      socket path Zsh uses), verifying a suggestion round-trips.
#   4. Lazy daemon auto-start: the plugin starts the daemon when the
#      socket is absent.
#
# Portable across Linux and macOS (no GNU-isms; uses stat -f on macOS).
#
# Usage:  bash tests/e2e-workflow.sh   (uses the project venv if present)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-${ROOT}/.venv/bin/python}"
if [[ ! -x "$PY" ]]; then PY=python3; fi
LLM_PORT="${LLM_PORT:-8097}"

tmp="$(mktemp -d)"
SOCK_PATH="$tmp/daemon.sock"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  # Kill any daemon still bound to our temp sockets (they were nohup-detached).
  pgrep -f "git_ai_commit.daemon" 2>/dev/null | while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

# --------------------------------------------------------------------------
# 1. Root loader (plugin-manager style) — run in a clean zsh.
# --------------------------------------------------------------------------
echo "== [1/4] plugin-manager load of the root loader =="
PLUGIN_OUT="$(zsh -f -c '
  zmodload zsh/zpty 2>/dev/null || { print "no zpty"; exit 1 }
  source "$1"
  print "PATH_HAS_BIN:$([[ ":$PATH:" == *":$2/bin:"* ]] && print yes || print no)"
  print "PLUGIN_LOADED:${+functions[_ai_in_commit_context]}"
  print "WORKER:$AI_WORKER_SCRIPT"
' zsh "$ROOT/git-ai-commit.plugin.zsh" "$ROOT" 2>/dev/null)" || PLUGIN_OUT="load-failed"
echo "$PLUGIN_OUT"
echo "$PLUGIN_OUT" | grep -q "PATH_HAS_BIN:yes"  && ok "root loader added bin/ to PATH"  || bad "bin/ not on PATH"
echo "$PLUGIN_OUT" | grep -q "PLUGIN_LOADED:1"  && ok "real plugin sourced by loader"  || bad "plugin not sourced"
echo "$PLUGIN_OUT" | grep -q "WORKER:$ROOT/bin/worker.py" && ok "worker path resolved to repo" || bad "worker path wrong"
echo

# --------------------------------------------------------------------------
# 2. Context detection + apply/clear in a real interactive zsh.
# --------------------------------------------------------------------------
echo "== [2/4] real interactive zsh (zpty self-test + context) =="
RESULT="$tmp/result.txt"
zsh -f -i -c '
  source "$1"
  {
    echo "READY:$AI_ENABLED"
    LBUFFER="git commit -m \"add login "
    RBUFFER=""
    _ai_in_commit_context && echo "CTX_OPEN:yes" || echo "CTX_OPEN:no"
    _ai_apply_suggestion " validation"
    echo "SUGGEST:${AI_SUGGESTION}"
    _ai_clear_suggestion
    echo "CLEARED:${AI_SUGGESTION}"
  } > "$2"
  exit
' zsh "$ROOT/zsh/git-ai-commit.plugin.zsh" "$RESULT" 2>/dev/null || true
sleep 0.3
R="$(cat "$RESULT" 2>/dev/null)"
echo "$R"
echo "$R" | grep -q "READY:1"       && ok "zpty self-test passed (plugin enabled)" || bad "plugin not enabled"
echo "$R" | grep -q "CTX_OPEN:yes"  && ok "open -m context detected"              || bad "context not detected"
echo "$R" | grep -q "SUGGEST: validation" && ok "suggestion applied"              || bad "apply failed"
echo "$R" | grep -q "CLEARED:"      && ok "suggestion cleared"                    || bad "clear failed"
echo

# --------------------------------------------------------------------------
# 3. Real daemon + real worker vs mock LLM (the exact socket path).
# --------------------------------------------------------------------------
echo "== [3/4] real daemon + real worker vs mock LLM =="
export GIT_AI_SOCKET_PATH="$SOCK_PATH"
"$PY" "$ROOT/tests/mock_llm.py" --port "$LLM_PORT" >/dev/null 2>&1 &
pids+=($!); sleep 1

GIT_AI_LLAMA_URL="http://127.0.0.1:$LLM_PORT/v1/completions" \
  "$PY" -m git_ai_commit.daemon >/dev/null 2>&1 &
pids+=($!)
for i in $(seq 1 50); do [[ -S "$SOCK_PATH" ]] && break; sleep 0.1; done
[[ -S "$SOCK_PATH" ]] && ok "daemon created socket" || bad "daemon socket missing"

RESP="$(printf '%s\n' '{"id":7,"prefix":"feat(auth): add ","cwd":"/tmp"}' | "$PY" "$ROOT/bin/worker.py")"
echo "$RESP"
echo "$RESP" | grep -q '"status": "ok"' && ok "worker -> daemon -> model round trip" || bad "no ok status"
echo "$RESP" | grep -q 'login validation' && ok "suggestion text correct" || bad "unexpected suggestion"

# portability: socket permission check (macOS: stat -f %Lp, Linux: stat -c %a)
case "$(uname -s)" in
  Darwin) perm="$(stat -f '%Lp' "$SOCK_PATH" 2>/dev/null)" ;;
  *)      perm="$(stat -c '%a' "$SOCK_PATH" 2>/dev/null)" ;;
esac
[[ "$perm" == "600" || "$perm" == "0600" ]] && ok "socket perms 0600" || bad "socket perm $perm != 600"
echo

# --------------------------------------------------------------------------
# 4. Lazy daemon auto-start (plugin starts the daemon when socket absent).
# --------------------------------------------------------------------------
echo "== [4/4] lazy daemon auto-start =="
# Kill the daemon, keep a fresh socket dir, and confirm the plugin's
# _ai_ensure_daemon (called from the plugin's load-time auto-start) spawns
# the daemon and creates the socket.
for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
pids=()
AUTO_SOCK="$tmp/auto.sock"
sleep 0.3
zsh -f -i -c '
  # export BEFORE sourcing so the plugin computes AI_SOCKET_PATH from it
  export GIT_AI_SOCKET_PATH="$2"
  export GIT_AI_AUTOSTART=1
  source "$1"
  for i in {1..50}; do [[ -S "$GIT_AI_SOCKET_PATH" ]] && break; sleep 0.1; done
  [[ -S "$GIT_AI_SOCKET_PATH" ]] && print "AUTOSTART:yes" || print "AUTOSTART:no"
' zsh "$ROOT/zsh/git-ai-commit.plugin.zsh" "$AUTO_SOCK" 2>/dev/null
# the daemon we just spawned was nohup-detached; it is killed by cleanup()
[[ -S "$AUTO_SOCK" ]] && ok "plugin auto-started the daemon" || bad "daemon not auto-started"
echo

echo "summary: $pass ok, $fail failures"
[[ "$fail" -eq 0 ]] && { echo "E2E OK"; exit 0; } || { echo "E2E FAILED"; exit 1; }
