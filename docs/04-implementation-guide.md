# Implementation Guide

This applies the corrections from `01-fact-check-and-refinements.md`.
Code is structural/skeleton-level and should be tested incrementally
per the checklist in §5 — it is written to be *correct in mechanism*
(real Zsh async primitives, real `region_highlight` syntax, real
current `llama.cpp` flags), not shipped as a finished, benchmarked
product.

## 1. Directory layout

```
~/.zsh/plugins/git-ai-commit/
├── git-ai-commit.plugin.zsh   # Zsh widgets (this file, §2)
├── bin/
│   ├── worker.py              # Runs inside zpty, bridges pty <-> Unix socket (§3)
│   └── daemon.py              # Long-lived: cache, debounce, llama-server client (§4)
└── README.md
```

## 2. Zsh plugin — `git-ai-commit.plugin.zsh`

```zsh
# Requires: zsh/zpty module (built into stock Zsh on macOS/Linux)
zmodload zsh/zpty 2>/dev/null || {
  print -u2 "git-ai-commit: zsh/zpty module unavailable, plugin disabled"
  return 1
}

typeset -g AI_SUGGESTION=""
typeset -gi AI_REQUEST_ID=0
typeset -g AI_CONTEXT_PREFIX=""
typeset -g AI_PTY_NAME="git_ai_commit_worker"
typeset -g AI_WORKER_SCRIPT="${0:A:h}/bin/worker.py"
typeset -g AI_HIGHLIGHT_STYLE="fg=244"

# --- context detection -------------------------------------------------
# Anchored so it only matches an OPEN quote after -m / --message on a
# git commit invocation, at the very end of the buffer.
_ai_in_commit_context() {
  [[ "$RBUFFER" == "" ]] || return 1   # cursor must be at end of buffer
  [[ "$LBUFFER" == git\ commit*(-m|--message=)\"* ]] || return 1
  # reject if the quote already closed before the cursor
  local after_quote="${LBUFFER##*(-m |--message=)\"}"
  [[ "$after_quote" != *\"* ]]
}

# --- suggestion clearing (single source of truth) -----------------------
_ai_clear_suggestion() {
  POSTDISPLAY=""
  region_highlight=("${(@)region_highlight:#*$AI_HIGHLIGHT_STYLE}")
  AI_SUGGESTION=""
}

_ai_apply_suggestion() {
  local suggestion="$1"
  POSTDISPLAY="$suggestion"
  AI_SUGGESTION="$suggestion"
  region_highlight+=("$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) $AI_HIGHLIGHT_STYLE")
}

# --- ensure the async worker is running ---------------------------------
_ai_ensure_worker() {
  zpty -t "$AI_PTY_NAME" 2>/dev/null && return 0
  zpty -b "$AI_PTY_NAME" python3 "$AI_WORKER_SCRIPT"
  # zpty -b starts it in the background and hands back a readable fd;
  # register that fd with ZLE's event loop:
  local fd
  zpty -F "$AI_PTY_NAME" _ai_on_pty_readable
}

# --- send a request ------------------------------------------------------
_ai_request_suggestion() {
  local prefix="$1"
  AI_REQUEST_ID=$(( AI_REQUEST_ID + 1 ))
  AI_CONTEXT_PREFIX="$prefix"
  _ai_ensure_worker
  local payload="{\"id\": $AI_REQUEST_ID, \"prefix\": $(_ai_json_escape "$prefix"), \"cwd\": $(_ai_json_escape "$PWD")}"
  zpty -w "$AI_PTY_NAME" "$payload"$'\n'
}

_ai_json_escape() {
  # Minimal, dependency-free JSON string escaping for a single-line value.
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  print -r -- "\"$s\""
}

# --- callback: worker pty has output ready --------------------------------
_ai_on_pty_readable() {
  local line
  zpty -r "$AI_PTY_NAME" line 2>/dev/null || return
  # response is one JSON object per line; a tiny hand-rolled parser
  # avoids a hard dependency on jq/python being callable synchronously
  # here. Use python3 -c only if a real JSON lib is available and the
  # call is guaranteed fast/local (no network) -- acceptable since this
  # runs after the async round trip already completed.
  local id status suggestion
  id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$line" 2>/dev/null) || return
  status=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status','ok'))" "$line" 2>/dev/null)
  (( id == AI_REQUEST_ID )) || return    # stale response, discard (fact-check §2.3)
  [[ "$status" == "ok" ]] || return
  suggestion=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['suggestion'])" "$line" 2>/dev/null)
  [[ "$LBUFFER" == "$AI_CONTEXT_PREFIX" ]] || return   # buffer moved on, discard
  _ai_apply_suggestion "$suggestion"
  zle -R
}
zle -N _ai_on_pty_readable

# --- self-insert wrapper --------------------------------------------------
ai-self-insert() {
  local typed="$KEYS"
  local prev_postdisplay="$POSTDISPLAY"

  zle .self-insert   # correct, original character insertion (fact-check §1.2)

  if [[ -n "$prev_postdisplay" ]]; then
    if [[ "$typed" == "${prev_postdisplay[1,1]}" ]]; then
      _ai_apply_suggestion "${prev_postdisplay:1}"    # shrink: typed through the ghost
    else
      _ai_clear_suggestion                             # mismatch: abandon suggestion
    fi
  fi

  if _ai_in_commit_context; then
    _ai_request_suggestion "$LBUFFER"
  fi

  zle -R
}
zle -N self-insert ai-self-insert

# --- Tab: accept-or-fallback ----------------------------------------------
ai-accept-suggestion() {
  if [[ -n "$POSTDISPLAY" ]]; then
    LBUFFER+="$POSTDISPLAY"
    _ai_clear_suggestion
    zle -R
  else
    zle expand-or-complete
  fi
}
zle -N ai-accept-suggestion
bindkey '^I' ai-accept-suggestion
```

Notes on deviations from both source documents, all justified in the
fact-check:
- `zle .self-insert` is called before any of our own logic touches the
  buffer (§1.2).
- `region_highlight` uses the verified `"start end fg=N"` format, and
  clearing filters the array by a style-suffix match rather than
  blanking the whole array (so this plugin doesn't clobber highlight
  entries other plugins, e.g. `zsh-syntax-highlighting`, may have
  added — neither source document considers plugin interoperability).
- Async transport is `zpty`/`zle -F`, not a FIFO-polling subshell
  (§2.2).
- Context detection is a slightly stricter pattern with a
  cursor-at-end check baked in, rather than a bare substring match
  (§3.3 low-level doc).

## 3. Worker — `bin/worker.py`

Runs *inside* the pty that `zpty` manages. Its only job: read
newline-delimited JSON from stdin (written there by Zsh via `zpty -w`),
forward it to the daemon over a Unix socket, and write the daemon's
response back to stdout (which Zsh reads via the `zle -F` callback on
the pty's fd). This indirection exists because `zpty` communicates with
a real subprocess over a pty, while the daemon speaks a plain Unix
socket — the worker bridges the two without either side blocking Zsh.

```python
#!/usr/bin/env python3
import json
import socket
import sys

SOCKET_PATH = "/tmp/git-ai-commit.sock"  # see daemon.py for the real,
                                          # non-guessable path recommendation

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.connect(SOCKET_PATH)
                sock.sendall((line + "\n").encode())
                sock.shutdown(socket.SHUT_WR)
                chunks = []
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    chunks.append(chunk)
                response = b"".join(chunks).decode()
        except OSError as e:
            req = json.loads(line)
            response = json.dumps({
                "id": req.get("id"),
                "status": "error",
                "message": f"daemon unreachable: {e}",
            })
        sys.stdout.write(response.strip() + "\n")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
```

## 4. Daemon — `bin/daemon.py`

```python
#!/usr/bin/env python3
"""Long-lived daemon: debounces requests, caches `git diff --cached`
per working directory, and calls llama-server's OpenAI-compatible
completion endpoint. One instance can serve multiple concurrent
terminal tabs/workers.
"""
import asyncio
import json
import subprocess
import time
from pathlib import Path

import aiohttp

SOCKET_PATH = "/tmp/git-ai-commit.sock"
# Use the OpenAI-compatible surface, not the legacy /completion route
# (fact-check §4.5) so llama-server can be swapped for another
# OpenAI-compatible local server without touching this file.
LLAMA_URL = "http://127.0.0.1:8080/v1/completions"
DEBOUNCE_SECONDS = 0.25
DIFF_CACHE_TTL_SECONDS = 300
DIFF_MAX_CHARS = 4000  # tune against your model's context window and
                        # --ctx-size / --parallel split (fact-check §4.4)


class DiffCache:
    def __init__(self):
        self._cache: dict[str, tuple[float, str]] = {}

    def get(self, cwd: str) -> str:
        now = time.time()
        cached = self._cache.get(cwd)
        if cached and (now - cached[0]) < DIFF_CACHE_TTL_SECONDS:
            return cached[1]
        try:
            diff = subprocess.run(
                ["git", "-C", cwd, "diff", "--cached"],
                capture_output=True, text=True, timeout=5,
            ).stdout[:DIFF_MAX_CHARS]
        except Exception:
            diff = ""
        self._cache[cwd] = (now, diff)
        return diff


class Daemon:
    def __init__(self):
        self.diff_cache = DiffCache()
        self.latest_id = 0
        self.session: aiohttp.ClientSession | None = None

    async def handle_client(self, reader, writer):
        data = await reader.readline()
        if not data:
            writer.close()
            return
        try:
            req = json.loads(data.decode())
        except json.JSONDecodeError:
            writer.close()
            return

        req_id = req.get("id")
        prefix = req.get("prefix", "")
        cwd = req.get("cwd", ".")
        self.latest_id = max(self.latest_id, req_id)

        await asyncio.sleep(DEBOUNCE_SECONDS)
        if req_id != self.latest_id:
            # superseded while debouncing — drop silently (fact-check §2.3)
            writer.close()
            return

        diff = self.diff_cache.get(cwd)
        prompt = self._build_prompt(diff, prefix)

        try:
            assert self.session is not None
            async with self.session.post(
                LLAMA_URL,
                json={
                    "prompt": prompt,
                    "max_tokens": 40,
                    "temperature": 0.2,
                    "stop": ["\n"],
                },
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                result = await resp.json()
                suggestion = result["choices"][0]["text"].strip()
            response = {"id": req_id, "status": "ok", "suggestion": suggestion}
        except Exception as e:
            response = {"id": req_id, "status": "error", "message": str(e)}

        if req_id == self.latest_id:  # still current after the HTTP round trip
            writer.write((json.dumps(response) + "\n").encode())
            await writer.drain()
        writer.close()

    @staticmethod
    def _build_prompt(diff: str, prefix: str) -> str:
        return (
            "You are an expert software engineer writing a git commit "
            "message in Conventional Commits format. Given the staged "
            "diff and the partial message already typed, output ONLY "
            "the remaining text that completes the message. Do not "
            "repeat the partial message. Do not output code or "
            "explanations.\n\n"
            f"Diff:\n{diff}\n\n"
            f"Partial message: {prefix}\n"
            "Completion:"
        )

    async def run(self):
        self.session = aiohttp.ClientSession()
        sock_path = Path(SOCKET_PATH)
        if sock_path.exists():
            sock_path.unlink()
        server = await asyncio.start_unix_server(self.handle_client, path=SOCKET_PATH)
        sock_path.chmod(0o600)  # restrict to the owning user
        async with server:
            await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(Daemon().run())
```

Deviations from both source documents, justified in the fact-check:
- Diff cache is keyed **per working directory**, not global — the
  original daemon skeleton assumed one repo per daemon instance, which
  breaks the moment two terminal tabs in different repos are both
  active (neither source document raised this).
- Socket file permissions are explicitly restricted (`0o600`) — this
  socket can trigger local LLM inference and read `git diff` output;
  neither source document addresses that it's a local, single-user
  attack surface worth locking down.
- Targets `/v1/completions` (fact-check §4.5), not the legacy
  `/completion` path either source document uses.
- Still-current check after the HTTP call, mirroring the low-level
  doc's state machine (§5), so a slow, now-superseded response isn't
  written back at all.

## 5. `llama-server` invocation

```bash
llama-server \
  --model /path/to/model-Q4_K_M.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  --ctx-size 4096 \
  --parallel 4 \
  --cont-batching \
  --load-mode mlock \
  --threads "$(nproc)"
```

- `--cont-batching` and `--parallel 4` are passed **explicitly** rather
  than relied on as defaults, because the shipped default for both has
  changed across `llama.cpp` versions (fact-check §4.1, §4.3).
- `--load-mode mlock` replaces the deprecated `--mlock` flag
  (fact-check §4.2). If running against an older `llama.cpp` build
  that predates `--load-mode`, fall back to `--mlock` and note the
  version constraint in your deployment docs.
- Pick a **causal decoder-only** instruct model (e.g. a current small
  Qwen/SmolLM/Phi-family GGUF — verify availability at deployment
  time, per fact-check §3.2), not a T5/CodeT5 checkpoint (fact-check
  §3.1).

## 6. Testing checklist (mechanism-level, not a benchmark)

1. `zmodload zsh/zpty` succeeds on the target OS/Zsh build before
   anything else is tested.
2. Typing `git commit -m "` with a non-empty `git diff --cached`
   produces a `POSTDISPLAY` suggestion within roughly one debounce
   interval plus one inference call.
3. Typing a character matching the suggestion's first character
   shrinks `POSTDISPLAY` without issuing a new request (verify via a
   daemon-side request counter — this should *not* increment on every
   keystroke, only on mismatches/new context entries).
4. Typing a character that does **not** match clears `POSTDISPLAY` and
   `region_highlight` immediately, with the mismatched character
   inserted normally.
5. `Tab` with an active suggestion appends it to `LBUFFER` and clears
   state. `Tab` with no suggestion still performs normal file/argument
   completion (test this in a directory with completable filenames —
   this exercises the fallback path, which is easy to get wrong).
6. Two requests fired in rapid succession (simulate fast typing) —
   confirm only the response matching the *current* buffer is ever
   applied; the earlier one is silently dropped (add temporary logging
   in the daemon to confirm this rather than assuming it from the
   code).
7. Kill `llama-server` mid-session; confirm the shell does not hang —
   the worker/daemon `status: "error"` path should surface as "no
   suggestion appears," never as a frozen prompt.
8. Open two terminal tabs in two different git repos against the same
   daemon; confirm diffs don't cross-contaminate (tests the per-`cwd`
   cache key).
