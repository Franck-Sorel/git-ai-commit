#!/usr/bin/env zsh
# git-ai-commit: Copilot-style ghost-text completion for `git commit -m "..."`
#
# Async transport is zsh/zpty + zle -F (ADR-0001). This plugin NEVER
# blocks Zsh's main thread (rule 1) and degrades gracefully if zpty is
# unavailable or fails its self-test (ADR-0011).
#
# AGENTS.md rules are normative; see docs/ for the full baseline.

zmodload zsh/zpty 2>/dev/null || {
  print -u2 "git-ai-commit: zsh/zpty module unavailable; plugin disabled"
  return 1
}

# ---------------------------------------------------------------------------
# Config (ADR-0010): env overrides file overrides defaults.
# ---------------------------------------------------------------------------
typeset -g AI_WORKER_SCRIPT="${0:A:h}/../bin/worker.py"
typeset -g AI_PTY_NAME="git_ai_commit_worker"
typeset -g AI_HIGHLIGHT_STYLE="${GIT_AI_HIGHLIGHT_STYLE:-fg=244}"
typeset -g AI_TRIGGER="${GIT_AI_TRIGGER:-space}"   # space | keystroke | manual

# ---------------------------------------------------------------------------
# State (typeset -g so it survives widget invocations within the shell).
# ---------------------------------------------------------------------------
typeset -g AI_SUGGESTION=""
typeset -gi AI_REQUEST_ID=0
typeset -gi AI_LAST_APPLIED_ID=0
typeset -g AI_CONTEXT_PREFIX=""
typeset -g AI_ENABLED=1
typeset -g AI_ACTIVE=0          # whether a worker pty is registered

# ---------------------------------------------------------------------------
# zpty self-test + graceful degradation (ADR-0011).
# ---------------------------------------------------------------------------
_ai_zpty_selftest() {
  local name="git_ai_commit_selftest"
  zpty "$name" 'printf hello'
  local out=""
  local i
  for i in {1..20}; do
    if zpty -r -t "$name" out 2>/dev/null && [[ -n "$out" ]]; then
      break
    fi
    sleep 0.01
  done
  zpty -d "$name" 2>/dev/null
  [[ "$out" == "hello" ]]
}

# Only act on an interactive shell (where ZLE is live). When sourced from a
# plain script (`zsh -f`), the functions below remain defined (so they can be
# exercised by tests) but nothing is bound and no pty is spawned.
if [[ -o interactive ]]; then
  if ! _ai_zpty_selftest; then
    print -u2 "git-ai-commit: zpty self-test failed; suggestions disabled (shell untouched)"
    AI_ENABLED=0
  fi
fi

# Stub so callers/tests can read readiness.
_ai_ready() { (( AI_ENABLED )) }

# ---------------------------------------------------------------------------
# Context detection (docs/03 §3): only inside an OPEN -m "…" on `git commit`,
# with cursor at the very end of the buffer.
# ---------------------------------------------------------------------------
_ai_in_commit_context() {
  [[ "$RBUFFER" == "" ]] || return 1            # cursor must be at end
  [[ "$LBUFFER" == git\ commit\ * ]] || return 1
  # An OPEN message quote: a -m / -am / --message[ =] " ... with NO closing
  # quote before the end of the buffer. Anchored at end so a completed
  # message (which has a closing quote) is correctly rejected, and
  # multi-flag spellings like `-am "` are accepted (docs/03 §3).
  [[ "$LBUFFER" =~ '((-a?m|--message)[ =])\"[^\"]*$' ]]
}

# ---------------------------------------------------------------------------
# Suggestion apply / clear — single source of truth (docs/03 §2, correction).
# ---------------------------------------------------------------------------
_ai_apply_suggestion() {
  local suggestion="$1"
  POSTDISPLAY="$suggestion"
  AI_SUGGESTION="$suggestion"
  # region_highlight elements are "start end fg=N" (rule 5).
  region_highlight+=("$#BUFFER $(( $#BUFFER + ${#POSTDISPLAY} )) $AI_HIGHLIGHT_STYLE")
  AI_LAST_APPLIED_ID="$AI_REQUEST_ID"
}

_ai_clear_suggestion() {
  [[ -z "$POSTDISPLAY" && -z "$AI_SUGGESTION" ]] && return 0
  POSTDISPLAY=""
  # Remove only OUR highlight entry, never other plugins' (rule 5 / interop).
  region_highlight=("${(@)region_highlight:#*$AI_HIGHLIGHT_STYLE}")
  AI_SUGGESTION=""
}

# ---------------------------------------------------------------------------
# Async worker lifecycle (ADR-0007): lazily spawn, respawn on liveness check.
# ---------------------------------------------------------------------------
_ai_ensure_worker() {
  (( AI_ACTIVE )) && return 0
  zpty -t "$AI_PTY_NAME" 2>/dev/null && { AI_ACTIVE=1; return 0 }
  # Start the worker and register its fd with ZLE's event loop.
  zpty "$AI_PTY_NAME" python3 "$AI_WORKER_SCRIPT"
  zle -F "$AI_PTY_NAME" _ai_on_pty_readable
  AI_ACTIVE=1
}

# ---------------------------------------------------------------------------
# Request a suggestion (Rule 15: debounced on the daemon side).
# ---------------------------------------------------------------------------
_ai_json_escape() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  print -r -- "$s"
}

_ai_request_suggestion() {
  local prefix="$1"
  AI_REQUEST_ID=$(( AI_REQUEST_ID + 1 ))
  AI_CONTEXT_PREFIX="$prefix"
  _ai_ensure_worker
  local payload="{\"id\": $AI_REQUEST_ID, \"prefix\": \"$(_ai_json_escape "$prefix")\", \"cwd\": \"$(_ai_json_escape "$PWD")\"}"
  zpty -w -n "$AI_PTY_NAME" "$payload"$'\n' 2>/dev/null
}

# ---------------------------------------------------------------------------
# zle -F callback: a worker response line is ready.
# Use ONE fast local python3 call (no jq dependency; rule: no jq in callback).
# Annotated: parses id,status,suggestion and path-checks before applying.
# ---------------------------------------------------------------------------
_ai_parse_response() {
  python3 -c '
import json, sys
try:
    r = json.loads(sys.stdin.read())
    print(r.get("id", ""))
    print(r.get("status", ""))
    print(r.get("suggestion", ""))
except Exception:
    sys.exit(1)
'
}

_ai_on_pty_readable() {
  local line=""
  zpty -r -t "$AI_PTY_NAME" line 2>/dev/null || return 0
  [[ -n "$line" ]] || return 0

  local id status suggestion
  id="$(printf '%s' "$line" | _ai_parse_response)" || return 0
  status="${id#*$'\n'}"; id="${id%%$'\n'*}"
  suggestion="${status#*$'\n'}"; status="${status%%$'\n'*}"
  [[ -n "$id" ]] || return 0

  # Discard stale responses (rule 14): id must match the latest request.
  (( id == AI_REQUEST_ID )) || return 0
  [[ "$status" == "ok" ]] || return 0
  # Buffer-prefix re-check: buffer must not have moved on.
  [[ "$LBUFFER" == "$AI_CONTEXT_PREFIX" ]] || return 0
  # Only show when the cursor is at the end (rule 4).
  [[ "$CURSOR" == "${#BUFFER}" ]] || return 0

  _ai_apply_suggestion "$suggestion"
  zle -R
}
if [[ -o interactive ]]; then
  zle -N _ai_on_pty_readable
fi

# ---------------------------------------------------------------------------
# self-insert wrapper (rule 3): insert via zle .self-insert, then shrink /
# clear ghost text and (per trigger) issue a new request.
# ---------------------------------------------------------------------------
ai-self-insert() {
  local typed="$KEYS"
  local prev="$POSTDISPLAY"

  zle .self-insert        # correct, native insertion (multibyte/repeat/paste)

  if [[ -n "$prev" ]]; then
    if [[ "$typed" == "${prev[1,1]}" ]]; then
      # User typed the ghost's first char -> shrink, do not re-request.
      _ai_clear_suggestion
      _ai_apply_suggestion "${prev:1}"
    else
      _ai_clear_suggestion
    fi
  fi

  if _ai_in_commit_context; then
    # Whitespace-triggered: only fire on a completed word boundary.
    if [[ "$AI_TRIGGER" == "keystroke" ]] || [[ "$typed" == " " || "$typed" == "$'\n'" ]]; then
      _ai_request_suggestion "$LBUFFER"
    fi
  fi

  zle -R
}
if [[ -o interactive ]]; then
  zle -N self-insert ai-self-insert
fi

# ---------------------------------------------------------------------------
# Tab: accept suggestion, else fall through to expand-or-complete (rule 6).
# ---------------------------------------------------------------------------
ai-accept-suggestion() {
  if [[ -n "$POSTDISPLAY" ]]; then
    LBUFFER+="$POSTDISPLAY"
    _ai_clear_suggestion
    zle -R
  else
    zle expand-or-complete
  fi
}
if [[ -o interactive ]]; then
  zle -N ai-accept-suggestion
  bindkey '^I' ai-accept-suggestion
fi

# ---------------------------------------------------------------------------
# Ctrl+Space: manual "suggest now" (ADR-0006 fallback, always available).
# ---------------------------------------------------------------------------
ai-suggest-now() {
  if _ai_in_commit_context; then
    _ai_request_suggestion "$LBUFFER"
  else
    # Not in commit context: Ctrl+Space does nothing (no fallthrough).
    return 0
  fi
  zle -R
}
if [[ -o interactive ]]; then
  zle -N ai-suggest-now
  bindkey '^@' ai-suggest-now
fi
