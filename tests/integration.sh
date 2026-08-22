#!/usr/bin/env bash
# End-to-end integration test: wires the REAL processes together.
#
#   mock-LLM(HTTP)  <--  daemon.py(AF_UNIX)  <--  worker.py(stdin/stdout)
#
# Verifies a JSON request piped to the real worker returns a suggestion
# from the "model", through the real daemon and the real socket. This is
# the exact path Zsh uses, minus ZLE.
#
# Usage:  bash tests/integration.sh   (uses the project venv if present)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-${ROOT}/.venv/bin/python}"
if [[ ! -x "$PY" ]]; then PY=python3; fi
sockdir="$(mktemp -d)"
LLM_PORT="${LLM_PORT:-8099}"
SOCK_PATH="$sockdir/daemon.sock"

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$sockdir"
}
trap cleanup EXIT

# Shared socket path for daemon and worker (both read GIT_AI_SOCKET_PATH).
export GIT_AI_SOCKET_PATH="$SOCK_PATH"

echo "== starting mock LLM on :$LLM_PORT"
"$PY" "$ROOT/tests/mock_llm.py" --port "$LLM_PORT" >/dev/null 2>&1 &
pids+=($!)
sleep 1

echo "== starting daemon (real)"
GIT_AI_LLAMA_URL="http://127.0.0.1:$LLM_PORT/v1/completions" \
  "$PY" -m git_ai_commit.daemon >/dev/null 2>&1 &
pids+=($!)
for i in $(seq 1 50); do [[ -S "$SOCK_PATH" ]] && break; sleep 0.1; done
[[ -S "$SOCK_PATH" ]] || { echo "FAIL: daemon socket not created"; exit 1; }
echo "   daemon socket: $SOCK_PATH"

echo "== round trip through the real worker"
RESP="$(printf '%s\n' '{"id":1,"prefix":"feat(auth): add ","cwd":"/no/such/repo"}' \
  | "$PY" "$ROOT/bin/worker.py")"
echo "   worker response: $RESP"

echo "$RESP" | grep -q '"status": "ok"' || { echo "FAIL: no ok status"; exit 1; }
echo "$RESP" | grep -q 'login validation' || { echo "FAIL: unexpected suggestion"; exit 1; }

echo "== security: socket permissions are 0600"
perm="$(stat -c '%a' "$SOCK_PATH")"
[[ "$perm" == "600" || "$perm" == "0600" ]] || { echo "FAIL: socket perm $perm != 600"; exit 1; }
echo "   socket perm: $perm"

echo
echo "INTEGRATION OK"
